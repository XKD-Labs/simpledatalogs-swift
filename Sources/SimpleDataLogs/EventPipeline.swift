import Foundation

/// The commands the facade sends to the pipeline, processed strictly in call order.
enum PipelineCommand: Sendable {
    /// Recover the outbox from disk and resend whatever a previous launch left.
    case start

    /// Journal one event.
    case track(TrackedEvent)

    /// Turn collection on or off; off also deletes every unsent event.
    case setEnabled(Bool)

    /// Seal and send now, then resume the continuation, if any, when that attempt ends.
    case flush(CheckedContinuation<Void, Never>?)

    /// Signal the semaphore once every earlier command is applied, so termination can wait for the journal.
    case journalBarrier(DispatchSemaphore)
}

/// The actor behind the facade: batching, the disk outbox, and a send loop with backoff and 401 re-probes.
actor EventPipeline {
    /// Waits out a delay; tests swap in one that records the delay instead of sleeping.
    typealias DelayWaiter = @Sendable (TimeInterval) async throws -> Void

    /// Picks the full-jitter fraction in 0...1; tests pin it.
    typealias JitterSource = @Sendable () -> Double

    /// The production waiter: a real, cancellable sleep.
    static let sleepingWaiter: DelayWaiter = { delay in
        try await Task.sleep(for: .seconds(delay))
    }

    // MARK: - Dependencies

    /// Every tunable, from the ingest API defaults or a test.
    private let configuration: PipelineConfiguration

    /// Sends one batch and classifies the response.
    private let ingestClient: IngestClient

    /// The journal and the sealed batches on disk.
    private let outbox: EventOutbox

    /// Waits out retry backoffs and 401 probe intervals.
    private let waitForDelay: DelayWaiter

    /// Supplies the full-jitter fraction.
    private let jitterSource: JitterSource

    /// Tells the facade one queued track command was applied, so its pending-track count goes down.
    private let onTrackHandled: @Sendable () -> Void

    // MARK: - State

    /// False after an opt-out.
    private var isEnabled: Bool

    /// True once `start()` has recovered the outbox.
    private var hasStarted = false

    /// True while a 401 holds sending until a re-probe gets through.
    private(set) var isSendingPaused = false

    /// True while waiting out a backoff after a failed send.
    private(set) var isBackingOff = false

    /// Failed sends in a row, which sets the backoff ceiling.
    private var consecutiveFailureCount = 0

    /// Re-probes booked during the current 401 pause.
    private var invalidKeyProbeCount = 0

    /// The batch whose file failed to read, and how many times in a row.
    private var unreadableBatchStreak: (batch: SealedBatch, failureCount: Int)?

    /// Fires when a partial batch has waited the batch interval.
    private var batchTimerTask: Task<Void, Never>?

    /// Fires when a backoff ends.
    private var retryTimerTask: Task<Void, Never>?

    /// Fires when it is time to re-probe a rejected key.
    private var invalidKeyProbeTask: Task<Void, Never>?

    /// The running send loop, if any.
    private var sendTask: Task<Void, Never>?

    /// Identifies the newest send loop, so a cancelled one never clears its replacement.
    private var sendLoopGeneration = 0

    /// Wires the pipeline to its outbox folder and session; nothing touches disk or network until `start()`.
    init(
        configuration: PipelineConfiguration,
        session: URLSession,
        isEnabled: Bool,
        waitForDelay: @escaping DelayWaiter = EventPipeline.sleepingWaiter,
        jitterSource: @escaping JitterSource = { Double.random(in: 0...1) },
        onTrackHandled: @escaping @Sendable () -> Void = {}
    ) {
        self.configuration = configuration
        self.onTrackHandled = onTrackHandled
        self.isEnabled = isEnabled
        self.waitForDelay = waitForDelay
        self.jitterSource = jitterSource
        self.outbox = EventOutbox(
            directory: configuration.storageDirectory,
            limits: configuration.outboxLimits,
            fileProtection: configuration.fileProtection
        )
        self.ingestClient = IngestClient(
            session: session,
            ingestURL: configuration.ingestURL,
            ingestKey: configuration.ingestKey,
            requestTimeout: configuration.requestTimeout
        )
    }

    /// Events still waiting in the journal and the sealed batches.
    var pendingEventCount: Int {
        outbox.totalEventCount
    }

    // MARK: - Commands

    /// Processes facade commands one at a time, in the order they were sent.
    func run(commands: AsyncStream<PipelineCommand>) async {
        for await command in commands {
            handle(command)
        }
    }

    /// Applies one facade command.
    func handle(_ command: PipelineCommand) {
        switch command {
        case .start:
            start()
        case .track(let event):
            enqueue(event)
            onTrackHandled()
        case .setEnabled(let shouldEnable):
            setEnabled(shouldEnable)
        case .flush(let flushContinuation):
            // A flush awaits the network, so it runs beside the command loop; it may also pick up events queued after it, which is harmless.
            Task {
                await self.flush()
                flushContinuation?.resume()
            }
        case .journalBarrier(let barrierSemaphore):
            // Commands apply synchronously and in order, so every earlier event is already in the journal.
            barrierSemaphore.signal()
        }
    }

    /// Recovers the outbox from disk, then resends whatever a previous launch could not deliver.
    func start() {
        guard !hasStarted else {
            return
        }

        hasStarted = true

        // Seal leftover journals and index the sealed batches; a broken disk only costs persistence.
        do {
            try outbox.recoverAfterLaunch()
        } catch {
            SDKLog.outbox.error("Could not create the outbox folder: \(error.localizedDescription, privacy: .public)")
        }

        // An opted-out user's leftovers are deleted, never sent.
        guard isEnabled else {
            outbox.deleteEverything()
            return
        }

        // The first send of a launch doubles as the re-probe for a key the last launch saw rejected.
        startSendingIfIdle()
    }

    /// Journals one event, sealing and sending as soon as the batch is full.
    func enqueue(_ event: TrackedEvent) {
        guard isEnabled else {
            return
        }

        // Encode now, so a broken event never reaches the disk.
        let eventLine: Data
        do {
            eventLine = try event.encodedLine()
        } catch {
            SDKLog.pipeline.error("Dropped event \(event.eventName, privacy: .public): it could not be encoded as JSON")
            return
        }

        // An event that alone overfills a request body could never be sent.
        guard EventOutbox.storedByteCount(of: eventLine) <= configuration.maxRequestBytes else {
            SDKLog.pipeline.error("Dropped event \(event.eventName, privacy: .public): \(eventLine.count) bytes is over the request limit")
            return
        }

        // Seal first when the journal is full; if that fails, drop this event rather than overfill a request.
        if outbox.wouldJournalOverflow(adding: eventLine), !sealJournalAndSend() {
            SDKLog.outbox.error("Dropped event \(event.eventName, privacy: .public): the full journal could not be sealed")
            return
        }

        // Journal it, so a crash from here on loses nothing.
        do {
            try outbox.appendToJournal(eventLine)
        } catch {
            SDKLog.outbox.error("Dropped event \(event.eventName, privacy: .public): the journal is not writable (\(error.localizedDescription, privacy: .public))")
            return
        }

        // A full batch goes out now; a partial one waits for the batch timer.
        if outbox.journalEventCount >= configuration.maxBatchEventCount {
            sealJournalAndSend()
        } else {
            startBatchTimerIfNeeded()
        }
    }

    /// Turns collection on or off; turning it off stops all sending and deletes every unsent event.
    func setEnabled(_ shouldEnable: Bool) {
        guard shouldEnable != isEnabled else {
            return
        }

        isEnabled = shouldEnable

        // Turning collection back on needs nothing more; the next event starts a new batch.
        guard !shouldEnable else {
            return
        }

        // Stop every timer and any in-flight request.
        cancelBackgroundWork()

        // An opt-out removes everything not yet delivered.
        outbox.deleteEverything()
        SDKLog.pipeline.info("Collection disabled; deleted every unsent event")
    }

    /// Seals the journal and sends every sealed batch now, unless a 401 pause or a backoff says to wait.
    func flush() async {
        guard isEnabled else {
            return
        }

        sealJournalAndSend()
        await sendTask?.value
    }

    /// Cancels every timer and any in-flight send, and forgets backoff and 401 state.
    func cancelBackgroundWork() {
        batchTimerTask?.cancel()
        retryTimerTask?.cancel()
        invalidKeyProbeTask?.cancel()
        sendTask?.cancel()

        batchTimerTask = nil
        retryTimerTask = nil
        invalidKeyProbeTask = nil
        sendTask = nil

        // With no timers left, nothing would ever lift a pause or a backoff, so reset both.
        isSendingPaused = false
        isBackingOff = false
        consecutiveFailureCount = 0
        invalidKeyProbeCount = 0
        unreadableBatchStreak = nil
    }

    // MARK: - Batching

    /// Seals the journal into a batch and makes sure the send loop is running; returns false when sealing failed.
    @discardableResult
    private func sealJournalAndSend() -> Bool {
        let didSeal = sealJournal()
        startSendingIfIdle()

        return didSeal
    }

    /// Seals the journal into a batch without starting a send; returns false when sealing failed.
    @discardableResult
    private func sealJournal() -> Bool {
        do {
            try outbox.sealJournal()
        } catch {
            // Keep (or restart) the batch timer, so the partial batch is tried again later.
            SDKLog.outbox.error("Could not seal the journal: \(error.localizedDescription, privacy: .public)")
            startBatchTimerIfNeeded()
            return false
        }

        // A sealed journal no longer needs its timer.
        batchTimerTask?.cancel()
        batchTimerTask = nil

        return true
    }

    /// Starts the batch timer when a partial batch begins.
    private func startBatchTimerIfNeeded() {
        guard batchTimerTask == nil else {
            return
        }

        let batchInterval = configuration.batchInterval
        batchTimerTask = Task {
            // Cancellation means the batch was sealed early or collection stopped.
            try? await Task.sleep(for: batchInterval)
            guard !Task.isCancelled else {
                return
            }

            self.batchTimerTask = nil

            // While a backoff or a 401 pause holds sending, the journal keeps growing instead of sealing one tiny file per interval.
            guard self.canSendNow else {
                return
            }

            self.sealJournalAndSend()
        }
    }

    // MARK: - Sending

    /// True when nothing holds sending back right now.
    private var canSendNow: Bool {
        isEnabled && !isSendingPaused && !isBackingOff
    }

    /// Starts the send loop unless it is already running, paused by a 401, or waiting out a backoff.
    @discardableResult
    private func startSendingIfIdle() -> Task<Void, Never>? {
        // Batches a locked device kept out of the index join the queue once they read.
        outbox.indexBatchesSkippedWhileLocked()

        // A running loop picks up newly sealed batches by itself.
        if let sendTask {
            return sendTask
        }

        guard canSendNow, outbox.oldestSealedBatch != nil else {
            return nil
        }

        return startSendLoop(probingWith: nil)
    }

    /// Launches a send loop, sending a 401 probe batch first when one is given.
    @discardableResult
    private func startSendLoop(probingWith probeBatch: SealedBatch?) -> Task<Void, Never> {
        sendLoopGeneration += 1
        let generation = sendLoopGeneration

        let sendLoopTask = Task {
            await self.runSendLoop(generation: generation, probeBatch: probeBatch)
        }
        sendTask = sendLoopTask

        return sendLoopTask
    }

    /// Sends sealed batches oldest first until the outbox is empty or a response says to stop.
    private func runSendLoop(generation: Int, probeBatch: SealedBatch?) async {
        var shouldKeepSending = true

        // A 401 re-probe goes first; only a 202 or a 413 ends the pause.
        if let probeBatch {
            shouldKeepSending = await send(probeBatch)

            // A probe batch that vanished from disk got no answer, so the pause holds and needs its next probe.
            if isSendingPaused, invalidKeyProbeTask == nil, !Task.isCancelled {
                scheduleInvalidKeyProbe()
            }
        }

        // Drain the outbox while every response is a 202 (or a 413 split).
        while shouldKeepSending, canSendNow, !Task.isCancelled, let nextBatch = outbox.oldestSealedBatch {
            shouldKeepSending = await send(nextBatch)
        }

        // Clear the handle only if a newer loop has not replaced this one.
        if sendLoopGeneration == generation {
            sendTask = nil
        }
    }

    /// Sends one batch and applies the ingest API rule for its response; returns whether to keep sending.
    private func send(_ batch: SealedBatch) async -> Bool {
        // A vanished file is skipped; a locked one waits for the unlock; an unreadable one is retried, then set aside.
        let batchBody: Data
        do {
            guard let storedBody = try outbox.body(of: batch) else {
                return true
            }

            batchBody = storedBody
        } catch OutboxReadError.protectedDataUnavailable {
            return handleLockedBatch()
        } catch {
            return handleUnreadableBatch(batch, error: error)
        }

        // A readable batch ends any read-failure streak.
        unreadableBatchStreak = nil

        let outcome = await ingestClient.send(batchBody)

        // An opt-out or shutdown mid-request already dealt with the outbox, so this answer no longer matters.
        guard isEnabled, !Task.isCancelled else {
            return false
        }

        switch outcome {
        case .accepted:
            endInvalidKeyPauseIfNeeded()
            consecutiveFailureCount = 0
            outbox.delete(batch)
            return true
        case .invalidKey:
            pauseForInvalidKey()
            return false
        case .payloadTooLarge:
            // Ingest authenticates before it weighs the body, so a 413 also proves the key works.
            endInvalidKeyPauseIfNeeded()
            return splitTooLargeBatch(batch, body: batchBody)
        case .unsupported:
            // Resending it unchanged can never work, so it is set aside and the next batch goes.
            endInvalidKeyPauseIfNeeded()
            SDKLog.pipeline.error("Ingest refused a batch of \(batch.eventCount) events as unsupported (415); it was set aside")
            outbox.setAside(batch, fileExtension: EventOutbox.unsupportedFileExtension)
            return true
        case .retryable(let retryAfter, let reason):
            handleFailedSend(retryAfter: retryAfter, reason: reason)
            return false
        }
    }

    /// Backs off after a failed send; during a 401 pause it books the next probe instead, since the key is still unproven.
    private func handleFailedSend(retryAfter: TimeInterval?, reason: String) {
        guard isSendingPaused else {
            scheduleRetry(retryAfter: retryAfter, reason: reason)
            return
        }

        // A probe lost in transit (offline, timeout, 503) says nothing about the key, so the pause holds.
        SDKLog.pipeline.notice("Key re-probe got no answer (\(reason, privacy: .public)); sending stays paused")
        scheduleInvalidKeyProbe(retryAfter: retryAfter)
    }

    /// Waits and reads a batch locked by data protection again; a locked read never counts toward setting it aside.
    private func handleLockedBatch() -> Bool {
        handleFailedSend(retryAfter: nil, reason: "a batch file locked until the device is unlocked")
        return false
    }

    /// Retries an unreadable batch a few times, then sets it aside so it cannot block newer batches.
    private func handleUnreadableBatch(_ batch: SealedBatch, error: any Error) -> Bool {
        // Count failures in a row on this same batch.
        let isSameBatchAsLastFailure = unreadableBatchStreak?.batch == batch
        let failureCount = isSameBatchAsLastFailure ? (unreadableBatchStreak?.failureCount ?? 0) + 1 : 1
        unreadableBatchStreak = (batch: batch, failureCount: failureCount)

        // After a few tries the batch is set aside, so it can no longer block every newer batch.
        if failureCount >= configuration.maxBatchReadAttempts {
            outbox.setAside(batch)
            unreadableBatchStreak = nil
            SDKLog.outbox.error("Set aside a batch of \(batch.eventCount) events that failed to read \(failureCount) times in a row")
            return true
        }

        // Otherwise wait and read it again, like any failed send.
        handleFailedSend(retryAfter: nil, reason: "an unreadable batch file (\(error.localizedDescription))")
        return false
    }

    /// Splits a batch the server called too large; returns whether to keep sending.
    private func splitTooLargeBatch(_ batch: SealedBatch, body batchBody: Data) -> Bool {
        do {
            switch try outbox.splitInHalf(batch, body: batchBody) {
            case .split:
                SDKLog.pipeline.notice("Ingest answered 413; split a batch of \(batch.eventCount) events in half")
            case .droppedLoneEvent:
                SDKLog.pipeline.error("Ingest answered 413 for a single event; dropped it because it can never be accepted")
            case .alreadyRemoved:
                break
            }

            return true
        } catch {
            // Only a failed half-write (e.g. a full disk) resends a batch unchanged: after a backoff it gets another 413 and is split again.
            scheduleRetry(retryAfter: nil, reason: "the halves of a too-large batch could not be written")
            return false
        }
    }

    // MARK: - Backoff

    /// Waits out a full-jitter backoff, never shorter than Retry-After, then resumes sending.
    private func scheduleRetry(retryAfter: TimeInterval?, reason: String) {
        consecutiveFailureCount += 1

        // Work out the wait from the failure streak and any server hint.
        let retryDelay = configuration.retryPolicy.delay(
            afterFailureCount: consecutiveFailureCount,
            retryAfter: retryAfter,
            jitterFraction: jitterSource()
        )
        SDKLog.pipeline.notice("Send failed (\(reason, privacy: .public)); retrying in \(retryDelay, format: .fixed(precision: 1)) s")

        // Hold every send until the timer fires.
        isBackingOff = true
        retryTimerTask?.cancel()
        retryTimerTask = Task {
            try? await self.waitForDelay(retryDelay)
            guard !Task.isCancelled else {
                return
            }

            self.retryTimerTask = nil
            self.isBackingOff = false

            // Events journaled during the backoff go out with this attempt.
            self.sealJournal()
            self.startSendingIfIdle()
        }
    }

    // MARK: - 401 pause

    /// Pauses sending after a 401, keeping every event, and books a re-probe.
    private func pauseForInvalidKey() {
        // Log the configuration error once, when the pause begins, not on every failed re-probe.
        if !isSendingPaused {
            SDKLog.pipeline.error("Ingest rejected the key (401); sending is paused and events are kept. Check the key passed to configure(ingestKey:endpoint:).")
        }

        isSendingPaused = true
        scheduleInvalidKeyProbe()
    }

    /// Books the next 401 re-probe: a minute after the first rejection, then every ~10 minutes, or later if Retry-After says so.
    private func scheduleInvalidKeyProbe(retryAfter: TimeInterval? = nil) {
        let probeDelay = configuration.retryPolicy.invalidKeyProbeDelay(afterProbeCount: invalidKeyProbeCount, retryAfter: retryAfter)
        invalidKeyProbeCount += 1

        invalidKeyProbeTask?.cancel()
        invalidKeyProbeTask = Task {
            try? await self.waitForDelay(probeDelay)
            guard !Task.isCancelled else {
                return
            }

            self.invalidKeyProbeTask = nil
            self.sendInvalidKeyProbe()
        }
    }

    /// Sends the smallest sealed batch as one small request, to learn whether the key works yet.
    private func sendInvalidKeyProbe() {
        guard isEnabled, isSendingPaused else {
            return
        }

        // Events tracked during the pause are probe candidates too.
        sealJournal()

        // With nothing to send, or a loop still finishing, there is nothing to learn yet.
        guard sendTask == nil, let probeBatch = outbox.smallestSealedBatch else {
            scheduleInvalidKeyProbe()
            return
        }

        startSendLoop(probingWith: probeBatch)
    }

    /// Ends a 401 pause once a 202 or 413 shows the key is accepted again.
    private func endInvalidKeyPauseIfNeeded() {
        guard isSendingPaused else {
            return
        }

        isSendingPaused = false
        invalidKeyProbeCount = 0
        invalidKeyProbeTask?.cancel()
        invalidKeyProbeTask = nil

        SDKLog.pipeline.info("Ingest accepted the key again; sending resumed")
    }
}

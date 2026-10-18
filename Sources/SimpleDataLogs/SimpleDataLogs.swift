import os
import Foundation

/// The public entry point: configure once at launch, then track events from any thread.
public enum SimpleDataLogs: Sendable {
    /// This SDK's version, sent in every User-Agent.
    public static let sdkVersion = "0.3.0"

    /// The production ingest host.
    public static let defaultEndpoint = URL(string: "https://edge.simpledatalogs.com")!

    /// The longest app termination is held so events tracked during it reach the journal.
    static let terminationJournalWaitLimit = DispatchTimeInterval.seconds(1)

    /// The facade's settings and the pipeline's command inbox, behind one lock.
    private static let facadeState = OSAllocatedUnfairLock(initialState: FacadeState())

    // MARK: - Public API

    /// The running autocapture, kept for the life of the process once `configure` turns it on.
    private static let autocaptureController = OSAllocatedUnfairLock<AutocaptureController?>(initialState: nil)

    /// Starts the SDK; call once at launch, after `setEnabled(_:)` if the user may have opted out; `autocapture: .all` sends launches, sessions and crashes.
    public static func configure(ingestKey: String, endpoint: URL = defaultEndpoint, autocapture: AutocaptureOptions = []) {
        // Trim copy-paste whitespace, and warn about a key that cannot work in an app.
        let trimmedIngestKey = ingestKey.trimmingCharacters(in: .whitespacesAndNewlines)
        warnAboutSuspiciousKey(trimmedIngestKey)

        // Claim the single pipeline slot and queue `.start` first, so every later command follows it.
        let (commandStream, commandContinuation) = AsyncStream.makeStream(of: PipelineCommand.self)
        let isEnabledAtLaunch: Bool? = facadeState.withLock { state in
            guard state.commandContinuation == nil else {
                return nil
            }

            state.commandContinuation = commandContinuation
            commandContinuation.yield(.start)
            return state.isEnabled
        }

        guard let isEnabledAtLaunch else {
            SDKLog.facade.warning("configure(ingestKey:endpoint:) was called again; the first configuration stays in effect")
            return
        }

        // Build the pipeline with the ingest API defaults and run it off the caller's thread.
        let configuration = PipelineConfiguration(
            ingestURL: ingestURL(for: endpoint),
            ingestKey: trimmedIngestKey,
            storageDirectory: StorageLocation.defaultDirectory()
        )
        let session = IngestClient.makeDefaultSession(requestTimeout: configuration.requestTimeout)
        let pipeline = EventPipeline(
            configuration: configuration,
            session: session,
            isEnabled: isEnabledAtLaunch,
            onTrackHandled: { SimpleDataLogs.releaseTrackSlot() }
        )

        Task.detached(priority: .utility) {
            await pipeline.run(commands: commandStream)
        }

        // Flush when the app terminates, the Mac sleeps, or an iOS app moves to the background.
        LifecycleFlushObserver.startObserving { lifecycleMoment in
            handleLifecycleMoment(lifecycleMoment)
        }

        // Opt-in autocapture: launches, sessions and crashes, as asked.
        startAutocapture(autocapture, storageDirectory: configuration.storageDirectory)
    }

    /// Records a screen view (`screen_view` with a `screen` prop); call it when a screen appears, or use the SwiftUI `trackScreenView(_:)` modifier.
    public static func trackScreen(_ screenName: String, properties: [String: PropertyValue] = [:]) {
        track("screen_view", properties: properties.merging(["screen": .string(screenName)]) { _, screenValue in screenValue })
    }

    /// Records one event; it returns at once, and never throws or blocks the caller.
    public static func track(_ eventName: String, properties: [String: PropertyValue] = [:]) {
        // An empty name cannot become an event.
        guard !eventName.isEmpty else {
            SDKLog.facade.error("track(_:properties:) was called with an empty event name; event dropped")
            return
        }

        // Drop NaN and infinity before the event is stamped.
        let validProperties = properties.droppingNonJSONValues()

        // Stamp event_id and ts now, when the event happens, and queue it in call order, within the pending-track cap.
        let occurredAt = Date()
        let queueResult = queueTrack { state in
            guard state.isEnabled else {
                return nil
            }

            let event = TrackedEvent.make(
                eventName: eventName,
                properties: validProperties,
                defaultProperties: state.defaultProperties,
                deviceID: state.deviceID,
                sessionID: state.sessionID,
                occurredAt: occurredAt
            )
            return .track(event)
        }

        // Tracking before configure is a setup bug worth a log line.
        if queueResult == .notConfigured {
            SDKLog.facade.error("track(\(eventName, privacy: .public)) was called before configure(ingestKey:endpoint:); event dropped")
        }

        // While the app terminates, wait briefly for the journal write, since the process may exit any moment.
        if queueResult == .queued {
            waitForJournalIfTerminating()
        }
    }

    /// Queues an autocaptured event with its own time and session id (a session_end after the session changed, a crash from the last launch).
    static func trackAutocaptured(_ eventName: String, properties: [String: PropertyValue], occurredAt: Date, sessionID: String?) {
        let validProperties = properties.droppingNonJSONValues()

        _ = queueTrack { state in
            guard state.isEnabled else {
                return nil
            }

            let event = TrackedEvent.make(
                eventName: eventName,
                properties: validProperties,
                defaultProperties: state.defaultProperties,
                deviceID: state.deviceID,
                sessionID: sessionID,
                occurredAt: occurredAt
            )
            return .track(event)
        }
    }

    /// Sets the session id on every later event; autocapture's sessions call it.
    static func setSessionID(_ sessionID: String?) {
        facadeState.withLock { state in
            state.sessionID = sessionID
        }
    }

    /// Starts the autocapture controller once, wired to the facade.
    private static func startAutocapture(_ options: AutocaptureOptions, storageDirectory: URL) {
        guard !options.isEmpty else {
            return
        }

        let controller = AutocaptureController(
            options: options,
            stateDirectory: storageDirectory,
            emit: { eventName, properties, occurredAt, sessionID in
                trackAutocaptured(eventName, properties: properties, occurredAt: occurredAt, sessionID: sessionID)
            },
            setSessionID: { sessionID in setSessionID(sessionID) }
        )

        autocaptureController.withLock { runningController in
            runningController = controller
        }

        controller.start()
        controller.observeAppActivity()
    }

    /// Sets the anonymous device id attached to every later event, or clears it with nil.
    public static func setDeviceID(_ deviceID: String?) {
        facadeState.withLock { state in
            state.deviceID = deviceID
        }
    }

    /// Replaces the properties merged into every later event, e.g. app_version, os_version, distribution.
    public static func setDefaultProperties(_ properties: [String: PropertyValue]) {
        let validProperties = properties.droppingNonJSONValues()

        facadeState.withLock { state in
            state.defaultProperties = validProperties
        }
    }

    /// Turns collection on or off; turning it off also deletes every event not yet delivered.
    public static func setEnabled(_ isEnabled: Bool) {
        facadeState.withLock { state in
            state.isEnabled = isEnabled
            state.commandContinuation?.yield(.setEnabled(isEnabled))
        }
    }

    /// Sends everything tracked so far; returns when that attempt ends, keeping anything undelivered on disk.
    public static func flush() async {
        await withCheckedContinuation { (flushContinuation: CheckedContinuation<Void, Never>) in
            let queueResult = queueCommand { state in
                state.isEnabled ? .flush(flushContinuation) : nil
            }

            // Nothing was queued, so nothing would resume the caller later.
            if queueResult != .queued {
                flushContinuation.resume()
            }
        }
    }

    // MARK: - Internal helpers

    /// Whether `queueCommand` handed a command to the pipeline.
    enum CommandQueueResult: Sendable, Equatable {
        /// The pipeline received the command.
        case queued

        /// The builder declined, e.g. after an opt-out.
        case skipped

        /// `configure` has not run yet, so there is no pipeline.
        case notConfigured
    }

    /// The ingest URL for an endpoint: `<endpoint>/v1/ingest`.
    static func ingestURL(for endpoint: URL) -> URL {
        endpoint.appending(path: "v1/ingest", directoryHint: .notDirectory)
    }

    /// Flushes on every lifecycle moment; on termination it also holds the app up to 1 s until queued events are journaled.
    static func handleLifecycleMoment(_ lifecycleMoment: LifecycleMoment) {
        // From termination on, every track call also waits for its own journal write, within one shared deadline.
        if lifecycleMoment == .terminating {
            facadeState.withLock { state in
                state.terminationDeadline = state.terminationDeadline ?? (DispatchTime.now() + terminationJournalWaitLimit)
            }
        }

        // Start a last send; whatever does not make it stays on disk for the next launch.
        _ = queueCommand { state in
            state.isEnabled ? .flush(nil) : nil
        }

        // Hold termination until everything queued so far is on disk.
        waitForJournalIfTerminating()
    }

    /// During termination, blocks until every queued event is journaled or the deadline passes; otherwise returns at once.
    private static func waitForJournalIfTerminating() {
        // Queue a barrier behind everything already queued, but only once termination has begun.
        let journalBarrier = DispatchSemaphore(value: 0)
        let terminationDeadline: DispatchTime? = facadeState.withLock { state in
            guard let terminationDeadline = state.terminationDeadline, state.isEnabled, let commandContinuation = state.commandContinuation else {
                return nil
            }

            guard case .enqueued = commandContinuation.yield(.journalBarrier(journalBarrier)) else {
                return nil
            }

            return terminationDeadline
        }

        guard let terminationDeadline else {
            return
        }

        // The pipeline runs off the main thread, so this wait cannot deadlock it.
        if journalBarrier.wait(timeout: terminationDeadline) == .timedOut {
            SDKLog.facade.warning("The app terminated before every queued event reached the journal; those events are lost")
        }
    }

    /// Gives back one pending-track slot once the pipeline applied a track command.
    static func releaseTrackSlot() {
        facadeState.withLock { state in
            state.pendingTrackCount = max(state.pendingTrackCount - 1, 0)
        }
    }

    /// Queues a track command like `queueCommand`, but only while fewer than `FacadeState.maxPendingTrackCount` wait.
    private static func queueTrack(_ makeCommand: @Sendable (FacadeState) -> PipelineCommand?) -> CommandQueueResult {
        facadeState.withLock { state in
            guard let command = makeCommand(state) else {
                return .skipped
            }

            guard let commandContinuation = state.commandContinuation else {
                return .notConfigured
            }

            // A host loop faster than the disk skips events instead of growing memory; they never got a 202, so no promise breaks.
            guard state.reserveTrackSlot() else {
                return .skipped
            }

            guard case .enqueued = commandContinuation.yield(command) else {
                state.pendingTrackCount -= 1
                return .skipped
            }

            return .queued
        }
    }

    /// Builds a command from the current state and queues it under the lock, so commands keep call order.
    private static func queueCommand(_ makeCommand: @Sendable (FacadeState) -> PipelineCommand?) -> CommandQueueResult {
        facadeState.withLock { state in
            // The builder may decline, e.g. after an opt-out.
            guard let command = makeCommand(state) else {
                return .skipped
            }

            // Before configure there is no pipeline to send to.
            guard let commandContinuation = state.commandContinuation else {
                return .notConfigured
            }

            // An unbounded stream only refuses once finished, which never happens.
            guard case .enqueued = commandContinuation.yield(command) else {
                return .skipped
            }

            return .queued
        }
    }

    /// Logs an empty key, or a secret key that belongs on servers only.
    private static func warnAboutSuspiciousKey(_ ingestKey: String) {
        if ingestKey.isEmpty {
            SDKLog.facade.error("configure(ingestKey:endpoint:) was given an empty key; ingest will answer 401")
        } else if ingestKey.hasPrefix("sdl_sec_") {
            SDKLog.facade.warning("A secret sdl_sec_ key was configured; apps should ship a public sdl_pub_ key")
        }
    }
}

/// The facade's mutable settings, guarded by `SimpleDataLogs.facadeState`.
struct FacadeState: Sendable {
    /// The pipeline's command inbox, set once by `configure`.
    var commandContinuation: AsyncStream<PipelineCommand>.Continuation?

    /// The anonymous device id attached to every event.
    var deviceID: String?

    /// The current session id, set by autocapture's sessions.
    var sessionID: String?

    /// Properties merged into every event's props.
    var defaultProperties: [String: PropertyValue] = [:]

    /// False after an opt-out: events are ignored and the outbox is deleted.
    var isEnabled = true

    /// Set when the app starts terminating; until then nothing in the SDK ever waits.
    var terminationDeadline: DispatchTime?

    /// The most track commands queued but not yet applied by the pipeline.
    static let maxPendingTrackCount = 5_000

    /// Track commands queued and not yet applied.
    var pendingTrackCount = 0

    /// True once the pending-track cap was logged, so a hot loop logs it once.
    var hasLoggedPendingTrackCap = false

    /// Takes one pending-track slot, or logs once and refuses when every slot is taken.
    mutating func reserveTrackSlot() -> Bool {
        guard pendingTrackCount < Self.maxPendingTrackCount else {
            if !hasLoggedPendingTrackCap {
                hasLoggedPendingTrackCap = true
                SDKLog.facade.warning("More than \(Self.maxPendingTrackCount) events wait for the disk; new events are skipped until it catches up")
            }

            return false
        }

        pendingTrackCount += 1
        return true
    }
}

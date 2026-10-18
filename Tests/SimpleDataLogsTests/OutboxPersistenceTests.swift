import XCTest
import Foundation

@testable import SimpleDataLogs

/// The journal and sealed batches survive a crash or quit, and the outbox never outgrows its cap.
final class OutboxPersistenceTests: PipelineTestCase {
    /// Limits small enough to exercise sealing and the cap with a handful of events.
    private let smallLimits = OutboxLimits(maxBatchEventCount: 5, maxBatchBytes: 256_000, maxTotalEventCount: 10, maxTotalBytes: 10 * 1024 * 1024)

    /// Events journaled but never sealed (a crash) are sent by the next launch, ids unchanged.
    func testJournaledEventsSurviveACrashAndAreSentOnRelaunch() async {
        let storageDirectory = makeTemporaryDirectory()

        // First launch journals three events, then "crashes" before the batch timer fires.
        let firstLaunchServer = makeServer()
        let firstLaunch = makePipeline(server: firstLaunchServer, storageDirectory: storageDirectory)
        await firstLaunch.start()
        let journaledEvents = await enqueueEvents(3, into: firstLaunch)
        await firstLaunch.cancelBackgroundWork()

        XCTAssertEqual(firstLaunchServer.requests.count, 0)
        XCTAssertTrue(hasJournal(in: storageDirectory))

        // The next launch seals the leftover journal and sends it.
        let secondLaunchServer = makeServer()
        let secondLaunch = makePipeline(server: secondLaunchServer, storageDirectory: storageDirectory)
        await secondLaunch.start()

        await waitUntil { secondLaunchServer.requests.count == 1 }
        await waitUntil { await secondLaunch.pendingEventCount == 0 }
        XCTAssertEqual(secondLaunchServer.requests.first?.eventIDs, journaledEvents.map(\.eventID.uuidString))
        XCTAssertFalse(hasJournal(in: storageDirectory))
    }

    /// A sealed batch that never got its 202 is resent by the next launch, then deleted.
    func testSealedBatchesAreResentOnRelaunch() async {
        let storageDirectory = makeTemporaryDirectory()

        // First launch seals two events, but ingest is busy.
        let busyServer = makeServer { _, _ in .status(503, retryAfter: "3600") }
        let firstLaunch = makePipeline(server: busyServer, storageDirectory: storageDirectory)
        await firstLaunch.start()
        let sealedEvents = await enqueueEvents(2, into: firstLaunch)
        await firstLaunch.flush()
        await firstLaunch.cancelBackgroundWork()

        XCTAssertEqual(busyServer.requests.count, 1)
        XCTAssertEqual(batchFileNames(in: storageDirectory).count, 1)

        // The next launch resends the same batch and deletes it after the 202.
        let healthyServer = makeServer()
        let secondLaunch = makePipeline(server: healthyServer, storageDirectory: storageDirectory)
        await secondLaunch.start()

        await waitUntil { await secondLaunch.pendingEventCount == 0 }
        XCTAssertEqual(healthyServer.requests.first?.eventIDs, sealedEvents.map(\.eventID.uuidString))
        XCTAssertEqual(batchFileNames(in: storageDirectory), [])
    }

    /// A line torn by a crash mid-append is discarded; the complete lines before it are kept.
    func testTornJournalLineIsDiscardedOnRecovery() throws {
        let storageDirectory = makeTemporaryDirectory()

        // Two whole events, then half of a third.
        var journalBody = try makeJournalBody(eventCount: 2)
        journalBody.append(Data("{\"event\":\"screensh".utf8))
        try journalBody.write(to: EventOutbox.journalURL(in: storageDirectory))

        let outbox = EventOutbox(directory: storageDirectory, limits: smallLimits)
        try outbox.recoverAfterLaunch()

        XCTAssertEqual(outbox.sealedBatches.map(\.eventCount), [2])
        XCTAssertFalse(hasJournal(in: storageDirectory))
    }

    /// A leftover journal larger than one batch is re-chunked into batches that respect the limits.
    func testRecoveryReChunksAnOversizedJournal() throws {
        let storageDirectory = makeTemporaryDirectory()

        // Twelve events with a five-event batch limit.
        try makeJournalBody(eventCount: 12).write(to: EventOutbox.journalURL(in: storageDirectory))

        let roomyLimits = OutboxLimits(maxBatchEventCount: 5, maxBatchBytes: 256_000, maxTotalEventCount: 10_000, maxTotalBytes: 10 * 1024 * 1024)
        let outbox = EventOutbox(directory: storageDirectory, limits: roomyLimits)
        try outbox.recoverAfterLaunch()

        XCTAssertEqual(outbox.sealedBatches.map(\.eventCount), [5, 5, 2])
    }

    /// Past the event cap, the oldest batches are dropped and the newest kept.
    func testEventCapDropsTheOldestBatches() throws {
        let storageDirectory = makeTemporaryDirectory()
        let outbox = EventOutbox(directory: storageDirectory, limits: smallLimits)
        try outbox.recoverAfterLaunch()

        // Three sealed batches of five events, tagged by batch number, against a cap of ten.
        for batchNumber in 1...3 {
            for _ in 0..<5 {
                try outbox.appendToJournal(makeEvent(properties: ["batch": .int(batchNumber)]).encodedLine())
            }
            try outbox.sealJournal()
        }

        // Only batches 2 and 3 remain, on disk and in the index.
        let oldestRemainingBatch = try XCTUnwrap(outbox.oldestSealedBatch)
        let oldestRemainingBody = try XCTUnwrap(outbox.body(of: oldestRemainingBatch))
        let firstRemainingEvent = try XCTUnwrap(JSONSerialization.jsonObject(with: EventOutbox.lines(in: oldestRemainingBody)[0]) as? [String: Any])
        let firstRemainingProps = try XCTUnwrap(firstRemainingEvent["props"] as? [String: Any])

        XCTAssertEqual(outbox.totalEventCount, 10)
        XCTAssertEqual(batchFileNames(in: storageDirectory).count, 2)
        XCTAssertEqual(firstRemainingProps["batch"] as? Int, 2)
    }

    /// Past the byte cap, the oldest batches are dropped too.
    func testByteCapDropsTheOldestBatches() throws {
        let storageDirectory = makeTemporaryDirectory()
        let eventLine = try makeEvent().encodedLine()

        // Room for about two five-event batches.
        let byteCappedLimits = OutboxLimits(
            maxBatchEventCount: 5,
            maxBatchBytes: 256_000,
            maxTotalEventCount: 10_000,
            maxTotalBytes: (eventLine.count + 1) * 11
        )
        let outbox = EventOutbox(directory: storageDirectory, limits: byteCappedLimits)
        try outbox.recoverAfterLaunch()

        for _ in 1...4 {
            for _ in 0..<5 {
                try outbox.appendToJournal(eventLine)
            }
            try outbox.sealJournal()
        }

        XCTAssertEqual(outbox.sealedBatches.count, 2)
        XCTAssertLessThanOrEqual(outbox.totalByteCount, byteCappedLimits.maxTotalBytes)
    }

    /// The cap also applies to what a long offline period left on disk.
    func testCapIsEnforcedOnRelaunch() throws {
        let storageDirectory = makeTemporaryDirectory()

        // An earlier launch with a roomy cap leaves four batches behind.
        let roomyLimits = OutboxLimits(maxBatchEventCount: 5, maxBatchBytes: 256_000, maxTotalEventCount: 10_000, maxTotalBytes: 10 * 1024 * 1024)
        let earlierOutbox = EventOutbox(directory: storageDirectory, limits: roomyLimits)
        try earlierOutbox.recoverAfterLaunch()
        for _ in 1...4 {
            for _ in 0..<5 {
                try earlierOutbox.appendToJournal(makeEvent().encodedLine())
            }
            try earlierOutbox.sealJournal()
        }

        // This launch's cap of ten keeps only the newest two.
        let relaunchedOutbox = EventOutbox(directory: storageDirectory, limits: smallLimits)
        try relaunchedOutbox.recoverAfterLaunch()

        XCTAssertEqual(relaunchedOutbox.totalEventCount, 10)
        XCTAssertEqual(batchFileNames(in: storageDirectory).count, 2)
    }

    /// The 401 re-probe picks the smallest sealed batch, so a still-bad key wastes little.
    func testSmallestSealedBatchIsTheCheapestProbe() throws {
        let storageDirectory = makeTemporaryDirectory()
        let outbox = EventOutbox(directory: storageDirectory, limits: smallLimits)
        try outbox.recoverAfterLaunch()

        // A five-event batch, then a one-event batch.
        for _ in 0..<5 {
            try outbox.appendToJournal(makeEvent().encodedLine())
        }
        try outbox.sealJournal()
        try outbox.appendToJournal(makeEvent().encodedLine())
        try outbox.sealJournal()

        XCTAssertEqual(outbox.oldestSealedBatch?.eventCount, 5)
        XCTAssertEqual(outbox.smallestSealedBatch?.eventCount, 1)
    }

    /// A journal set aside by an earlier failed recovery is sealed by the next launch.
    func testSetAsideJournalIsSealedOnTheNextLaunch() throws {
        let storageDirectory = makeTemporaryDirectory()
        let setAsideJournalURL = storageDirectory.appending(path: "journal-1760000000000-000001-ABCDEF12.ndjson")
        try makeJournalBody(eventCount: 2).write(to: setAsideJournalURL)

        let outbox = EventOutbox(directory: storageDirectory, limits: smallLimits)
        try outbox.recoverAfterLaunch()

        XCTAssertEqual(outbox.sealedBatches.map(\.eventCount), [2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: setAsideJournalURL.path))
    }

    /// A journal barrier signals only once every event queued before it is on disk, which termination relies on.
    func testJournalBarrierSignalsOnceEarlierEventsAreOnDisk() async throws {
        let storageDirectory = makeTemporaryDirectory()
        let pipeline = makePipeline(server: makeServer(), storageDirectory: storageDirectory)
        let (commandStream, commandContinuation) = AsyncStream.makeStream(of: PipelineCommand.self)
        let commandLoopTask = Task {
            await pipeline.run(commands: commandStream)
        }

        // Queue a launch, three events and a barrier, the way termination does.
        let journalBarrier = DispatchSemaphore(value: 0)
        commandContinuation.yield(.start)
        for _ in 0..<3 {
            commandContinuation.yield(.track(makeEvent()))
        }
        commandContinuation.yield(.journalBarrier(journalBarrier))

        // Once signalled, all three lines are in the journal file.
        let didSignal = await waitForSignal(journalBarrier)
        let journalBody = try Data(contentsOf: EventOutbox.journalURL(in: storageDirectory))
        XCTAssertTrue(didSignal)
        XCTAssertEqual(EventOutbox.lines(in: journalBody).count, 3)

        // End the command loop.
        commandContinuation.finish()
        await commandLoopTask.value
    }

    /// When sealing keeps failing, the journal never grows past one batch: the overflowing event is dropped instead.
    func testJournalNeverGrowsPastOneBatchWhenSealingFails() async throws {
        try XCTSkipIf(getuid() == 0, "root can write into a read-only folder")

        let storageDirectory = makeTemporaryDirectory()
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory) { configuration in
            configuration.maxBatchEventCount = 2
        }
        await pipeline.start()

        // A read-only batch folder makes every seal fail.
        let batchesPath = EventOutbox.batchesDirectory(in: storageDirectory).path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: batchesPath)

        // Two events fill the journal; the third would overfill it, so it is dropped.
        let keptEvents = await enqueueEvents(2, into: pipeline)
        await enqueueEvents(1, into: pipeline)

        let pendingWhileStuck = await pipeline.pendingEventCount
        XCTAssertEqual(pendingWhileStuck, 2)

        // Once the folder is writable again, the kept batch seals and goes out.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: batchesPath)
        await pipeline.flush()

        XCTAssertEqual(server.requests.map(\.eventIDs), [keptEvents.map(\.eventID.uuidString)])
    }

    /// A batch that stays unreadable is set aside after three tries in a row, so newer batches are not blocked forever.
    func testUnreadableBatchIsSetAsideAfterThreeTries() async throws {
        try XCTSkipIf(getuid() == 0, "root can read a file whatever its permissions")

        // The first request's 503 is held back until the test opens the gate.
        let storageDirectory = makeTemporaryDirectory()
        let requestGate = RequestGate()
        let server = makeServer { _, requestIndex in
            requestIndex == 0 ? MockResponse.status(503).held(by: requestGate) : .accepted
        }
        let delayRecorder = DelayRecorder(immediateReturnCount: 3)
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory, delayRecorder: delayRecorder) { configuration in
            configuration.maxBatchEventCount = 1
        }
        await pipeline.start()

        // The first batch goes out and stays in flight.
        await enqueueEvents(1, into: pipeline)
        await waitUntil { server.requests.count == 1 }

        // Its file becomes unreadable, and a newer batch queues behind it.
        let unreadableBatchName = try XCTUnwrap(batchFileNames(in: storageDirectory).first)
        let unreadableBatchURL = EventOutbox.batchesDirectory(in: storageDirectory).appending(path: unreadableBatchName)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadableBatchURL.path)
        let newerEvents = await enqueueEvents(1, into: pipeline)

        // The 503 starts the retries; three failed reads set the old batch aside, and the newer one goes out.
        requestGate.open()
        await waitUntil { server.requests.count == 2 }

        XCTAssertEqual(server.requests.last?.eventIDs, newerEvents.map(\.eventID.uuidString))
        XCTAssertEqual(delayRecorder.delays, [1, 2, 4])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadableBatchURL.appendingPathExtension("unreadable").path))
    }

    /// A batch set aside as unreadable is put back and sent by the next launch, never parked for good (reliability review, 2026-10-16).
    func testSetAsideBatchIsRetriedOnTheNextLaunch() async throws {
        let storageDirectory = makeTemporaryDirectory()

        // First launch seals two events while ingest is busy, then the batch gets set aside.
        let busyServer = makeServer { _, _ in .status(503, retryAfter: "3600") }
        let firstLaunch = makePipeline(server: busyServer, storageDirectory: storageDirectory)
        await firstLaunch.start()
        let sealedEvents = await enqueueEvents(2, into: firstLaunch)
        await firstLaunch.flush()
        await firstLaunch.cancelBackgroundWork()

        let batchName = try XCTUnwrap(batchFileNames(in: storageDirectory).first)
        let batchURL = EventOutbox.batchesDirectory(in: storageDirectory).appending(path: batchName)
        try FileManager.default.moveItem(at: batchURL, to: batchURL.appendingPathExtension(EventOutbox.setAsideFileExtension))

        // The next launch restores and sends it.
        let healthyServer = makeServer()
        let secondLaunch = makePipeline(server: healthyServer, storageDirectory: storageDirectory)
        await secondLaunch.start()

        await waitUntil { await secondLaunch.pendingEventCount == 0 }
        XCTAssertEqual(healthyServer.requests.first?.eventIDs, sealedEvents.map(\.eventID.uuidString))
        XCTAssertEqual(batchFileNames(in: storageDirectory), [])
    }

    /// Splitting a batch that already left the outbox writes nothing back.
    func testSplittingABatchNoLongerInTheOutboxChangesNothing() throws {
        let storageDirectory = makeTemporaryDirectory()
        let outbox = EventOutbox(directory: storageDirectory, limits: smallLimits)
        try outbox.recoverAfterLaunch()

        // Seal a batch, read it as the send loop would, then let it leave the outbox.
        for _ in 0..<2 {
            try outbox.appendToJournal(makeEvent().encodedLine())
        }
        try outbox.sealJournal()
        let inFlightBatch = try XCTUnwrap(outbox.oldestSealedBatch)
        let inFlightBody = try XCTUnwrap(outbox.body(of: inFlightBatch))
        outbox.delete(inFlightBatch)

        XCTAssertEqual(try outbox.splitInHalf(inFlightBatch, body: inFlightBody), .alreadyRemoved)
        XCTAssertEqual(batchFileNames(in: storageDirectory), [])
    }

    /// An NDJSON journal body holding `eventCount` fresh events.
    private func makeJournalBody(eventCount: Int) throws -> Data {
        var journalBody = Data()

        for _ in 0..<eventCount {
            journalBody.append(try makeEvent().encodedLine())
            journalBody.append(UInt8(ascii: "\n"))
        }

        return journalBody
    }
}

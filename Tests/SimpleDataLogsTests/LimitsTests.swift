import os
import XCTest
import Foundation

@testable import SimpleDataLogs

/// The SDK's bounds: the pending-track cap, the sealed-file cap, no sealing during a backoff, and 415.
final class LimitsTests: PipelineTestCase {
    /// Past 5,000 queued track commands, new ones are refused until the pipeline applies some.
    func testThePendingTrackCapRefusesTheNextEventUntilASlotFrees() {
        var facadeState = FacadeState()

        for _ in 0..<FacadeState.maxPendingTrackCount {
            XCTAssertTrue(facadeState.reserveTrackSlot())
        }

        XCTAssertFalse(facadeState.reserveTrackSlot())
        XCTAssertTrue(facadeState.hasLoggedPendingTrackCap)

        // The pipeline applied one, so one more fits.
        facadeState.pendingTrackCount -= 1
        XCTAssertTrue(facadeState.reserveTrackSlot())
    }

    /// The pipeline reports every applied track command, so the facade's count comes back down.
    func testThePipelineReportsEachAppliedTrack() async {
        let server = makeServer()
        let handledCount = OSAllocatedUnfairLock(initialState: 0)

        var configuration = PipelineConfiguration(ingestURL: server.ingestURL, ingestKey: Self.testIngestKey, storageDirectory: makeTemporaryDirectory())
        configuration.batchInterval = .seconds(3600)

        let pipeline = EventPipeline(
            configuration: configuration,
            session: server.makeSession(),
            isEnabled: true,
            waitForDelay: DelayRecorder().waiter,
            jitterSource: { 1 },
            onTrackHandled: { handledCount.withLock { count in count += 1 } }
        )
        addTeardownBlock { await pipeline.cancelBackgroundWork() }

        await pipeline.handle(.start)
        for _ in 0..<7 {
            await pipeline.handle(.track(makeEvent()))
        }

        XCTAssertEqual(handledCount.withLock { count in count }, 7)
    }

    /// The outbox keeps at most its sealed-file cap, dropping the oldest batches first.
    func testTheOutboxKeepsAtMostItsSealedBatchCount() throws {
        var limits = OutboxLimits(maxBatchEventCount: 1, maxBatchBytes: 256_000, maxTotalEventCount: 10_000, maxTotalBytes: 10 * 1024 * 1024)
        limits.maxSealedBatchCount = 20

        let outbox = EventOutbox(directory: makeTemporaryDirectory(), limits: limits)
        try outbox.recoverAfterLaunch()

        for eventNumber in 0..<50 {
            try outbox.appendToJournal(Data("{\"event\":\"tap\",\"n\":\(eventNumber)}".utf8))
            try outbox.sealJournal()
        }

        XCTAssertEqual(outbox.sealedBatches.count, 20)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outbox.batchesDirectory.path).count, 20)
    }

    /// While a backoff holds sending, batch-interval timers seal nothing, so an offline app never leaves one file per event.
    func testNoBatchIsSealedWhileABackoffHoldsSending() async throws {
        let storageDirectory = makeTemporaryDirectory()
        let server = makeServer { _, _ in .status(503) }
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory) { configuration in
            configuration.batchInterval = .milliseconds(50)
        }
        await pipeline.start()

        // The first event's batch fails and starts a backoff that never ends in this test.
        await enqueueEvents(1, into: pipeline)
        await waitUntil { server.requests.count == 1 }
        await waitUntil { await pipeline.isBackingOff }

        // Thirty more events, each followed by a batch interval.
        for _ in 0..<30 {
            await enqueueEvents(1, into: pipeline)
            try await Task.sleep(for: .milliseconds(60))
        }

        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertLessThanOrEqual(batchFileNames(in: storageDirectory).filter { name in name.hasSuffix(".ndjson") }.count, 1)
        XCTAssertEqual(pendingEventCount, 31)
        XCTAssertEqual(server.requests.count, 1)
    }

    /// A 415 sets the batch aside for good and the next batch goes.
    func testA415SetsTheBatchAsideAndTheNextOneGoes() async {
        let storageDirectory = makeTemporaryDirectory()
        let server = makeServer { _, requestIndex in requestIndex == 0 ? .status(415) : .accepted }
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory)
        await pipeline.start()

        await enqueueEvents(60, into: pipeline)
        await pipeline.flush()

        await waitUntil { server.requests.count == 2 }
        await waitUntil { await pipeline.pendingEventCount == 0 }
        XCTAssertEqual(batchFileNames(in: storageDirectory).filter { name in name.hasSuffix(".unsupported") }.count, 1)
    }

    /// 415 maps to its own outcome, never a retry.
    func testA415IsUnsupportedNotRetryable() {
        XCTAssertEqual(IngestOutcome(statusCode: 415, retryAfterHeader: nil, now: Date()), .unsupported)
    }
}

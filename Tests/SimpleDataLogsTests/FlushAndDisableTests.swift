import XCTest
import Foundation

@testable import SimpleDataLogs

/// Flush-then-disable sends what is queued, then stops and deletes whatever is left.
final class FlushAndDisableTests: PipelineTestCase {
    /// Queued events go out, the outbox ends empty, and later events are ignored.
    func testQueuedEventsAreSentThenCollectionStops() async {
        let storageDirectory = makeTemporaryDirectory()
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory)
        await pipeline.start()

        // Three journaled events go out with the last send.
        await enqueueEvents(3, into: pipeline)
        await pipeline.flushAndDisable(timeLimit: .seconds(5))

        XCTAssertEqual(server.requests.map(\.eventCount), [3])
        XCTAssertFalse(hasJournal(in: storageDirectory))
        XCTAssertEqual(batchFileNames(in: storageDirectory), [])

        // Collection is off afterwards.
        await enqueueEvents(2, into: pipeline)
        await pipeline.flush()

        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertEqual(pendingEventCount, 0)
        XCTAssertEqual(server.requests.count, 1)
    }

    /// When the last send fails, the outbox is still deleted and nothing is retried.
    func testAFailedLastSendStillDeletesTheOutbox() async {
        let storageDirectory = makeTemporaryDirectory()
        let server = makeServer { _, _ in .status(503) }
        let delayRecorder = DelayRecorder()
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory, delayRecorder: delayRecorder)
        await pipeline.start()

        await enqueueEvents(4, into: pipeline)
        await pipeline.flushAndDisable(timeLimit: .seconds(5))

        let pendingEventCount = await pipeline.pendingEventCount
        let isBackingOff = await pipeline.isBackingOff
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(pendingEventCount, 0)
        XCTAssertFalse(isBackingOff)
        XCTAssertEqual(batchFileNames(in: storageDirectory), [])
    }

    /// A backoff in progress does not hold back the last send.
    func testTheLastSendSkipsAPendingBackoff() async {
        let server = makeServer { _, requestIndex in requestIndex == 0 ? .status(503, retryAfter: "3600") : .accepted }
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory())
        await pipeline.start()

        // The first send fails and parks a one-hour backoff.
        await enqueueEvents(2, into: pipeline)
        await pipeline.flush()
        let isBackingOffBeforeDrain = await pipeline.isBackingOff
        XCTAssertTrue(isBackingOffBeforeDrain)

        // The drain sends anyway.
        await pipeline.flushAndDisable(timeLimit: .seconds(5))

        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(server.requests.last?.eventCount, 2)
    }

    /// A send slower than the time limit is abandoned, and the outbox is deleted on time.
    func testASlowSendIsCutOffAtTheTimeLimit() async {
        let storageDirectory = makeTemporaryDirectory()
        let requestGate = RequestGate()
        let server = makeServer { _, _ in MockResponse.accepted.held(by: requestGate) }
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory)
        addTeardownBlock { requestGate.open() }
        await pipeline.start()

        await enqueueEvents(2, into: pipeline)
        let drainStartedAt = Date()
        await pipeline.flushAndDisable(timeLimit: .milliseconds(300))

        XCTAssertLessThan(Date().timeIntervalSince(drainStartedAt), 3)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(batchFileNames(in: storageDirectory), [])
        XCTAssertFalse(hasJournal(in: storageDirectory))
    }

    /// An opt-in that arrives while the drain is still sending wins over the drain's late disable.
    func testALaterOptInWinsOverAnUnfinishedDrain() async {
        let requestGate = RequestGate()
        let server = makeServer { _, _ in MockResponse.accepted.held(by: requestGate) }
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory())
        addTeardownBlock { requestGate.open() }
        await pipeline.start()
        await enqueueEvents(1, into: pipeline)

        // Queue the drain, then an opt-out and opt-in before its send answers.
        let drainFinished = DispatchSemaphore(value: 0)
        await pipeline.handle(.flushAndDisable(timeLimit: .seconds(5), completion: { drainFinished.signal() }))
        await waitUntil { server.requests.count == 1 }
        await pipeline.handle(.setEnabled(false))
        await pipeline.handle(.setEnabled(true))
        requestGate.open()
        let didFinish = await waitForSignal(drainFinished)

        // Collection is still on, so a new event is journaled.
        await enqueueEvents(1, into: pipeline)
        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertTrue(didFinish)
        XCTAssertEqual(pendingEventCount, 1)
    }

    /// Before configure, both forms return at once, run the completion, and leave collection off until re-enabled.
    func testFacadeCallsBeforeConfigureReturnAtOnce() async {
        let completionCalled = DispatchSemaphore(value: 0)
        SimpleDataLogs.flushAndDisable { completionCalled.signal() }
        let didCallCompletion = await waitForSignal(completionCalled, timeout: 1)
        XCTAssertTrue(didCallCompletion)

        let drainStartedAt = Date()
        await SimpleDataLogs.flushAndDisable()
        XCTAssertLessThan(Date().timeIntervalSince(drainStartedAt), 1)

        // disable() is the same opt-out as setEnabled(false).
        SimpleDataLogs.disable()
        await SimpleDataLogs.flush()
        SimpleDataLogs.setEnabled(true)
    }
}

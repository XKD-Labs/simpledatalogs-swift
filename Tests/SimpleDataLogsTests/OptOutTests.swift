import XCTest
import Foundation

@testable import SimpleDataLogs

/// An opt-out deletes every unsent event and keeps anything new from being collected.
final class OptOutTests: PipelineTestCase {
    /// Disabling deletes the journal and every sealed batch.
    func testDisablingDeletesTheJournalAndEverySealedBatch() async {
        let storageDirectory = makeTemporaryDirectory()
        let server = makeServer { _, _ in .status(503, retryAfter: "3600") }
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory)
        await pipeline.start()

        // Three events sealed but undelivered, two more still in the journal.
        await enqueueEvents(3, into: pipeline)
        await pipeline.flush()
        await enqueueEvents(2, into: pipeline)

        let pendingBeforeOptOut = await pipeline.pendingEventCount
        XCTAssertEqual(pendingBeforeOptOut, 5)
        XCTAssertEqual(batchFileNames(in: storageDirectory).count, 1)
        XCTAssertTrue(hasJournal(in: storageDirectory))

        await pipeline.setEnabled(false)

        let pendingAfterOptOut = await pipeline.pendingEventCount
        XCTAssertEqual(pendingAfterOptOut, 0)
        XCTAssertEqual(batchFileNames(in: storageDirectory), [])
        XCTAssertFalse(hasJournal(in: storageDirectory))
    }

    /// An opt-out while a request is in flight deletes everything, and the late answer cannot bring anything back.
    func testOptOutDuringAnInFlightSendKeepsNothing() async {
        let storageDirectory = makeTemporaryDirectory()
        let requestGate = RequestGate()
        let server = makeServer { _, _ in MockResponse.accepted.held(by: requestGate) }
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory)
        await pipeline.start()

        // Start a send and hold its answer back.
        await enqueueEvents(2, into: pipeline)
        let flushTask = Task {
            await pipeline.flush()
        }
        await waitUntil { server.requests.count == 1 }

        // Opt out mid-request, then let the answer through; the flush must still return.
        await pipeline.setEnabled(false)
        requestGate.open()
        await flushTask.value

        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertEqual(pendingEventCount, 0)
        XCTAssertEqual(batchFileNames(in: storageDirectory), [])
        XCTAssertFalse(hasJournal(in: storageDirectory))
        XCTAssertEqual(server.requests.count, 1)
    }

    /// While disabled, events are ignored and nothing is sent.
    func testEventsTrackedWhileDisabledAreIgnored() async {
        let storageDirectory = makeTemporaryDirectory()
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory)
        await pipeline.start()

        await pipeline.setEnabled(false)
        await enqueueEvents(3, into: pipeline)
        await pipeline.flush()

        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertEqual(pendingEventCount, 0)
        XCTAssertEqual(server.requests.count, 0)
        XCTAssertFalse(hasJournal(in: storageDirectory))
    }

    /// A launch that starts opted out deletes what an earlier launch left, without sending it.
    func testStartingDisabledDeletesWhatAnEarlierLaunchLeft() async {
        let storageDirectory = makeTemporaryDirectory()

        // An earlier launch journals events, then quits.
        let earlierServer = makeServer()
        let earlierLaunch = makePipeline(server: earlierServer, storageDirectory: storageDirectory)
        await earlierLaunch.start()
        await enqueueEvents(3, into: earlierLaunch)
        await earlierLaunch.cancelBackgroundWork()

        // This launch starts with collection off.
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory, isEnabled: false)
        await pipeline.start()

        XCTAssertEqual(server.requests.count, 0)
        XCTAssertEqual(batchFileNames(in: storageDirectory), [])
        XCTAssertFalse(hasJournal(in: storageDirectory))
    }

    /// Opting back in collects and sends again.
    func testReEnablingCollectsAgain() async {
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory())
        await pipeline.start()

        await pipeline.setEnabled(false)
        await pipeline.setEnabled(true)
        await enqueueEvents(1, into: pipeline)
        await pipeline.flush()

        XCTAssertEqual(server.requests.count, 1)
    }
}

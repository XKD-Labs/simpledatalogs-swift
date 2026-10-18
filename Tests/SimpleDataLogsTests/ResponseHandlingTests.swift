import XCTest
import Foundation

@testable import SimpleDataLogs

/// 401 pauses and re-probes without losing events, 413 splits, and only a 202 deletes a batch.
final class ResponseHandlingTests: PipelineTestCase {
    // MARK: - 401

    /// A 401 pauses sending, keeps every event, and books the first re-probe a minute out.
    func testInvalidKeyPausesSendingAndKeepsEveryEvent() async {
        let server = makeServer { _, _ in .status(401) }
        let delayRecorder = DelayRecorder()
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory(), delayRecorder: delayRecorder)
        await pipeline.start()

        await enqueueEvents(3, into: pipeline)
        await pipeline.flush()

        // Neither a full batch nor another flush gets past the pause.
        await enqueueEvents(50, into: pipeline)
        await pipeline.flush()

        let isSendingPaused = await pipeline.isSendingPaused
        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertTrue(isSendingPaused)
        XCTAssertEqual(pendingEventCount, 53)
        XCTAssertEqual(server.requests.count, 1)
        await waitUntil { delayRecorder.delays == [60] }
    }

    /// A key that is not live yet (401 once) is re-probed, and sending resumes once it is accepted.
    func testReProbeResumesSendingOnceTheKeyIsAccepted() async {
        let server = makeServer { _, requestIndex in
            requestIndex == 0 ? .status(401) : .accepted
        }
        let delayRecorder = DelayRecorder(immediateReturnCount: 1)
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory(), delayRecorder: delayRecorder)
        await pipeline.start()

        await enqueueEvents(2, into: pipeline)
        await pipeline.flush()

        // The re-probe resends the rejected batch and gets its 202.
        await waitUntil { await pipeline.pendingEventCount == 0 }
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(server.requests[1].eventIDs, server.requests[0].eventIDs)
        XCTAssertEqual(delayRecorder.delays, [60])

        // Normal sending is back.
        await enqueueEvents(1, into: pipeline)
        await pipeline.flush()

        let isSendingPaused = await pipeline.isSendingPaused
        XCTAssertFalse(isSendingPaused)
        XCTAssertEqual(server.requests.count, 3)
    }

    /// A key that stays rejected is re-probed every ten minutes with one request each, never losing events.
    func testStillRejectedKeyIsReProbedEveryTenMinutes() async {
        let server = makeServer { _, _ in .status(401) }
        let delayRecorder = DelayRecorder(immediateReturnCount: 2)
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory(), delayRecorder: delayRecorder)
        await pipeline.start()

        await enqueueEvents(2, into: pipeline)
        await pipeline.flush()

        // The original send plus two re-probes, then the third probe waits.
        await waitUntil { delayRecorder.delays.count == 3 }
        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertEqual(delayRecorder.delays, [60, 600, 600])
        XCTAssertEqual(server.requests.count, 3)
        XCTAssertEqual(pendingEventCount, 2)
    }

    /// A re-probe that gets no answer (offline) keeps the pause and books the next probe, without a backoff.
    func testProbeLostInTransitKeepsThePause() async {
        let server = makeServer { _, requestIndex in
            requestIndex == 0 ? .status(401) : .networkFailure(.notConnectedToInternet)
        }
        let delayRecorder = DelayRecorder(immediateReturnCount: 1)
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory(), delayRecorder: delayRecorder)
        await pipeline.start()

        await enqueueEvents(2, into: pipeline)
        await pipeline.flush()

        // The one-minute probe fails in transit, so the ten-minute probe is booked next.
        await waitUntil { delayRecorder.delays.count == 2 }

        let isSendingPaused = await pipeline.isSendingPaused
        let isBackingOff = await pipeline.isBackingOff
        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertEqual(delayRecorder.delays, [60, 600])
        XCTAssertTrue(isSendingPaused)
        XCTAssertFalse(isBackingOff)
        XCTAssertEqual(pendingEventCount, 2)
        XCTAssertEqual(server.requests.count, 2)
    }

    /// A busy answer to a re-probe pushes the next probe out to its Retry-After.
    func testBusyProbeHonorsRetryAfter() async {
        let server = makeServer { _, requestIndex in
            requestIndex == 0 ? .status(401) : .status(503, retryAfter: "1800")
        }
        let delayRecorder = DelayRecorder(immediateReturnCount: 1)
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory(), delayRecorder: delayRecorder)
        await pipeline.start()

        await enqueueEvents(1, into: pipeline)
        await pipeline.flush()

        await waitUntil { delayRecorder.delays.count == 2 }

        let isSendingPaused = await pipeline.isSendingPaused
        XCTAssertEqual(delayRecorder.delays, [60, 1800])
        XCTAssertTrue(isSendingPaused)
    }

    /// A 413 to a re-probe proves the key works (ingest authenticates first), so the pause ends and the batch is split.
    func testTooLargeProbeEndsThePause() async {
        let server = makeServer { request, requestIndex in
            if requestIndex == 0 {
                return .status(401)
            }

            return request.eventCount > 1 ? .status(413) : .accepted
        }
        let delayRecorder = DelayRecorder(immediateReturnCount: 1)
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory(), delayRecorder: delayRecorder)
        await pipeline.start()

        await enqueueEvents(2, into: pipeline)
        await pipeline.flush()

        // Rejected, probed into a 413, then both halves accepted.
        await waitUntil { await pipeline.pendingEventCount == 0 }

        let isSendingPaused = await pipeline.isSendingPaused
        XCTAssertEqual(server.requests.map(\.eventCount), [2, 2, 1, 1])
        XCTAssertFalse(isSendingPaused)
    }

    /// A rejected key on one launch is tried again by the next launch.
    func testNextLaunchTriesARejectedKeyAgain() async {
        let storageDirectory = makeTemporaryDirectory()

        // First launch: the key is rejected and the events stay on disk.
        let rejectingServer = makeServer { _, _ in .status(401) }
        let firstLaunch = makePipeline(server: rejectingServer, storageDirectory: storageDirectory)
        await firstLaunch.start()
        await enqueueEvents(2, into: firstLaunch)
        await firstLaunch.flush()
        await firstLaunch.cancelBackgroundWork()

        // Next launch: the key works and the kept events go out.
        let acceptingServer = makeServer()
        let secondLaunch = makePipeline(server: acceptingServer, storageDirectory: storageDirectory)
        await secondLaunch.start()

        await waitUntil { await secondLaunch.pendingEventCount == 0 }
        XCTAssertEqual(acceptingServer.requests.count, 1)
    }

    // MARK: - 413

    /// A 413 splits the batch in half and resends the halves, never the unchanged batch.
    func testPayloadTooLargeSplitsTheBatchInHalf() async {
        let server = makeServer { request, _ in
            request.eventCount > 2 ? .status(413) : .accepted
        }
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory())
        await pipeline.start()

        let enqueuedEvents = await enqueueEvents(4, into: pipeline)
        await pipeline.flush()

        // One rejected request of four, then two accepted halves of two.
        let acceptedEventIDs = server.requests.filter { request in request.eventCount <= 2 }.flatMap(\.eventIDs)
        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertEqual(server.requests.map(\.eventCount), [4, 2, 2])
        XCTAssertEqual(acceptedEventIDs, enqueuedEvents.map(\.eventID.uuidString))
        XCTAssertEqual(pendingEventCount, 0)
    }

    /// A single event that is still too large is dropped, and sending carries on.
    func testLoneEventStillTooLargeIsDropped() async {
        // The server refuses any body holding the oversized event, whatever its byte size.
        let server = makeServer { request, _ in
            request.eventNames.contains("oversized_event") ? .status(413) : .accepted
        }
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory())
        await pipeline.start()

        // The refused event alone, then an ordinary one.
        await enqueueEvents(1, into: pipeline, named: "oversized_event")
        await pipeline.flush()
        let ordinaryEvents = await enqueueEvents(1, into: pipeline)
        await pipeline.flush()

        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertEqual(server.requests.map(\.eventNames), [["oversized_event"], ["screenshot_taken"]])
        XCTAssertEqual(server.requests.last?.eventIDs, ordinaryEvents.map(\.eventID.uuidString))
        XCTAssertEqual(pendingEventCount, 0)
    }

    /// A batch the cap evicts while in flight is not resurrected by its 413, and newer batches still go out.
    func testBatchEvictedWhileInFlightIsNotResurrected() async {
        // The first request's 413 is held back until the test opens the gate.
        let requestGate = RequestGate()
        let server = makeServer { _, requestIndex in
            requestIndex == 0 ? MockResponse.status(413).held(by: requestGate) : .accepted
        }
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory()) { configuration in
            configuration.maxBatchEventCount = 2
            configuration.maxOutboxEventCount = 4
        }
        await pipeline.start()

        // The first full batch goes out and stays in flight.
        await enqueueEvents(2, into: pipeline)
        await waitUntil { server.requests.count == 1 }

        // Two newer batches push the outbox past its cap of four, evicting the in-flight one.
        let newerEvents = await enqueueEvents(4, into: pipeline)
        let pendingAfterEviction = await pipeline.pendingEventCount
        XCTAssertEqual(pendingAfterEviction, 4)

        // The late 413 finds its batch gone, so nothing is split back in; the newer batches go out.
        requestGate.open()
        await waitUntil { await pipeline.pendingEventCount == 0 }

        XCTAssertEqual(server.requests.map(\.eventCount), [2, 2, 2])
        XCTAssertEqual(server.requests.dropFirst().flatMap(\.eventIDs), newerEvents.map(\.eventID.uuidString))
    }

    // MARK: - Other statuses

    /// A 2xx other than 202 does not confirm storage, so the batch is kept and retried.
    func testOtherSuccessStatusesAreRetried() async {
        let server = makeServer { _, requestIndex in
            requestIndex == 0 ? .status(200) : .accepted
        }
        let delayRecorder = DelayRecorder(immediateReturnCount: 1)
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory(), delayRecorder: delayRecorder)
        await pipeline.start()

        await enqueueEvents(1, into: pipeline)
        await pipeline.flush()

        await waitUntil { await pipeline.pendingEventCount == 0 }
        XCTAssertEqual(server.requests.count, 2)
    }
}

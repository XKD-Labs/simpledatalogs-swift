import XCTest
import Foundation

@testable import SimpleDataLogs

/// Batches go out at 50 events or after the batch interval, and every request stays under the byte limit.
final class BatchingTests: PipelineTestCase {
    /// Debug builds, which tests are, send a partial batch after 5 s; release builds wait 10 s.
    func testDebugBuildsSendAPartialBatchAfterFiveSeconds() {
        XCTAssertEqual(PipelineConfiguration.defaultBatchInterval, .seconds(5))
    }

    /// The 50th event seals and sends a batch without waiting for the timer.
    func testFiftyEventsSendOneBatchWithoutWaitingForTheTimer() async {
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory())
        await pipeline.start()

        let enqueuedEvents = await enqueueEvents(50, into: pipeline)

        await waitUntil { server.requests.count == 1 }
        await waitUntil { await pipeline.pendingEventCount == 0 }
        XCTAssertEqual(server.requests.first?.eventIDs, enqueuedEvents.map(\.eventID.uuidString))
    }

    /// The 51st event starts the next batch, which waits for its own trigger.
    func testTheFiftyFirstEventStartsTheNextBatch() async {
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory())
        await pipeline.start()

        await enqueueEvents(51, into: pipeline)

        await waitUntil { server.requests.count == 1 }
        await waitUntil { await pipeline.pendingEventCount == 1 }
        XCTAssertEqual(server.requests.first?.eventCount, 50)
    }

    /// A partial batch stays in the journal until its interval passes; the hour-long interval here never does.
    func testAPartialBatchWaitsForTheBatchInterval() async throws {
        let storageDirectory = makeTemporaryDirectory()
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory)
        await pipeline.start()

        await enqueueEvents(3, into: pipeline)

        // Give any wrongly scheduled send time to show up.
        try await Task.sleep(for: .milliseconds(300))

        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertEqual(server.requests.count, 0)
        XCTAssertEqual(pendingEventCount, 3)
        XCTAssertTrue(hasJournal(in: storageDirectory))
    }

    /// A partial batch goes out by itself once the batch interval passes.
    func testAPartialBatchSendsAfterTheBatchInterval() async {
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory()) { configuration in
            configuration.batchInterval = .milliseconds(200)
        }
        await pipeline.start()

        await enqueueEvents(3, into: pipeline)

        await waitUntil { server.requests.count == 1 }
        XCTAssertEqual(server.requests.first?.eventCount, 3)
    }

    /// `flush()` sends a partial batch at once and returns after the attempt.
    func testFlushSendsAPartialBatchAtOnce() async {
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory())
        await pipeline.start()

        await enqueueEvents(2, into: pipeline)
        await pipeline.flush()

        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.requests.first?.eventCount, 2)
        XCTAssertEqual(pendingEventCount, 0)
    }

    /// Requests are NDJSON POSTs to /v1/ingest with the bearer key and SDK User-Agent.
    func testRequestsCarryTheIngestHeaders() async throws {
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory())
        await pipeline.start()

        await enqueueEvents(1, into: pipeline)
        await pipeline.flush()

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path(), "/v1/ingest")
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(Self.testIngestKey)")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-ndjson")
        XCTAssertEqual(request.headers["User-Agent"], IngestClient.userAgent)
    }

    /// The journal seals early whenever the next event would push a request past the byte limit.
    func testBatchesStayUnderTheRequestByteLimit() async {
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory()) { configuration in
            configuration.maxRequestBytes = 1_000
        }
        await pipeline.start()

        // Each event is roughly 400 bytes, so only two fit in one request.
        await enqueueEvents(6, into: pipeline, properties: ["padding": .string(String(repeating: "x", count: 300))])
        await pipeline.flush()

        XCTAssertGreaterThanOrEqual(server.requests.count, 3)
        XCTAssertEqual(server.requests.map(\.eventCount).reduce(0, +), 6)
        XCTAssertTrue(server.requests.allSatisfy { request in request.body.count <= 1_000 })
    }

    /// An event that alone overfills one request is dropped at track time instead of clogging the outbox.
    func testAnEventLargerThanOneRequestIsDropped() async {
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory()) { configuration in
            configuration.maxRequestBytes = 500
        }
        await pipeline.start()

        await enqueueEvents(1, into: pipeline, properties: ["padding": .string(String(repeating: "x", count: 600))])
        await pipeline.flush()

        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertEqual(pendingEventCount, 0)
        XCTAssertEqual(server.requests.count, 0)
    }
}

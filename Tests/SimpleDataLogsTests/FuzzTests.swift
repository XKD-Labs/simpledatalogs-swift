import XCTest
import Foundation

@testable import SimpleDataLogs

/// A seeded SplitMix64 generator, so a failing round replays from its seed.
struct SeededGenerator: RandomNumberGenerator {
    /// The generator's running state.
    private var state: UInt64

    /// Starts the sequence at a seed.
    init(seed: UInt64) {
        state = seed
    }

    /// The next 64 random bits.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixedBits = state
        mixedBits = (mixedBits ^ (mixedBits >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixedBits = (mixedBits ^ (mixedBits >> 27)) &* 0x94D0_49BB_1331_11EB

        return mixedBits ^ (mixedBits >> 31)
    }
}

/// Seeded random checks against the ingest API: any event encodes to one valid line, delays stay in bounds, and random answers lose nothing.
final class FuzzTests: PipelineTestCase {
    /// Text pieces that stress JSON: quotes, backslashes, newlines, controls, accents, emoji and joiners.
    private static let textPieces = ["a", "Z", "0", " ", "\"", "\\", "\n", "\r", "\t", "\u{0}", "\u{1F}", "é", "ß", "中", "😀", "👩‍👩‍👧", "\u{2028}", "</script>", "{", "]"]

    /// Random text up to a length, from the stress pieces.
    private func randomText(maxLength: Int, using generator: inout SeededGenerator) -> String {
        let length = Int.random(in: 0...maxLength, using: &generator)

        return (0..<length).map { _ in Self.textPieces.randomElement(using: &generator)! }.joined()
    }

    /// A property value of any kind, including NaN, infinity and the integer extremes.
    private func randomPropertyValue(using generator: inout SeededGenerator) -> PropertyValue {
        switch Int.random(in: 0...7, using: &generator) {
        case 0: return .string(randomText(maxLength: 40, using: &generator))
        case 1: return .int(Int.random(in: Int.min...Int.max, using: &generator))
        case 2: return .int([Int.min, Int.max, 0, -1].randomElement(using: &generator)!)
        case 3: return .double(Double.random(in: -1e300...1e300, using: &generator))
        case 4: return .double([Double.nan, .infinity, -.infinity, -0.0, .leastNonzeroMagnitude].randomElement(using: &generator)!)
        case 5: return .bool(Bool.random(using: &generator))
        default: return .string("")
        }
    }

    /// Any event, encoded, is one JSON object on one line with its id, time, name and every JSON-safe property.
    func testRandomEventsEncodeToOneValidJSONLine() throws {
        var generator = SeededGenerator(seed: 14)

        for round in 0..<500 {
            // Build an event the way track does: NaN and infinity are dropped first.
            var rawProperties: [String: PropertyValue] = [:]
            for _ in 0..<Int.random(in: 0...8, using: &generator) {
                rawProperties[randomText(maxLength: 12, using: &generator)] = randomPropertyValue(using: &generator)
            }

            let properties = rawProperties.droppingNonJSONValues()
            let eventName = randomText(maxLength: 30, using: &generator)
            let deviceID = Bool.random(using: &generator) ? randomText(maxLength: 20, using: &generator) : nil
            let event = TrackedEvent.make(eventName: eventName, properties: properties, defaultProperties: [:], deviceID: deviceID)

            // One line: no raw newline byte survives encoding.
            let eventLine = try event.encodedLine()
            XCTAssertFalse(eventLine.contains(0x0A), "round \(round)")

            // It decodes back to the same fields.
            let eventObject = try XCTUnwrap(JSONSerialization.jsonObject(with: eventLine) as? [String: Any], "round \(round)")
            XCTAssertEqual(eventObject["event"] as? String, eventName, "round \(round)")
            XCTAssertEqual(eventObject["event_id"] as? String, event.eventID.uuidString)
            XCTAssertEqual(eventObject["device_id"] as? String, deviceID)
            XCTAssertNotNil(try? TrackedEvent.timestampStyle.parse(try XCTUnwrap(eventObject["ts"] as? String)))

            let decodedProperties = try XCTUnwrap(eventObject["props"] as? [String: Any])
            XCTAssertEqual(decodedProperties.count, properties.count, "round \(round)")

            for case let (propertyKey, .string(stringValue)) in properties {
                XCTAssertEqual(decodedProperties[propertyKey] as? String, stringValue, "round \(round)")
            }
        }
    }

    /// Every retry delay is at least 0.25 s and Retry-After (capped at an hour), and never past the larger of 5 min and that hint.
    func testRetryDelaysStayWithinTheDocs14Bounds() {
        var generator = SeededGenerator(seed: 3)
        let retryPolicy = RetryPolicy()

        for _ in 0..<5_000 {
            let failureCount = Int.random(in: -3...200, using: &generator)
            let retryAfter: TimeInterval? = Bool.random(using: &generator) ? nil : Double.random(in: 0...100_000, using: &generator)
            let jitterFraction = Double.random(in: -1...2, using: &generator)

            let delay = retryPolicy.delay(afterFailureCount: failureCount, retryAfter: retryAfter, jitterFraction: jitterFraction)
            let cappedRetryAfter = min(retryAfter ?? 0, 3600)

            XCTAssertGreaterThanOrEqual(delay, 0.25)
            XCTAssertGreaterThanOrEqual(delay, cappedRetryAfter)
            XCTAssertLessThanOrEqual(delay, max(300, cappedRetryAfter))
        }
    }

    /// Random answers for a while, then only 202s: every event is accepted exactly once, except a lone one refused as too large.
    func testRandomServerAnswersLoseNothingAndAcceptEachEventOnce() async throws {
        for seed in UInt64(1)...6 {
            var generator = SeededGenerator(seed: seed)
            let randomAnswers = (0..<40).map { _ in randomAnswer(using: &generator) }

            // The first answers are random; afterwards ingest accepts everything.
            let server = makeServer { _, requestIndex in
                requestIndex < randomAnswers.count ? randomAnswers[requestIndex] : .accepted
            }
            let pipeline = makePipeline(
                server: server,
                storageDirectory: makeTemporaryDirectory(),
                delayRecorder: DelayRecorder(immediateReturnCount: Int.max)
            )
            await pipeline.start()

            // Track in bursts, flushing between them, as an app moving between screens would.
            var enqueuedIDs: [String] = []
            for _ in 0..<6 {
                let events = await enqueueEvents(Int.random(in: 1...70, using: &generator), into: pipeline)
                enqueuedIDs += events.map(\.eventID.uuidString)
                await pipeline.flush()
            }

            await waitUntil(timeout: 20) { await pipeline.pendingEventCount == 0 }

            // Pair each request with the status it got.
            let answeredRequests = server.requests.enumerated().map { requestIndex, request in
                (request: request, statusCode: requestIndex < randomAnswers.count ? randomAnswers[requestIndex].statusCode : 202)
            }
            let acceptedIDs = answeredRequests.filter { $0.statusCode == 202 }.flatMap(\.request.eventIDs)
            let droppedIDs = answeredRequests.filter { $0.statusCode == 413 && $0.request.eventCount == 1 }.flatMap(\.request.eventIDs)

            XCTAssertEqual(Set(acceptedIDs).count, acceptedIDs.count, "seed \(seed): an event was accepted twice")
            XCTAssertEqual(Set(acceptedIDs).union(droppedIDs), Set(enqueuedIDs), "seed \(seed): an event was lost")

            await pipeline.cancelBackgroundWork()
        }
    }

    /// Many tasks tracking and flushing at once, against a server that sometimes fails, still send every event once in valid batches.
    func testConcurrentTrackingAndFlushingSendsEveryEventOnce() async {
        let server = makeServer { _, requestIndex in
            requestIndex % 3 == 1 ? .status(503, retryAfter: "1") : .accepted
        }
        let pipeline = makePipeline(
            server: server,
            storageDirectory: makeTemporaryDirectory(),
            delayRecorder: DelayRecorder(immediateReturnCount: Int.max)
        )
        await pipeline.start()

        // Eight tasks each track 100 events, flushing now and then.
        let enqueuedIDs = await withTaskGroup(of: [String].self) { taskGroup in
            for _ in 0..<8 {
                taskGroup.addTask {
                    var taskEventIDs: [String] = []

                    for eventIndex in 0..<100 {
                        let event = makeEvent()
                        await pipeline.enqueue(event)
                        taskEventIDs.append(event.eventID.uuidString)

                        if eventIndex % 37 == 0 {
                            await pipeline.flush()
                        }
                    }

                    return taskEventIDs
                }
            }

            return await taskGroup.reduce(into: []) { allEventIDs, taskEventIDs in allEventIDs += taskEventIDs }
        }

        await pipeline.flush()
        await waitUntil(timeout: 20) { await pipeline.pendingEventCount == 0 }

        // Accepted bodies hold every event exactly once, in batches of at most 50.
        let acceptedRequests = server.requests.enumerated().filter { requestIndex, _ in requestIndex % 3 != 1 }.map(\.element)
        let acceptedIDs = acceptedRequests.flatMap(\.eventIDs)

        XCTAssertEqual(acceptedIDs.count, 800)
        XCTAssertEqual(Set(acceptedIDs), Set(enqueuedIDs))
        XCTAssertTrue(server.requests.allSatisfy { $0.eventCount <= 50 })
    }

    /// One random answer: any ingest API status, an odd success, or a network failure, with or without Retry-After.
    private func randomAnswer(using generator: inout SeededGenerator) -> MockResponse {
        let retryAfter = [nil, "0", "1", "120", "garbage", "Wed, 21 Oct 2015 07:28:00 GMT"].randomElement(using: &generator)!

        switch Int.random(in: 0...11, using: &generator) {
        case 0...3: return .accepted
        case 4: return .status(200)
        case 5: return .status(401)
        case 6: return .status(408)
        case 7: return .status(413)
        case 8: return .status(429, retryAfter: retryAfter)
        case 9: return .status(503, retryAfter: retryAfter)
        case 10: return .status(500)
        default: return .networkFailure(.notConnectedToInternet)
        }
    }
}

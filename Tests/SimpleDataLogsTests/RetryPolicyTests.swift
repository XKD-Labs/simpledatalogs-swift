import XCTest
import Foundation

@testable import SimpleDataLogs

/// Backoff grows from 1 s to 5 min with full jitter, Retry-After is parsed and honored, and failures are retried.
final class RetryPolicyTests: PipelineTestCase {
    /// The ingest API defaults.
    private let retryPolicy = RetryPolicy()

    /// The instant RFC 9110's example HTTP-date names: Sun, 06 Nov 1994 08:49:37 GMT.
    private let exampleHTTPDateInstant = Date(timeIntervalSince1970: 784_111_777)

    // MARK: - Backoff

    /// The ceiling doubles per failure from 1 s and stops at 5 min.
    func testBackoffCeilingDoublesFromOneSecondUpToFiveMinutes() {
        let ceilings = [1, 2, 3, 9, 10, 100].map { failureCount in
            retryPolicy.backoffCeiling(afterFailureCount: failureCount)
        }

        XCTAssertEqual(ceilings, [1, 2, 4, 256, 300, 300])
    }

    /// Full jitter spans the 250 ms floor to the ceiling, so a draw near zero never spins the send loop.
    func testFullJitterSpansTheFloorToTheCeiling() {
        XCTAssertEqual(retryPolicy.delay(afterFailureCount: 4, retryAfter: nil, jitterFraction: 0), 0.25)
        XCTAssertEqual(retryPolicy.delay(afterFailureCount: 4, retryAfter: nil, jitterFraction: 0.01), 0.25)
        XCTAssertEqual(retryPolicy.delay(afterFailureCount: 4, retryAfter: nil, jitterFraction: 0.5), 4)
        XCTAssertEqual(retryPolicy.delay(afterFailureCount: 4, retryAfter: nil, jitterFraction: 1), 8)
    }

    /// Retry-After is a floor: a longer server hint wins, a shorter one does not cut the backoff.
    func testRetryAfterIsAFloorForTheDelay() {
        XCTAssertEqual(retryPolicy.delay(afterFailureCount: 1, retryAfter: 120, jitterFraction: 1), 120)
        XCTAssertEqual(retryPolicy.delay(afterFailureCount: 1, retryAfter: 120, jitterFraction: 0), 120)
        XCTAssertEqual(retryPolicy.delay(afterFailureCount: 6, retryAfter: 2, jitterFraction: 1), 32)
    }

    /// An absurd Retry-After is bounded, so a broken header cannot stall sending for days.
    func testRetryAfterIsCappedAtOneHour() {
        XCTAssertEqual(retryPolicy.delay(afterFailureCount: 1, retryAfter: 86_400 * 30, jitterFraction: 1), 3600)
    }

    /// A 401 is re-probed a minute later, then every ten minutes.
    func testInvalidKeyProbesStartSoonThenSlowDown() {
        XCTAssertEqual(retryPolicy.invalidKeyProbeDelay(afterProbeCount: 0), 60)
        XCTAssertEqual(retryPolicy.invalidKeyProbeDelay(afterProbeCount: 1), 600)
        XCTAssertEqual(retryPolicy.invalidKeyProbeDelay(afterProbeCount: 7), 600)
    }

    /// A Retry-After from a busy probe can only push the next probe later, within the one-hour bound.
    func testRetryAfterPushesAProbeLaterButNeverSooner() {
        XCTAssertEqual(retryPolicy.invalidKeyProbeDelay(afterProbeCount: 1, retryAfter: 30), 600)
        XCTAssertEqual(retryPolicy.invalidKeyProbeDelay(afterProbeCount: 1, retryAfter: 1800), 1800)
        XCTAssertEqual(retryPolicy.invalidKeyProbeDelay(afterProbeCount: 1, retryAfter: 86_400), 3600)
    }

    // MARK: - Retry-After parsing

    /// delay-seconds parses as whole seconds, ignoring surrounding spaces.
    func testParsesDelaySeconds() {
        XCTAssertEqual(RetryAfterHeader.delay(fromHeaderValue: "120", now: exampleHTTPDateInstant), 120)
        XCTAssertEqual(RetryAfterHeader.delay(fromHeaderValue: " 7 ", now: exampleHTTPDateInstant), 7)
        XCTAssertEqual(RetryAfterHeader.delay(fromHeaderValue: "0", now: exampleHTTPDateInstant), 0)
    }

    /// All three RFC 9110 HTTP-date layouts parse to the time left until that date.
    func testParsesEveryHTTPDateLayout() {
        let oneMinuteEarlier = exampleHTTPDateInstant.addingTimeInterval(-60)

        XCTAssertEqual(RetryAfterHeader.delay(fromHeaderValue: "Sun, 06 Nov 1994 08:49:37 GMT", now: oneMinuteEarlier), 60)
        XCTAssertEqual(RetryAfterHeader.delay(fromHeaderValue: "Sunday, 06-Nov-94 08:49:37 GMT", now: oneMinuteEarlier), 60)
        XCTAssertEqual(RetryAfterHeader.delay(fromHeaderValue: "Sun Nov  6 08:49:37 1994", now: oneMinuteEarlier), 60)
    }

    /// An HTTP-date already in the past means retry now.
    func testPastHTTPDateMeansRetryNow() {
        let oneMinuteLater = exampleHTTPDateInstant.addingTimeInterval(60)

        XCTAssertEqual(RetryAfterHeader.delay(fromHeaderValue: "Sun, 06 Nov 1994 08:49:37 GMT", now: oneMinuteLater), 0)
    }

    /// Missing, blank, negative and nonsense values carry no hint.
    func testUnreadableRetryAfterIsIgnored() {
        for unreadableValue in [nil, "", "   ", "-5", "1.5", "soon", "Sun, 06 Nov"] {
            XCTAssertNil(RetryAfterHeader.delay(fromHeaderValue: unreadableValue, now: exampleHTTPDateInstant), "\(String(describing: unreadableValue))")
        }
    }

    /// Each status maps onto its ingest API rule; only 202 is success.
    func testResponseStatusesMapOntoTheIngestTable() {
        let now = exampleHTTPDateInstant

        XCTAssertEqual(IngestOutcome(statusCode: 202, retryAfterHeader: nil, now: now), .accepted)
        XCTAssertEqual(IngestOutcome(statusCode: 401, retryAfterHeader: nil, now: now), .invalidKey)
        XCTAssertEqual(IngestOutcome(statusCode: 413, retryAfterHeader: nil, now: now), .payloadTooLarge)
        XCTAssertEqual(IngestOutcome(statusCode: 429, retryAfterHeader: "30", now: now), .retryable(retryAfter: 30, reason: "HTTP 429"))
        XCTAssertEqual(IngestOutcome(statusCode: 503, retryAfterHeader: "5", now: now), .retryable(retryAfter: 5, reason: "HTTP 503"))
        XCTAssertEqual(IngestOutcome(statusCode: 200, retryAfterHeader: nil, now: now), .retryable(retryAfter: nil, reason: "HTTP 200"))
        XCTAssertEqual(IngestOutcome(statusCode: 500, retryAfterHeader: nil, now: now), .retryable(retryAfter: nil, reason: "HTTP 500"))
    }

    // MARK: - Pipeline retries

    /// A 503 is retried no sooner than its Retry-After, resending the same batch.
    func testBusyServerIsRetriedNoSoonerThanRetryAfter() async {
        let server = makeServer { _, requestIndex in
            requestIndex == 0 ? .status(503, retryAfter: "42") : .accepted
        }
        let delayRecorder = DelayRecorder(immediateReturnCount: 1)
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory(), delayRecorder: delayRecorder)
        await pipeline.start()

        await enqueueEvents(1, into: pipeline)
        await pipeline.flush()

        await waitUntil { await pipeline.pendingEventCount == 0 }
        XCTAssertEqual(delayRecorder.delays, [42])
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(server.requests[0].eventIDs, server.requests[1].eventIDs)
    }

    /// A 429 with an HTTP-date Retry-After waits until that date.
    func testRateLimitHonorsAnHTTPDateRetryAfter() async {
        let retryAfterDate = Date().addingTimeInterval(120)
        let server = makeServer { _, requestIndex in
            requestIndex == 0 ? .status(429, retryAfter: Self.httpDateString(for: retryAfterDate)) : .accepted
        }
        let delayRecorder = DelayRecorder(immediateReturnCount: 1)
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory(), delayRecorder: delayRecorder)
        await pipeline.start()

        await enqueueEvents(1, into: pipeline)
        await pipeline.flush()

        await waitUntil { await pipeline.pendingEventCount == 0 }
        let recordedDelay = delayRecorder.delays.first ?? 0
        XCTAssertEqual(recordedDelay, 120, accuracy: 2)
    }

    /// Network errors and unexpected statuses back off exponentially: 1 s, 2 s, 4 s with jitter pinned at 1.
    func testRepeatedFailuresBackOffExponentially() async {
        let server = makeServer { _, requestIndex in
            switch requestIndex {
            case 0:
                return .networkFailure(.notConnectedToInternet)
            case 1:
                return .networkFailure(.timedOut)
            case 2:
                return .status(500)
            default:
                return .accepted
            }
        }
        let delayRecorder = DelayRecorder(immediateReturnCount: 3)
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory(), delayRecorder: delayRecorder)
        await pipeline.start()

        await enqueueEvents(1, into: pipeline)
        await pipeline.flush()

        await waitUntil { await pipeline.pendingEventCount == 0 }
        XCTAssertEqual(delayRecorder.delays, [1, 2, 4])
        XCTAssertEqual(server.requests.count, 4)
    }

    /// A backoff holds back even a full batch until the timer fires.
    func testBackoffHoldsBackNewBatches() async {
        let server = makeServer { _, _ in .status(503, retryAfter: "3600") }
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory())
        await pipeline.start()

        await enqueueEvents(1, into: pipeline)
        await pipeline.flush()
        await enqueueEvents(50, into: pipeline)
        await pipeline.flush()

        let pendingEventCount = await pipeline.pendingEventCount
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(pendingEventCount, 51)
    }

    /// Formats a date as an IMF-fixdate, the preferred HTTP-date layout.
    private static func httpDateString(for date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "GMT")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"

        return dateFormatter.string(from: date)
    }
}

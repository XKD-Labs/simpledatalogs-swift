import XCTest
import Foundation

@testable import SimpleDataLogs

/// Events tracked with a past time and a caller's event id keep both on the wire, within the ingest API's `ts` window.
final class BackdatedEventTests: PipelineTestCase {
    /// A fixed "now" for exact assertions.
    private let now = Date(timeIntervalSince1970: 1_791_796_443)

    /// No time means now, a past time inside the window is kept, a future time becomes now, and a too-old time is refused.
    func testResolvedTimestampKeepsThePastAndClampsTheFuture() {
        let anHourAgo = now.addingTimeInterval(-3600)
        let nearTheLimit = now.addingTimeInterval(-TrackedEvent.maxTimestampAge + 60)
        let pastTheLimit = now.addingTimeInterval(-TrackedEvent.maxTimestampAge - 60)

        XCTAssertEqual(TrackedEvent.resolvedTimestamp(nil, now: now), now)
        XCTAssertEqual(TrackedEvent.resolvedTimestamp(anHourAgo, now: now), anHourAgo)
        XCTAssertEqual(TrackedEvent.resolvedTimestamp(nearTheLimit, now: now), nearTheLimit)
        XCTAssertEqual(TrackedEvent.resolvedTimestamp(now.addingTimeInterval(600), now: now), now)
        XCTAssertNil(TrackedEvent.resolvedTimestamp(pastTheLimit, now: now))
    }

    /// The SDK's window stays inside the ingest API's 10 calendar years.
    func testTheWindowIsInsideTenCalendarYears() throws {
        let tenYearsAgo = try XCTUnwrap(Calendar(identifier: .gregorian).date(byAdding: .year, value: -10, to: now))

        XCTAssertLessThan(TrackedEvent.maxTimestampAge, now.timeIntervalSince(tenYearsAgo))
    }

    /// A back-dated event with a caller's id is sent with exactly that `ts` and `event_id`.
    func testABackdatedEventIsSentWithItsTimeAndID() async throws {
        let server = makeServer()
        let pipeline = makePipeline(server: server, storageDirectory: makeTemporaryDirectory())
        await pipeline.start()

        // An onboarding step recorded two hours before consent, sent now.
        let stepEventID = UUID()
        let stepTime = Date(timeIntervalSince1970: 1_791_789_243.5)
        let stepEvent = TrackedEvent.make(
            eventName: "onboarding_step",
            properties: ["step": "welcome"],
            defaultProperties: [:],
            deviceID: nil,
            occurredAt: stepTime,
            eventID: stepEventID
        )
        await pipeline.enqueue(stepEvent)
        await pipeline.flush()

        let sentEvent = try XCTUnwrap(server.requests.first?.eventObjects.first)
        XCTAssertEqual(sentEvent["event_id"] as? String, stepEventID.uuidString)
        XCTAssertEqual(sentEvent["ts"] as? String, "2026-10-12T07:14:03.500Z")
    }

    /// The public overloads return at once and never crash, even before configure or with a too-old time.
    func testPublicOverloadsNeverCrashBeforeConfigure() {
        SimpleDataLogs.track("onboarding_step", properties: ["step": "welcome"], at: Date().addingTimeInterval(-60))
        SimpleDataLogs.track("onboarding_step", at: Date().addingTimeInterval(-60), eventID: UUID())
        SimpleDataLogs.track("onboarding_step", at: Date(timeIntervalSince1970: 0))
        SimpleDataLogs.track("purchase", properties: ["plan": "pro"], eventID: UUID())
        SimpleDataLogs.track("", at: Date())
    }
}

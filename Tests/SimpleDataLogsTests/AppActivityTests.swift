import XCTest
import Foundation

@testable import SimpleDataLogs

/// Activity stamps: whether someone was using the app, and its foreground time between events.
final class AppActivityTests: XCTestCase {
    /// A fixed launch time.
    private let launchTime = Date(timeIntervalSince1970: 1_791_796_443)

    /// The moment some seconds after launch.
    private func at(_ seconds: TimeInterval) -> Date {
        launchTime.addingTimeInterval(seconds)
    }

    /// An app in front reports its foreground time since the previous event, counted afresh after each one.
    func testForegroundTimeBetweenEvents() {
        var tracker = ActivityTracker(isAppActive: true, at: launchTime)

        XCTAssertEqual(tracker.stamp(at: at(30), hasRecentInput: false), ["app_state": .string("active"), "engaged_ms": .int(30_000)])
        XCTAssertEqual(tracker.stamp(at: at(32.5), hasRecentInput: false), ["app_state": .string("active"), "engaged_ms": .int(2_500)])
    }

    /// Time in the background doesn't count, and a background event says so without an engaged time.
    func testBackgroundTimeIsLeftOut() {
        var tracker = ActivityTracker(isAppActive: true, at: launchTime)

        tracker.appResignedActive(at: at(10))
        XCTAssertEqual(tracker.stamp(at: at(600), hasRecentInput: false), ["app_state": .string("background")])

        // Back in front for 20 seconds after an hour away: only the 20 seconds count.
        tracker.appBecameActive(at: at(3_600))
        XCTAssertEqual(tracker.stamp(at: at(3_620), hasRecentInput: false), ["app_state": .string("active"), "engaged_ms": .int(20_000)])
    }

    /// A finished foreground stretch still counts toward the next event, even one tracked in the background.
    func testAStretchThatEndedCountsOnce() {
        var tracker = ActivityTracker(isAppActive: false, at: launchTime)

        tracker.appBecameActive(at: at(100))
        tracker.appResignedActive(at: at(145))

        // In the background with input (a hotkey), so active, with the 45 seconds measured.
        XCTAssertEqual(tracker.stamp(at: at(200), hasRecentInput: true), ["app_state": .string("active"), "engaged_ms": .int(45_000)])
        XCTAssertEqual(tracker.stamp(at: at(210), hasRecentInput: false), ["app_state": .string("background")])
    }

    /// A menu-bar app that never comes to the front is active on recent input, with no measured time for the server to trust.
    func testRecentInputWithoutAForegroundStretch() {
        var tracker = ActivityTracker(isAppActive: false, at: launchTime)

        XCTAssertEqual(tracker.stamp(at: at(60), hasRecentInput: true), ["app_state": .string("active")])
        XCTAssertEqual(tracker.stamp(at: at(120), hasRecentInput: false), ["app_state": .string("background")])
    }

    /// Repeated notifications change nothing, and an engaged time never passes a day.
    func testRepeatsAndTheDailyCap() {
        var tracker = ActivityTracker(isAppActive: true, at: launchTime)
        tracker.appBecameActive(at: at(50))

        XCTAssertEqual(tracker.stamp(at: at(2 * 86_400), hasRecentInput: false), ["app_state": .string("active"), "engaged_ms": .int(86_400_000)])

        tracker.appResignedActive(at: at(2 * 86_400 + 5))
        tracker.appResignedActive(at: at(2 * 86_400 + 50))
        XCTAssertEqual(tracker.stamp(at: at(2 * 86_400 + 60), hasRecentInput: true), ["app_state": .string("active"), "engaged_ms": .int(5_000)])
    }
}

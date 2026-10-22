import XCTest
import Foundation

@testable import SimpleDataLogs

/// Inactivity-timeout sessions for menu-bar and accessory apps: track calls, not activation, start and end sessions.
final class SessionModeTests: PipelineTestCase {
    /// A fixed launch time.
    private let launchTime = Date(timeIntervalSince1970: 1_791_796_443)

    /// Activation is the default, its timeout stays 30 minutes, and the inactivity timeout is in minutes, at least one.
    func testModeTimeouts() {
        XCTAssertEqual(SessionMode.activation.timeout, 30 * 60)
        XCTAssertEqual(SessionMode.inactivityTimeout(minutes: 10).timeout, 10 * 60)
        XCTAssertEqual(SessionMode.inactivityTimeout(minutes: 0).timeout, 60)

        let controller = EmittedEventRecorder().makeController(options: [.sessions], stateDirectory: makeTemporaryDirectory())
        XCTAssertEqual(controller.sessionMode, .activation)
    }

    /// Tracking inside the timeout keeps the session; a longer gap ends it at the last activity and starts a new one.
    func testAGapWithoutTrackingEndsTheSession() throws {
        let recorder = EmittedEventRecorder()
        let controller = recorder.makeController(options: [.sessions], stateDirectory: makeTemporaryDirectory(), sessionMode: .inactivityTimeout(minutes: 10))

        controller.start(at: launchTime)
        let firstSessionID = try XCTUnwrap(recorder.currentSessionID)

        // Activity every few minutes keeps one session going well past the timeout.
        controller.recordTrackActivity(at: launchTime.addingTimeInterval(5 * 60))
        controller.recordTrackActivity(at: launchTime.addingTimeInterval(12 * 60))
        controller.recordTrackActivity(at: launchTime.addingTimeInterval(20 * 60))
        XCTAssertEqual(recorder.events.map(\.eventName), ["session_start"])
        XCTAssertEqual(recorder.currentSessionID, firstSessionID)

        // Fifteen quiet minutes end it, stamped at the last activity, before the new session starts.
        let lastActivityAt = launchTime.addingTimeInterval(20 * 60)
        controller.recordTrackActivity(at: lastActivityAt.addingTimeInterval(15 * 60))

        let events = recorder.events
        XCTAssertEqual(events.map(\.eventName), ["session_start", "session_end", "session_start"])
        XCTAssertEqual(events[1].sessionID, firstSessionID)
        XCTAssertEqual(events[1].occurredAt, lastActivityAt)
        XCTAssertEqual(events[1].properties["duration_s"], .int(20 * 60))
        XCTAssertNotEqual(events[2].sessionID, firstSessionID)
        XCTAssertEqual(recorder.currentSessionID, events[2].sessionID)
    }

    /// In inactivity mode, activation moments do nothing; in activation mode, track activity does nothing.
    func testEachModeIgnoresTheOtherSignal() {
        let inactivityRecorder = EmittedEventRecorder()
        let inactivityController = inactivityRecorder.makeController(options: [.sessions], stateDirectory: makeTemporaryDirectory(), sessionMode: .inactivityTimeout(minutes: 5))
        inactivityController.start(at: launchTime)
        inactivityController.observeAppActivity()
        XCTAssertEqual(inactivityRecorder.events.map(\.eventName), ["session_start"])

        let activationRecorder = EmittedEventRecorder()
        let activationController = activationRecorder.makeController(options: [.sessions], stateDirectory: makeTemporaryDirectory())
        activationController.start(at: launchTime)
        activationController.recordTrackActivity(at: launchTime.addingTimeInterval(3 * 3600))
        XCTAssertEqual(activationRecorder.events.map(\.eventName), ["session_start"])
    }

    /// Activity earlier than the last one, e.g. after a clock change, never ends or moves the session.
    func testActivityNeverMovesBackwards() {
        var tracker = SessionTracker(session: nil, timeout: 600)
        _ = tracker.recordActivity(at: launchTime, newSessionID: { "session-1" })
        _ = tracker.recordActivity(at: launchTime.addingTimeInterval(300))

        let changes = tracker.recordActivity(at: launchTime.addingTimeInterval(-3600))

        XCTAssertEqual(changes, [])
        XCTAssertEqual(tracker.session?.lastActiveAt, launchTime.addingTimeInterval(300))
    }

    /// A quit app's session is saved with its last activity, so the next launch ends it at the right time.
    func testTheNextLaunchEndsAQuitSessionAtItsLastActivity() throws {
        let stateDirectory = makeTemporaryDirectory()
        let firstRecorder = EmittedEventRecorder()
        let firstController = firstRecorder.makeController(options: [.sessions], stateDirectory: stateDirectory, sessionMode: .inactivityTimeout(minutes: 10))

        // Activity within the write interval is saved by the termination write.
        firstController.start(at: launchTime)
        firstController.recordTrackActivity(at: launchTime.addingTimeInterval(30))
        firstController.persistSession()

        // The next launch comes an hour later.
        let secondRecorder = EmittedEventRecorder()
        secondRecorder.makeController(options: [.sessions], stateDirectory: stateDirectory, sessionMode: .inactivityTimeout(minutes: 10)).start(at: launchTime.addingTimeInterval(3600))

        let firstSessionID = try XCTUnwrap(firstRecorder.events.first?.sessionID)
        XCTAssertEqual(secondRecorder.events.map(\.eventName), ["session_end", "session_start"])
        XCTAssertEqual(secondRecorder.events[0].sessionID, firstSessionID)
        XCTAssertEqual(secondRecorder.events[0].properties["duration_s"], .int(30))
    }

    /// Busy tracking writes the session file at most once a minute, off the caller's thread.
    func testActivityWritesAreThrottled() throws {
        let stateDirectory = makeTemporaryDirectory()
        let controller = EmittedEventRecorder().makeController(options: [.sessions], stateDirectory: stateDirectory, sessionMode: .inactivityTimeout(minutes: 10))
        controller.start(at: launchTime)

        // The first activity is written; one ten seconds later is not.
        controller.recordTrackActivity(at: launchTime.addingTimeInterval(5))
        controller.recordTrackActivity(at: launchTime.addingTimeInterval(15))
        controller.waitForSessionWrites()
        XCTAssertEqual(try storedSession(in: stateDirectory).lastActiveAt, launchTime.addingTimeInterval(5))

        // A minute later it is written again.
        controller.recordTrackActivity(at: launchTime.addingTimeInterval(70))
        controller.waitForSessionWrites()
        XCTAssertEqual(try storedSession(in: stateDirectory).lastActiveAt, launchTime.addingTimeInterval(70))
    }

    /// The session file as saved on disk.
    private func storedSession(in stateDirectory: URL) throws -> SessionTracker.Session {
        let sessionFileURL = stateDirectory.appending(path: AutocaptureController.sessionFileName)

        return try JSONDecoder().decode(SessionTracker.Session.self, from: Data(contentsOf: sessionFileURL))
    }
}

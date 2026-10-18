import os
import XCTest
import Foundation

@testable import SimpleDataLogs

/// Records every event the controller emits, and the session id it sets.
final class EmittedEventRecorder: Sendable {
    /// One emitted event.
    struct EmittedEvent: Sendable, Equatable {
        /// The event name.
        let eventName: String

        /// Its properties.
        let properties: [String: PropertyValue]

        /// When it happened.
        let occurredAt: Date

        /// The session id it carries.
        let sessionID: String?
    }

    /// The events and the latest session id, behind a lock.
    private let recorded = OSAllocatedUnfairLock<(events: [EmittedEvent], sessionID: String?)>(initialState: ([], nil))

    /// Every event so far.
    var events: [EmittedEvent] {
        recorded.withLock { state in state.events }
    }

    /// The session id the facade would now put on events.
    var currentSessionID: String? {
        recorded.withLock { state in state.sessionID }
    }

    /// A controller for these options, writing state into `stateDirectory`.
    func makeController(options: AutocaptureOptions, stateDirectory: URL) -> AutocaptureController {
        AutocaptureController(
            options: options,
            stateDirectory: stateDirectory,
            emit: { [self] eventName, properties, occurredAt, sessionID in
                recorded.withLock { state in
                    state.events.append(EmittedEvent(eventName: eventName, properties: properties, occurredAt: occurredAt, sessionID: sessionID))
                }
            },
            setSessionID: { [self] sessionID in
                recorded.withLock { state in
                    state.sessionID = sessionID
                }
            }
        )
    }
}

/// Opt-in autocapture: launches, sessions across foreground and background, and crashes sent on the next launch.
final class AutocaptureTests: PipelineTestCase {
    /// A fixed launch time.
    private let launchTime = Date(timeIntervalSince1970: 1_791_796_443)

    /// Nothing is captured unless asked for, and `.all` is launches, sessions and crashes.
    func testAutocaptureIsOptIn() {
        let defaultOptions: AutocaptureOptions = []

        XCTAssertTrue(defaultOptions.isEmpty)
        XCTAssertEqual(AutocaptureOptions.all, [.appLaunches, .sessions, .crashes])
    }

    /// The first launch sends session_start then app_launched with is_first_launch, both in the new session; later launches say false.
    func testLaunchSendsSessionStartAndAppLaunched() {
        let stateDirectory = makeTemporaryDirectory()
        let recorder = EmittedEventRecorder()

        recorder.makeController(options: [.appLaunches, .sessions], stateDirectory: stateDirectory).start(at: launchTime)

        let events = recorder.events
        XCTAssertEqual(events.map(\.eventName), ["session_start", "app_launched"])
        XCTAssertEqual(events[1].properties["is_first_launch"], .bool(true))
        XCTAssertNotNil(events[0].sessionID)
        XCTAssertEqual(events[1].sessionID, events[0].sessionID)
        XCTAssertEqual(recorder.currentSessionID, events[0].sessionID)

        // A second launch a minute later resumes the stored session and is no longer the first.
        let secondRecorder = EmittedEventRecorder()
        secondRecorder.makeController(options: [.appLaunches, .sessions], stateDirectory: stateDirectory).start(at: launchTime.addingTimeInterval(60))

        XCTAssertEqual(secondRecorder.events.map(\.eventName), ["app_launched"])
        XCTAssertEqual(secondRecorder.events[0].properties["is_first_launch"], .bool(false))
        XCTAssertEqual(secondRecorder.currentSessionID, events[0].sessionID)
    }

    /// A short trip to the background keeps the session; 30 minutes away ends it at the background time and starts a new one.
    func testBackgroundLongerThanTheTimeoutEndsTheSession() throws {
        let recorder = EmittedEventRecorder()
        let controller = recorder.makeController(options: [.sessions], stateDirectory: makeTemporaryDirectory())

        controller.start(at: launchTime)
        let firstSessionID = try XCTUnwrap(recorder.currentSessionID)

        // Five minutes away: the same session.
        controller.appWentToBackground(at: launchTime.addingTimeInterval(60))
        controller.appBecameActive(at: launchTime.addingTimeInterval(360))
        XCTAssertEqual(recorder.events.map(\.eventName), ["session_start"])

        // Forty minutes away: session_end stamped when it left, with its length, then a new session.
        let leftAt = launchTime.addingTimeInterval(600)
        controller.appWentToBackground(at: leftAt)
        controller.appBecameActive(at: leftAt.addingTimeInterval(40 * 60))

        let events = recorder.events
        XCTAssertEqual(events.map(\.eventName), ["session_start", "session_end", "session_start"])
        XCTAssertEqual(events[1].sessionID, firstSessionID)
        XCTAssertEqual(events[1].occurredAt, leftAt)
        XCTAssertEqual(events[1].properties["duration_s"], .int(600))
        XCTAssertNotEqual(events[2].sessionID, firstSessionID)
        XCTAssertEqual(recorder.currentSessionID, events[2].sessionID)
    }

    /// An app killed in the background ends its session on the next launch, from the stored file.
    func testAKilledAppEndsItsSessionOnTheNextLaunch() {
        let stateDirectory = makeTemporaryDirectory()
        let firstRecorder = EmittedEventRecorder()
        let firstController = firstRecorder.makeController(options: [.sessions], stateDirectory: stateDirectory)

        firstController.start(at: launchTime)
        firstController.appWentToBackground(at: launchTime.addingTimeInterval(120))

        // The next launch comes hours later.
        let secondRecorder = EmittedEventRecorder()
        secondRecorder.makeController(options: [.sessions], stateDirectory: stateDirectory).start(at: launchTime.addingTimeInterval(4 * 3600))

        XCTAssertEqual(secondRecorder.events.map(\.eventName), ["session_end", "session_start"])
        XCTAssertEqual(secondRecorder.events[0].sessionID, firstRecorder.events[0].sessionID)
        XCTAssertEqual(secondRecorder.events[0].properties["duration_s"], .int(120))
    }

    /// A crash saved by the handler is sent as app_crashed on the next launch, stamped at the crash, then the file is gone.
    func testASavedCrashIsSentOnTheNextLaunch() throws {
        let stateDirectory = makeTemporaryDirectory()
        let crashedAt = launchTime.addingTimeInterval(-30)
        let crashFileURL = stateDirectory.appending(path: CrashRecorder.fileName)

        CrashRecorder.record(PendingCrash(exceptionName: "NSRangeException", reason: String(repeating: "r", count: 10_000), stack: "0 App main\n1 libdyld start", occurredAt: crashedAt), to: crashFileURL)

        let recorder = EmittedEventRecorder()
        recorder.makeController(options: [.crashes], stateDirectory: stateDirectory).start(at: launchTime)

        let crashEvent = try XCTUnwrap(recorder.events.first)
        XCTAssertEqual(crashEvent.eventName, "app_crashed")
        XCTAssertEqual(crashEvent.occurredAt.timeIntervalSince1970, crashedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(crashEvent.properties["exception_name"], .string("NSRangeException"))
        XCTAssertEqual(crashEvent.properties["stack"], .string("0 App main\n1 libdyld start"))
        XCTAssertEqual(crashEvent.properties["reason"], .string(String(repeating: "r", count: CrashRecorder.maxTextLength)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashFileURL.path))
    }

    /// The handler path writes the exception to the installed crash file.
    func testTheHandlerSavesAnUncaughtException() throws {
        let stateDirectory = makeTemporaryDirectory()
        CrashRecorder.install(stateDirectory: stateDirectory)

        CrashRecorder.handleUncaughtException(NSException(name: .invalidArgumentException, reason: "bad argument"))

        let pendingCrash = try XCTUnwrap(CrashRecorder.takePendingCrash(stateDirectory: stateDirectory))
        XCTAssertEqual(pendingCrash.exceptionName, NSExceptionName.invalidArgumentException.rawValue)
        XCTAssertEqual(pendingCrash.reason, "bad argument")
    }

    /// session_id goes on the wire only when set.
    func testSessionIDIsEncodedWhenSet() throws {
        let event = TrackedEvent.make(eventName: "app_launched", properties: [:], defaultProperties: [:], deviceID: nil, sessionID: "session-1")

        let eventObject = try XCTUnwrap(JSONSerialization.jsonObject(with: event.encodedLine()) as? [String: Any])
        XCTAssertEqual(eventObject["session_id"] as? String, "session-1")
    }
}

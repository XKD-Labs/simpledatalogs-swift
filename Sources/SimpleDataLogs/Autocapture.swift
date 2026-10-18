import os
import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// What `configure(ingestKey:endpoint:autocapture:)` captures without any `track` call; off unless asked for.
public struct AutocaptureOptions: OptionSet, Sendable {
    /// The option bits.
    public let rawValue: Int

    /// Creates options from their bits.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// `app_launched` on every launch, with `is_first_launch` on the first.
    public static let appLaunches = AutocaptureOptions(rawValue: 1 << 0)

    /// `session_start`, `session_end` and a `session_id` on every event; a session ends after 30 minutes away.
    public static let sessions = AutocaptureOptions(rawValue: 1 << 1)

    /// Uncaught NSExceptions, saved at the crash and sent as `app_crashed` on the next launch.
    public static let crashes = AutocaptureOptions(rawValue: 1 << 2)

    /// Everything: the one-line opt-in.
    public static let all: AutocaptureOptions = [.appLaunches, .sessions, .crashes]
}

/// The session state machine: active and background moments in, session_start and session_end out.
struct SessionTracker: Sendable, Equatable {
    /// A session as stored between launches.
    struct Session: Codable, Sendable, Equatable {
        /// The id sent as `session_id`.
        var id: String

        /// When the session began.
        var startedAt: Date

        /// The last moment the app was active, or when it went to the background.
        var lastActiveAt: Date

        /// True while the app is in the background.
        var isInBackground: Bool
    }

    /// What a moment produced, in order.
    enum Change: Sendable, Equatable {
        /// A session began.
        case started(sessionID: String, at: Date)

        /// A session ended at its last activity, after this many seconds.
        case ended(sessionID: String, at: Date, durationSeconds: Int)
    }

    /// Time away that ends a session, as in Firebase and most app analytics.
    static let timeout: TimeInterval = 30 * 60

    /// The current session, if any.
    var session: Session?

    /// The app became active: ends a session idle for the whole timeout, then starts one or resumes the current one.
    mutating func appBecameActive(at now: Date, newSessionID: () -> String = { UUID().uuidString }) -> [Change] {
        var changes: [Change] = []

        // A session away for the whole timeout ends where its activity stopped.
        if let currentSession = session, now.timeIntervalSince(currentSession.lastActiveAt) >= Self.timeout {
            let durationSeconds = max(0, Int(currentSession.lastActiveAt.timeIntervalSince(currentSession.startedAt).rounded()))
            changes.append(.ended(sessionID: currentSession.id, at: currentSession.lastActiveAt, durationSeconds: durationSeconds))
            session = nil
        }

        // No session: start one; otherwise resume it.
        if session == nil {
            let startedSession = Session(id: newSessionID(), startedAt: now, lastActiveAt: now, isInBackground: false)
            session = startedSession
            changes.append(.started(sessionID: startedSession.id, at: now))
        } else {
            session?.lastActiveAt = now
            session?.isInBackground = false
        }

        return changes
    }

    /// The app went to the background: remembers when, so the next activity can decide whether the session ended.
    mutating func appWentToBackground(at now: Date) {
        session?.lastActiveAt = now
        session?.isInBackground = true
    }
}

/// Saved at the moment of an uncaught NSException, sent on the next launch.
struct PendingCrash: Codable, Sendable, Equatable {
    /// The exception's name, e.g. `NSRangeException`.
    var exceptionName: String

    /// The exception's reason.
    var reason: String

    /// The call stack, one frame per line, bounded.
    var stack: String

    /// When the crash happened.
    var occurredAt: Date
}

/// Writes and reads the crash file; the uncaught-exception handler can only reach static state.
enum CrashRecorder {
    /// The file one crash is saved to.
    static let fileName = "pending-crash.json"

    /// The most stack frames kept.
    static let maxStackFrames = 40

    /// The most characters kept of the reason and the stack.
    static let maxTextLength = 4_000

    /// Guards the two handler values below; they are written once, at install.
    private static let installLock = NSLock()

    /// Where the handler writes; nil until installed.
    private nonisolated(unsafe) static var crashFileURL: URL?

    /// The handler installed before ours, called after we save the crash.
    private nonisolated(unsafe) static var previousHandler: NSUncaughtExceptionHandler?

    /// Installs the uncaught-exception handler once, keeping any earlier handler in the chain.
    static func install(stateDirectory: URL) {
        installLock.lock()
        defer { installLock.unlock() }

        // A second configure only moves the crash file.
        let isAlreadyInstalled = crashFileURL != nil
        crashFileURL = stateDirectory.appending(path: fileName, directoryHint: .notDirectory)

        guard !isAlreadyInstalled else {
            return
        }

        previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CrashRecorder.handleUncaughtException(exception)
        }
    }

    /// Saves the exception synchronously, then hands it to the previous handler; the process is about to die.
    static func handleUncaughtException(_ exception: NSException) {
        // No lock here: the values are set once at install, and a crash must never wait.
        if let crashFileURL {
            record(
                PendingCrash(
                    exceptionName: exception.name.rawValue,
                    reason: exception.reason ?? "",
                    stack: exception.callStackSymbols.prefix(maxStackFrames).joined(separator: "\n"),
                    occurredAt: Date()
                ),
                to: crashFileURL
            )
        }

        previousHandler?(exception)
    }

    /// Writes one crash to the file, bounded; a failure is ignored, the app is crashing anyway.
    static func record(_ crash: PendingCrash, to crashFileURL: URL) {
        var boundedCrash = crash
        boundedCrash.reason = String(crash.reason.prefix(maxTextLength))
        boundedCrash.stack = String(crash.stack.prefix(maxTextLength))

        try? FileManager.default.createDirectory(at: crashFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(boundedCrash).write(to: crashFileURL)
    }

    /// Reads and deletes the crash a previous launch saved, if any.
    static func takePendingCrash(stateDirectory: URL) -> PendingCrash? {
        let crashFileURL = stateDirectory.appending(path: fileName, directoryHint: .notDirectory)

        guard let crashData = try? Data(contentsOf: crashFileURL) else {
            return nil
        }

        try? FileManager.default.removeItem(at: crashFileURL)
        return try? JSONDecoder().decode(PendingCrash.self, from: crashData)
    }
}

/// Runs the enabled autocapture features and turns their moments into events.
final class AutocaptureController: Sendable {
    /// Sends one event with its own time and session id.
    typealias Emit = @Sendable (_ eventName: String, _ properties: [String: PropertyValue], _ occurredAt: Date, _ sessionID: String?) -> Void

    /// The session file, kept beside the outbox.
    static let sessionFileName = "session.json"

    /// The marker written on the first launch.
    static let firstLaunchMarkerName = "first-launch.marker"

    /// The features turned on.
    let options: AutocaptureOptions

    /// The folder for the session file, the crash file and the first-launch marker.
    let stateDirectory: URL

    /// Where events go.
    private let emit: Emit

    /// Sets the session id on every later event.
    private let setSessionID: @Sendable (String?) -> Void

    /// The session state, behind a lock.
    private let sessionTracker: OSAllocatedUnfairLock<SessionTracker>

    /// Reads the stored session, if sessions are on.
    init(options: AutocaptureOptions, stateDirectory: URL, emit: @escaping Emit, setSessionID: @escaping @Sendable (String?) -> Void) {
        self.options = options
        self.stateDirectory = stateDirectory
        self.emit = emit
        self.setSessionID = setSessionID
        self.sessionTracker = OSAllocatedUnfairLock(initialState: SessionTracker(session: Self.readSession(in: stateDirectory)))
    }

    /// The launch: the last launch's crash, app_launched, and the session; then the crash handler.
    func start(at now: Date = Date()) {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        // A crash saved by the last launch goes first, stamped when it happened.
        if options.contains(.crashes), let pendingCrash = CrashRecorder.takePendingCrash(stateDirectory: stateDirectory) {
            let crashProperties: [String: PropertyValue] = [
                "exception_name": .string(pendingCrash.exceptionName),
                "reason": .string(pendingCrash.reason),
                "stack": .string(pendingCrash.stack),
            ]
            emit("app_crashed", crashProperties, pendingCrash.occurredAt, nil)
        }

        // Launching counts as becoming active, so the session starts before app_launched and carries it.
        if options.contains(.sessions) {
            appBecameActive(at: now)
        }

        if options.contains(.appLaunches) {
            emit("app_launched", ["is_first_launch": .bool(markFirstLaunch())], now, currentSessionID)
        }

        if options.contains(.crashes) {
            CrashRecorder.install(stateDirectory: stateDirectory)
        }
    }

    /// Feeds an active moment to the session tracker and sends what it produced.
    func appBecameActive(at now: Date = Date()) {
        guard options.contains(.sessions) else {
            return
        }

        let (changes, session) = sessionTracker.withLock { tracker in
            (tracker.appBecameActive(at: now), tracker.session)
        }

        // Each change is sent with its own session id; later events carry the current one.
        for change in changes {
            switch change {
            case .ended(let sessionID, let endedAt, let durationSeconds):
                emit("session_end", ["duration_s": .int(durationSeconds)], endedAt, sessionID)
            case .started(let sessionID, let startedAt):
                setSessionID(sessionID)
                emit("session_start", [:], startedAt, sessionID)
            }
        }

        setSessionID(session?.id)
        writeSession(session)
    }

    /// Feeds a background moment to the session tracker and saves it, so a later launch can end the session.
    func appWentToBackground(at now: Date = Date()) {
        guard options.contains(.sessions) else {
            return
        }

        let session = sessionTracker.withLock { tracker in
            tracker.appWentToBackground(at: now)
            return tracker.session
        }

        writeSession(session)
    }

    /// The current session id, if any.
    var currentSessionID: String? {
        sessionTracker.withLock { tracker in tracker.session?.id }
    }

    /// Listens for the app becoming active and going to the background (iOS foreground/background, macOS activation).
    func observeAppActivity() {
        guard options.contains(.sessions) else {
            return
        }

        for (notificationName, isBecomingActive) in Self.activityNotifications {
            // The center keeps block observers alive for the life of the process, like the lifecycle observer.
            _ = NotificationCenter.default.addObserver(forName: notificationName, object: nil, queue: nil) { [self] _ in
                if isBecomingActive {
                    appBecameActive()
                } else {
                    appWentToBackground()
                }
            }
        }
    }

    /// The activity notifications on this platform, each with whether it means becoming active.
    private static var activityNotifications: [(Notification.Name, Bool)] {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)]
        #elseif canImport(UIKit) && !os(watchOS)
        return [(UIApplication.willEnterForegroundNotification, true), (UIApplication.didEnterBackgroundNotification, false)]
        #else
        return []
        #endif
    }

    /// True on the very first launch; writes the marker so later launches say false.
    private func markFirstLaunch() -> Bool {
        let markerURL = stateDirectory.appending(path: Self.firstLaunchMarkerName, directoryHint: .notDirectory)

        guard !FileManager.default.fileExists(atPath: markerURL.path) else {
            return false
        }

        FileManager.default.createFile(atPath: markerURL.path, contents: Data())
        return true
    }

    /// Saves the session, or deletes the file when there is none.
    private func writeSession(_ session: SessionTracker.Session?) {
        let sessionFileURL = stateDirectory.appending(path: Self.sessionFileName, directoryHint: .notDirectory)

        guard let session, let sessionData = try? JSONEncoder().encode(session) else {
            try? FileManager.default.removeItem(at: sessionFileURL)
            return
        }

        try? sessionData.write(to: sessionFileURL, options: .atomic)
    }

    /// The session a previous launch saved, if readable.
    private static func readSession(in stateDirectory: URL) -> SessionTracker.Session? {
        let sessionFileURL = stateDirectory.appending(path: sessionFileName, directoryHint: .notDirectory)

        guard let sessionData = try? Data(contentsOf: sessionFileURL) else {
            return nil
        }

        return try? JSONDecoder().decode(SessionTracker.Session.self, from: sessionData)
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// The SwiftUI screen-view helper.
extension View {
    /// Sends `screen_view` with this screen name each time the view appears.
    public func trackScreenView(_ screenName: String, properties: [String: PropertyValue] = [:]) -> some View {
        onAppear {
            SimpleDataLogs.trackScreen(screenName, properties: properties)
        }
    }
}
#endif

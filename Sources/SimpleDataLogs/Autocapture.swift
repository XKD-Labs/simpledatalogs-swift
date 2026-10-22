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

    /// `session_start`, `session_end` and a `session_id` on every event; `SessionMode` decides when a session ends.
    public static let sessions = AutocaptureOptions(rawValue: 1 << 1)

    /// Uncaught NSExceptions, saved at the crash and sent as `app_crashed` on the next launch.
    public static let crashes = AutocaptureOptions(rawValue: 1 << 2)

    /// Everything: the one-line opt-in.
    public static let all: AutocaptureOptions = [.appLaunches, .sessions, .crashes]
}

/// How `.sessions` decides when a session starts and ends.
public enum SessionMode: Sendable, Equatable {
    /// Sessions follow the app becoming active (macOS) or coming to the foreground (iOS), and end after 30 minutes away.
    case activation

    /// Sessions follow `track` calls: this many minutes without one ends the session; suits menu-bar and accessory apps.
    case inactivityTimeout(minutes: Int)

    /// The gap that ends a session in this mode, at least one minute.
    var timeout: TimeInterval {
        switch self {
        case .activation:
            return SessionTracker.defaultTimeout
        case .inactivityTimeout(let minutes):
            return TimeInterval(max(minutes, 1) * 60)
        }
    }
}

/// How much of an uncaught exception's reason `.crashes` sends.
public struct CrashReasonRedaction: Sendable, Equatable {
    /// Replaces digit runs with `#`, and UUIDs and hex values with `<uuid>` and `<hex>`.
    public var shouldStripNumbers: Bool

    /// Replaces file paths and file URLs with `<path>`.
    public var shouldStripPaths: Bool

    /// Replaces email addresses with `<email>`.
    public var shouldStripEmails: Bool

    /// The most characters of the reason sent, after redaction.
    public var maxLength: Int

    /// Creates a redaction; the defaults strip numbers, paths and emails and keep 200 characters.
    public init(shouldStripNumbers: Bool = true, shouldStripPaths: Bool = true, shouldStripEmails: Bool = true, maxLength: Int = 200) {
        self.shouldStripNumbers = shouldStripNumbers
        self.shouldStripPaths = shouldStripPaths
        self.shouldStripEmails = shouldStripEmails
        self.maxLength = maxLength
    }

    /// The reason word for word, up to 4,000 characters (the default).
    public static let verbatim = CrashReasonRedaction(shouldStripNumbers: false, shouldStripPaths: false, shouldStripEmails: false, maxLength: CrashRecorder.maxTextLength)

    /// Numbers, paths and emails stripped, cut at 200 characters.
    public static let standard = CrashReasonRedaction()

    /// Applies this redaction to one exception reason.
    func redact(_ reason: String) -> String {
        var redactedReason = reason

        // Emails go first, since they also contain digits and dots.
        if shouldStripEmails {
            redactedReason = redactedReason.replacingMatches(of: Self.emailPattern, with: "<email>")
        }

        if shouldStripPaths {
            redactedReason = redactedReason.replacingMatches(of: Self.fileURLPattern, with: "<path>")
            redactedReason = redactedReason.replacingMatches(of: Self.pathPattern, with: "<path>")
        }

        // Whole identifiers first, then whatever digits remain.
        if shouldStripNumbers {
            redactedReason = redactedReason.replacingMatches(of: Self.uuidPattern, with: "<uuid>")
            redactedReason = redactedReason.replacingMatches(of: Self.hexPattern, with: "<hex>")
            redactedReason = redactedReason.replacingMatches(of: "[0-9]+", with: "#")
        }

        return redactedReason.truncated(toCharacterCount: max(maxLength, 0))
    }

    /// An email address.
    static let emailPattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"

    /// A `file://` URL.
    static let fileURLPattern = "file://[^\\s'\"]+"

    /// An absolute, home-relative or dot-relative path that starts a word, e.g. `/var/mobile/a.txt` or `~/a.txt`.
    static let pathPattern = "(?<![\\w.~])(?:~|\\.{1,2})?/[^\\s'\",:;()\\[\\]{}<>]+"

    /// A UUID.
    static let uuidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

    /// A `0x` value, or a run of 8 or more hex characters that holds a digit.
    static let hexPattern = "0x[0-9A-Fa-f]+|\\b(?=[0-9A-Fa-f]*[0-9])[0-9A-Fa-f]{8,}\\b"
}

/// Regular expression helpers for redaction.
extension String {
    /// Replaces every match of `pattern` with `replacement`; an invalid pattern leaves the text unchanged.
    func replacingMatches(of pattern: String, with replacement: String) -> String {
        guard let regularExpression = try? NSRegularExpression(pattern: pattern) else {
            return self
        }

        let fullRange = NSRange(startIndex..., in: self)
        let escapedReplacement = NSRegularExpression.escapedTemplate(for: replacement)

        return regularExpression.stringByReplacingMatches(in: self, range: fullRange, withTemplate: escapedReplacement)
    }

    /// Cuts the text to at most `characterCount` characters, ending a cut text with `…`.
    func truncated(toCharacterCount characterCount: Int) -> String {
        guard count > characterCount else {
            return self
        }

        guard characterCount > 0 else {
            return ""
        }

        return String(prefix(characterCount - 1)) + "…"
    }
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
    static let defaultTimeout: TimeInterval = 30 * 60

    /// The current session, if any.
    var session: Session?

    /// Time away, or without activity, that ends a session.
    var timeout: TimeInterval = SessionTracker.defaultTimeout

    /// The app became active: ends a session idle for the whole timeout, then starts one or resumes the current one.
    mutating func appBecameActive(at now: Date, newSessionID: () -> String = { UUID().uuidString }) -> [Change] {
        var changes: [Change] = []

        // A session away for the whole timeout ends where its activity stopped.
        if let currentSession = session, now.timeIntervalSince(currentSession.lastActiveAt) >= timeout {
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

    /// A `track` call happened: like becoming active, but a moment earlier than the last activity changes nothing.
    mutating func recordActivity(at now: Date, newSessionID: () -> String = { UUID().uuidString }) -> [Change] {
        // Activity never moves backwards, e.g. after the clock was set back.
        if let currentSession = session, now < currentSession.lastActiveAt {
            return []
        }

        return appBecameActive(at: now, newSessionID: newSessionID)
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

    /// A path inside a stack frame, keeping its last component, e.g. `/Volumes/Work/App/Sources/Store.swift`.
    static let framePathPattern = "(?<![\\w.~])(?:file://|~|\\.{1,2})?/(?:[^\\s/]+/)*([^\\s/]+)"

    /// The stack with every file path cut to its module or file name.
    static func trimmedStack(_ stack: String) -> String {
        guard let regularExpression = try? NSRegularExpression(pattern: framePathPattern) else {
            return stack
        }

        return regularExpression.stringByReplacingMatches(in: stack, range: NSRange(stack.startIndex..., in: stack), withTemplate: "$1")
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

    /// Whether sessions follow app activation or `track` activity.
    let sessionMode: SessionMode

    /// How much of a crash reason is sent.
    let crashReasonRedaction: CrashReasonRedaction

    /// The session state, behind a lock.
    private let sessionTracker: OSAllocatedUnfairLock<SessionTracker>

    /// When the session file was last written for plain activity, so busy tracking writes it at most once a minute.
    private let lastActivityWriteAt = OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// Serializes session file writes, so an activity write never lands after a newer one.
    private let sessionFileQueue = DispatchQueue(label: "com.simpledatalogs.session-file", qos: .utility)

    /// The longest plain activity goes unsaved; a killed app's session ends at most this much early.
    static let activityWriteInterval: TimeInterval = 60

    /// Reads the stored session, if sessions are on.
    init(
        options: AutocaptureOptions,
        stateDirectory: URL,
        sessionMode: SessionMode = .activation,
        crashReasonRedaction: CrashReasonRedaction = .verbatim,
        emit: @escaping Emit,
        setSessionID: @escaping @Sendable (String?) -> Void
    ) {
        self.options = options
        self.stateDirectory = stateDirectory
        self.sessionMode = sessionMode
        self.crashReasonRedaction = crashReasonRedaction
        self.emit = emit
        self.setSessionID = setSessionID
        self.sessionTracker = OSAllocatedUnfairLock(
            initialState: SessionTracker(session: Self.readSession(in: stateDirectory), timeout: sessionMode.timeout)
        )
    }

    /// The launch: the last launch's crash, app_launched, and the session; then the crash handler.
    func start(at now: Date = Date()) {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        // A crash saved by the last launch goes first, stamped when it happened.
        if options.contains(.crashes), let pendingCrash = CrashRecorder.takePendingCrash(stateDirectory: stateDirectory) {
            // The reason is redacted as configured; frame paths are always cut to their file name.
            let crashProperties: [String: PropertyValue] = [
                "exception_name": .string(pendingCrash.exceptionName),
                "reason": .string(crashReasonRedaction.redact(pendingCrash.reason)),
                "stack": .string(CrashRecorder.trimmedStack(pendingCrash.stack)),
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

        emitSessionChanges(changes, currentSession: session)
        writeSession(session)
    }

    /// In inactivity-timeout mode, counts one `track` call as activity, sending session_end and session_start first when the gap was long enough.
    func recordTrackActivity(at now: Date = Date()) {
        guard options.contains(.sessions), sessionMode != .activation else {
            return
        }

        // Emit under the lock, so a concurrent track never sees the new session before its session_start is queued.
        let (changes, session) = sessionTracker.withLock { tracker in
            let changes = tracker.recordActivity(at: now)
            emitSessionChanges(changes, currentSession: tracker.session)
            return (changes, tracker.session)
        }

        // A new session is saved at once; plain activity at most once a minute.
        let shouldWriteSession = lastActivityWriteAt.withLock { lastWriteAt in
            guard !changes.isEmpty || lastWriteAt.map({ now.timeIntervalSince($0) >= Self.activityWriteInterval }) ?? true else {
                return false
            }

            lastWriteAt = now
            return true
        }

        if shouldWriteSession {
            writeSession(session, waitsForDisk: false)
        }
    }

    /// Saves the session as it is now, waiting for the disk; termination calls it so the next launch ends the session on time.
    func persistSession() {
        guard options.contains(.sessions) else {
            return
        }

        writeSession(currentSession)
    }

    /// Blocks until every queued session write is on disk.
    func waitForSessionWrites() {
        sessionFileQueue.sync {}
    }

    /// Sends each change with its own session id, then points later events at the current session.
    private func emitSessionChanges(_ changes: [SessionTracker.Change], currentSession: SessionTracker.Session?) {
        for change in changes {
            switch change {
            case .ended(let sessionID, let endedAt, let durationSeconds):
                emit("session_end", ["duration_s": .int(durationSeconds)], endedAt, sessionID)
            case .started(let sessionID, let startedAt):
                setSessionID(sessionID)
                emit("session_start", [:], startedAt, sessionID)
            }
        }

        setSessionID(currentSession?.id)
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
        currentSession?.id
    }

    /// The current session, if any.
    private var currentSession: SessionTracker.Session? {
        sessionTracker.withLock { tracker in tracker.session }
    }

    /// Listens for the app becoming active and going to the background (iOS foreground/background, macOS activation).
    func observeAppActivity() {
        // In inactivity-timeout mode, only track calls move sessions.
        guard options.contains(.sessions), sessionMode == .activation else {
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

    /// Saves the session, or deletes the file when there is none; writes run in order on one queue.
    private func writeSession(_ session: SessionTracker.Session?, waitsForDisk: Bool = true) {
        let sessionFileURL = stateDirectory.appending(path: Self.sessionFileName, directoryHint: .notDirectory)

        // The write itself, run on the session file queue.
        let storeSession: @Sendable () -> Void = {
            guard let session, let sessionData = try? JSONEncoder().encode(session) else {
                try? FileManager.default.removeItem(at: sessionFileURL)
                return
            }

            try? sessionData.write(to: sessionFileURL, options: .atomic)
        }

        // A track call never waits for the disk; activation and termination do.
        if waitsForDisk {
            sessionFileQueue.sync(execute: storeSession)
        } else {
            sessionFileQueue.async(execute: storeSession)
        }
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

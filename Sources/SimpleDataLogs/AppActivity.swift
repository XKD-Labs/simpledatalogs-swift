import os
import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import CoreGraphics
#elseif canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Whether events say if someone was using the app (`app_state`) and for how long (`engaged_ms`).
public enum ActivityReporting: Sendable, Equatable {
    /// Every event tracked now carries `app_state`, and `engaged_ms` while the app is in front.
    case automatic

    /// Events carry neither; the server counts every session as active.
    case off
}

/// The app's foreground time between events: active and background moments in, one stamp per event out.
struct ActivityTracker: Sendable, Equatable {
    /// The longest engaged time one event reports: a day, as the server accepts.
    static let maxEngagedMilliseconds = 86_400_000

    /// True while the app is in front (macOS active app, iOS foreground).
    private(set) var isAppActive: Bool

    /// When the current foreground stretch started, or the last stamp inside it.
    private var activeSince: Date?

    /// Foreground time from stretches that ended since the last stamp.
    private var finishedActiveSeconds: TimeInterval = 0

    /// Starts in the given state, e.g. active when the app launched in front.
    init(isAppActive: Bool, at now: Date) {
        self.isAppActive = isAppActive
        activeSince = isAppActive ? now : nil
    }

    /// The app came to the front.
    mutating func appBecameActive(at now: Date) {
        guard !isAppActive else {
            return
        }

        isAppActive = true
        activeSince = now
    }

    /// The app went to the background; its foreground stretch so far is kept for the next stamp.
    mutating func appResignedActive(at now: Date) {
        guard isAppActive else {
            return
        }

        finishedActiveSeconds += activeSeconds(until: now)
        isAppActive = false
        activeSince = nil
    }

    /// The props for one event tracked now; user input in the last few seconds counts as active (a menu-bar hotkey never activates the app).
    mutating func stamp(at now: Date, hasRecentInput: Bool) -> [String: PropertyValue] {
        // Foreground time since the last stamp, then a fresh count from now.
        let engagedSeconds = finishedActiveSeconds + activeSeconds(until: now)
        finishedActiveSeconds = 0
        activeSince = isAppActive ? now : nil

        // Background events say so; their engaged time is 0 by definition on the server.
        guard isAppActive || hasRecentInput else {
            return ["app_state": .string("background")]
        }

        // Without a foreground stretch, input alone gives no measured time, so the server estimates it.
        guard engagedSeconds > 0 || isAppActive else {
            return ["app_state": .string("active")]
        }

        let engagedMilliseconds = min(Int((engagedSeconds * 1000).rounded()), Self.maxEngagedMilliseconds)
        return ["app_state": .string("active"), "engaged_ms": .int(engagedMilliseconds)]
    }

    /// The current stretch's length up to now, never negative.
    private func activeSeconds(until now: Date) -> TimeInterval {
        guard let activeSince else {
            return 0
        }

        return max(now.timeIntervalSince(activeSince), 0)
    }
}

/// Feeds the tracker from the platform's activation notifications and reads recent user input on macOS.
final class ActivityMonitor: Sendable {
    /// Input this recent means a person is at the Mac, e.g. a screenshot hotkey.
    static let recentInputSeconds: TimeInterval = 10

    /// The tracker, behind a lock, since events are tracked from any thread.
    private let tracker: OSAllocatedUnfairLock<ActivityTracker>

    /// Starts with the app's current state and begins listening.
    init(now: Date = Date()) {
        tracker = OSAllocatedUnfairLock(initialState: ActivityTracker(isAppActive: Self.isAppInFront(), at: now))
        observe()
    }

    /// The props for one event tracked now.
    func stamp(at now: Date = Date()) -> [String: PropertyValue] {
        let hasRecentInput = Self.hasRecentInput()
        return tracker.withLock { tracker in tracker.stamp(at: now, hasRecentInput: hasRecentInput) }
    }

    /// Listens for the app coming to the front and leaving it, for the life of the process.
    private func observe() {
        for (notificationName, isBecomingActive) in Self.activityNotifications {
            _ = NotificationCenter.default.addObserver(forName: notificationName, object: nil, queue: nil) { [tracker] _ in
                let now = Date()

                tracker.withLock { tracker in
                    if isBecomingActive {
                        tracker.appBecameActive(at: now)
                    } else {
                        tracker.appResignedActive(at: now)
                    }
                }
            }
        }
    }

    /// The notifications that move the app in or out of the front, each with whether it means becoming active.
    private static var activityNotifications: [(Notification.Name, Bool)] {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)]
        #elseif canImport(UIKit) && !os(watchOS)
        return [(UIApplication.willEnterForegroundNotification, true), (UIApplication.didEnterBackgroundNotification, false)]
        #else
        return []
        #endif
    }

    /// Whether the app is in front right now; read on the main thread, as AppKit and UIKit expect.
    private static func isAppInFront() -> Bool {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return onMainThread { NSApplication.shared.isActive }
        #elseif canImport(UIKit) && !os(watchOS)
        return onMainThread { UIApplication.shared.applicationState != .background }
        #else
        return true
        #endif
    }

    /// True when the person pressed a key or moved the pointer in the last few seconds (macOS; no permission needed).
    private static func hasRecentInput() -> Bool {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // Every input type at once, as CoreGraphics spells kCGAnyInputEventType.
        guard let anyInputEventType = CGEventType(rawValue: ~0) else {
            return false
        }

        let secondsSinceInput = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEventType)
        return secondsSinceInput <= recentInputSeconds
        #else
        return false
        #endif
    }

    /// Runs a read on the main thread, at once when already there.
    private static func onMainThread<Value: Sendable>(_ read: @MainActor () -> Value) -> Value {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(read)
        }

        return DispatchQueue.main.sync { MainActor.assumeIsolated(read) }
    }
}

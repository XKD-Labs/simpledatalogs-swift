import os
import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The app lifecycle moments the SDK reacts to.
enum LifecycleMoment: Sendable, Equatable {
    /// The app is about to exit.
    case terminating

    /// An iOS app is moving to the background, or the Mac is going to sleep.
    case suspending
}

/// Reports app termination, Mac sleep and iOS backgrounding, so the facade can flush.
enum LifecycleFlushObserver {
    /// Registers the observers; `handler` runs on the posting thread, the main thread for every moment here.
    static func startObserving(handler: @escaping @Sendable (LifecycleMoment) -> Void) {
        for (notificationCenter, notificationName, lifecycleMoment) in observedNotifications {
            // The center keeps block observers alive for the life of the process, so the token is not needed.
            _ = notificationCenter.addObserver(forName: notificationName, object: nil, queue: nil) { _ in
                handler(lifecycleMoment)
            }
        }
    }

    /// The notifications worth a flush on this platform, each with the center that posts it.
    private static var observedNotifications: [(NotificationCenter, Notification.Name, LifecycleMoment)] {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // macOS has no background state; quitting and sleeping are when the network goes away.
        return [
            (NotificationCenter.default, NSApplication.willTerminateNotification, .terminating),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, .suspending),
        ]
        #elseif canImport(UIKit) && !os(watchOS)
        return [
            (NotificationCenter.default, UIApplication.willTerminateNotification, .terminating),
            (NotificationCenter.default, UIApplication.didEnterBackgroundNotification, .suspending),
        ]
        #else
        return []
        #endif
    }
}

/// Background time for the last send when an iOS app moves to the background; a no-op elsewhere.
final class BackgroundTimeRequest: Sendable {
    /// The longest the SDK keeps an iOS app awake in the background, well inside the system's own limit.
    static let timeLimit: TimeInterval = 20

    #if canImport(UIKit) && !os(watchOS)
    /// The system's id for the background task, `.invalid` once it was given back.
    private let taskIdentifier = OSAllocatedUnfairLock<UIBackgroundTaskIdentifier>(initialState: .invalid)
    #endif

    /// Asks iOS for background time, or returns nil off the main thread, in app extensions and on macOS.
    static func begin() -> BackgroundTimeRequest? {
        #if canImport(UIKit) && !os(watchOS)
        guard Thread.isMainThread else {
            return nil
        }

        return MainActor.assumeIsolated {
            guard let application = sharedApplication() else {
                return nil
            }

            // The expiry handler and the time limit both give the time back, whichever comes first.
            let request = BackgroundTimeRequest()
            let taskIdentifier = application.beginBackgroundTask(withName: "SimpleDataLogs last send") {
                request.end()
            }
            request.taskIdentifier.withLock { storedIdentifier in
                storedIdentifier = taskIdentifier
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeLimit) {
                request.end()
            }

            return request
        }
        #else
        return nil
        #endif
    }

    /// Gives the background time back; safe to call more than once, from any thread.
    func end() {
        #if canImport(UIKit) && !os(watchOS)
        // Take the id exactly once, so the task is ended exactly once.
        let taskIdentifier = taskIdentifier.withLock { storedIdentifier in
            let currentIdentifier = storedIdentifier
            storedIdentifier = .invalid
            return currentIdentifier
        }

        guard taskIdentifier != .invalid else {
            return
        }

        Task { @MainActor in
            Self.sharedApplication()?.endBackgroundTask(taskIdentifier)
        }
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// The app's UIApplication, looked up at run time so the SDK stays safe to link into app extensions.
    @MainActor
    private static func sharedApplication() -> UIApplication? {
        // App extensions have no shared application to ask.
        guard Bundle.main.bundleURL.pathExtension != "appex" else {
            return nil
        }

        let sharedApplicationSelector = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: sharedApplicationSelector) else {
            return nil
        }

        return UIApplication.perform(sharedApplicationSelector)?.takeUnretainedValue() as? UIApplication
    }
    #endif
}

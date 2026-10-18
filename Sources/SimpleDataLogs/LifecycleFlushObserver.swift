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

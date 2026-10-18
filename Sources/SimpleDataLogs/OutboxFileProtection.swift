import Foundation

/// How the outbox protects its files on disk, and how it recognizes a read blocked by that protection.
struct OutboxFileProtection: Sendable {
    /// Writes a whole file atomically, with the protection class where the platform has one.
    var writeAtomically: @Sendable (_ fileBody: Data, _ fileURL: URL) throws -> Void

    /// Sets the protection class on an existing file or folder; new files in a protected folder inherit it.
    var protectExistingItem: @Sendable (_ itemURL: URL) throws -> Void

    /// True when a read failed only because protected data is unavailable, so the read should simply be tried later.
    var isProtectedDataUnavailable: @Sendable (_ readError: any Error) -> Bool

    /// The protection this platform uses: until first unlock on iOS-family devices, nothing on macOS.
    static var platformDefault: OutboxFileProtection {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return untilFirstUserAuthentication
        #else
        return unprotected
        #endif
    }

    /// Plain atomic writes, for platforms without data protection.
    static let unprotected = OutboxFileProtection(
        writeAtomically: { fileBody, fileURL in try fileBody.write(to: fileURL, options: .atomic) },
        protectExistingItem: { _ in },
        isProtectedDataUnavailable: { _ in false }
    )

    #if canImport(Darwin)
    /// The protection class every outbox file and folder gets: readable once the user has unlocked the device after boot.
    static let protectionType = FileProtectionType.completeUntilFirstUserAuthentication

    /// The options for every atomic outbox write under that protection class.
    static let protectedWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    /// The standard choice for analytics queues, so background work on a locked device can still read and write the outbox.
    static let untilFirstUserAuthentication = OutboxFileProtection(
        writeAtomically: { fileBody, fileURL in try fileBody.write(to: fileURL, options: protectedWriteOptions) },
        protectExistingItem: { itemURL in
            try FileManager.default.setAttributes([.protectionKey: protectionType], ofItemAtPath: itemURL.path)
        },
        isProtectedDataUnavailable: isPermissionDenied
    )
    #endif

    /// True when an error, or any error under it, is a denied read: how iOS reports a file locked by data protection.
    static func isPermissionDenied(_ readError: any Error) -> Bool {
        let nsError = readError as NSError

        // Foundation's own code for a read it was not allowed to make.
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return true
        }

        // The POSIX codes a locked file's open() fails with.
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return true
        }

        // Foundation often wraps the POSIX error, so look underneath.
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlyingError)
        }

        return false
    }
}

/// The read failures the outbox reports in its own words.
enum OutboxReadError: Error {
    /// The file is fine but locked by data protection until the user unlocks the device; try again later.
    case protectedDataUnavailable(underlyingError: any Error)
}

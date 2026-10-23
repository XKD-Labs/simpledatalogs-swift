import Foundation

/// Every tunable the pipeline reads; the defaults follow the ingest API, and tests shrink them.
struct PipelineConfiguration: Sendable {
    /// 5 s in debug builds, so a new event shows within seconds; 10 s in release, to spare battery and requests.
    static var defaultBatchInterval: Duration {
        #if DEBUG
        .seconds(5)
        #else
        .seconds(10)
        #endif
    }

    /// The full ingest URL, `<endpoint>/v1/ingest`.
    var ingestURL: URL

    /// The bearer key sent with every request.
    var ingestKey: String

    /// The outbox folder holding the journal and the sealed batches.
    var storageDirectory: URL

    /// Seal and send as soon as the journal holds this many events.
    var maxBatchEventCount = 50

    /// Seal and send a partial batch this long after its first event.
    var batchInterval: Duration = PipelineConfiguration.defaultBatchInterval

    /// The largest request body ever sent, safely under the 256 KB the ingest API allows.
    var maxRequestBytes = 256_000

    /// The most events the outbox keeps before it drops the oldest batches.
    var maxOutboxEventCount = 10_000

    /// The most bytes the outbox keeps before it drops the oldest batches.
    var maxOutboxBytes = 10 * 1024 * 1024

    /// Backoff and Retry-After rules for failed sends.
    var retryPolicy = RetryPolicy()

    /// How long one request may take before it counts as a timeout.
    var requestTimeout: TimeInterval = 30

    /// Reads of one batch that may fail in a row before it is set aside, so it cannot block newer batches.
    var maxBatchReadAttempts = 3

    /// The data protection class for outbox files, and how a read blocked by it is recognized.
    var fileProtection = OutboxFileProtection.platformDefault

    /// The outbox limits derived from this configuration.
    var outboxLimits: OutboxLimits {
        OutboxLimits(
            maxBatchEventCount: maxBatchEventCount,
            maxBatchBytes: maxRequestBytes,
            maxTotalEventCount: maxOutboxEventCount,
            maxTotalBytes: maxOutboxBytes
        )
    }
}

/// Where the SDK keeps its outbox on disk.
enum StorageLocation {
    /// The folder name under the app's own Application Support folder.
    static let sdkFolderName = "SimpleDataLogs"

    /// Application Support/<bundle id>/SimpleDataLogs/, which sandboxed apps get inside their container.
    static func defaultDirectory() -> URL {
        // Command-line tools have no bundle id, so they fall back to their process name.
        let appFolderName = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName

        return URL.applicationSupportDirectory
            .appending(path: appFolderName, directoryHint: .isDirectory)
            .appending(path: sdkFolderName, directoryHint: .isDirectory)
    }
}

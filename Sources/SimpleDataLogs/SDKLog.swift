import os

/// The os.Logger categories every SDK component writes to.
enum SDKLog {
    /// The subsystem shared by every SDK log line.
    static let subsystem = "com.simpledatalogs.sdk"

    /// Public API misuse and configuration problems.
    static let facade = Logger(subsystem: subsystem, category: "Facade")

    /// Batching, sending, retries and opt-out.
    static let pipeline = Logger(subsystem: subsystem, category: "Pipeline")

    /// The journal, sealed batches and the outbox cap.
    static let outbox = Logger(subsystem: subsystem, category: "Outbox")
}

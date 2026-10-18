import Foundation

/// One sealed batch file: an NDJSON request body waiting for its 202.
struct SealedBatch: Sendable, Equatable {
    /// Where the batch lives on disk.
    let fileURL: URL

    /// How many events (lines) the batch holds.
    let eventCount: Int

    /// The size of the batch body in bytes.
    let byteCount: Int
}

/// The size limits the outbox enforces.
struct OutboxLimits: Sendable {
    /// The most events one sealed batch may hold.
    var maxBatchEventCount: Int

    /// The most bytes one sealed batch (one request body) may hold.
    var maxBatchBytes: Int

    /// The most events kept across the journal and every sealed batch.
    var maxTotalEventCount: Int

    /// The most bytes kept across the journal and every sealed batch.
    var maxTotalBytes: Int

    /// The most sealed batch files kept, so days offline with one event per batch never leave thousands of files.
    var maxSealedBatchCount: Int = 500
}

/// What happened to a batch the server called too large.
enum BatchSplitOutcome: Sendable, Equatable {
    /// The batch was replaced by its two halves.
    case split

    /// The batch held a single event, which was dropped because it can never be accepted.
    case droppedLoneEvent

    /// The batch had already left the outbox, e.g. trimmed by the cap while in flight.
    case alreadyRemoved
}

/// The crash-safe disk outbox: an append-only journal, plus sealed batch files deleted only after a 202.
final class EventOutbox {
    /// The live journal's file name inside the outbox folder.
    static let journalFileName = "journal.ndjson"

    /// Every journal file name, live or set aside after a failed recovery, starts with this.
    static let journalFilePrefix = "journal"

    /// The folder of sealed batches inside the outbox folder.
    static let batchesFolderName = "batches"

    /// Every sealed batch file name starts with this.
    static let batchFilePrefix = "batch-"

    /// Journals and sealed batches both end with this extension.
    static let batchFileExtension = "ndjson"

    /// The extra extension a batch gets when it is set aside as unreadable.
    static let setAsideFileExtension = "unreadable"

    /// The extra extension a batch gets when ingest refused it as unsupported (415); unlike unreadable ones, it is never retried.
    static let unsupportedFileExtension = "unsupported"

    /// The NDJSON line separator.
    private static let newlineByte = UInt8(ascii: "\n")

    /// The live journal every tracked event is appended to.
    let journalURL: URL

    /// The folder holding sealed batches.
    let batchesDirectory: URL

    /// The outbox root folder.
    private let directory: URL

    /// Batch and total size limits.
    private let limits: OutboxLimits

    /// The file manager every disk operation goes through.
    private let fileManager = FileManager.default

    /// Protects every file and folder, and recognizes reads blocked while the device is locked.
    private let fileProtection: OutboxFileProtection

    /// How many events the journal holds right now.
    private(set) var journalEventCount = 0

    /// How many bytes the journal holds right now.
    private(set) var journalByteCount = 0

    /// Every sealed batch on disk, oldest first.
    private(set) var sealedBatches: [SealedBatch] = []

    /// A per-launch counter that keeps file names sorted within one millisecond.
    private var fileNameSequence = 0

    /// True when indexing skipped batch files locked by data protection, so a later send indexes them again.
    private(set) var hasBatchesSkippedWhileLocked = false

    /// Points the outbox at its folder; nothing touches the disk until `recoverAfterLaunch()`.
    init(directory: URL, limits: OutboxLimits, fileProtection: OutboxFileProtection = .platformDefault) {
        self.directory = directory
        self.limits = limits
        self.fileProtection = fileProtection
        self.journalURL = Self.journalURL(in: directory)
        self.batchesDirectory = Self.batchesDirectory(in: directory)
    }

    /// The live journal location inside an outbox folder.
    static func journalURL(in directory: URL) -> URL {
        directory.appending(path: journalFileName, directoryHint: .notDirectory)
    }

    /// The sealed-batch folder inside an outbox folder.
    static func batchesDirectory(in directory: URL) -> URL {
        directory.appending(path: batchesFolderName, directoryHint: .isDirectory)
    }

    // MARK: - Totals

    /// Events held across the journal and every sealed batch.
    var totalEventCount: Int {
        journalEventCount + sealedBatches.map(\.eventCount).reduce(0, +)
    }

    /// Bytes held across the journal and every sealed batch.
    var totalByteCount: Int {
        journalByteCount + sealedBatches.map(\.byteCount).reduce(0, +)
    }

    /// The batch the send loop should try next.
    var oldestSealedBatch: SealedBatch? {
        sealedBatches.first
    }

    /// The cheapest batch to send as a 401 re-probe.
    var smallestSealedBatch: SealedBatch? {
        sealedBatches.min { firstBatch, secondBatch in firstBatch.byteCount < secondBatch.byteCount }
    }

    // MARK: - Launch

    /// Creates the folders, seals every journal earlier sessions left behind, and indexes the sealed batches.
    func recoverAfterLaunch() throws {
        // A folder failure is reported at the end, after everything already on disk is recovered.
        var folderCreationError: (any Error)?
        do {
            try createFoldersIfNeeded()
        } catch {
            folderCreationError = error
        }

        // Seal whatever earlier sessions journaled but never sealed, including after a crash.
        sealLeftoverJournals()

        // Always index every sealed batch, oldest first, so no file is orphaned by an earlier failure.
        sealedBatches = loadSealedBatches()

        // A long offline period may have pushed the outbox over its cap.
        enforceCap()

        if let folderCreationError {
            throw folderCreationError
        }
    }

    // MARK: - Journal

    /// The bytes one event line takes on disk and on the wire, including its newline.
    static func storedByteCount(of eventLine: Data) -> Int {
        eventLine.count + 1
    }

    /// True when the journal must be sealed before this line: it already holds a full batch, or the line would overfill a request.
    func wouldJournalOverflow(adding eventLine: Data) -> Bool {
        guard journalEventCount > 0 else {
            return false
        }

        let isJournalFull = journalEventCount >= limits.maxBatchEventCount
        let wouldExceedRequestBytes = journalByteCount + Self.storedByteCount(of: eventLine) > limits.maxBatchBytes

        return isJournalFull || wouldExceedRequestBytes
    }

    /// Appends one encoded event line to the journal, so a crash from here on loses nothing.
    func appendToJournal(_ eventLine: Data) throws {
        // Every line ends in a newline, so the journal stays valid NDJSON as it grows.
        var lineWithNewline = eventLine
        lineWithNewline.append(Self.newlineByte)

        // Append to the live journal, or start one atomically, recreating the folders if they went missing.
        if fileManager.fileExists(atPath: journalURL.path) {
            try appendLineToExistingJournal(lineWithNewline)
        } else {
            try createFoldersIfNeeded()
            try fileProtection.writeAtomically(lineWithNewline, journalURL)
        }

        // Count the line only once it is fully on disk.
        journalEventCount += 1
        journalByteCount += lineWithNewline.count
    }

    /// Turns the journal into a sealed batch with one atomic rename, then trims the outbox to its cap.
    func sealJournal() throws {
        guard journalEventCount > 0 else {
            return
        }

        // A journal removed behind the SDK's back leaves nothing to seal, so the counters restart.
        guard fileManager.fileExists(atPath: journalURL.path) else {
            SDKLog.outbox.warning("The journal disappeared before sealing; \(self.journalEventCount) events are gone")
            journalEventCount = 0
            journalByteCount = 0
            return
        }

        // The batch folder may also have been removed, so recreate it before the rename.
        try createFoldersIfNeeded()

        // A rename is atomic, so the events are always in exactly one file.
        let batchURL = makeBatchURL()
        try fileManager.moveItem(at: journalURL, to: batchURL)

        // Index the new batch and start an empty journal.
        sealedBatches.append(SealedBatch(fileURL: batchURL, eventCount: journalEventCount, byteCount: journalByteCount))
        journalEventCount = 0
        journalByteCount = 0

        enforceCap()
    }

    // MARK: - Sealed batches

    /// Reads a batch body, or returns nil (and forgets the batch) when its file has vanished.
    /// Throws `OutboxReadError.protectedDataUnavailable` when the device is locked, so the caller only tries later.
    func body(of batch: SealedBatch) throws -> Data? {
        // A missing file can never be sent, so it leaves the index.
        guard fileManager.fileExists(atPath: batch.fileURL.path) else {
            removeFromIndex(batch)
            return nil
        }

        // A read blocked by data protection says nothing about the file itself.
        do {
            return try Data(contentsOf: batch.fileURL)
        } catch where fileProtection.isProtectedDataUnavailable(error) {
            throw OutboxReadError.protectedDataUnavailable(underlyingError: error)
        }
    }

    /// Indexes the batch files a locked device made recovery skip, once they read; returns true when any were added.
    @discardableResult
    func indexBatchesSkippedWhileLocked() -> Bool {
        guard hasBatchesSkippedWhileLocked else {
            return false
        }

        // Assume the device is unlocked now; a file that is still locked raises the flag again.
        hasBatchesSkippedWhileLocked = false
        let indexedFileNames = Set(sealedBatches.map(\.fileURL.lastPathComponent))
        let newlyReadableBatches = batchFileURLs()
            .filter { batchFileURL in !indexedFileNames.contains(batchFileURL.lastPathComponent) }
            .compactMap(readIndexEntry)

        guard !newlyReadableBatches.isEmpty else {
            return false
        }

        // Merge them in by name, so the queue stays oldest first.
        sealedBatches = (sealedBatches + newlyReadableBatches).sorted { firstBatch, secondBatch in
            firstBatch.fileURL.lastPathComponent < secondBatch.fileURL.lastPathComponent
        }

        enforceCap()

        return true
    }

    /// Deletes a delivered batch.
    func delete(_ batch: SealedBatch) {
        removeFromIndex(batch)
        try? fileManager.removeItem(at: batch.fileURL)
    }

    /// Moves an unreadable batch out of the queue under a `.unreadable` name (or another extension), keeping the file for inspection.
    func setAside(_ batch: SealedBatch, fileExtension: String = EventOutbox.setAsideFileExtension) {
        removeFromIndex(batch)

        // If even the rename fails, the next launch indexes the file again and retries it.
        let setAsideURL = batch.fileURL.appendingPathExtension(fileExtension)
        try? fileManager.moveItem(at: batch.fileURL, to: setAsideURL)
    }

    /// Replaces a batch the server called too large with its two halves, in the same queue position.
    func splitInHalf(_ batch: SealedBatch, body: Data) throws -> BatchSplitOutcome {
        // The cap may have trimmed the batch while it was in flight.
        guard let batchIndex = sealedBatches.firstIndex(of: batch) else {
            return .alreadyRemoved
        }

        // A lone event that is still too large can never be accepted.
        let eventLines = Self.lines(in: body)
        guard eventLines.count > 1 else {
            delete(batch)
            return .droppedLoneEvent
        }

        // Write both halves before removing the original, so a crash can only duplicate, never lose.
        let middleIndex = eventLines.count / 2
        let firstHalf = try writeBatchFile(lines: Array(eventLines[..<middleIndex]), to: halfURL(of: batch, halfNumber: 1))
        let secondHalf = try writeBatchFile(lines: Array(eventLines[middleIndex...]), to: halfURL(of: batch, halfNumber: 2))

        // Swap the original for its halves.
        sealedBatches.replaceSubrange(batchIndex...batchIndex, with: [firstHalf, secondHalf])
        try? fileManager.removeItem(at: batch.fileURL)

        return .split
    }

    /// Deletes every journal and every batch file, for an opt-out.
    func deleteEverything() {
        // Remove the live journal and any set aside by an earlier failed recovery.
        for journalFileURL in leftoverJournalURLs() {
            try? fileManager.removeItem(at: journalFileURL)
        }

        // Remove every batch file, indexed, unindexed or set aside.
        let batchFileURLs = (try? fileManager.contentsOfDirectory(at: batchesDirectory, includingPropertiesForKeys: nil)) ?? []
        for batchFileURL in batchFileURLs {
            try? fileManager.removeItem(at: batchFileURL)
        }

        // Reset the in-memory view to match the empty folders.
        sealedBatches = []
        journalEventCount = 0
        journalByteCount = 0
    }

    // MARK: - Private helpers

    /// Forgets a batch without touching its file.
    private func removeFromIndex(_ batch: SealedBatch) {
        sealedBatches.removeAll { indexedBatch in indexedBatch == batch }
    }

    /// Creates the outbox and batch folders when missing, and keeps them out of iCloud and iTunes backups.
    private func createFoldersIfNeeded() throws {
        guard !fileManager.fileExists(atPath: batchesDirectory.path) else {
            return
        }

        try fileManager.createDirectory(at: batchesDirectory, withIntermediateDirectories: true)

        // New files inherit the folders' protection class, so the outbox stays usable on a locked device.
        protectBestEffort(directory)
        protectBestEffort(batchesDirectory)

        // Unsent analytics are not worth backing up.
        var backupExclusion = URLResourceValues()
        backupExclusion.isExcludedFromBackup = true

        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(backupExclusion)
    }

    /// Sets the protection class on one item, logging a failure instead of throwing.
    private func protectBestEffort(_ itemURL: URL) {
        do {
            try fileProtection.protectExistingItem(itemURL)
        } catch {
            SDKLog.outbox.error("Could not set file protection on \(itemURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes a line at the end of the live journal, cutting a partial write back off so it can never fuse with the next line.
    private func appendLineToExistingJournal(_ lineWithNewline: Data) throws {
        let journalHandle = try FileHandle(forWritingTo: journalURL)
        defer { try? journalHandle.close() }

        // Remember where this line starts.
        let lineStartOffset = try journalHandle.seekToEnd()

        // A full disk can fail mid-write, so undo whatever part of the line landed.
        do {
            try journalHandle.write(contentsOf: lineWithNewline)
        } catch {
            try? journalHandle.truncate(atOffset: lineStartOffset)
            throw error
        }
    }

    /// Seals every journal earlier sessions left: the live one, plus any set aside by a failed recovery.
    private func sealLeftoverJournals() {
        for leftoverJournalURL in leftoverJournalURLs() {
            do {
                try sealLeftoverJournal(at: leftoverJournalURL)
            } catch {
                SDKLog.outbox.error("Could not seal a leftover journal (\(error.localizedDescription, privacy: .public)); keeping it for the next launch")

                // The live journal's path must be free, so this session's appends never mix with old lines.
                if leftoverJournalURL.lastPathComponent == Self.journalFileName {
                    setLiveJournalAside()
                }
            }
        }
    }

    /// Every journal file in the outbox folder, live or set aside.
    private func leftoverJournalURLs() -> [URL] {
        let folderContents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []

        return folderContents.filter { fileURL in
            fileURL.lastPathComponent.hasPrefix(Self.journalFilePrefix) && fileURL.pathExtension == Self.batchFileExtension
        }
    }

    /// Seals one leftover journal into batches, discarding a line torn by a crash mid-append, then removes it.
    private func sealLeftoverJournal(at leftoverJournalURL: URL) throws {
        // Keep only complete JSON objects.
        let journalLines = Self.lines(in: try Data(contentsOf: leftoverJournalURL))
        let validEventLines = journalLines.filter(Self.isJSONObjectLine)

        let tornLineCount = journalLines.count - validEventLines.count
        if tornLineCount > 0 {
            SDKLog.outbox.warning("Discarded \(tornLineCount) unreadable journal lines left by a previous launch")
        }

        // Re-chunk into batches that respect today's limits.
        for batchLines in chunkIntoBatches(validEventLines) {
            _ = try writeBatchFile(lines: batchLines, to: makeBatchURL())
        }

        // Only now that every event is in a sealed batch is the journal safe to remove.
        try fileManager.removeItem(at: leftoverJournalURL)
    }

    /// Renames the live journal to a unique set-aside name, so a fresh journal starts and the next launch retries the old one.
    private func setLiveJournalAside() {
        let setAsideFileName = "\(Self.journalFilePrefix)-\(makeSortableFileStamp()).\(Self.batchFileExtension)"

        do {
            try fileManager.moveItem(at: journalURL, to: directory.appending(path: setAsideFileName, directoryHint: .notDirectory))
        } catch {
            SDKLog.outbox.error("Could not set the leftover journal aside; its events may be sent twice")
        }
    }

    /// Lists sealed batch files, oldest first, counting events and bytes in each.
    private func loadSealedBatches() -> [SealedBatch] {
        restoreSetAsideBatches()

        return batchFileURLs().compactMap(readIndexEntry)
    }

    /// Every finished batch file, oldest first; set-aside files have another extension.
    private func batchFileURLs() -> [URL] {
        let folderContents = (try? fileManager.contentsOfDirectory(at: batchesDirectory, includingPropertiesForKeys: nil)) ?? []

        return folderContents
            .filter { fileURL in fileURL.lastPathComponent.hasPrefix(Self.batchFilePrefix) && fileURL.pathExtension == Self.batchFileExtension }
            .sorted { firstURL, secondURL in firstURL.lastPathComponent < secondURL.lastPathComponent }
    }

    /// Reads one batch file into its index entry, or returns nil when it cannot be read right now.
    private func readIndexEntry(of batchFileURL: URL) -> SealedBatch? {
        do {
            let batchBody = try Data(contentsOf: batchFileURL)

            return SealedBatch(fileURL: batchFileURL, eventCount: Self.lines(in: batchBody).count, byteCount: batchBody.count)
        } catch where fileProtection.isProtectedDataUnavailable(error) {
            // A locked device only delays the file, so a later send indexes it again.
            hasBatchesSkippedWhileLocked = true
            SDKLog.outbox.notice("Skipped a batch file locked until the device is unlocked; it is indexed once readable")
            return nil
        } catch {
            // Any other unreadable file is skipped and retried next launch.
            SDKLog.outbox.error("Skipped an unreadable batch file")
            return nil
        }
    }

    /// Puts batches set aside as unreadable back in the queue, so every launch retries them; file protection may only have locked them.
    private func restoreSetAsideBatches() {
        let folderContents = (try? fileManager.contentsOfDirectory(at: batchesDirectory, includingPropertiesForKeys: nil)) ?? []

        for setAsideURL in folderContents where setAsideURL.pathExtension == Self.setAsideFileExtension {
            let batchURL = setAsideURL.deletingPathExtension()
            guard batchURL.pathExtension == Self.batchFileExtension, !fileManager.fileExists(atPath: batchURL.path) else { continue }

            try? fileManager.moveItem(at: setAsideURL, to: batchURL)
        }
    }

    /// Drops the oldest sealed batches until the outbox is back under its event and byte caps.
    private func enforceCap() {
        var droppedEventCount = 0
        var droppedBatchCount = 0

        // Totals are read once and counted down, so trimming many batches stays linear.
        var heldEventCount = totalEventCount
        var heldByteCount = totalByteCount

        // The journal is bounded by one batch, so trimming sealed batches always ends.
        while droppedBatchCount < sealedBatches.count,
              heldEventCount > limits.maxTotalEventCount || heldByteCount > limits.maxTotalBytes
                || sealedBatches.count - droppedBatchCount > limits.maxSealedBatchCount {
            let oldestBatch = sealedBatches[droppedBatchCount]
            try? fileManager.removeItem(at: oldestBatch.fileURL)
            heldEventCount -= oldestBatch.eventCount
            heldByteCount -= oldestBatch.byteCount
            droppedEventCount += oldestBatch.eventCount
            droppedBatchCount += 1
        }

        sealedBatches.removeFirst(droppedBatchCount)

        if droppedEventCount > 0 {
            SDKLog.outbox.warning("Outbox over its cap; dropped the oldest \(droppedEventCount) unsent events")
        }
    }

    /// Groups event lines into batches under the event-count and byte limits.
    private func chunkIntoBatches(_ eventLines: [Data]) -> [[Data]] {
        var batches: [[Data]] = []
        var currentBatch: [Data] = []
        var currentBatchBytes = 0

        for eventLine in eventLines {
            // Start a new batch when this line would break either limit.
            let lineBytes = Self.storedByteCount(of: eventLine)
            let isCurrentBatchFull = currentBatch.count >= limits.maxBatchEventCount || currentBatchBytes + lineBytes > limits.maxBatchBytes
            if !currentBatch.isEmpty, isCurrentBatchFull {
                batches.append(currentBatch)
                currentBatch = []
                currentBatchBytes = 0
            }

            currentBatch.append(eventLine)
            currentBatchBytes += lineBytes
        }

        // Keep the final partial batch.
        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }

        return batches
    }

    /// Writes event lines as one NDJSON batch file, atomically, and returns its index entry.
    private func writeBatchFile(lines eventLines: [Data], to batchURL: URL) throws -> SealedBatch {
        // Every line, including the last, ends in a newline.
        var batchBody = Data()
        for eventLine in eventLines {
            batchBody.append(eventLine)
            batchBody.append(Self.newlineByte)
        }

        // An atomic write means a crash leaves either the whole file or none of it.
        try fileProtection.writeAtomically(batchBody, batchURL)

        return SealedBatch(fileURL: batchURL, eventCount: eventLines.count, byteCount: batchBody.count)
    }

    /// A unique stamp that sorts oldest first: milliseconds, a per-launch sequence, then a random suffix.
    private func makeSortableFileStamp() -> String {
        fileNameSequence += 1

        let millisecondsSince1970 = Int64(Date().timeIntervalSince1970 * 1000)
        let randomSuffix = String(UUID().uuidString.prefix(8))

        return String(format: "%013lld-%06ld-%@", millisecondsSince1970, fileNameSequence, randomSuffix)
    }

    /// A unique batch file URL that sorts oldest first.
    private func makeBatchURL() -> URL {
        let fileName = "\(Self.batchFilePrefix)\(makeSortableFileStamp()).\(Self.batchFileExtension)"

        return batchesDirectory.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// The file name for one half of a split batch, sorting right where the original did.
    private func halfURL(of batch: SealedBatch, halfNumber: Int) -> URL {
        let originalStem = batch.fileURL.deletingPathExtension().lastPathComponent

        return batchesDirectory.appending(path: "\(originalStem)-\(halfNumber).\(Self.batchFileExtension)", directoryHint: .notDirectory)
    }

    /// Splits an NDJSON body into its non-empty lines.
    static func lines(in ndjsonBody: Data) -> [Data] {
        ndjsonBody.split(separator: newlineByte).map { lineSlice in Data(lineSlice) }
    }

    /// True when a line parses as a JSON object.
    private static func isJSONObjectLine(_ eventLine: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: eventLine)) is [String: Any]
    }
}

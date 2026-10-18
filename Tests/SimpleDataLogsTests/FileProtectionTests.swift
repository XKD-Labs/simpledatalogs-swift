import os
import XCTest
import Foundation

@testable import SimpleDataLogs

/// Records what the outbox asks to protect and write, while still writing for real.
final class ProtectionRecorder: Sendable {
    /// The name of every file or folder the outbox asked to protect, in order.
    private let protectedItemNames = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// The name of every file the outbox wrote through the protection seam, in order.
    private let writtenFileNames = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// Every item the outbox asked to protect so far.
    var protectedItems: [String] {
        protectedItemNames.withLock { itemNames in itemNames }
    }

    /// Every file the outbox wrote so far.
    var writtenFiles: [String] {
        writtenFileNames.withLock { fileNames in fileNames }
    }

    /// A protection seam that records each call; `isProtectedDataUnavailable` decides which read errors mean a locked device.
    func makeFileProtection(isProtectedDataUnavailable: @escaping @Sendable (any Error) -> Bool = { _ in false }) -> OutboxFileProtection {
        OutboxFileProtection(
            writeAtomically: { [self] fileBody, fileURL in
                writtenFileNames.withLock { fileNames in fileNames.append(fileURL.lastPathComponent) }
                try fileBody.write(to: fileURL, options: .atomic)
            },
            protectExistingItem: { [self] itemURL in
                protectedItemNames.withLock { itemNames in itemNames.append(itemURL.lastPathComponent) }
            },
            isProtectedDataUnavailable: isProtectedDataUnavailable
        )
    }
}

/// Outbox files carry an explicit data protection class, and a read blocked by it is only ever tried later.
final class FileProtectionTests: PipelineTestCase {
    /// Limits small enough to seal and split with a handful of events.
    private let smallLimits = OutboxLimits(maxBatchEventCount: 5, maxBatchBytes: 256_000, maxTotalEventCount: 1_000, maxTotalBytes: 10 * 1024 * 1024)

    /// The real policy uses "until first unlock" for writes and attributes, and macOS stays unprotected.
    func testProtectionClassIsCompleteUntilFirstUserAuthentication() {
        XCTAssertEqual(OutboxFileProtection.protectionType, .completeUntilFirstUserAuthentication)
        XCTAssertTrue(OutboxFileProtection.protectedWriteOptions.contains(.atomic))
        XCTAssertTrue(OutboxFileProtection.protectedWriteOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))

        // macOS has no data protection, so the default never calls a read locked.
        #if os(macOS)
        let permissionError = CocoaError(.fileReadNoPermission)
        XCTAssertFalse(OutboxFileProtection.platformDefault.isProtectedDataUnavailable(permissionError))
        #endif
    }

    /// A denied read is recognized directly, wrapped, or as a POSIX code; other read errors are not.
    func testPermissionDeniedReadErrorsAreRecognized() {
        let posixPermissionError = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let wrappedPermissionError = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: posixPermissionError])

        XCTAssertTrue(OutboxFileProtection.isPermissionDenied(CocoaError(.fileReadNoPermission)))
        XCTAssertTrue(OutboxFileProtection.isPermissionDenied(posixPermissionError))
        XCTAssertTrue(OutboxFileProtection.isPermissionDenied(wrappedPermissionError))
        XCTAssertFalse(OutboxFileProtection.isPermissionDenied(CocoaError(.fileReadCorruptFile)))
        XCTAssertFalse(OutboxFileProtection.isPermissionDenied(CocoaError(.fileReadNoSuchFile)))
    }

    /// New folders get the protection class, and every journal, batch and split half is written through the protected write.
    func testNewFoldersAndEveryWriteUseTheProtection() throws {
        let storageDirectory = makeTemporaryDirectory()
        let recorder = ProtectionRecorder()
        let outbox = EventOutbox(directory: storageDirectory, limits: smallLimits, fileProtection: recorder.makeFileProtection())
        try outbox.recoverAfterLaunch()

        // Creating the folders protects both.
        XCTAssertTrue(recorder.protectedItems.contains(storageDirectory.lastPathComponent))
        XCTAssertTrue(recorder.protectedItems.contains(EventOutbox.batchesFolderName))

        // Two events start a journal; sealing renames it, so its protection carries over.
        for _ in 0..<2 {
            try outbox.appendToJournal(makeEvent().encodedLine())
        }
        try outbox.sealJournal()

        // Splitting writes both halves through the same protected write.
        let sealedBatch = try XCTUnwrap(outbox.oldestSealedBatch)
        let sealedBody = try XCTUnwrap(outbox.body(of: sealedBatch))
        XCTAssertEqual(try outbox.splitInHalf(sealedBatch, body: sealedBody), .split)

        let batchStem = sealedBatch.fileURL.deletingPathExtension().lastPathComponent
        XCTAssertEqual(recorder.writtenFiles, [
            EventOutbox.journalFileName,
            "\(batchStem)-1.ndjson",
            "\(batchStem)-2.ndjson",
        ])
    }

    /// A read blocked by data protection throws the locked error, and the batch stays queued.
    func testLockedReadThrowsProtectedDataUnavailableAndKeepsTheBatch() throws {
        try XCTSkipIf(getuid() == 0, "root can read a file whatever its permissions")

        let storageDirectory = makeTemporaryDirectory()
        let lockedFileProtection = ProtectionRecorder().makeFileProtection(isProtectedDataUnavailable: OutboxFileProtection.isPermissionDenied)
        let outbox = EventOutbox(directory: storageDirectory, limits: smallLimits, fileProtection: lockedFileProtection)
        try outbox.recoverAfterLaunch()

        // Seal one batch, then lock its file the way iOS does before the first unlock.
        try outbox.appendToJournal(makeEvent().encodedLine())
        try outbox.sealJournal()
        let lockedBatch = try XCTUnwrap(outbox.oldestSealedBatch)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedBatch.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedBatch.fileURL.path) }

        XCTAssertThrowsError(try outbox.body(of: lockedBatch)) { readError in
            guard case OutboxReadError.protectedDataUnavailable = readError else {
                return XCTFail("Expected a protected-data error, got \(readError)")
            }
        }
        XCTAssertEqual(outbox.sealedBatches, [lockedBatch])
    }

    /// A batch locked during launch is skipped without being set aside, then indexed once it reads.
    func testBatchLockedAtLaunchIsIndexedOnceReadable() throws {
        try XCTSkipIf(getuid() == 0, "root can read a file whatever its permissions")

        // An earlier launch leaves one sealed batch.
        let storageDirectory = makeTemporaryDirectory()
        let earlierOutbox = EventOutbox(directory: storageDirectory, limits: smallLimits)
        try earlierOutbox.recoverAfterLaunch()
        try earlierOutbox.appendToJournal(makeEvent().encodedLine())
        try earlierOutbox.sealJournal()
        let batchURL = try XCTUnwrap(earlierOutbox.oldestSealedBatch?.fileURL)

        // This launch runs while the file is locked, so it skips the batch but keeps its file.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: batchURL.path)
        let lockedFileProtection = ProtectionRecorder().makeFileProtection(isProtectedDataUnavailable: OutboxFileProtection.isPermissionDenied)
        let outbox = EventOutbox(directory: storageDirectory, limits: smallLimits, fileProtection: lockedFileProtection)
        try outbox.recoverAfterLaunch()

        XCTAssertEqual(outbox.sealedBatches, [])
        XCTAssertTrue(outbox.hasBatchesSkippedWhileLocked)
        XCTAssertEqual(batchFileNames(in: storageDirectory), [batchURL.lastPathComponent])

        // Once the device unlocks, the batch joins the queue.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: batchURL.path)

        XCTAssertTrue(outbox.indexBatchesSkippedWhileLocked())
        XCTAssertEqual(outbox.sealedBatches.map(\.eventCount), [1])
        XCTAssertFalse(outbox.hasBatchesSkippedWhileLocked)
    }

    /// A batch locked by data protection is retried for as long as it stays locked, never set aside, and sent once readable.
    func testLockedBatchIsRetriedInsteadOfSetAside() async throws {
        try XCTSkipIf(getuid() == 0, "root can read a file whatever its permissions")

        // The first request's 503 is held back until the test opens the gate; later requests succeed.
        let storageDirectory = makeTemporaryDirectory()
        let requestGate = RequestGate()
        let server = makeServer { _, requestIndex in
            requestIndex == 0 ? MockResponse.status(503).held(by: requestGate) : .accepted
        }

        // Five retries return at once, more than the three reads that set an unreadable batch aside.
        let delayRecorder = DelayRecorder(immediateReturnCount: 5)
        let lockedFileProtection = ProtectionRecorder().makeFileProtection(isProtectedDataUnavailable: OutboxFileProtection.isPermissionDenied)
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory, delayRecorder: delayRecorder) { configuration in
            configuration.maxBatchEventCount = 1
            configuration.fileProtection = lockedFileProtection
        }
        await pipeline.start()

        // The batch goes out and stays in flight.
        let lockedEvents = await enqueueEvents(1, into: pipeline)
        await waitUntil { server.requests.count == 1 }

        // Its file locks, the way iOS locks files before the first unlock.
        let lockedBatchName = try XCTUnwrap(batchFileNames(in: storageDirectory).first)
        let lockedBatchURL = EventOutbox.batchesDirectory(in: storageDirectory).appending(path: lockedBatchName)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedBatchURL.path)

        // The 503 starts the retries; every locked read backs off again instead of counting toward a set-aside.
        requestGate.open()
        await waitUntil { delayRecorder.delays.count == 6 }

        let pendingWhileLocked = await pipeline.pendingEventCount
        XCTAssertEqual(delayRecorder.delays, [1, 2, 4, 8, 16, 32])
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(pendingWhileLocked, 1)
        XCTAssertEqual(batchFileNames(in: storageDirectory), [lockedBatchName])

        // Once the device unlocks, a later attempt sends the same batch.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedBatchURL.path)
        await pipeline.cancelBackgroundWork()
        await pipeline.flush()

        XCTAssertEqual(server.requests.last?.eventIDs, lockedEvents.map(\.eventID.uuidString))
        XCTAssertEqual(batchFileNames(in: storageDirectory), [])
    }
}

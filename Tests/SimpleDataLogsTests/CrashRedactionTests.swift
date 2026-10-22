import XCTest
import Foundation

@testable import SimpleDataLogs

/// Crash reasons are redacted as configured, and file paths in stack frames are always cut to the file name.
final class CrashRedactionTests: PipelineTestCase {
    /// The default sends the reason word for word.
    func testVerbatimKeepsTheReason() {
        let reason = "index 12 beyond bounds [0 .. 3] for /Volumes/Work/Documents/Taxes.pdf"

        XCTAssertEqual(CrashReasonRedaction.verbatim.redact(reason), reason)
    }

    /// The standard redaction strips numbers, paths, file URLs, UUIDs, hex values and emails.
    func testStandardStripsNumbersPathsAndEmails() {
        let redaction = CrashReasonRedaction.standard

        XCTAssertEqual(redaction.redact("index 12 beyond bounds [0 .. 3]"), "index # beyond bounds [# .. #]")
        XCTAssertEqual(redaction.redact("cannot open /Volumes/Work/Library/Data/notes.db: denied"), "cannot open <path>: denied")
        XCTAssertEqual(redaction.redact("missing ~/Desktop/shot.png"), "missing <path>")
        XCTAssertEqual(redaction.redact("bad url file:///private/var/tmp/x.json"), "bad url <path>")
        XCTAssertEqual(redaction.redact("user someone@example.com failed"), "user <email> failed")
        XCTAssertEqual(redaction.redact("object 0x600003a1c2d0 for 1F0C2D7E-8B4A-4C1E-9D2F-3A5B6C7D8E9F"), "object <hex> for <uuid>")
        XCTAssertEqual(redaction.redact("checksum deadbeef42 mismatch"), "checksum <hex> mismatch")
    }

    /// Words with a slash inside, like "and/or", are not paths.
    func testSlashesInsideWordsAreNotPaths() {
        XCTAssertEqual(CrashReasonRedaction.standard.redact("read and/or write failed"), "read and/or write failed")
    }

    /// Each part can be switched off, and the length cap ends a cut reason with an ellipsis.
    func testEachPartIsOptionalAndTheLengthIsCapped() {
        let numbersOnly = CrashReasonRedaction(shouldStripNumbers: true, shouldStripPaths: false, shouldStripEmails: false, maxLength: 1_000)
        XCTAssertEqual(numbersOnly.redact("row 7 of /tmp/a.csv"), "row # of /tmp/a.csv")

        let capped = CrashReasonRedaction(shouldStripNumbers: false, shouldStripPaths: false, shouldStripEmails: false, maxLength: 10)
        let cappedReason = capped.redact(String(repeating: "x", count: 50))
        XCTAssertEqual(cappedReason.count, 10)
        XCTAssertTrue(cappedReason.hasSuffix("…"))
        XCTAssertEqual(CrashReasonRedaction.standard.redact(String(repeating: "y", count: 500)).count, 200)
    }

    /// File paths in frames keep only the file name; frames without paths are unchanged.
    func testStackFramePathsAreCutToTheFileName() {
        let stack = [
            "0   CoreFoundation   0x000000018c5d2ccc __exceptionPreprocess + 176",
            "1   MyApp   0x0000000100003f20 /Volumes/Work/Projects/MyApp/Sources/Store.swift:42",
            "2   Helper   0x0000000100004000 file:///Applications/MyApp.app/Contents/Frameworks/Helper.framework/Helper + 12",
        ].joined(separator: "\n")

        let trimmedStack = CrashRecorder.trimmedStack(stack).components(separatedBy: "\n")

        XCTAssertEqual(trimmedStack[0], "0   CoreFoundation   0x000000018c5d2ccc __exceptionPreprocess + 176")
        XCTAssertEqual(trimmedStack[1], "1   MyApp   0x0000000100003f20 Store.swift:42")
        XCTAssertEqual(trimmedStack[2], "2   Helper   0x0000000100004000 Helper + 12")
    }

    /// The next launch sends the saved crash with the configured redaction and a trimmed stack.
    func testTheSavedCrashIsSentRedacted() throws {
        let stateDirectory = makeTemporaryDirectory()
        let crash = PendingCrash(
            exceptionName: "NSRangeException",
            reason: "index 12 beyond bounds for /Volumes/Work/Data/list.plist",
            stack: "0 MyApp /Volumes/Work/MyApp/Sources/List.swift:9",
            occurredAt: Date(timeIntervalSince1970: 1_791_796_400)
        )
        CrashRecorder.record(crash, to: stateDirectory.appending(path: CrashRecorder.fileName))

        let recorder = EmittedEventRecorder()
        recorder.makeController(options: [.crashes], stateDirectory: stateDirectory, crashReasonRedaction: .standard).start()

        let crashEvent = try XCTUnwrap(recorder.events.first)
        XCTAssertEqual(crashEvent.properties["reason"], .string("index # beyond bounds for <path>"))
        XCTAssertEqual(crashEvent.properties["stack"], .string("0 MyApp List.swift:9"))
        XCTAssertEqual(crashEvent.properties["exception_name"], .string("NSRangeException"))
    }
}

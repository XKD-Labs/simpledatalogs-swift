import os
import XCTest
import Foundation

@testable import SimpleDataLogs

/// Records each delay the pipeline asks to wait, returning at once for the first few and then parking.
final class DelayRecorder: Sendable {
    /// Every requested delay, in order.
    private let recordedDelays = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])

    /// How many waits return at once before later ones park like a long real wait.
    private let immediateReturnCount: Int

    /// Creates a recorder; the default parks every wait, so nothing retries on its own.
    init(immediateReturnCount: Int = 0) {
        self.immediateReturnCount = immediateReturnCount
    }

    /// Every requested delay, in order.
    var delays: [TimeInterval] {
        recordedDelays.withLock { delays in delays }
    }

    /// The waiter to hand the pipeline.
    var waiter: EventPipeline.DelayWaiter {
        { [self] requestedDelay in
            let waitNumber = recordedDelays.withLock { delays in
                delays.append(requestedDelay)
                return delays.count
            }

            // Past the allowed immediate returns, park until the test tears the pipeline down.
            if waitNumber > immediateReturnCount {
                try await Task.sleep(for: .seconds(3600))
            }
        }
    }
}

/// Shared setup for pipeline tests: a temp outbox folder, a mock server, and a pipeline wired to both.
class PipelineTestCase: XCTestCase {
    /// The key every test pipeline sends.
    static let testIngestKey = "sdl_pub_test"

    /// A fresh, empty folder that is removed after the test.
    func makeTemporaryDirectory() -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SimpleDataLogsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        addTeardownBlock {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        return temporaryDirectory
    }

    /// A registered mock server that is unregistered after the test.
    func makeServer(responder: @escaping MockIngestServer.Responder = { _, _ in .accepted }) -> MockIngestServer {
        let server = MockIngestServer(responder: responder)
        server.register()

        addTeardownBlock {
            server.unregister()
        }

        return server
    }

    /// A pipeline posting to `server` and storing in `storageDirectory`, with a long batch interval and full jitter pinned to 1.
    func makePipeline(
        server: MockIngestServer,
        storageDirectory: URL,
        isEnabled: Bool = true,
        delayRecorder: DelayRecorder = DelayRecorder(),
        adjustConfiguration: (inout PipelineConfiguration) -> Void = { _ in }
    ) -> EventPipeline {
        // Start from the production defaults, but never let the timer fire unless a test asks.
        var configuration = PipelineConfiguration(ingestURL: server.ingestURL, ingestKey: Self.testIngestKey, storageDirectory: storageDirectory)
        configuration.batchInterval = .seconds(3600)
        adjustConfiguration(&configuration)

        let pipeline = EventPipeline(
            configuration: configuration,
            session: server.makeSession(),
            isEnabled: isEnabled,
            waitForDelay: delayRecorder.waiter,
            jitterSource: { 1 }
        )

        // Stop parked timers so nothing outlives the test.
        addTeardownBlock {
            await pipeline.cancelBackgroundWork()
        }

        return pipeline
    }

    /// Journals `eventCount` fresh events and returns them.
    @discardableResult
    func enqueueEvents(
        _ eventCount: Int,
        into pipeline: EventPipeline,
        named eventName: String = "screenshot_taken",
        properties: [String: PropertyValue] = ["type": "area"]
    ) async -> [TrackedEvent] {
        var enqueuedEvents: [TrackedEvent] = []

        for _ in 0..<eventCount {
            let event = makeEvent(eventName, properties: properties)
            await pipeline.enqueue(event)
            enqueuedEvents.append(event)
        }

        return enqueuedEvents
    }

    /// The sealed batch file names in an outbox folder.
    func batchFileNames(in storageDirectory: URL) -> [String] {
        let batchesDirectory = EventOutbox.batchesDirectory(in: storageDirectory)

        return (try? FileManager.default.contentsOfDirectory(atPath: batchesDirectory.path)) ?? []
    }

    /// True when the outbox folder still has a journal file.
    func hasJournal(in storageDirectory: URL) -> Bool {
        FileManager.default.fileExists(atPath: EventOutbox.journalURL(in: storageDirectory).path)
    }
}

/// A ready-made event, so tests read as behavior rather than setup.
func makeEvent(_ eventName: String = "screenshot_taken", properties: [String: PropertyValue] = ["type": "area"]) -> TrackedEvent {
    TrackedEvent.make(eventName: eventName, properties: properties, defaultProperties: [:], deviceID: "test-device")
}

/// Polls a condition every 20 ms until it holds, failing the test after `timeout` seconds.
func waitUntil(
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @Sendable () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if await condition() {
            return
        }

        try? await Task.sleep(for: .milliseconds(20))
    }

    XCTFail("Timed out after \(timeout) s waiting for a condition", file: file, line: line)
}

/// Waits for a semaphore on a Dispatch thread, since async code may not block; returns false on timeout.
func waitForSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval = 5) async -> Bool {
    await withCheckedContinuation { signalContinuation in
        DispatchQueue.global().async {
            signalContinuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
        }
    }
}

import XCTest
import Foundation

@testable import SimpleDataLogs

/// On quit, the last events are journaled and get a short, bounded send instead of waiting for the next launch.
final class TerminationFlushTests: PipelineTestCase {
    /// A pipeline running its command loop, and the inbox that feeds it.
    private func makeRunningPipeline(server: MockIngestServer, storageDirectory: URL) -> AsyncStream<PipelineCommand>.Continuation {
        let pipeline = makePipeline(server: server, storageDirectory: storageDirectory)
        let (commandStream, commandContinuation) = AsyncStream.makeStream(of: PipelineCommand.self)
        let commandLoopTask = Task {
            await pipeline.run(commands: commandStream)
        }

        // End the command loop after the test.
        addTeardownBlock {
            commandContinuation.finish()
            await commandLoopTask.value
        }

        return commandContinuation
    }

    /// Events tracked just before quitting are sent before the bounded wait returns.
    func testTheLastEventsAreSentBeforeTheAppQuits() async {
        let storageDirectory = makeTemporaryDirectory()
        let server = makeServer()
        let commandContinuation = makeRunningPipeline(server: server, storageDirectory: storageDirectory)

        // Two events tracked moments before quitting.
        commandContinuation.yield(.start)
        commandContinuation.yield(.track(makeEvent("settings_closed")))
        commandContinuation.yield(.track(makeEvent("app_quit")))

        // The termination path blocks a thread, so run it on one.
        let didFlushInTime = await runOnDispatchThread {
            SimpleDataLogs.performBoundedFlush(until: .now() + .seconds(5)) { flushCommand in
                commandContinuation.yield(flushCommand)
                return true
            }
        }

        XCTAssertTrue(didFlushInTime)
        XCTAssertEqual(server.requests.flatMap(\.eventNames), ["settings_closed", "app_quit"])
        XCTAssertEqual(batchFileNames(in: storageDirectory), [])
    }

    /// A slow network never holds the quit past the deadline, and the events stay on disk for the next launch.
    func testASlowSendIsAbandonedAtTheDeadline() async {
        let storageDirectory = makeTemporaryDirectory()
        let requestGate = RequestGate()
        let server = makeServer { _, _ in MockResponse.accepted.held(by: requestGate) }
        let commandContinuation = makeRunningPipeline(server: server, storageDirectory: storageDirectory)
        addTeardownBlock { requestGate.open() }

        commandContinuation.yield(.start)
        commandContinuation.yield(.track(makeEvent("app_quit")))

        let waitStartedAt = Date()
        let didFlushInTime = await runOnDispatchThread {
            SimpleDataLogs.performBoundedFlush(until: .now() + .milliseconds(300)) { flushCommand in
                commandContinuation.yield(flushCommand)
                return true
            }
        }

        XCTAssertFalse(didFlushInTime)
        XCTAssertLessThan(Date().timeIntervalSince(waitStartedAt), 2)
        XCTAssertEqual(batchFileNames(in: storageDirectory).count, 1)
    }

    /// With nothing queued (opted out, or not configured), the wait returns at once.
    func testNothingQueuedReturnsAtOnce() {
        let waitStartedAt = Date()

        let didFlushInTime = SimpleDataLogs.performBoundedFlush(until: .now() + .seconds(5)) { _ in false }

        XCTAssertTrue(didFlushInTime)
        XCTAssertLessThan(Date().timeIntervalSince(waitStartedAt), 0.5)
    }

    /// A termination before configure returns at once, and the background flush helper is a no-op on macOS.
    func testLifecycleMomentsBeforeConfigureReturnAtOnce() {
        let waitStartedAt = Date()

        SimpleDataLogs.handleLifecycleMoment(.suspending)
        XCTAssertNil(BackgroundTimeRequest.begin())

        XCTAssertLessThan(Date().timeIntervalSince(waitStartedAt), 0.5)
    }

    /// Runs blocking work on a Dispatch thread, since async code may not block.
    private func runOnDispatchThread<Result: Sendable>(_ work: @escaping @Sendable () -> Result) async -> Result {
        await withCheckedContinuation { resultContinuation in
            DispatchQueue.global().async {
                resultContinuation.resume(returning: work())
            }
        }
    }
}

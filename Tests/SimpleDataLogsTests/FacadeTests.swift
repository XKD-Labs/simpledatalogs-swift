import XCTest
import Foundation

@testable import SimpleDataLogs

/// The public facade before configure: every call returns at once and never crashes the host (ingest API "fail open").
final class FacadeTests: XCTestCase {
    /// Tracking, flushing and settings before configure are dropped quietly, and flush still returns.
    func testCallsBeforeConfigureNeverCrashOrHang() async {
        SimpleDataLogs.setDeviceID("device-1")
        SimpleDataLogs.setDefaultProperties(["app_version": "1.0", "ratio": .double(.nan)])

        // Events with an empty name, odd properties or none at all are all dropped without a pipeline.
        SimpleDataLogs.track("")
        SimpleDataLogs.track("screenshot_taken", properties: ["size": .double(.infinity), "type": "area"])
        SimpleDataLogs.track("app_opened")

        // A flush with nothing configured resumes its caller instead of waiting forever.
        let flushStartedAt = Date()
        await SimpleDataLogs.flush()
        XCTAssertLessThan(Date().timeIntervalSince(flushStartedAt), 1)

        // An opted-out flush returns at once too, and a lifecycle flush is a no-op.
        SimpleDataLogs.setEnabled(false)
        await SimpleDataLogs.flush()
        SimpleDataLogs.handleLifecycleMoment(.suspending)
        SimpleDataLogs.setEnabled(true)
        SimpleDataLogs.setDeviceID(nil)
        SimpleDataLogs.setDefaultProperties([:])
    }

    /// Endpoints with and without a trailing slash or a base path all post to their /v1/ingest.
    func testIngestURLJoinsAnyEndpointShape() {
        let expectedURLsByEndpoint = [
            "https://in.example.test": "https://in.example.test/v1/ingest",
            "https://in.example.test/": "https://in.example.test/v1/ingest",
            "https://proxy.example.test/sdl": "https://proxy.example.test/sdl/v1/ingest",
        ]

        for (endpointText, expectedURLText) in expectedURLsByEndpoint {
            XCTAssertEqual(SimpleDataLogs.ingestURL(for: URL(string: endpointText)!).absoluteString, expectedURLText)
        }
    }
}

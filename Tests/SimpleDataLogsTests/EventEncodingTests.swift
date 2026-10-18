import XCTest
import Foundation

@testable import SimpleDataLogs

/// The event object, property values and request headers match the ingest API.
final class EventEncodingTests: XCTestCase {
    /// 2026-10-12T09:14:03.125Z; .125 is exact in binary, so the milliseconds format predictably.
    private let fixedOccurredAt = Date(timeIntervalSince1970: 1_791_796_443.125)

    /// A fixed event id for exact assertions.
    private let fixedEventID = UUID(uuidString: "1F0C2D7E-8B4A-4C1E-9D2F-3A5B6C7D8E9F")!

    /// One event line carries exactly the ingest API fields, with `ts` in ISO 8601, UTC, millisecond precision.
    func testEventLineMatchesTheIngestEventObject() throws {
        let event = TrackedEvent.make(
            eventName: "screenshot_taken",
            properties: ["type": "area", "count": 3, "ratio": 0.5, "is_retina": true],
            defaultProperties: [:],
            deviceID: "A6B1-device",
            occurredAt: fixedOccurredAt,
            eventID: fixedEventID
        )

        // Decode the line back to check every field.
        let eventLine = try event.encodedLine()
        let eventObject = try XCTUnwrap(JSONSerialization.jsonObject(with: eventLine) as? [String: Any])
        let props = try XCTUnwrap(eventObject["props"] as? [String: Any])

        XCTAssertEqual(Set(eventObject.keys), ["event", "event_id", "ts", "device_id", "props"])
        XCTAssertEqual(eventObject["event"] as? String, "screenshot_taken")
        XCTAssertEqual(eventObject["event_id"] as? String, "1F0C2D7E-8B4A-4C1E-9D2F-3A5B6C7D8E9F")
        XCTAssertEqual(eventObject["ts"] as? String, "2026-10-12T09:14:03.125Z")
        XCTAssertEqual(eventObject["device_id"] as? String, "A6B1-device")

        // Each property keeps its JSON type.
        XCTAssertEqual(props["type"] as? String, "area")
        XCTAssertEqual(props["count"] as? Int, 3)
        XCTAssertEqual(props["ratio"] as? Double, 0.5)
        XCTAssertEqual(props["is_retina"] as? Bool, true)

        // One event is one line.
        XCTAssertFalse(eventLine.contains(UInt8(ascii: "\n")))
    }

    /// A newline inside a property value is escaped, so NDJSON framing survives.
    func testNewlinesInsideValuesStayOnOneLine() throws {
        let event = makeEvent(properties: ["note": "first line\nsecond line"])

        let eventLine = try event.encodedLine()

        XCTAssertFalse(eventLine.contains(UInt8(ascii: "\n")))
    }

    /// `device_id` is left out entirely when the host never set one.
    func testDeviceIDIsOmittedWhenUnset() throws {
        let event = TrackedEvent.make(eventName: "app_launched", properties: [:], defaultProperties: [:], deviceID: nil)

        let eventObject = try XCTUnwrap(JSONSerialization.jsonObject(with: event.encodedLine()) as? [String: Any])

        XCTAssertNil(eventObject["device_id"])
    }

    /// `event_id` and `ts` are fixed when the event is tracked, so every resend carries the same pair.
    func testEventIDAndTimestampAreFixedAtTrackTime() throws {
        let event = makeEvent()

        // Encoding later, as a retry would, changes nothing.
        let firstEncoding = try event.encodedLine()
        Thread.sleep(forTimeInterval: 0.01)
        let laterEncoding = try event.encodedLine()

        XCTAssertEqual(firstEncoding, laterEncoding)
    }

    /// Default properties fill in, and the event's own properties win on a clash.
    func testEventPropertiesOverrideDefaultProperties() {
        let event = TrackedEvent.make(
            eventName: "screenshot_taken",
            properties: ["type": "area", "app_version": "9.9.9"],
            defaultProperties: ["app_version": "1.1.0", "distribution": "website"],
            deviceID: nil
        )

        XCTAssertEqual(event.properties, ["type": "area", "app_version": "9.9.9", "distribution": "website"])
    }

    /// NaN and infinity cannot be JSON, so those properties are dropped and the rest kept.
    func testNonFiniteNumbersAreDropped() {
        let properties: [String: PropertyValue] = ["ratio": 1.5, "broken": .double(.nan), "unbounded": .double(.infinity)]

        XCTAssertEqual(properties.droppingNonJSONValues(), ["ratio": 1.5])
    }

    /// Loosely typed values, such as Firebase parameters, bridge to the right property kind.
    func testBridgingLooselyTypedValues() {
        XCTAssertEqual(PropertyValue(bridging: "area"), .string("area"))
        XCTAssertEqual(PropertyValue(bridging: 3), .int(3))
        XCTAssertEqual(PropertyValue(bridging: 2.5), .double(2.5))
        XCTAssertEqual(PropertyValue(bridging: true), .bool(true))
        XCTAssertEqual(PropertyValue(bridging: NSNumber(value: false)), .bool(false))
        XCTAssertEqual(PropertyValue(bridging: NSNumber(value: 1)), .int(1))
        XCTAssertNil(PropertyValue(bridging: Date()))
        XCTAssertNil(PropertyValue(bridging: ["nested": "dictionary"]))
    }

    /// Every request is a POST to `<endpoint>/v1/ingest` with the bearer key, NDJSON type and SDK User-Agent.
    func testRequestCarriesTheIngestHeaders() {
        let ingestClient = IngestClient(
            session: .shared,
            ingestURL: SimpleDataLogs.ingestURL(for: SimpleDataLogs.defaultEndpoint),
            ingestKey: "sdl_pub_example",
            requestTimeout: 30
        )

        let request = ingestClient.makeRequest(body: Data("{}\n".utf8))

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://edge.simpledatalogs.com/v1/ingest")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sdl_pub_example")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-ndjson")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "simpledatalogs-swift/\(SimpleDataLogs.sdkVersion)")
    }

    /// A development endpoint with a trailing slash still joins cleanly.
    func testIngestURLJoinsAnEndpointWithATrailingSlash() {
        let developmentEndpoint = URL(string: "http://localhost:4001/")!

        XCTAssertEqual(SimpleDataLogs.ingestURL(for: developmentEndpoint).absoluteString, "http://localhost:4001/v1/ingest")
    }
}

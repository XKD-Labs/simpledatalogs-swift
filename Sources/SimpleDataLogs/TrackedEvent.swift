import Foundation

/// One tracked event, stamped at `track` time and sent as one NDJSON line (ingest API "Event object").
struct TrackedEvent: Sendable, Equatable {
    /// The event name, e.g. `screenshot_taken`.
    let eventName: String

    /// The per-event UUID that makes retries safe to dedupe.
    let eventID: UUID

    /// When the host app called `track`, or the past moment it passed.
    let occurredAt: Date

    /// The anonymous device id, when the host set one.
    let deviceID: String?

    /// The session id, when autocapture's sessions are on.
    var sessionID: String? = nil

    /// Default properties merged with the event's own properties.
    let properties: [String: PropertyValue]

    /// The `ts` layout: ISO 8601 in UTC with millisecond precision, e.g. `2026-10-12T09:14:03.120Z`.
    static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)

    /// The oldest `ts` accepted: 3,650 days, safely inside the ingest API's 10-year limit.
    static let maxTimestampAge: TimeInterval = 3_650 * 24 * 60 * 60

    /// The time to stamp for a caller's timestamp: nil means now, the future is clamped to now, and nil comes back when it is too old.
    static func resolvedTimestamp(_ requestedTimestamp: Date?, now: Date = Date()) -> Date? {
        guard let requestedTimestamp else {
            return now
        }

        // A clock running ahead (or a typo) cannot date an event after it was tracked.
        guard requestedTimestamp <= now else {
            return now
        }

        // Ingest would file anything older than its window under Unparsed, so it is refused here.
        guard now.timeIntervalSince(requestedTimestamp) <= maxTimestampAge else {
            return nil
        }

        return requestedTimestamp
    }

    /// Stamps a new event, letting the event's own properties win over the defaults.
    static func make(
        eventName: String,
        properties: [String: PropertyValue],
        defaultProperties: [String: PropertyValue],
        deviceID: String?,
        sessionID: String? = nil,
        occurredAt: Date = Date(),
        eventID: UUID = UUID()
    ) -> TrackedEvent {
        // The call site knows best, so its properties overwrite same-named defaults.
        let mergedProperties = defaultProperties.merging(properties) { _, eventPropertyValue in eventPropertyValue }

        return TrackedEvent(
            eventName: eventName,
            eventID: eventID,
            occurredAt: occurredAt,
            deviceID: deviceID,
            sessionID: sessionID,
            properties: mergedProperties
        )
    }

    /// Encodes the event as one compact JSON object with no trailing newline.
    func encodedLine() throws -> Data {
        // Sorted keys keep lines stable; JSON escapes every newline inside strings, so one event stays one line.
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        return try jsonEncoder.encode(self)
    }
}

/// Writes the ingest API field names.
extension TrackedEvent: Encodable {
    /// The wire names of each field.
    private enum CodingKeys: String, CodingKey {
        case eventName = "event"
        case eventID = "event_id"
        case occurredAt = "ts"
        case deviceID = "device_id"
        case sessionID = "session_id"
        case properties = "props"
    }

    /// Encodes `event`, `event_id`, `ts`, `props`, and `device_id` and `session_id` only when they are set.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(eventName, forKey: .eventName)
        try container.encode(eventID.uuidString, forKey: .eventID)
        try container.encode(Self.timestampStyle.format(occurredAt), forKey: .occurredAt)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encode(properties, forKey: .properties)
    }
}

import Foundation

/// One event property value: a string, an integer, a floating-point number or a boolean.
public enum PropertyValue: Sendable, Hashable {
    /// A text value, e.g. a capture type.
    case string(String)

    /// A whole-number value.
    case int(Int)

    /// A floating-point value; NaN and infinity are dropped at track time.
    case double(Double)

    /// A true or false flag.
    case bool(Bool)
}

/// Converts loosely typed analytics parameters, such as Firebase's `[String: Any]`.
extension PropertyValue {
    /// Wraps a String, Bool, integer or floating-point value, or returns nil for anything else.
    public init?(bridging anyValue: Any) {
        // Strings pass through unchanged.
        if let stringValue = anyValue as? String {
            self = .string(stringValue)
            return
        }

        // Swift and Objective-C numbers both bridge to NSNumber, which remembers their original kind.
        guard let numberValue = anyValue as? NSNumber else {
            return nil
        }

        // Booleans, floating-point numbers and integers each map to their own case.
        if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
            self = .bool(numberValue.boolValue)
        } else if CFNumberIsFloatType(numberValue) {
            self = .double(numberValue.doubleValue)
        } else {
            self = .int(numberValue.intValue)
        }
    }

    /// False for NaN and infinity, which JSON cannot represent.
    var isJSONRepresentable: Bool {
        guard case .double(let doubleValue) = self else {
            return true
        }

        return doubleValue.isFinite
    }
}

/// Lets string literals stand in for `.string`.
extension PropertyValue: ExpressibleByStringLiteral {
    /// Wraps a string literal.
    public init(stringLiteral stringValue: String) {
        self = .string(stringValue)
    }
}

/// Lets interpolated strings such as `"\(count) items"` stand in for `.string`.
extension PropertyValue: ExpressibleByStringInterpolation {}

/// Lets integer literals stand in for `.int`.
extension PropertyValue: ExpressibleByIntegerLiteral {
    /// Wraps an integer literal.
    public init(integerLiteral integerValue: Int) {
        self = .int(integerValue)
    }
}

/// Lets floating-point literals stand in for `.double`.
extension PropertyValue: ExpressibleByFloatLiteral {
    /// Wraps a floating-point literal.
    public init(floatLiteral doubleValue: Double) {
        self = .double(doubleValue)
    }
}

/// Lets `true` and `false` stand in for `.bool`.
extension PropertyValue: ExpressibleByBooleanLiteral {
    /// Wraps a boolean literal.
    public init(booleanLiteral boolValue: Bool) {
        self = .bool(boolValue)
    }
}

/// Encodes each case as its bare JSON value.
extension PropertyValue: Encodable {
    /// Writes the wrapped value as a JSON string, number or boolean.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let stringValue):
            try container.encode(stringValue)
        case .int(let integerValue):
            try container.encode(integerValue)
        case .double(let doubleValue):
            try container.encode(doubleValue)
        case .bool(let boolValue):
            try container.encode(boolValue)
        }
    }
}

/// Property-map helpers shared by `track` and `setDefaultProperties`.
extension Dictionary where Key == String, Value == PropertyValue {
    /// Removes NaN and infinite numbers, logging each dropped key.
    func droppingNonJSONValues() -> [String: PropertyValue] {
        // Find the keys whose values JSON cannot carry; usually there are none.
        let droppedKeys = compactMap { propertyKey, propertyValue in
            propertyValue.isJSONRepresentable ? nil : propertyKey
        }

        guard !droppedKeys.isEmpty else {
            return self
        }

        // Log every dropped key so the host can fix its call site.
        for droppedKey in droppedKeys.sorted() {
            SDKLog.facade.warning("Dropped property \(droppedKey, privacy: .public): NaN and infinity are not valid JSON")
        }

        // Keep everything else unchanged.
        var validProperties = self
        for droppedKey in droppedKeys {
            validProperties[droppedKey] = nil
        }

        return validProperties
    }
}

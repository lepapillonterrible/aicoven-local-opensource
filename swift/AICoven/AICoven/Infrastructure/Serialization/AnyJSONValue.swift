import Foundation

/// Canonical "any JSON" value for the local client.
///
/// Uses an enum for type-safe storage, making it fully `Sendable` without
/// `@unchecked`. A computed `value: Any` property is provided for backward
/// compatibility with existing call sites that use `value as? Type` patterns.
public enum AnyJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dictionary([String: AnyJSONValue])
    case array([AnyJSONValue])
    case null

    // MARK: - Backward-compatible Any accessor

    /// Returns the stored value as `Any` for call sites that use
    /// `.value as? String`, `.value as? Int`, etc.
    nonisolated var value: Any {
        switch self {
        case let .string(v): v
        case let .int(v): v
        case let .double(v): v
        case let .bool(v): v
        case let .dictionary(v): v
        case let .array(v): v
        case .null: NSNull()
        }
    }

    // MARK: - Convenience initializers

    /// Initialize from an `Any` value at runtime. This dynamically maps to
    /// the correct enum case. Unrecognized types become `.null`.
    ///
    /// Order matters: Bool must be checked before Int/Double because
    /// `NSNumber(value: true)` also bridges to Int and Double.
    init(_ value: Any) {
        // Check Bool first (NSNumber with bool type)
        if let v = value as? Bool {
            self = .bool(v)
        } else if let v = value as? Int {
            self = .int(v)
        } else if let v = value as? Double {
            self = .double(v)
        } else if let v = value as? String {
            self = .string(v)
        } else if let v = value as? [String: AnyJSONValue] {
            self = .dictionary(v)
        } else if let v = value as? [AnyJSONValue] {
            self = .array(v)
        } else if let v = value as? [String: Any] {
            self = .dictionary(v.mapValues { AnyJSONValue($0) })
        } else if let v = value as? [Any] {
            self = .array(v.map { AnyJSONValue($0) })
        } else {
            self = .null
        }
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Bool must be decoded before Int to avoid false positives.
        if let v = try? c.decode(Bool.self) { self = .bool(v)
            return
        }
        if let v = try? c.decode(Int.self) { self = .int(v)
            return
        }
        if let v = try? c.decode(Double.self) { self = .double(v)
            return
        }
        if let v = try? c.decode(String.self) { self = .string(v)
            return
        }
        if let v = try? c.decode([String: AnyJSONValue].self) { self = .dictionary(v)
            return
        }
        if let v = try? c.decode([AnyJSONValue].self) { self = .array(v)
            return
        }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(v): try c.encode(v)
        case let .int(v): try c.encode(v)
        case let .double(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case let .dictionary(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

// MARK: - Literal Conformances

extension AnyJSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension AnyJSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension AnyJSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension AnyJSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension AnyJSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: AnyJSONValue...) {
        self = .array(elements)
    }
}

extension AnyJSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, AnyJSONValue)...) {
        var dict: [String: AnyJSONValue] = [:]
        for (k, v) in elements {
            dict[k] = v
        }
        self = .dictionary(dict)
    }
}

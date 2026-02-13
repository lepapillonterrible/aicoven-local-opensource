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
    var value: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .dictionary(let v): return v
        case .array(let v): return v
        case .null: return NSNull()
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
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String: AnyJSONValue].self) { self = .dictionary(v); return }
        if let v = try? c.decode([AnyJSONValue].self) { self = .array(v); return }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .dictionary(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

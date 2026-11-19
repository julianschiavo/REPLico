import Foundation

/// A JSON value that preserves signed and unsigned 64-bit integers at Swift protocol boundaries.
///
/// Decoding prefers signed integers, so a small `unsignedInteger` can decode as `integer`.
/// JavaScript receives JSON numbers as `Number`, which loses integer precision beyond
/// ±(2^53 − 1). Nonfinite `number` values are rejected when encoded as JSON.
public indirect enum JSONValue: Sendable, Hashable, Codable {
    /// A JSON null value.
    case null
    /// A Boolean value.
    case bool(Bool)
    /// An exactly represented signed integer.
    case integer(Int64)
    /// An exactly represented unsigned integer, including values beyond `Int64.max`.
    case unsignedInteger(UInt64)
    /// A floating-point JSON number.
    case number(Double)
    /// A Unicode string.
    case string(String)
    /// An ordered collection of JSON values.
    case array([JSONValue])
    /// A string-keyed collection of JSON values.
    case object([String: JSONValue])

    /// Decodes JSON, preferring exact integer representations over floating-point numbers.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    /// Encodes the underlying JSON value, rejecting nonfinite floating-point numbers.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .unsignedInteger(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "JSON numbers must be finite."
                    ))
            }
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    /// The dictionary payload when this value is an object.
    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else {
            return nil
        }
        return value
    }

    /// The string payload when this value is a string.
    public var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    /// The array payload when this value is an array.
    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else {
            return nil
        }
        return value
    }

    /// The Boolean payload when this value is a Boolean.
    public var boolValue: Bool? {
        guard case .bool(let value) = self else {
            return nil
        }
        return value
    }

    /// Looks up a key when this value is an object; otherwise returns nil.
    public subscript(_ key: String) -> JSONValue? {
        objectValue?[key]
    }
}

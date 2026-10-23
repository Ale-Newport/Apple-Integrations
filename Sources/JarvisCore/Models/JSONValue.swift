import Foundation

/// A JSON object: string keys to ``JSONValue``.
public typealias JSONObject = [String: JSONValue]

/// A strongly typed, `Sendable` JSON value.
///
/// Tool-call arguments, structured results and the local IPC wire format are all expressed with this
/// type so that nothing executable ever travels between the interpreter, the engine and integrations —
/// only plain data that is validated against a ``ToolDescriptor`` before use.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(JSONObject.self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Accessors

public extension JSONValue {
    var isNull: Bool { if case .null = self { return true } else { return false } }

    var stringValue: String? { if case .string(let value) = self { return value } else { return nil } }

    var boolValue: Bool? { if case .bool(let value) = self { return value } else { return nil } }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value && abs(value) < 9e15: return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? { if case .array(let value) = self { return value } else { return nil } }

    var objectValue: JSONObject? { if case .object(let value) = self { return value } else { return nil } }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }
}

// MARK: - Bridging with Codable types

public extension JSONValue {
    /// Encodes any `Encodable` into a ``JSONValue``.
    static func encoding<T: Encodable>(_ value: T, encoder: JSONEncoder = JSONValue.defaultEncoder) throws -> JSONValue {
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value into any `Decodable`.
    func decoded<T: Decodable>(as type: T.Type = T.self, decoder: JSONDecoder = JSONValue.defaultDecoder) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(T.self, from: data)
    }

    static var defaultEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var defaultDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// Compact, deterministic (sorted-key) JSON text. Used for duplicate-detection fingerprints and logging.
    func canonicalString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

public extension JSONValue {
    /// Optional-friendly constructors that map `nil` to `.null`.
    init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
    init(_ value: Int?) { self = value.map(JSONValue.int) ?? .null }
    init(_ value: Bool?) { self = value.map(JSONValue.bool) ?? .null }
    init(_ value: Double?) { self = value.map(JSONValue.double) ?? .null }
}

public extension Dictionary where Key == String, Value == JSONValue {
    /// Removes `.null` members; handy when building result payloads from optionals.
    func droppingNulls() -> JSONObject { filter { !$0.value.isNull } }
}

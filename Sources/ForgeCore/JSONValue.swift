import Foundation

/// A JSON value with deterministic encoding (object keys are always emitted sorted).
///
/// This is the lingua franca between the command bus, MCP, scripts and the file format.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d):
            // Encode integral values as integers so output is stable and readable ("25", not "25.0").
            if d.rounded() == d, abs(d) < 9.007_199_254_740_992e15 {
                try c.encode(Int64(d))
            } else {
                try c.encode(d)
            }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var doubleValue: Double? { if case .number(let d) = self { return d } else { return nil } }
    public var intValue: Int? {
        if case .number(let d) = self, d.rounded() == d { return Int(d) }
        return nil
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }
}

// MARK: - Codable bridging

public enum JSONCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }

    /// Convert any Encodable to a JSONValue.
    public static func toJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try encoder().encode(value)
        return try decoder().decode(JSONValue.self, from: data)
    }

    /// Decode a Decodable from a JSONValue.
    public static func fromJSON<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        let data = try encoder().encode(value)
        return try decoder().decode(T.self, from: data)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try decoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try decoder().decode(JSONValue.self, from: data)
    }

    public static func string(_ value: JSONValue, pretty: Bool = false) -> String {
        // Encoding a JSONValue cannot fail (non-finite numbers are converted to strings).
        let data = (try? encoder(pretty: pretty).encode(value)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { JSONCoding.string(self) }
}

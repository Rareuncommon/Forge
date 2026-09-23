import Foundation

// JSON Schema generation from Swift `Decodable` types — the single source of truth for
// command parameters (SPEC §5.1, docs/adr/0008-command-schema.md).
//
// `SchemaBuilder.describe(T.self)` runs `T.init(from:)` against a recording Decoder. Every
// key the type's decoding logic asks for becomes a property; `decodeIfPresent` marks it
// optional. The schema can therefore never drift from what the decoder actually accepts.
//
// Rules for types used as params/results:
//   - Leaf types with custom decoding (units, enums, vectors) conform to `JSONSchemaProviding`.
//   - String enums conform to `SchemaEnum` (gets schema + placeholder for free).
//   - `init(from:)` must not validate values (placeholders are zero/empty); put validation
//     in a separate method. This is enforced by the test that builds every command schema.
//   - Field documentation comes from `SchemaDocumented.fieldDocs`; a test asserts every
//     property is documented and every documented key exists.

/// A type that supplies its own JSON Schema and a placeholder value for schema extraction.
public protocol JSONSchemaProviding {
    static var jsonSchema: JSONValue { get }
    static var schemaPlaceholder: Self { get }
}

/// String-backed enums: schema is `{"type":"string","enum":[...]}`.
public protocol SchemaEnum: JSONSchemaProviding, CaseIterable, RawRepresentable, Codable where RawValue == String {}

extension SchemaEnum {
    public static var jsonSchema: JSONValue {
        ["type": "string", "enum": .array(allCases.map { .string($0.rawValue) })]
    }
    public static var schemaPlaceholder: Self { allCases.first! }
}

extension LengthUnit: SchemaEnum {}
extension AngleUnit: SchemaEnum {}

/// Per-field documentation and defaults.
public struct FieldDoc: Sendable, ExpressibleByStringLiteral {
    public var description: String
    public var defaultValue: JSONValue?

    public init(_ description: String, default defaultValue: JSONValue? = nil) {
        self.description = description
        self.defaultValue = defaultValue
    }

    public init(stringLiteral value: String) { self.init(value) }
}

public protocol SchemaDocumented {
    static var fieldDocs: [String: FieldDoc] { get }
}

extension Length: JSONSchemaProviding {
    public static var jsonSchema: JSONValue {
        [
            "oneOf": [
                ["type": "number", "description": "value in document length units"],
                ["type": "string", "pattern": #"^\s*[-+]?[0-9.]+([eE][-+]?[0-9]+)?\s*[a-zA-Zµ"']*\s*$"#,
                 "description": "value with unit, e.g. \"25 mm\", \"1 in\""],
            ],
            "x-forge-quantity": "length",
        ]
    }
    public static var schemaPlaceholder: Length { .mm(0) }
}

extension Angle: JSONSchemaProviding {
    public static var jsonSchema: JSONValue {
        [
            "oneOf": [
                ["type": "number", "description": "value in document angle units"],
                ["type": "string", "description": "value with unit, e.g. \"90 deg\", \"1.57 rad\""],
            ],
            "x-forge-quantity": "angle",
        ]
    }
    public static var schemaPlaceholder: Angle { Angle(radians: 0) }
}

extension Vec3: JSONSchemaProviding {
    public static var jsonSchema: JSONValue {
        ["type": "array", "items": ["type": "number"], "minItems": 3, "maxItems": 3,
         "description": "[x, y, z] (unitless direction)"]
    }
    public static var schemaPlaceholder: Vec3 { .zero }
}

extension JSONValue: JSONSchemaProviding {
    public static var jsonSchema: JSONValue { ["description": "any JSON value"] }
    public static var schemaPlaceholder: JSONValue { .null }
}

/// A point in model space: three lengths, each a number in document units or a unit string.
public struct Point3: Codable, Sendable, Hashable, JSONSchemaProviding {
    public var mm: Vec3

    public init(mm: Vec3) { self.mm = mm }
    public init(_ x: Double, _ y: Double, _ z: Double) { mm = Vec3(x, y, z) }
    public static let origin = Point3(mm: .zero)

    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let x = try c.decode(Length.self), y = try c.decode(Length.self), z = try c.decode(Length.self)
        guard c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected exactly 3 coordinates") }
        mm = Vec3(x.millimeters, y.millimeters, z.millimeters)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(mm.x)
        try c.encode(mm.y)
        try c.encode(mm.z)
    }

    public static var jsonSchema: JSONValue {
        ["type": "array", "items": Length.jsonSchema, "minItems": 3, "maxItems": 3,
         "description": "[x, y, z]; each a length in document units or with a unit string"]
    }
    public static var schemaPlaceholder: Point3 { .origin }
}

public enum SchemaBuilder {
    /// Returns the JSON Schema for a Decodable type.
    public static func schema<T: Decodable>(for type: T.Type) throws -> JSONValue {
        try describe(type).schema
    }

    static func describe<T: Decodable>(_ type: T.Type) throws -> (schema: JSONValue, placeholder: T) {
        if let p = T.self as? any JSONSchemaProviding.Type {
            return (p.jsonSchema, p.schemaPlaceholder as! T)
        }
        switch T.self {
        case is String.Type: return (["type": "string"], "" as! T)
        case is Bool.Type: return (["type": "boolean"], false as! T)
        case is Double.Type: return (["type": "number"], 0.0 as! T)
        case is Float.Type: return (["type": "number"], Float(0) as! T)
        case is Int.Type: return (["type": "integer"], 0 as! T)
        case is Int32.Type: return (["type": "integer"], Int32(0) as! T)
        case is Int64.Type: return (["type": "integer"], Int64(0) as! T)
        case is UInt32.Type: return (["type": "integer", "minimum": 0], UInt32(0) as! T)
        case is UInt64.Type: return (["type": "integer", "minimum": 0], UInt64(0) as! T)
        case is UInt.Type: return (["type": "integer", "minimum": 0], UInt(0) as! T)
        case is Int8.Type: return (["type": "integer"], Int8(0) as! T)
        case is Int16.Type: return (["type": "integer"], Int16(0) as! T)
        case is UInt8.Type: return (["type": "integer", "minimum": 0], UInt8(0) as! T)
        case is UInt16.Type: return (["type": "integer", "minimum": 0], UInt16(0) as! T)
        default: break
        }
        let recorder = SchemaRecorder()
        let value = try T(from: SchemaDecoder(recorder: recorder, codingPath: []))
        var schema = recorder.schema()
        if let docs = (T.self as? any SchemaDocumented.Type)?.fieldDocs, case .object(var o) = schema,
            case .object(var props)? = o["properties"]
        {
            for (key, doc) in docs {
                guard case .object(var p)? = props[key] else { continue }
                p["description"] = .string(doc.description)
                if let d = doc.defaultValue { p["default"] = d }
                props[key] = .object(p)
            }
            o["properties"] = .object(props)
            schema = .object(o)
        }
        return (schema, value)
    }

    /// Property names of an object schema (for documentation coverage tests).
    public static func propertyNames(of schema: JSONValue) -> [String] {
        schema["properties"]?.objectValue.map { $0.keys.sorted() } ?? []
    }
}

// MARK: - Recording decoder

final class SchemaRecorder {
    enum Kind { case unknown, object, array, single }
    var kind: Kind = .unknown
    var properties: [String: JSONValue] = [:]
    var required: Set<String> = []
    var order: [String] = []
    var items: JSONValue?
    var single: JSONValue?

    func record(key: String, schema: JSONValue, required isRequired: Bool) {
        if properties[key] == nil { order.append(key) }
        properties[key] = schema
        if isRequired { required.insert(key) }
    }

    func schema() -> JSONValue {
        switch kind {
        case .object:
            var o: [String: JSONValue] = [
                "type": "object",
                "properties": .object(properties),
                "additionalProperties": false,
            ]
            if !required.isEmpty { o["required"] = .array(required.sorted().map { .string($0) }) }
            return .object(o)
        case .array:
            return ["type": "array", "items": items ?? [:]]
        case .single:
            return single ?? [:]
        case .unknown:
            // A type that decodes nothing (e.g. an empty params struct) takes an empty object.
            return ["type": "object", "properties": [:], "additionalProperties": false]
        }
    }
}

struct SchemaDecoder: Decoder {
    let recorder: SchemaRecorder
    var codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        recorder.kind = .object
        return KeyedDecodingContainer(SchemaKeyedContainer<Key>(recorder: recorder, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        recorder.kind = .array
        return SchemaUnkeyedContainer(recorder: recorder, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        recorder.kind = .single
        return SchemaSingleContainer(recorder: recorder, codingPath: codingPath)
    }
}

struct SchemaKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let recorder: SchemaRecorder
    var codingPath: [any CodingKey]
    var allKeys: [Key] { [] }

    func contains(_ key: Key) -> Bool { true }
    func decodeNil(forKey key: Key) throws -> Bool { false }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let (schema, value) = try SchemaBuilder.describe(type)
        recorder.record(key: key.stringValue, schema: schema, required: true)
        return value
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        let (schema, _) = try SchemaBuilder.describe(type)
        recorder.record(key: key.stringValue, schema: schema, required: false)
        return nil
    }

    // The protocol's default implementations of the non-generic overloads route through
    // `decode`, which would mark optional primitives as required — override them all.
    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { try optional(type, key) }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { try optional(type, key) }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { try optional(type, key) }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { try optional(type, key) }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { try optional(type, key) }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { try optional(type, key) }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { try optional(type, key) }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { try optional(type, key) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { try optional(type, key) }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { try optional(type, key) }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { try optional(type, key) }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { try optional(type, key) }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { try optional(type, key) }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { try optional(type, key) }

    private func optional<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T? {
        let (schema, _) = try SchemaBuilder.describe(type)
        recorder.record(key: key.stringValue, schema: schema, required: false)
        return nil
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        throw ForgeError(.internalError, "schema extraction does not support nested containers (key \(key.stringValue))")
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        throw ForgeError(.internalError, "schema extraction does not support nested containers (key \(key.stringValue))")
    }

    func superDecoder() throws -> any Decoder {
        throw ForgeError(.internalError, "schema extraction does not support superDecoder")
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        throw ForgeError(.internalError, "schema extraction does not support superDecoder")
    }
}

struct SchemaUnkeyedContainer: UnkeyedDecodingContainer {
    let recorder: SchemaRecorder
    var codingPath: [any CodingKey]
    var count: Int? { nil }
    var currentIndex = 0
    // Report "not at end" exactly once so Array.init(from:) decodes one element.
    var isAtEnd: Bool { currentIndex > 0 }

    init(recorder: SchemaRecorder, codingPath: [any CodingKey]) {
        self.recorder = recorder
        self.codingPath = codingPath
    }

    mutating func decodeNil() throws -> Bool { false }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let (schema, value) = try SchemaBuilder.describe(type)
        if recorder.items == nil { recorder.items = schema }
        currentIndex += 1
        return value
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        throw ForgeError(.internalError, "schema extraction does not support nested containers")
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw ForgeError(.internalError, "schema extraction does not support nested containers")
    }

    mutating func superDecoder() throws -> any Decoder {
        throw ForgeError(.internalError, "schema extraction does not support superDecoder")
    }
}

struct SchemaSingleContainer: SingleValueDecodingContainer {
    let recorder: SchemaRecorder
    var codingPath: [any CodingKey]

    func decodeNil() -> Bool { false }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let (schema, value) = try SchemaBuilder.describe(type)
        recorder.single = schema
        return value
    }
}

// MARK: - Validation

/// Lightweight structural validation against a generated schema: unknown keys (typos),
/// missing required keys and basic JSON types. Semantic validation is the command's job.
public enum SchemaValidator {
    public static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "params") -> [String] {
        var problems: [String] = []
        if let alternatives = schema["oneOf"]?.arrayValue {
            let ok = alternatives.contains { validate(value, against: $0, path: path).isEmpty }
            if !ok { problems.append("\(path): does not match any allowed form") }
            return problems
        }
        guard let type = schema["type"]?.stringValue else { return problems }
        switch (type, value) {
        case ("object", .object(let o)):
            let props = schema["properties"]?.objectValue ?? [:]
            for key in o.keys.sorted() where props[key] == nil {
                let hint = closest(key, in: Array(props.keys)).map { " (did you mean '\($0)'?)" } ?? ""
                problems.append("\(path): unknown parameter '\(key)'\(hint)")
            }
            for req in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where o[req] == nil {
                problems.append("\(path): missing required parameter '\(req)'")
            }
            for (key, sub) in o.sorted(by: { $0.key < $1.key }) {
                if let ps = props[key] { problems += validate(sub, against: ps, path: "\(path).\(key)") }
            }
        case ("array", .array(let a)):
            if let min = schema["minItems"]?.intValue, a.count < min {
                problems.append("\(path): expected at least \(min) items, got \(a.count)")
            }
            if let max = schema["maxItems"]?.intValue, a.count > max {
                problems.append("\(path): expected at most \(max) items, got \(a.count)")
            }
            if let items = schema["items"] {
                for (i, e) in a.enumerated() { problems += validate(e, against: items, path: "\(path)[\(i)]") }
            }
        case ("string", .string(let s)):
            if let allowed = schema["enum"]?.arrayValue?.compactMap(\.stringValue), !allowed.contains(s) {
                problems.append("\(path): '\(s)' is not one of \(allowed.joined(separator: ", "))")
            }
        case ("number", .number), ("boolean", .bool):
            break
        case ("integer", .number(let d)):
            if d.rounded() != d { problems.append("\(path): expected an integer") }
        default:
            problems.append("\(path): expected \(type)")
        }
        return problems
    }

    /// Nearest key by edit distance (for "did you mean").
    public static func closest(_ key: String, in candidates: [String]) -> String? {
        let limit = max(2, key.count / 3)
        var best: (name: String, distance: Int)?
        for candidate in candidates.sorted() {
            let d = levenshtein(key.lowercased(), candidate.lowercased())
            if d <= limit, best == nil || d < best!.distance { best = (candidate, d) }
        }
        return best?.name
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

/// A point in sketch coordinates: two lengths (numbers in document units or unit strings).
public struct Point2: Codable, Sendable, Hashable, JSONSchemaProviding {
    public var u: Double
    public var v: Double

    public init(_ u: Double, _ v: Double) {
        self.u = u
        self.v = v
    }

    public var tuple: (Double, Double) { (u, v) }

    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let u = try c.decode(Length.self), v = try c.decode(Length.self)
        guard c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected exactly 2 coordinates") }
        self.u = u.millimeters
        self.v = v.millimeters
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(u)
        try c.encode(v)
    }

    public static var jsonSchema: JSONValue {
        ["type": "array", "items": Length.jsonSchema, "minItems": 2, "maxItems": 2,
         "description": "[u, v] in sketch coordinates; lengths in document units or with a unit string"]
    }
    public static var schemaPlaceholder: Point2 { Point2(0, 0) }
}

/// A dimension value whose kind (length or angle) depends on context: a number in document
/// units, or a string with units ("25 mm", "30 deg").
public struct Quantity: Codable, Sendable, Hashable, JSONSchemaProviding {
    enum Raw: Hashable { case number(Double), text(String) }
    let raw: Raw
    let units: UnitSystem

    public init(millimeters: Double) {
        raw = .text("\(millimeters) mm")
        units = .mmgs
    }

    public init(from decoder: any Decoder) throws {
        units = decoder.userInfo[.unitSystem] as? UnitSystem ?? .mmgs
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            raw = .number(d)
        } else {
            raw = .text(try c.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch raw {
        case .number(let d): try c.encode(d)
        case .text(let s): try c.encode(s)
        }
    }

    public func length() throws -> Double {
        switch raw {
        case .number(let d): return d * units.length.millimeters
        case .text(let s): return try QuantityParser.length(s, default: units.length)
        }
    }

    public func angle() throws -> Double {
        switch raw {
        case .number(let d): return d * units.angle.radians
        case .text(let s): return try QuantityParser.angle(s, default: units.angle)
        }
    }

    public static var jsonSchema: JSONValue {
        ["oneOf": [
            ["type": "number", "description": "value in document units (length or angle, by dimension type)"],
            ["type": "string", "description": "value with unit, e.g. \"25 mm\", \"1 in\", \"30 deg\""],
        ]]
    }
    public static var schemaPlaceholder: Quantity { Quantity(millimeters: 0) }
}

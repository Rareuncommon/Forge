import Foundation
import Testing

@testable import ForgeCore

@Suite("Units")
struct UnitTests {
    func decodeLength(_ json: String, units: UnitSystem = .mmgs) throws -> Double {
        let d = JSONCoding.decoder()
        d.userInfo[.unitSystem] = units
        return try d.decode(Length.self, from: Data(json.utf8)).millimeters
    }

    @Test func lengthStrings() throws {
        #expect(try decodeLength(#""25 mm""#) == 25)
        #expect(try decodeLength(#""1in""#) == 25.4)
        #expect(abs(try decodeLength(#""0.5 ft""#) - 152.4) < 1e-9)
        #expect(try decodeLength(#""2.5e1 mm""#) == 25)
        #expect(try decodeLength(#""-3 cm""#) == -30)
        #expect(try decodeLength(#""1 m""#) == 1000)
    }

    @Test func bareNumbersUseDocumentUnits() throws {
        #expect(try decodeLength("10") == 10)
        #expect(try decodeLength("2", units: UnitSystem(length: .inch)) == 50.8)
        #expect(try decodeLength(#""2""#, units: UnitSystem(length: .inch)) == 50.8)
    }

    @Test func badUnitsAreStructuredErrors() {
        do {
            _ = try decodeLength(#""5 furlongs""#)
            Issue.record("expected error")
        } catch let e as ForgeError {
            #expect(e.code == .invalidUnit)
            #expect(e.message.contains("furlongs"))
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(throws: ForgeError.self) { try decodeLength(#""abc""#) }
    }

    @Test func angles() throws {
        let d = JSONCoding.decoder()
        #expect(abs(try d.decode(Angle.self, from: Data(#""90 deg""#.utf8)).radians - .pi / 2) < 1e-12)
        #expect(abs(try d.decode(Angle.self, from: Data("180".utf8)).radians - .pi) < 1e-12)  // default degrees
        #expect(try d.decode(Angle.self, from: Data(#""1 rad""#.utf8)).radians == 1)
    }

    @Test func quantityParserRejectsTrailingGarbageNumbers() {
        #expect(QuantityParser.split("5 elephants")?.1 == "elephants")
        #expect(QuantityParser.split("") == nil)
    }
}

@Suite("JSON")
struct JSONTests {
    @Test func deterministicSortedEncoding() throws {
        let v: JSONValue = ["b": 1, "a": [true, nil, "x"], "c": 2.5]
        #expect(JSONCoding.string(v) == #"{"a":[true,null,"x"],"b":1,"c":2.5}"#)
        #expect(try JSONCoding.parse(JSONCoding.string(v)) == v)
    }

    @Test func codableBridging() throws {
        struct S: Codable, Equatable { var x: Int; var y: [String] }
        let s = S(x: 3, y: ["a"])
        let j = try JSONCoding.toJSON(s)
        #expect(j["x"] == 3)
        #expect(try JSONCoding.fromJSON(S.self, j) == s)
    }
}

@Suite("Schema extraction")
struct SchemaTests {
    enum Color: String, Codable, CaseIterable, SchemaEnum { case red, green }

    struct Inner: Codable, SchemaDocumented {
        var r: Length
        static let fieldDocs: [String: FieldDoc] = ["r": "radius"]
    }

    struct P: Codable, SchemaDocumented {
        var width: Length
        var count: Int?
        var color: Color
        var inner: Inner?
        var tags: [String]
        var at: Point3?
        var flag: Bool
        enum CodingKeys: String, CodingKey {
            case width, count, color, inner, tags, flag
            case at = "at_point"
        }
        static let fieldDocs: [String: FieldDoc] = ["width": FieldDoc("the width", default: 5)]
    }

    @Test func schemaMatchesDecoder() throws {
        let s = try SchemaBuilder.schema(for: P.self)
        #expect(s["type"] == "object")
        #expect(SchemaBuilder.propertyNames(of: s) == ["at_point", "color", "count", "flag", "inner", "tags", "width"])
        #expect(s["required"] == ["color", "flag", "tags", "width"])
        #expect(s["properties"]?["width"]?["description"] == "the width")
        #expect(s["properties"]?["width"]?["default"] == 5)
        #expect(s["properties"]?["color"]?["enum"] == ["red", "green"])
        #expect(s["properties"]?["count"]?["type"] == "integer")
        #expect(s["properties"]?["tags"]?["items"]?["type"] == "string")
        #expect(s["properties"]?["inner"]?["properties"]?["r"]?["description"] == "radius")
        #expect(s["additionalProperties"] == false)
    }

    @Test func validatorCatchesTyposAndTypes() throws {
        let s = try SchemaBuilder.schema(for: P.self)
        let problems = SchemaValidator.validate(["widht": 3, "color": "blue", "tags": [], "flag": 1], against: s)
        #expect(problems.contains { $0.contains("unknown parameter 'widht'") && $0.contains("did you mean 'width'") })
        #expect(problems.contains { $0.contains("missing required parameter 'width'") })
        #expect(problems.contains { $0.contains("'blue' is not one of") })
        #expect(problems.contains { $0.contains("params.flag: expected boolean") })
        #expect(SchemaValidator.validate(["width": "3 mm", "color": "red", "tags": ["a"], "flag": true, "at_point": [1, "2 in", 3]], against: s).isEmpty)
        #expect(!SchemaValidator.validate(["width": 1, "color": "red", "tags": [], "flag": true, "at_point": [1, 2]], against: s).isEmpty)
    }
}

@Suite("Geometry")
struct GeometryTests {
    @Test func rotationAboutOffsetAxis() {
        let t = Transform3.rotation(axis: .unitZ, angle: .pi / 2, origin: Vec3(1, 0, 0))
        let p = t.apply(Vec3(2, 0, 0))
        #expect((p - Vec3(1, 1, 0)).length < 1e-12)
    }

    @Test func vec3DecodingRejectsWrongArity() {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Vec3.self, from: Data("[1,2]".utf8)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Vec3.self, from: Data("[1,2,3,4]".utf8)) }
        #expect((try? JSONDecoder().decode(Vec3.self, from: Data("[1,2,3]".utf8))) == Vec3(1, 2, 3))
    }
}

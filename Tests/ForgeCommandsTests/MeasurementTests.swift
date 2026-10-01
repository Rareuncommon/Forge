import ForgeCore
import ForgeKernel
import Foundation
import Testing

@testable import ForgeCommands

@Suite("Selected entity measurements")
struct MeasurementTests {
    func engine() async throws -> Engine {
        let engine = Engine()
        try await engine.execute("document.new")
        try await engine.execute("body.create_box", ["width": 10, "height": 20, "depth": 30])
        return engine
    }

    func face(_ engine: Engine, normal: Vec3) async throws -> String {
        let body = try #require(await engine.activeDocument?.bodies["body-1"])
        for i in 0..<(try body.shape.topology().faces) {
            if (try body.shape.face(i).normal - normal).length < 1e-9 { return "body-1/face-\(i)" }
        }
        throw ForgeError(.internalError, "test face missing")
    }

    func vertex(_ shape: Shape, at point: Vec3) throws -> Int {
        for i in 0..<(try shape.topology().vertices) {
            if (try shape.vertex(i) - point).length < 1e-9 { return i }
        }
        throw ForgeError(.internalError, "test vertex missing")
    }

    @Test func bodyFaceAndEdgePropertiesUsePhysicalUnits() async throws {
        let engine = try await engine()
        let body = try #require(await engine.activeDocument?.bodies["body-1"])
        let measurement = try await engine.execute("query.measure", ["from": "body-1"]).result
        #expect(measurement["distance_mm"] == nil)
        #expect(abs(measurement["from_entity"]!["volume_mm3"]!.doubleValue! - 6000) < 1e-8)
        #expect(abs(measurement["from_entity"]!["area_mm2"]!.doubleValue! - 2200) < 1e-8)
        let top = try await face(engine, normal: .unitZ)
        let area = try await engine.execute("query.measure", ["from": .string(top)]).result
        #expect(abs(area["from_entity"]!["area_mm2"]!.doubleValue! - 200) < 1e-8)
        #expect(area["from_entity"]?["normal"] == [0, 0, 1])
        for i in 0..<(try body.shape.topology().edges) {
            let edge = try body.shape.edge(i)
            let result = try await engine.execute("query.measure", ["from": .string("body-1/edge-\(i)")]).result
            let length = try #require(result["from_entity"]?["length_mm"]?.doubleValue)
            #expect(abs(length - (edge.end - edge.start).length) < 1e-8)
        }
    }

    @Test func selectedFacesAndEdgesMeasureTheirOwnGeometry() async throws {
        let engine = try await engine()
        let bottom = try await face(engine, normal: -.unitZ)
        let top = try await face(engine, normal: .unitZ)
        let between = try await engine.execute("query.measure", ["from": .string(bottom), "to": .string(top)]).result
        #expect(abs(between["distance_mm"]!.doubleValue! - 30) < 1e-8)
        #expect(between["delta_mm"] == [0, 0, 30])
        let body = try #require(await engine.activeDocument?.bodies["body-1"])
        let index = try #require((0..<(try body.shape.topology().edges)).first {
            guard let edge = try? body.shape.edge($0) else { return false }
            return abs(edge.start.z) < 1e-9 && abs(edge.end.z) < 1e-9
        })
        let edge = "body-1/edge-\(index)"
        let separated = try await engine.execute("query.measure", ["from": .string(edge), "to": .string(top)]).result
        #expect(abs(separated["distance_mm"]!.doubleValue! - 30) < 1e-8)
        let touching = try await engine.execute("query.measure", ["from": .string(edge), "to": .string(bottom)]).result
        #expect(abs(touching["distance_mm"]!.doubleValue!) < 1e-8)
        let named = try #require(body.naming?.edges[index])
        let persistent = try await engine.execute("query.measure", ["from": .string("body-1/edge@\(named)"), "to": .string(top)]).result
        #expect(persistent["distance_mm"] == separated["distance_mm"])
    }

    @Test func verticesMeasureExactCoordinatesAndCrossBodyDistances() async throws {
        let engine = try await engine()
        try await engine.execute("body.create_box", ["width": 2, "height": 3, "depth": 4, "origin": [20, 30, 40]])
        let doc = try #require(await engine.activeDocument)
        let a = try vertex(doc.body("body-1").shape, at: .zero)
        let b = try vertex(doc.body("body-2").shape, at: Vec3(20, 30, 40))
        let result = try await engine.execute("query.measure", ["from": .string("body-1/vertex-\(a)"), "to": .string("body-2/vertex-\(b)")]).result
        #expect(abs(result["distance_mm"]!.doubleValue! - Double(2900).squareRoot()) < 1e-8)
        #expect(result["point_from"] == [0, 0, 0])
        #expect(result["point_to"] == [20, 30, 40])
        #expect(result["from_entity"]?["position"] == [0, 0, 0])
        #expect(result["to_entity"]?["position"] == [20, 30, 40])
        #expect(result["delta_mm"] == [20, 30, 40])
        let vertexToBody = try await engine.execute("query.measure", ["from": .string("body-2/vertex-\(b)"), "to": "body-1"]).result
        #expect(abs(vertexToBody["distance_mm"]!.doubleValue! - Double(300).squareRoot()) < 1e-8)
    }

    @Test func circularEdgesReportRadiusAndCircumference() async throws {
        let engine = Engine()
        try await engine.execute("document.new", ["units": ["length": "in"]])
        try await engine.execute("body.create_cylinder", ["radius": "5 mm", "height": "10 mm"])
        let body = try #require(await engine.activeDocument?.bodies["body-1"])
        let i = try #require((0..<(try body.shape.topology().edges)).first { (try? body.shape.edge($0).curveType) == .circle })
        let result = try await engine.execute("query.measure", ["from": .string("body-1/edge-\(i)")]).result
        #expect(abs(result["from_entity"]!["radius_mm"]!.doubleValue! - 5) < 1e-9)
        #expect(abs(result["from_entity"]!["length_mm"]!.doubleValue! - 10 * .pi) < 1e-8)
    }

    @Test func rejectsMissingAndOutOfRangeSelectionsWithoutMutatingDocument() async throws {
        let engine = try await engine()
        let before = try await engine.execute("document.state").result
        for ref in ["body-1/vertex-999", "body-1/face-999", "body-1/edge-999", "body-2", "body-1/face@missing", "body-1/vertex-9223372036854775807"] {
            await #expect(throws: ForgeError.self) { try await engine.execute("query.measure", ["from": .string(ref)]) }
        }
        #expect(try await engine.execute("document.state").result == before)
    }
}

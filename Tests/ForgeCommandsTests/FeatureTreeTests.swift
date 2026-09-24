import ForgeCore
import Foundation
import Testing

@testable import ForgeCommands

@Suite("Feature tree")
struct FeatureTreeTests {
    func volume(_ e: Engine, _ body: String = "body-1") async throws -> Double {
        try await e.execute("query.mass_properties", ["body": .string(body)]).result["volume_mm3"]!.doubleValue!
    }

    /// A 40 × 20 rectangle with its width dimensioned, extruded 10.
    func block() async throws -> (Engine, String) {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("sketch.create", ["plane": "front"])
        let r = try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [40, 20]]]).result
        let bottom = r["created"]!.arrayValue!.compactMap(\.stringValue).first { $0.hasPrefix("line") }!
        let dim = try await e.execute("sketch.add_dimension", ["type": "distance", "entities": [.string(bottom)], "value": 40]).result
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 10])
        return (e, dim["constraints"]![0]!.stringValue!)
    }

    @Test func sketchAndExtrudeBecomeFeatures() async throws {
        let (e, _) = try await block()
        let tree = try await e.execute("feature.list").result["features"]!.arrayValue!
        #expect(tree.map { $0["name"]!.stringValue! } == ["Sketch1", "Boss-Extrude1"])
        #expect(tree[1]["created_bodies"] == ["body-1"])
        #expect(tree[1]["params"]?["sketch"] == "sketch-1")
    }

    @Test func editingASketchDimensionUpdatesTheExtrusion() async throws {
        let (e, dim) = try await block()
        #expect(abs(try await volume(e) - 40 * 20 * 10) < 1e-6)
        try await e.execute("sketch.edit", ["sketch": "sketch-1"])
        try await e.execute("sketch.set_dimension", ["constraint": .string(dim), "value": 60])
        try await e.execute("sketch.exit")
        #expect(abs(try await volume(e) - 60 * 20 * 10) < 1e-6)
        // Undo brings back the old sketch and the old solid together.
        try await e.execute("edit.undo")
        #expect(abs(try await volume(e) - 40 * 20 * 10) < 1e-6)
    }

    @Test func editSuppressRollbackDelete() async throws {
        let (e, _) = try await block()
        try await e.execute("feature.edit", ["feature": "Boss-Extrude1", "params": ["depth": 25]])
        #expect(abs(try await volume(e) - 40 * 20 * 25) < 1e-6)

        try await e.execute("feature.suppress", ["feature": "Boss-Extrude1"])
        #expect(await e.activeDocument!.bodies.isEmpty)
        try await e.execute("feature.suppress", ["feature": "Boss-Extrude1", "suppressed": false])
        #expect(abs(try await volume(e) - 40 * 20 * 25) < 1e-6)

        try await e.execute("feature.rollback", ["before": "Boss-Extrude1"])
        #expect(await e.activeDocument!.bodies.isEmpty)
        let states = try await e.execute("feature.list").result["features"]!.arrayValue!.map { $0["state"]!.stringValue! }
        #expect(states == ["ok", "rolled_back"])
        try await e.execute("feature.rollback")
        #expect(await e.activeDocument!.bodies.count == 1)

        try await e.execute("feature.delete", ["feature": "Boss-Extrude1"])
        #expect(await e.activeDocument!.bodies.isEmpty)
        #expect(await e.activeDocument!.features.count == 1)
    }

    @Test func bodyIdsSurviveSuppressingAnEarlierFeature() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        try await e.execute("body.create_box", ["width": 20, "height": 20, "depth": 20])
        try await e.execute("feature.suppress", ["feature": "Box1"])
        #expect(await e.activeDocument!.bodyOrder == ["body-2"])
        #expect(abs(try await volume(e, "body-2") - 8000) < 1e-6)
    }

    @Test func aFailingFeatureDoesNotStopLaterOnes() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        try await e.execute("body.create_box", ["width": 20, "height": 20, "depth": 20])
        try await e.execute("body.boolean", ["operation": "fuse", "target": "body-1", "tool": "body-2", "keep_tool": true])
        try await e.execute("body.create_sphere", ["radius": 3])
        // Suppress Box2: Combine1 loses its tool and fails; Sphere1 still regenerates.
        let tree = try await e.execute("feature.suppress", ["feature": "Box2"]).result["features"]!.arrayValue!
        #expect(tree.map { $0["state"]!.stringValue! } == ["ok", "suppressed", "error", "ok"])
        #expect(tree[2]["error_code"] == "unknown_entity")
        #expect(await e.activeDocument!.bodyOrder == ["body-1", "body-3"])
    }

    @Test func editIsValidatedAndUndoable() async throws {
        let (e, _) = try await block()
        await #expect(throws: ForgeError.self) { try await e.execute("feature.edit", ["feature": "Boss-Extrude1", "params": ["depth": -3]]) }
        await #expect(throws: ForgeError.self) { try await e.execute("feature.edit", ["feature": "Sketch1", "params": ["depth": 3]]) }
        try await e.execute("feature.edit", ["feature": "Boss-Extrude1", "params": ["depth": 5]])
        try await e.execute("edit.undo")
        #expect(abs(try await volume(e) - 40 * 20 * 10) < 1e-6)
    }
}

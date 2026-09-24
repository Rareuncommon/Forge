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

@Suite("Extrude end conditions")
struct ExtrudeOptionsTests {
    func volume(_ e: Engine, _ body: String = "body-1") async throws -> Double {
        try await e.execute("query.mass_properties", ["body": .string(body)]).result["volume_mm3"]!.doubleValue!
    }

    /// A 40 × 20 × 10 block on the Front plane (z from 0 to 10), and an open sketch-2 with a
    /// 10 × 10 square at the plate's centre on the same plane.
    func plate() async throws -> Engine {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("sketch.create", ["plane": "front"])
        try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [40, 20]]])
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 10])
        try await e.execute("sketch.create", ["plane": "front"])
        try await e.execute("sketch.add_rectangle", ["points": [[15, 5], [25, 15]]])
        try await e.execute("sketch.exit")
        return e
    }

    @Test func throughAllCutMakesAHole() async throws {
        let e = try await plate()
        try await e.execute("body.extrude", ["sketch": "sketch-2", "end_condition": "through_all", "operation": "cut"])
        #expect(abs(try await volume(e) - (8000 - 1000)) < 1e-6)
        #expect(await e.activeDocument!.features.last?.name == "Cut-Extrude1")
        #expect(await e.activeDocument!.bodies.count == 1)
    }

    @Test func blindCutReversedAndInScope() async throws {
        let e = try await plate()
        // The plate lies on the +normal side; a cut along the normal 4 deep removes 400.
        try await e.execute("body.extrude", ["sketch": "sketch-2", "depth": 4, "operation": "cut", "scope": ["body-1"]])
        #expect(abs(try await volume(e) - (8000 - 400)) < 1e-6)
        // Reversed, the cut misses the plate.
        await #expect(throws: ForgeError.self) {
            try await e.execute("body.extrude", ["sketch": "sketch-2", "depth": 4, "operation": "cut", "reverse": true])
        }
    }

    @Test func directionTwoMidPlaneAndThroughAllBoth() async throws {
        let e = try await plate()
        try await e.execute("body.extrude", ["sketch": "sketch-2", "depth": 5, "direction2": ["depth": 3]])
        let b = await e.activeDocument!.bodyOrder.last!
        #expect(abs(try await volume(e, b) - 100 * 8) < 1e-6)
        let bb = try await e.activeDocument!.body(b).shape.boundingBox()
        #expect(abs(bb.min.z + 3) < 1e-6 && abs(bb.max.z - 5) < 1e-6)

        try await e.execute("feature.edit", ["feature": "Boss-Extrude2", "params": ["end_condition": "mid_plane", "depth": 6, "direction2": .null]])
        let mid = try await e.activeDocument!.body(b).shape.boundingBox()
        #expect(abs(mid.min.z + 3) < 1e-6 && abs(mid.max.z - 3) < 1e-6)

        try await e.execute("feature.edit", ["feature": "Boss-Extrude2", "params": ["end_condition": "through_all_both", "scope": ["body-1"]]])
        let both = try await e.activeDocument!.body(b).shape.boundingBox()
        #expect(both.min.z < -0.5 && both.max.z > 10.5)
    }

    @Test func upToVertexAndMerge() async throws {
        let e = try await plate()
        // Up to z = 25, merged into the plate: one body of 8000 + 10·10·25 − overlap 10·10·10.
        try await e.execute("body.extrude", ["sketch": "sketch-2", "end_condition": "up_to_vertex", "vertex": [0, 0, 25], "merge": true])
        #expect(await e.activeDocument!.bodies.count == 1)
        #expect(abs(try await volume(e) - (8000 + 2500 - 1000)) < 1e-6)
    }

    @Test func invalidCombinationsAreRefused() async throws {
        let e = try await plate()
        for bad: JSONValue in [
            ["sketch": "sketch-2", "end_condition": "up_to_vertex"],
            ["sketch": "sketch-2", "end_condition": "mid_plane", "depth": 4, "direction2": ["depth": 2]],
            ["sketch": "sketch-2"],
        ] {
            await #expect(throws: ForgeError.self) { try await e.execute("body.extrude", bad) }
        }
    }
}

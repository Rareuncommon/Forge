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

@Suite("Applied features and extrude draft/thin")
struct AppliedFeatureTests {
    func volume(_ e: Engine, _ body: String = "body-1") async throws -> Double {
        try await e.execute("query.mass_properties", ["body": .string(body)]).result["volume_mm3"]!.doubleValue!
    }

    func square() async throws -> Engine {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("sketch.create", ["plane": "front"])
        try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [10, 10]]])
        try await e.execute("sketch.exit")
        return e
    }

    @Test func draftedAndThinExtrusions() async throws {
        let e = try await square()
        try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 10, "draft": ["angle": "5 deg"]])
        let a = 5.0 * .pi / 180, top = 10 - 20 * tan(a)
        #expect(abs(try await volume(e) - 10.0 / 3 * (100 + top * top + 10 * top)) < 1e-6)
        // Thin, outward 1 mm: the band's area is 40 + π (rounded outer corners).
        try await e.execute("feature.edit", ["feature": "Boss-Extrude1", "params": ["draft": .null, "thin": ["thickness": 1]]])
        #expect(abs(try await volume(e) - 10 * (40 + .pi)) < 1e-6)
        // Inward 1 mm: 100 − 64.
        try await e.execute("feature.edit", ["feature": "Boss-Extrude1", "params": ["thin": ["thickness": 1, "reverse": true]]])
        #expect(abs(try await volume(e) - 10 * 36) < 1e-6)
        // Mid-plane 2 mm: offsets ±1, (100 + 40 + π) − 64.
        try await e.execute("feature.edit", ["feature": "Boss-Extrude1", "params": ["thin": ["thickness": 2, "type": "mid_plane"]]])
        #expect(abs(try await volume(e) - 10 * (76 + .pi)) < 1e-6)
    }

    @Test func chamferShellAndDraftAreFeatures() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        let faces = try await e.execute("query.faces", ["body": "body-1"]).result["faces"]!.arrayValue!
        func face(_ n: [Double]) -> String {
            faces.first { f in zip(f["normal"]!.arrayValue!.map { $0.doubleValue! }, n).allSatisfy { abs($0 - $1) < 1e-9 } }!["id"]!.stringValue!
        }
        let top = face([0, 0, 1]), bottom = face([0, 0, -1]), side = face([1, 0, 0])
        try await e.execute("body.draft", ["body": "body-1", "neutral_plane": .string(bottom), "faces": [.string(side)], "angle": "3 deg", "reverse": true])
        let a = 3.0 * .pi / 180
        #expect(abs(try await volume(e) - (1000 - 10 * (100 * tan(a)) / 2)) < 1e-6)
        try await e.execute("feature.suppress", ["feature": "Draft1"])
        try await e.execute("body.shell", ["body": "body-1", "faces": [.string(top)], "thickness": 1])
        #expect(abs(try await volume(e) - (1000 - 576)) < 1e-6)
        let names = try await e.execute("feature.list").result["features"]!.arrayValue!.map { $0["name"]!.stringValue! }
        #expect(names == ["Box1", "Draft1", "Shell1"])
    }
}

@Suite("Reference planes and sketches on faces")
struct ReferencePlaneTests {
    func topFace(_ e: Engine, _ body: String = "body-1") async throws -> String {
        let faces = try await e.execute("query.faces", ["body": .string(body)]).result["faces"]!.arrayValue!
        return faces.first { $0["normal"]!.arrayValue!.map { $0.doubleValue! } == [0, 1, 0] }!["id"]!.stringValue!
    }

    @Test func sketchOnAFaceFollowsTheModel() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 40, "height": 10, "depth": 40])  // y from 0 to 10
        let top = try await topFace(e)
        try await e.execute("sketch.create", ["face": .string(top)])
        try await e.execute("sketch.add_circle", ["center": [20, -20], "radius": 5])
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 5])
        let boss = try await e.activeDocument!.body("body-2").shape.boundingBox()
        #expect(abs(boss.min.y - 10) < 1e-6 && abs(boss.max.y - 15) < 1e-6)
        // Make the box taller: the sketch plane (the top face) and the boss move up.
        try await e.execute("feature.edit", ["feature": "Box1", "params": ["height": 25]])
        let moved = try await e.activeDocument!.body("body-2").shape.boundingBox()
        #expect(abs(moved.min.y - 25) < 1e-6 && abs(moved.max.y - 30) < 1e-6)
    }

    @Test func offsetPlaneFeature() async throws {
        let e = Engine()
        try await e.execute("document.new")
        let r = try await e.execute("plane.create", ["reference": "top", "offset": 30]).result
        #expect(r["plane"] == "plane-1" && r["normal"] == [0, 1, 0] && r["origin"] == [0, 30, 0])
        try await e.execute("sketch.create", ["plane": "Plane1"])
        try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [10, 10]]])
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 2])
        #expect(abs(try await e.activeDocument!.body("body-1").shape.boundingBox().min.y - 30) < 1e-6)
        try await e.execute("feature.edit", ["feature": "Plane1", "params": ["offset": 50]])
        #expect(abs(try await e.activeDocument!.body("body-1").shape.boundingBox().min.y - 50) < 1e-6)
        let names = try await e.execute("feature.list").result["features"]!.arrayValue!.map { $0["name"]!.stringValue! }
        #expect(names == ["Plane1", "Sketch1", "Boss-Extrude1"])
        // Deleting the plane leaves the sketch with a lost reference.
        let states = try await e.execute("feature.delete", ["feature": "Plane1"]).result["features"]!.arrayValue!.map { $0["state"]!.stringValue! }
        #expect(states == ["error", "ok"])
    }
}

@Suite("Hole Wizard")
struct HoleWizardTests {
    /// A 40 × 40 × 10 plate (z from 0 to 10) and a sketch on its top face with one point at
    /// (20, 20).
    func plate() async throws -> Engine {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("sketch.create", ["plane": "front"])
        try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [40, 40]]])
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 10])
        let faces = try await e.execute("query.faces", ["body": "body-1"]).result["faces"]!.arrayValue!
        let top = faces.first { $0["normal"]!.arrayValue!.map { $0.doubleValue! } == [0, 0, 1] }!["id"]!
        try await e.execute("sketch.create", ["face": top])
        try await e.execute("sketch.add_point", ["at": [20, 20]])
        try await e.execute("sketch.exit")
        return e
    }

    func removed(_ e: Engine) async throws -> Double {
        16000 - (try await e.execute("query.mass_properties", ["body": "body-1"]).result["volume_mm3"]!.doubleValue!)
    }

    @Test func clearanceCounterboreCountersinkAndTapped() async throws {
        let e = try await plate()
        try await e.execute("body.hole", ["sketch": "sketch-2", "size": "M6"])
        #expect(abs(try await removed(e) - .pi * 3.3 * 3.3 * 10) < 1e-6)
        #expect(await e.activeDocument!.features.last?.name == "M6 Clearance Hole1")

        try await e.execute("feature.edit", ["feature": "M6 Clearance Hole1", "params": ["type": "counterbore"]])
        #expect(abs(try await removed(e) - .pi * (5.5 * 5.5 * 6.5 + 3.3 * 3.3 * 3.5)) < 1e-6)

        try await e.execute("feature.edit", ["feature": "M6 Clearance Hole1", "params": ["type": "countersink"]])
        let (R, r, h) = (6.72, 3.3, (13.44 - 6.6) / 2)
        let cone = Double.pi * h / 3 * (R * R + R * r + r * r)
        #expect(abs(try await removed(e) - (cone + .pi * r * r * (10 - h))) < 1e-6)

        try await e.execute("feature.edit", ["feature": "M6 Clearance Hole1", "params": [
            "type": "tapped", "size": "M4", "end_condition": "blind", "depth": 5, "thread_depth": 4,
        ]])
        let rt = 3.3 / 2, point = rt / tan(59 * Double.pi / 180)
        #expect(abs(try await removed(e) - .pi * rt * rt * (5 + point / 3)) < 1e-6)
    }

    @Test func refusesBadInput() async throws {
        let e = try await plate()
        await #expect(throws: ForgeError.self) { try await e.execute("body.hole", ["sketch": "sketch-2", "size": "M7"]) }
        await #expect(throws: ForgeError.self) { try await e.execute("body.hole", ["sketch": "sketch-2", "size": "M6", "reverse": true]) }
        await #expect(throws: ForgeError.self) { try await e.execute("body.hole", ["sketch": "sketch-1", "size": "M6"]) }  // no points
    }
}

@Suite("Patterns and mirror")
struct PatternTests {
    func volume(_ e: Engine) async throws -> Double {
        try await e.execute("query.mass_properties", ["body": "body-1"]).result["volume_mm3"]!.doubleValue!
    }

    /// A 40 × 40 × 10 plate centred on the origin (z from 0 to 10), and a sketch on its top face.
    func plate() async throws -> (Engine, JSONValue) {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("sketch.create", ["plane": "front"])
        try await e.execute("sketch.add_rectangle", ["points": [[-20, -20], [20, 20]]])
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 10])
        let faces = try await e.execute("query.faces", ["body": "body-1"]).result["faces"]!.arrayValue!
        return (e, faces.first { $0["normal"]!.arrayValue!.map { $0.doubleValue! } == [0, 0, 1] }!["id"]!)
    }

    @Test func linearPatternOfHolesFollowsTheSeed() async throws {
        let (e, top) = try await plate()
        try await e.execute("sketch.create", ["face": top])
        try await e.execute("sketch.add_point", ["at": [-12, -12]])
        try await e.execute("sketch.exit")
        try await e.execute("body.hole", ["sketch": "sketch-2", "type": "hole", "size": "M3"])
        try await e.execute("pattern.linear", ["features": ["M3 Clearance Hole1"], "direction": "x", "spacing": 12, "count": 3,
                                               "direction2": "y", "spacing2": 12, "count2": 2])
        #expect(abs(try await volume(e) - (16000 - 6 * .pi * 1.7 * 1.7 * 10)) < 1e-6)
        // A bigger seed: every instance follows.
        try await e.execute("feature.edit", ["feature": "M3 Clearance Hole1", "params": ["size": "M4"]])
        #expect(abs(try await volume(e) - (16000 - 6 * .pi * 2.25 * 2.25 * 10)) < 1e-6)
        #expect(await e.activeDocument!.features.last?.name == "LPattern1")
    }

    @Test func circularPatternAndMirrorOfBosses() async throws {
        let (e, top) = try await plate()
        try await e.execute("sketch.create", ["face": top])
        try await e.execute("sketch.add_circle", ["center": [10, 0], "radius": 2])
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-2", "depth": 5, "merge": true])
        let boss = Double.pi * 4 * 5
        #expect(abs(try await volume(e) - (16000 + boss)) < 1e-6)
        try await e.execute("pattern.circular", ["features": ["Boss-Extrude2"], "axis": "z", "count": 4])
        #expect(abs(try await volume(e) - (16000 + 4 * boss)) < 1e-6)
        try await e.execute("feature.suppress", ["feature": "CirPattern1"])
        try await e.execute("pattern.mirror", ["features": ["Boss-Extrude2"], "plane": "right"])
        #expect(abs(try await volume(e) - (16000 + 2 * boss)) < 1e-6)
        #expect(await e.activeDocument!.bodies.count == 1)
    }

    @Test func unsupportedSeedsAreRefused() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        await #expect(throws: ForgeError.self) {
            try await e.execute("pattern.linear", ["features": ["Box1"], "direction": "x", "spacing": 20, "count": 2])
        }
    }
}

@Suite("Fillet and chamfer selections")
struct FilletSelectionTests {
    @Test func severalEdgesFacesAndBodiesInOneFeature() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        try await e.execute("body.transform", ["body": "body-2", "translate": [30, 0, 0]])
        func top(_ b: String) async throws -> String {
            let faces = try await e.execute("query.faces", ["body": .string(b)]).result["faces"]!.arrayValue!
            return faces.first { $0["normal"]!.arrayValue!.map { $0.doubleValue! } == [0, 0, 1] }!["id"]!.stringValue!
        }
        // All four edges of body-1's top face, and one edge of body-2: one Fillet1.
        let t1 = try await top("body-1")
        try await e.execute("body.fillet_edges", ["edges": [.string(t1), "body-2/edge-0"], "radius": 1])
        let v1 = try await e.execute("query.mass_properties", ["body": "body-1"]).result["volume_mm3"]!.doubleValue!
        let v2 = try await e.execute("query.mass_properties", ["body": "body-2"]).result["volume_mm3"]!.doubleValue!
        // Each rounded edge removes (1 − π/4) mm² per mm; the four top edges meet in mitred
        // corners, so body-1 loses between 4 × 8 and 4 × 10 mm of that section.
        let a: Double = 1 - Double.pi / 4
        let most: Double = 1000 - 40 * a, least: Double = 1000 - 32 * a
        #expect(v1 > most - 1e-6)
        #expect(v1 < least + 1e-6)
        #expect(abs(v2 - (1000 - 10 * a)) < 1e-6)
        let tree = try await e.execute("feature.list").result["features"]!.arrayValue!
        #expect(tree.last?["name"] == "Fillet1")
    }
}

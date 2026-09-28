import ForgeCore
import Foundation
import Testing

@testable import ForgeCommands

// Persistent naming torture suite (docs/adr/0002, SPEC §9): upstream edits must leave a
// reference on the geometrically intended entity or fail with reference_lost — never rebind
// silently. Expected values are derived from the geometry, not from program output.
@Suite("Persistent naming")
struct NamingTests {
    func volume(_ e: Engine, _ body: String = "body-1") async throws -> Double {
        try await e.execute("query.mass_properties", ["body": .string(body)]).result["volume_mm3"]!.doubleValue!
    }

    /// A 40 × 20 rectangle on the Front plane (width dimensioned), extruded 10 along +Z.
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

    /// The transient id of the edge whose midpoint satisfies `where`.
    func edge(_ e: Engine, _ body: String = "body-1", where test: (Vec3) -> Bool) async throws -> String {
        let edges = try await e.execute("query.edges", ["body": .string(body)]).result["edges"]!.arrayValue!
        let hits = edges.filter { d in
            let m = d["midpoint"]!.arrayValue!.map { $0.doubleValue! }
            return test(Vec3(m[0], m[1], m[2]))
        }
        try #require(hits.count == 1, "expected one edge, found \(hits.count)")
        return hits[0]["id"]!.stringValue!
    }

    /// Centroids of the body's cylindrical faces (fillet blends).
    func blends(_ e: Engine, _ body: String = "body-1") async throws -> [Vec3] {
        try await e.execute("query.faces", ["body": .string(body)]).result["faces"]!.arrayValue!
            .filter { $0["surface_type"]?.stringValue == "cylinder" }
            .map { d in
                let c = d["centroid"]!.arrayValue!.map { $0.doubleValue! }
                return Vec3(c[0], c[1], c[2])
            }
    }

    /// The front-top edge: y = 0, z = 10 (between the end cap and the bottom line's side).
    func frontTop(_ v: Vec3) -> Bool { abs(v.y) < 1e-6 && abs(v.z - 10) < 1e-6 }

    @Test func facesAreNamedByFeatureAndRole() async throws {
        let (e, _) = try await block()
        let faces = try await e.execute("query.faces", ["body": "body-1"]).result["faces"]!.arrayValue!
        let ids = Set(faces.compactMap { $0["persistent_id"]?.stringValue })
        // Feature 1 is the sketch, feature 2 the extrusion; the rectangle is line-1 … line-4.
        #expect(ids.contains("body-1/face@feature-2:end_cap"))
        #expect(ids.contains("body-1/face@feature-2:start_cap"))
        #expect(ids.filter { $0.hasPrefix("body-1/face@feature-2:side(line-") }.count == 4)
        let edges = try await e.execute("query.edges", ["body": "body-1"]).result["edges"]!.arrayValue!
        #expect(Set(edges.compactMap { $0["persistent_id"]?.stringValue }).count == 12)
    }

    @Test func featuresStoreNamesNotIndices() async throws {
        let (e, _) = try await block()
        let edge = try await edge(e, where: frontTop)
        try await e.execute("body.fillet_edges", ["edges": [.string(edge)], "radius": 2])
        let f = try await e.execute("feature.list").result["features"]!.arrayValue!.last!
        let stored = f["params"]!["edges"]![0]!.stringValue!
        #expect(stored.hasPrefix("body-1/edge@"))
        #expect(stored.contains("feature-2:end_cap"))
        #expect(await e.activeDocument!.features.last!.references?[stored]?.type == "line")
    }

    @Test func filletFollowsItsEdgeWhenAnUpstreamDimensionChanges() async throws {
        let (e, dim) = try await block()
        try await e.execute("body.fillet_edges", ["edges": [.string(try await edge(e, where: frontTop))], "radius": 2])
        try await e.execute("sketch.edit", ["sketch": "sketch-1"])
        try await e.execute("sketch.set_dimension", ["constraint": .string(dim), "value": 60])
        try await e.execute("sketch.exit")
        // A constant fillet of radius r along a straight edge of length L removes (1 - π/4)·r²·L.
        #expect(abs(try await volume(e) - (60 * 20 * 10 - (1 - .pi / 4) * 4 * 60)) < 1e-4)
        // …still on the front-top edge: the blend's centroid is near y = 0, z = 10.
        let b = try await blends(e)
        #expect(b.count == 1 && b[0].y < 2 && b[0].z > 8)
        let states = try await e.execute("feature.list").result["features"]!.arrayValue!.map { $0["state"]!.stringValue! }
        #expect(states == ["ok", "ok", "ok"])
    }

    @Test func filletFollowsItsEdgeWhenAFeatureIsInsertedUpstream() async throws {
        let (e, _) = try await block()
        try await e.execute("body.fillet_edges", ["edges": [.string(try await edge(e, where: frontTop))], "radius": 2])
        // Insert a through-all hole before the fillet: it adds faces and edges (renumbering).
        try await e.execute("feature.rollback", ["before": "Fillet1"])
        let before = try await e.execute("query.edges", ["body": "body-1"]).result["edges"]!.arrayValue!.count
        try await e.execute("sketch.create", ["plane": "front"])
        try await e.execute("sketch.add_circle", ["center": [30, 12], "radius": 3])
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-2", "end_condition": "through_all_both", "operation": "cut"])
        let after = try await e.execute("query.edges", ["body": "body-1"]).result["edges"]!.arrayValue!.count
        #expect(after > before)
        try await e.execute("feature.rollback")
        let names = try await e.execute("feature.list").result["features"]!.arrayValue!.map { $0["name"]!.stringValue! }
        #expect(names == ["Sketch1", "Boss-Extrude1", "Sketch2", "Cut-Extrude1", "Fillet1"])
        let hole = Double.pi * 9 * 10
        #expect(abs(try await volume(e) - (40 * 20 * 10 - hole - (1 - .pi / 4) * 4 * 40)) < 1e-4)
        let b = try await blends(e).filter { abs($0.x - 30) > 3.5 || abs($0.y - 12) > 3.5 }  // not the hole's wall
        #expect(b.count == 1 && b[0].y < 2 && b[0].z > 8)
    }

    @Test func aSplitEdgeFilletsAllItsPieces() async throws {
        let (e, _) = try await block()
        try await e.execute("body.fillet_edges", ["edges": [.string(try await edge(e, where: frontTop))], "radius": 2])
        // A notch 4 wide and 5 deep through the front face cuts the edge in two (x 0–18, 22–40).
        try await e.execute("feature.rollback", ["before": "Fillet1"])
        try await e.execute("sketch.create", ["plane": "front"])
        try await e.execute("sketch.add_rectangle", ["points": [[18, -1], [22, 5]]])
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-2", "end_condition": "through_all_both", "operation": "cut"])
        try await e.execute("feature.rollback")
        let notch = 4.0 * 5 * 10
        #expect(abs(try await volume(e) - (40 * 20 * 10 - notch - (1 - .pi / 4) * 4 * 36)) < 1e-4)
        #expect(try await blends(e).count == 2)
    }

    @Test func aLostReferenceFailsAndOffersRepairs() async throws {
        let (e, _) = try await block()
        // A boss on the end cap, and a fillet on one of its edges.
        try await e.execute("sketch.create", ["plane": "front", "offset": 10])
        try await e.execute("sketch.add_rectangle", ["points": [[5, 5], [15, 15]]])
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-2", "depth": 5, "merge": true])
        let bossEdge = try await edge(e) { abs($0.y - 5) < 1e-6 && abs($0.z - 15) < 1e-6 }
        try await e.execute("body.fillet_edges", ["edges": [.string(bossEdge)], "radius": 1])
        // Suppressing the boss removes that edge: the fillet must fail, not move elsewhere.
        try await e.execute("feature.suppress", ["feature": "Boss-Extrude2"])
        let fillet = try await e.execute("feature.list").result["features"]!.arrayValue!.last!
        #expect(fillet["state"] == "error")
        #expect(fillet["error_code"] == "reference_lost")
        let fixes = try #require(fillet["suggestions"]?.arrayValue).filter { $0["command"] == "feature.repair_reference" }
        try #require(!fixes.isEmpty, "\(fillet)")
        #expect(abs(try await volume(e) - 40 * 20 * 10) < 1e-6)
        // Repairing onto the front-top edge of the block.
        let target = try await edge(e, where: frontTop)
        let old = fixes[0]["params"]!["old"]!
        try await e.execute("feature.repair_reference", ["feature": "Fillet1", "old": old, "new": .string(target)])
        #expect(try await e.execute("feature.list").result["features"]!.arrayValue!.last!["state"] == "ok")
        #expect(abs(try await volume(e) - (40 * 20 * 10 - (1 - .pi / 4) * 1 * 40)) < 1e-4)
    }

    @Test func namesSurviveSaveAndOpen() async throws {
        let (e, dim) = try await block()
        try await e.execute("body.fillet_edges", ["edges": [.string(try await edge(e, where: frontTop))], "radius": 2])
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("naming-\(UUID().uuidString).forgepart").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await e.execute("document.save", ["path": .string(path)])
        let e2 = Engine()
        try await e2.execute("document.open", ["path": .string(path)])
        let faces = try await e2.execute("query.faces", ["body": "body-1"]).result["faces"]!.arrayValue!
        #expect(faces.contains { $0["persistent_id"] == "body-1/face@feature-2:end_cap" })
        try await e2.execute("sketch.edit", ["sketch": "sketch-1"])
        try await e2.execute("sketch.set_dimension", ["constraint": .string(dim), "value": 50])
        try await e2.execute("sketch.exit")
        #expect(abs(try await volume(e2) - (50 * 20 * 10 - (1 - .pi / 4) * 4 * 50)) < 1e-4)
    }

    @Test func namedReferencesWorkEverywhereATransientOneDoes() async throws {
        let (e, _) = try await block()
        try await e.execute("selection.set", ["entities": ["body-1/face@feature-2:end_cap"]])
        let sel = await e.activeDocument!.selection
        #expect(sel.count == 1 && sel[0].hasPrefix("body-1/face-"))
        let d = try await e.execute("query.entity", ["ref": "body-1/face@feature-2:end_cap"]).result
        #expect(d["face"]?["normal"] == [0, 0, 1])
        try await e.execute("body.shell", ["body": "body-1", "faces": ["body-1/face@feature-2:end_cap"], "thickness": 1])
        // Open-top shell of a 40 × 20 × 10 block, walls 1: 38 × 18 × 9 removed.
        #expect(abs(try await volume(e) - (40 * 20 * 10 - 38 * 18 * 9)) < 1e-4)
    }

    @Test func semanticFaceQueries() async throws {
        let (e, _) = try await block()
        let cap = try await e.execute("query.find_faces", ["feature": "Boss-Extrude1", "role": "end_cap"]).result["faces"]!.arrayValue!
        #expect(cap.count == 1 && cap[0]["normal"] == [0, 0, 1] && cap[0]["centroid"] == [20, 10, 10])
        #expect(try await e.execute("query.find_faces", ["feature": "Boss-Extrude1", "role": "side"]).result["faces"]!.arrayValue!.count == 4)
        #expect(try await e.execute("query.find_faces", ["feature": "Boss-Extrude1"]).result["faces"]!.arrayValue!.count == 6)
        // A sketch entity names the face swept from it.
        let line = try #require(await e.activeDocument!.sketches["sketch-1"]?.orderedEntities.first { $0.kind == .line }?.id)
        #expect(try await e.execute("query.find_faces", ["feature": "Boss-Extrude1", "role": .string(line)]).result["faces"]!.arrayValue!.count == 1)
    }

    @Test func nameSyntax() {
        #expect(Naming.faceBase("feature-2:side(line-1)#3") == "feature-2:side(line-1)")
        #expect(Naming.faceBase("feature-5:blend(A#1|B)") == "feature-5:blend(A#1|B)")
        #expect(Naming.edgeParts("feature-5:blend(A|B)|C~2") == ["feature-5:blend(A|B)", "C"])
        #expect(EntityRef(parsing: "body-1/edge@A|B")?.name == "A|B")
        #expect(EntityRef(parsing: "body-1/edge@A|B")?.description == "body-1/edge@A|B")
    }
}

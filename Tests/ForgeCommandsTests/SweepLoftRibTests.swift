import ForgeCore
import Foundation
import Testing

@testable import ForgeCommands

// Sweep, Loft and Rib through the command bus. Expected volumes are derived analytically.
@Suite("Sweep, loft and rib")
struct SweepLoftRibTests {
    func volume(_ e: Engine, _ body: String = "body-1") async throws -> Double {
        try await e.execute("query.mass_properties", ["body": .string(body)]).result["volume_mm3"]!.doubleValue!
    }

    func lines(_ e: Engine, _ pts: [[Double]], closed: Bool) async throws -> [String] {
        var ids: [String] = []
        let n = closed ? pts.count : pts.count - 1
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            let r = try await e.execute("sketch.add_line", ["start": .array(a.map { .number($0) }), "end": .array(b.map { .number($0) })]).result
            ids += r["created"]!.arrayValue!.compactMap(\.stringValue).filter { $0.hasPrefix("line") }
        }
        return ids
    }

    @Test func circularSweepAlongALineAndAnArc() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("sketch.create", ["plane": "front"])
        let line = try await e.execute("sketch.add_line", ["start": [0, 0], "end": [20, 0]]).result["created"]!.arrayValue!
            .compactMap(\.stringValue).first { $0.hasPrefix("line") }!
        try await e.execute("sketch.add_arc", ["center": [20, 10], "start": [20, 0], "end": [30, 10]])
        try await e.execute("sketch.exit")
        try await e.execute("body.sweep", ["path": "sketch-1", "circular_diameter": 4])
        // Pappus: π r² times the path length, 20 + (π/2)·10.
        #expect(abs(try await volume(e) - .pi * 4 * (20 + 5 * .pi)) < 1e-3)
        let f = try await e.execute("feature.list").result["features"]!.arrayValue!.last!
        #expect(f["name"] == "Sweep1" && f["state"] == "ok")
        // The feature edits and regenerates: diameter 6.
        try await e.execute("feature.edit", ["feature": "Sweep1", "params": ["circular_diameter": 6]])
        #expect(abs(try await volume(e) - .pi * 9 * (20 + 5 * .pi)) < 1e-3)
        _ = line
    }

    @Test func profileSweepAndCut() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("sketch.create", ["plane": "front"])
        try await e.execute("sketch.add_line", ["start": [0, 0], "end": [30, 0]])
        try await e.execute("sketch.exit")
        // A 4 × 4 square on the Right plane (x = 0), centred on the path's start.
        try await e.execute("sketch.create", ["plane": "right"])
        try await e.execute("sketch.add_rectangle", ["points": [[-2, -2], [2, 2]]])
        try await e.execute("sketch.exit")
        try await e.execute("body.sweep", ["profile": "sketch-2", "path": "sketch-1"])
        #expect(abs(try await volume(e) - 16 * 30) < 1e-6)
        let sides = try await e.execute("query.find_faces", ["feature": "Sweep1", "role": "side"]).result["faces"]!.arrayValue!
        #expect(sides.count == 4)
        // A circular sweep cut along the same path removes a 2 mm diameter tunnel.
        try await e.execute("body.sweep", ["path": "sketch-1", "circular_diameter": 2, "operation": "cut"])
        #expect(abs(try await volume(e) - (16 * 30 - .pi * 30)) < 1e-4)
        #expect(try await e.execute("feature.list").result["features"]!.arrayValue!.last!["name"] == "Cut-Sweep1")
    }

    @Test func loftBetweenSquares() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("sketch.create", ["plane": "front"])
        try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [10, 10]]])
        try await e.execute("sketch.exit")
        try await e.execute("sketch.create", ["plane": "front", "offset": 10])
        try await e.execute("sketch.add_rectangle", ["points": [[-5, -5], [15, 15]]])
        try await e.execute("sketch.exit")
        try await e.execute("body.loft", ["profiles": ["sketch-1", "sketch-2"], "ruled": true])
        // Frustum of a square pyramid: h/3 (A1 + A2 + √(A1 A2)) = 10/3 (100 + 400 + 200).
        #expect(abs(try await volume(e) - 7000.0 / 3) < 1e-6)
        #expect(try await e.execute("query.find_faces", ["feature": "Loft1", "role": "side"]).result["faces"]!.arrayValue!.count == 4)
        #expect(try await e.execute("query.find_faces", ["feature": "Loft1", "role": "end_cap"]).result["faces"]!.arrayValue!.count == 1)
        // Editing a profile regenerates the loft: the top square grows to 30 (centred), so
        // 10/3 (100 + 900 + 300).
        try await e.execute("sketch.edit", ["sketch": "sketch-2"])
        let old = await e.activeDocument!.sketches["sketch-2"]!.orderedEntities.filter { $0.kind == .line }.map { JSONValue.string($0.id) }
        try await e.execute("sketch.delete", ["items": .array(old)])
        try await e.execute("sketch.add_rectangle", ["points": [[-10, -10], [20, 20]]])
        try await e.execute("sketch.exit")
        #expect(abs(try await volume(e) - 13000.0 / 3) < 1e-6)
    }

    @Test func ribInAnLBracket() async throws {
        let e = Engine()
        try await e.execute("document.new")
        // L section: 40 × 5 foot and 5 × 35 upright (area 375), extruded 20 along +Z.
        try await e.execute("sketch.create", ["plane": "front"])
        _ = try await lines(e, [[0, 0], [40, 0], [40, 5], [5, 5], [5, 40], [0, 40]], closed: true)
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 20])
        #expect(abs(try await volume(e) - 7500) < 1e-6)
        // A diagonal rib across the inner corner, mid-depth, 2 thick.
        try await e.execute("sketch.create", ["plane": "front", "offset": 10])
        try await e.execute("sketch.add_line", ["start": [5, 25], "end": [25, 5]])
        try await e.execute("sketch.exit")
        try await e.execute("body.rib", ["sketch": "sketch-2", "thickness": 2])
        // The triangle (5,5)-(5,25)-(25,5) has area 200; times the thickness, 400.
        #expect(abs(try await volume(e) - 7900) < 1e-6)
        let f = try await e.execute("feature.list").result["features"]!.arrayValue!.last!
        #expect(f["name"] == "Rib1" && f["state"] == "ok")
        #expect(await e.activeDocument!.bodies.count == 1)
        // Growing it away from the corner never meets the body.
        await #expect(throws: ForgeError.self) { try await e.execute("body.rib", ["sketch": "sketch-2", "thickness": 2, "flip": true]) }
        // Thicker rib, one side: the feature edits and regenerates.
        try await e.execute("feature.edit", ["feature": "Rib1", "params": ["thickness": 4, "thickness_side": "first"]])
        #expect(abs(try await volume(e) - 8300) < 1e-6)
    }

    @Test func ribNormalToTheSketch() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 40, "height": 40, "depth": 5])
        // A line 20 long, 15 above the plate: the rib grows down to it, 2 thick → 20 · 2 · 15.
        try await e.execute("sketch.create", ["plane": "front", "offset": 20])
        try await e.execute("sketch.add_line", ["start": [10, 20], "end": [30, 20]])
        try await e.execute("sketch.exit")
        try await e.execute("body.rib", ["sketch": "sketch-1", "thickness": 2, "direction": "normal_to_sketch"])
        #expect(abs(try await volume(e) - (8000 + 600)) < 1e-6)
    }
}

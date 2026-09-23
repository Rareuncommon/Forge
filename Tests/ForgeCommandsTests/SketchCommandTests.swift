import ForgeCore
import Foundation
import Testing

@testable import ForgeCommands

@Suite("Sketch commands")
struct SketchCommandTests {
    func engine() async throws -> Engine {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("sketch.create", ["plane": "front"])
        return e
    }

    func entity(_ e: Engine, _ id: String) async throws -> JSONValue {
        let s = try await e.execute("sketch.get").result
        return s["entities"]!.arrayValue!.first { $0["id"] == .string(id) }!
    }

    @Test func noSketchGivesActionableError() async throws {
        let e = Engine()
        try await e.execute("document.new")
        do {
            try await e.execute("sketch.add_line", ["start": [0, 0], "end": [1, 0]])
            Issue.record("expected error")
        } catch let err as ForgeError {
            #expect(err.code == .preconditionFailed)
            #expect(err.suggestions.first?.command == "sketch.create")
        }
    }

    @Test func coordinatesInferCoincidenceAndOrientation() async throws {
        let e = try await engine()
        let a = try await e.execute("sketch.add_line", ["start": [0, 0], "end": [30, 0]]).result
        // Starts on the origin and is exactly horizontal.
        #expect(a["inferred"]?.arrayValue?.compactMap { $0["kind"]?.stringValue }.sorted() == ["coincident", "horizontal"])
        try await e.execute("sketch.add_line", ["start": [30, 0], "end": [30, 20]])
        try await e.execute("sketch.add_line", ["start": [30, 20], "end": [0, 0]])
        let check = try await e.execute("sketch.check").result
        #expect(check["valid"] == true)
        #expect(abs(check["region_area_mm2"]!.doubleValue! - 300) < 1e-9)
        #expect(try await e.execute("document.state").result["sketches"]?[0]?["dof"] == 2)  // hypotenuse-free triangle: width + height
    }

    @Test func fullyDefinedPlateWithUnitsAndEditing() async throws {
        let e = try await engine()
        let r = try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [40, 20]]]).result
        let lines = r["created"]!.arrayValue!.compactMap(\.stringValue)
        #expect(r["inferred"]?.arrayValue?.count == 1)  // corner on the origin
        let w = try await e.execute("sketch.add_dimension", ["type": "distance", "entities": [.string(lines[0])], "value": "2 in"]).result
        try await e.execute("sketch.add_dimension", ["type": "distance", "entities": [.string(lines[1])], "value": 25])
        let hole = try await e.execute("sketch.add_circle", ["center": [20, 10], "radius": 5]).result["created"]![0]!
        let cid = hole.stringValue!
        let summary = try await e.execute("sketch.get").result
        let center = summary["entities"]!.arrayValue!.first { $0["id"] == hole }!["points"]![0]!.stringValue!
        try await e.execute("sketch.add_dimension", ["type": "diameter", "entities": [.string(cid)], "value": 10])
        try await e.execute("sketch.add_dimension", ["type": "horizontal_distance", "entities": ["point-0", .string(center)], "value": "1 in"])
        let last = try await e.execute("sketch.add_dimension", ["type": "vertical_distance", "entities": ["point-0", .string(center)], "value": 12.5]).result
        #expect(last["sketch"]?["status"] == "fully_defined")
        #expect(last["sketch"]?["dof"] == 0)
        let check = try await e.execute("sketch.check").result
        #expect(abs(check["region_area_mm2"]!.doubleValue! - (50.8 * 25 - .pi * 25)) < 1e-9)

        // Changing a dimension moves the geometry; undo restores it.
        let wid = w["constraints"]![0]!.stringValue!
        try await e.execute("sketch.set_dimension", ["constraint": .string(wid), "value": 60])
        let l0 = try await entity(e, lines[0])
        #expect(abs(l0["length_mm"]!.doubleValue! - 60) < 1e-9)
        try await e.execute("edit.undo")
        #expect(abs(try await entity(e, lines[0])["length_mm"]!.doubleValue! - 50.8) < 1e-9)
    }

    @Test func conflictsAreRejectedAndLeaveNoTrace() async throws {
        let e = try await engine()
        let l = try await e.execute("sketch.add_line", ["start": [0, 5], "end": [10, 5]]).result["created"]![0]!
        try await e.execute("sketch.add_dimension", ["type": "distance", "entities": [l], "value": 10])
        let undoBefore = try await e.execute("document.state").result["undo"]!.arrayValue!.count
        do {
            try await e.execute("sketch.add_relation", ["type": "vertical", "entities": [l]])
            Issue.record("expected conflict")
        } catch let err as ForgeError {
            #expect(err.code == .sketchConflict)
        }
        do {
            try await e.execute("sketch.add_relation", ["type": "horizontal", "entities": ["point-2", "point-3"]])
            Issue.record("expected redundancy")
        } catch let err as ForgeError {
            #expect(err.code == .sketchRedundant)
        }
        let state = try await e.execute("document.state").result
        #expect(state["undo"]!.arrayValue!.count == undoBefore)
        #expect(try await e.execute("sketch.get").result["solver"]?["status"] == "under_defined")
    }

    @Test func tangentArcContinuesALine() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_line", ["start": [0, 0], "end": [20, 0]])
        let arc = try await e.execute("sketch.add_arc", ["mode": "tangent", "tangent_to": "line-1", "end": [30, 10]]).result
        let id = arc["created"]![0]!.stringValue!
        let a = try await entity(e, id)
        // Tangent to a horizontal line at (20, 0) and passing through (30, 10): centre (20, 10), r = 10.
        #expect(abs(a["radius"]!.doubleValue! - 10) < 1e-9)
        #expect(abs(a["center"]![0]!.doubleValue! - 20) < 1e-9 && abs(a["center"]![1]!.doubleValue! - 10) < 1e-9)
    }

    @Test func threePointArcAndPerimeterCircle() async throws {
        let e = try await engine()
        let arc = try await e.execute("sketch.add_arc", ["mode": "three_point", "start": [10, 0], "through": [0, 10], "end": [-10, 0]]).result
        let a = try await entity(e, arc["created"]![0]!.stringValue!)
        #expect(abs(a["radius"]!.doubleValue! - 10) < 1e-9)
        #expect(abs(a["start"]![0]!.doubleValue! - 10) < 1e-9)  // CCW from (10,0) through (0,10)
        let c = try await e.execute("sketch.add_circle", ["through": [[0, 0], [6, 0], [0, 8]]]).result
        #expect(abs(try await entity(e, c["created"]![0]!.stringValue!)["radius"]!.doubleValue! - 5) < 1e-9)
    }

    @Test func dragAndDelete() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_line", ["start": [1, 1], "end": [10, 1]])
        try await e.execute("sketch.drag", ["entity": "point-3", "to": [10, 7]])
        let l = try await entity(e, "line-1")
        // The dragged end reaches the target and the (inferred) horizontal relation still holds.
        #expect(abs(l["end"]![0]!.doubleValue! - 10) < 1e-9 && abs(l["end"]![1]!.doubleValue! - 7) < 1e-9)
        #expect(abs(l["start"]![1]!.doubleValue! - 7) < 1e-9)
        try await e.execute("selection.set", ["entities": ["sketch-1/line-1"]])
        let d = try await e.execute("sketch.delete", ["items": ["line-1"]]).result
        #expect(d["deleted_entities"] == ["line-1", "point-2", "point-3"])
        #expect(try await e.execute("selection.get").result["selection"] == [])
    }

    @Test func renderAndPickSketchCurves() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [40, 20]]])
        let view: JSONValue = ["orientation": "front", "width": 200, "height": 120]
        let img = try await e.execute("view.render", ["view": view])
        #expect(img.result["png_base64"] != nil)
        // Bottom edge of the rectangle: 40 wide centred in a 200px image with margin.
        var hit: JSONValue?
        for y in stride(from: 60, to: 120, by: 1) {
            let p = try await e.execute("view.pick", ["x": 100, "y": .number(Double(y)), "view": view, "radius": 0]).result
            if p["element"] == "sketch_curve" {
                hit = p
                break
            }
        }
        #expect(hit?["hit"] == "sketch-1/line-1")
    }

    @Test func sketchesAndEditModeAreExplicitState() async throws {
        let e = try await engine()
        try await e.execute("sketch.create", ["plane": "top", "name": "Second"])
        var st = try await e.execute("document.state").result
        #expect(st["active_sketch"] == "sketch-2")
        #expect(st["sketches"]?.arrayValue?.count == 2)
        try await e.execute("sketch.exit")
        st = try await e.execute("document.state").result
        #expect(st["active_sketch"] == nil || st["active_sketch"] == .null)
        try await e.execute("sketch.add_point", ["sketch": "Second", "at": [1, 2]])
        try await e.execute("sketch.edit", ["sketch": "sketch-1"])
        try await e.execute("sketch.remove", ["sketch": "sketch-2"])
        #expect(try await e.execute("document.state").result["sketches"]?.arrayValue?.count == 1)
        try await e.execute("edit.undo")
        #expect(try await e.execute("document.state").result["sketches"]?.arrayValue?.count == 2)
    }

    @Test func dryRunDimensionPreviewsSolve() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_line", ["start": [0, 0], "end": [10, 0]])
        let dry = try await e.execute("sketch.add_dimension", ["type": "distance", "entities": ["line-1"], "value": 25], dryRun: true)
        #expect(dry.changes.modified == ["sketch-1"])
        #expect(abs(try await entity(e, "line-1")["length_mm"]!.doubleValue! - 10) < 1e-9)
    }

    @Test func extrudeHandlesHolesAndIslands() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [40, 40]]])
        try await e.execute("sketch.add_rectangle", ["points": [[10, 10], [30, 30]]])
        try await e.execute("sketch.add_circle", ["center": [20, 20], "radius": 5])
        let check = try await e.execute("sketch.check").result
        #expect(check["loops"]?.arrayValue?.compactMap { $0["depth"]?.intValue }.sorted() == [0, 1, 2])
        let body = try await e.execute("body.extrude", ["depth": 2]).result["body"]!
        #expect(abs(body["volume_mm3"]!.doubleValue! - (1600 - 400 + 25 * Double.pi) * 2) < 1e-6)
        #expect(body["topology"]?["solids"] == 2)  // the island is a separate solid
    }

    @Test func extrudingAnOpenProfileExplainsWhy() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_line", ["start": [0, 0], "end": [10, 0]])
        try await e.execute("sketch.add_line", ["start": [10, 0], "end": [10, 10]])
        do {
            try await e.execute("body.extrude", ["depth": 5])
            Issue.record("expected error")
        } catch let err as ForgeError {
            #expect(err.code == .preconditionFailed)
            #expect(err.message.contains("open contour"))
            #expect(err.suggestions.first?.command == "sketch.check")
        }
    }
    @Test func mirrorAndPatternsThroughTheBus() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_line", ["start": [0, -5], "end": [0, 30], "construction": true])  // line-1
        try await e.execute("sketch.add_circle", ["center": [10, 10], "radius": 2])  // circle-4
        let before = try await e.execute("sketch.get").result["entities"]!.arrayValue!.count
        let m = try await e.execute("sketch.mirror", ["entities": ["sketch-1/circle-4"], "axis": "line-1"]).result
        #expect(m["created"]?.arrayValue?.count == 1)
        let copy = m["created"]![0]!.stringValue!
        #expect(try await entity(e, copy)["center"] == [-10, 10])
        try await e.execute("edit.undo")
        #expect(try await e.execute("sketch.get").result["entities"]!.arrayValue!.count == before)

        let lin = try await e.execute("sketch.pattern_linear", ["entities": ["circle-4"], "count": 3, "spacing": "0.5 in", "along": "line-1"]).result
        #expect(lin["instances"]?.arrayValue?.count == 2)
        let top = try await entity(e, lin["instances"]![1]![0]!.stringValue!)["center"]!.arrayValue!
        #expect(abs(top[0].doubleValue! - 10) < 1e-9 && abs(top[1].doubleValue! - (10 + 2 * 12.7)) < 1e-9)

        let circ = try await e.execute("sketch.pattern_circular", ["entities": ["circle-4"], "count": 4, "about": "point-0"]).result
        #expect(circ["created"]?.arrayValue?.count == 3)
        do {
            try await e.execute("sketch.pattern_circular", ["entities": ["circle-4"], "count": 4, "about": "line-1"])
            Issue.record("expected error")
        } catch let err as ForgeError {
            #expect(err.code == .invalidParams)
        }
    }
    @Test func trimAndExtendThroughTheBus() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_line", ["start": [0, 0], "end": [5, 0], "infer": false])  // line-1
        try await e.execute("sketch.add_line", ["start": [10, -5], "end": [10, 5], "infer": false])  // line-4
        let ext = try await e.execute("sketch.extend", ["entity": "line-1", "near": [4, 0]]).result
        #expect(ext["constraints"]?.arrayValue?.count == 1)
        #expect(try await entity(e, "point-3")["at"] == [10, 0])
        let t = try await e.execute("sketch.trim", ["entity": "line-4", "at": [10, 3]]).result
        #expect(t["created"] == [] && t["deleted"] == [])
        #expect(try await entity(e, "point-6")["at"] == [10, 0])
        try await e.execute("edit.undo")
        #expect(try await entity(e, "point-6")["at"] == [10, 5])
        do {
            try await e.execute("sketch.extend", ["entity": "line-1", "near": [0, 0]])
            Issue.record("expected error")
        } catch let err as ForgeError {
            #expect(err.code == .invalidParams)
        }
    }
    @Test func offsetThroughTheBus() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_circle", ["center": [0, 0], "radius": 10])  // circle-1
        let r = try await e.execute("sketch.offset", ["entities": ["circle-1"], "distance": "0.1 in", "toward": [0, 0]]).result
        let copy = r["sides"]![0]![0]!.stringValue!
        #expect(abs(try await entity(e, copy)["radius"]!.doubleValue! - 7.46) < 1e-9)
        let dim = r["dimension"]!.stringValue!
        try await e.execute("sketch.set_dimension", ["constraint": .string(dim), "value": 4])
        // The original is free too, so check what the dimension controls: the radius difference.
        let r0 = try await entity(e, "circle-1")["radius"]!.doubleValue!, r1 = try await entity(e, copy)["radius"]!.doubleValue!
        #expect(abs(r0 - r1 - 4) < 1e-9)
        try await e.execute("edit.undo")
        try await e.execute("edit.undo")
        #expect(try await e.execute("sketch.get").result["entities"]!.arrayValue!.count == 3)
        do {
            try await e.execute("sketch.offset", ["entities": ["circle-1"], "distance": 1, "cap_ends": true])
            Issue.record("expected error")
        } catch let err as ForgeError {
            #expect(err.code == .invalidParams)
        }
    }
    @Test func moveRotateScaleThroughTheBus() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_line", ["start": [10, 0], "end": [20, 0]])  // line-1, inferred horizontal
        let m = try await e.execute("sketch.move", ["entities": ["line-1"], "from": [10, 0], "to": [10, 5]]).result
        #expect(m["entities"] == ["line-1"])
        #expect(try await entity(e, "point-2")["at"] == [10, 5])
        let r = try await e.execute("sketch.rotate", ["entities": ["line-1"], "angle": "90 deg", "about": "point-2"]).result
        #expect(r["removed_constraints"]?.arrayValue?.count == 1)  // horizontal
        let end = try await entity(e, "point-3")["at"]!.arrayValue!.map { $0.doubleValue! }
        #expect(abs(end[0] - 10) < 1e-9 && abs(end[1] - 15) < 1e-9)
        let c = try await e.execute("sketch.scale", ["entities": ["line-1"], "factor": 2, "center": [10, 5], "copy": true]).result
        let copy = c["entities"]![0]!.stringValue!
        let pts = try await entity(e, copy)["points"]!.arrayValue!.map { $0.stringValue! }
        #expect(try await entity(e, pts[1])["at"] == [10, 25])
        try await e.execute("edit.undo")
        #expect(try await e.execute("sketch.get").result["entities"]!.arrayValue!.count == 4)
    }
    @Test func splitThroughTheBus() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_circle", ["center": [0, 0], "radius": 5])  // circle-1
        let r = try await e.execute("sketch.split", ["entity": "circle-1", "at": [[5, 0], [-5, 0]]]).result
        #expect(r["created"]?.arrayValue?.count == 2 && r["deleted"] == ["circle-1"])
        try await e.execute("edit.undo")
        #expect(try await entity(e, "circle-1")["radius"] == 5)
        do {
            try await e.execute("sketch.split", ["entity": "circle-1", "at": [[5, 0]]])
            Issue.record("expected error")
        } catch let err as ForgeError {
            #expect(err.code == .invalidParams)
        }
    }
}

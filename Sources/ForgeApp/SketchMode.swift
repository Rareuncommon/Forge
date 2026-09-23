// Sketch editing (M1). Every action is a command on the bus; the UI only turns clicks into
// sketch coordinates (and, for trim, the curve under the cursor) and chooses the command.

import ForgeCommands
import ForgeCore
import ForgeRender
import ForgeSketch
import SwiftUI

enum SketchTool: String, CaseIterable, Identifiable {
    case line, rectangle, circle, arc, point, fillet, trim
    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .arc: "3 Point\nArc"
        case .point: "Point"
        case .fillet: "Sketch\nFillet"
        case .trim: "Trim"
        }
    }

    var systemImage: String {
        switch self {
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .arc: "circle.bottomhalf.filled"
        case .point: "smallcircle.filled.circle"
        case .fillet: "arrow.turn.down.right"
        case .trim: "scissors"
        }
    }

    var hint: String {
        switch self {
        case .line: "Line: click points to draw connected lines; Esc ends the chain."
        case .rectangle: "Rectangle: click two opposite corners."
        case .circle: "Circle: click the centre, then a point on the circle."
        case .arc: "3 Point Arc: click the start, the end, then a point the arc passes through."
        case .point: "Point: click to place a point."
        case .fillet: "Sketch Fillet: click a corner where two lines meet (radius in the panel on the right)."
        case .trim: "Trim: click the piece of a curve to remove (up to the curves crossing it)."
        }
    }
}

/// Sketch-mode state kept by the app model.
struct SketchUIState {
    var tool: SketchTool?
    var pending: [Point2] = []
    var filletRadius = 2.0
    /// Snap targets: sketch point positions (u, v) by id, refreshed after each command.
    var points: [(id: String, u: Double, v: Double)] = []
    var plane: SketchPlane?
    var status: String = ""
}

extension AppModel {
    func newSketch(on plane: StandardPlane) async {
        operation = nil
        if await run("sketch.create", ["plane": .string(plane.rawValue)]) != nil {
            setOrientation(plane == .front ? .front : plane == .top ? .top : .right)
            chooseTool(.line)
        }
    }

    func editSketch(_ id: String) async {
        operation = nil
        if await run("sketch.edit", ["sketch": .string(id)]) != nil { normalToSketch() }
    }

    func exitSketch() async {
        sketchState.tool = nil
        sketchState.pending = []
        await run("sketch.exit")
    }

    func chooseTool(_ tool: SketchTool?) {
        sketchState.tool = tool
        sketchState.pending = []
    }

    func refreshSketchState() async {
        guard let doc = await engine.activeDocument, let id = doc.activeSketch, let sk = doc.sketches[id] else {
            activeSketch = nil
            sketchState.plane = nil
            sketchState.points = []
            sketchState.status = ""
            sketchState.tool = nil
            return
        }
        activeSketch = id
        sketchState.plane = sk.plane
        sketchState.points = sk.orderedEntities.filter { $0.kind == .point }.map { e in
            let (u, v) = sk.point(e.id)
            return (e.id, u, v)
        }
        let r = sk.report
        sketchState.status = "\(sk.name): \(r?.status.rawValue.replacingOccurrences(of: "_", with: " ") ?? "") · \(r?.dof ?? 0) DOF"
    }

    /// Snap to an existing sketch point within `tolerance` (sketch units), so inference makes
    /// the new geometry coincident with it.
    func snap(_ p: Point2, tolerance: Double) -> Point2 {
        var best: (Point2, Double)?
        for q in sketchState.points {
            let d = hypot(q.u - p.u, q.v - p.v)
            if d <= tolerance && (best == nil || d < best!.1) { best = (Point2(q.u, q.v), d) }
        }
        return best?.0 ?? p
    }

    /// A click on the sketch plane with a tool active. `curve` is the sketch curve under the
    /// cursor, if any (used by trim).
    func sketchClick(_ raw: Point2, tolerance: Double, curve: String?) async {
        guard let tool = sketchState.tool else { return }
        let p = snap(raw, tolerance: tolerance)
        func pt(_ q: Point2) -> JSONValue { [.number(q.u), .number(q.v)] }
        switch tool {
        case .point:
            await run("sketch.add_point", ["at": pt(p)])
        case .line:
            if let start = sketchState.pending.last {
                guard start != p else { return }
                await run("sketch.add_line", ["start": pt(start), "end": pt(p)])
            }
            sketchState.pending = [p]
        case .rectangle:
            if let a = sketchState.pending.first {
                sketchState.pending = []
                await run("sketch.add_rectangle", ["points": [pt(a), pt(p)]])
            } else {
                sketchState.pending = [p]
            }
        case .circle:
            if let c = sketchState.pending.first {
                sketchState.pending = []
                let r = hypot(p.u - c.u, p.v - c.v)
                if r > 0 { await run("sketch.add_circle", ["center": pt(c), "radius": .number(r)]) }
            } else {
                sketchState.pending = [p]
            }
        case .arc:
            sketchState.pending.append(p)
            if sketchState.pending.count == 3 {
                let (s, e, through) = (sketchState.pending[0], sketchState.pending[1], sketchState.pending[2])
                sketchState.pending = []
                await run("sketch.add_arc", ["mode": "three_point", "start": pt(s), "end": pt(e), "through": pt(through)])
            }
        case .fillet:
            if let corner = sketchState.points.first(where: { $0.u == p.u && $0.v == p.v }) {
                await run("sketch.fillet", ["corner": .string(corner.id), "radius": .number(sketchState.filletRadius)])
            } else {
                lastError = ForgeError(.invalidParams, "click exactly on a corner point to fillet it")
            }
        case .trim:
            guard let curve, let local = curve.split(separator: "/").last else {
                lastError = ForgeError(.invalidParams, "click on the curve piece to remove")
                return
            }
            await run("sketch.trim", ["entity": .string(String(local)), "at": pt(raw)])
        }
        await refreshSketchState()
    }

    func cancelSketchOperation() {
        if sketchState.pending.isEmpty { sketchState.tool = nil }
        sketchState.pending = []
    }

    /// Smart dimension from the current selection (SPEC 7.1): one line → length, one circle →
    /// diameter, one arc → radius, two lines → angle, otherwise distance.
    func smartDimension(value: String) async {
        guard let id = activeSketch, let doc = await engine.activeDocument, let sk = doc.sketches[id] else { return }
        let local = selection.compactMap { ref -> String? in
            ref.hasPrefix(id + "/") ? String(ref.dropFirst(id.count + 1)) : nil
        }
        guard !local.isEmpty else {
            lastError = ForgeError(.invalidParams, "select the sketch curves to dimension first (click them with no tool active; ⇧-click adds)")
            return
        }
        let kinds = local.compactMap { sk.entities[$0]?.kind }
        let type: String
        switch kinds {
        case [.line]: type = "distance"
        case [.circle]: type = "diameter"
        case [.arc]: type = "radius"
        case [.line, .line]: type = "angle"
        default: type = "distance"
        }
        var params: JSONValue = ["type": .string(type), "entities": .array(local.map { .string($0) })]
        if !value.trimmingCharacters(in: .whitespaces).isEmpty, case .object(var o) = params {
            o["value"] = Double(value).map { .number($0) } ?? .string(value)
            params = .object(o)
        }
        await run("sketch.add_dimension", params)
        await refreshSketchState()
    }
}

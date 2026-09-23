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
        case .line: "Line: click or drag to draw; lines chain on. Click the first point to close, double-click or Esc to stop."
        case .rectangle: "Rectangle: click (or drag between) two opposite corners."
        case .circle: "Circle: click the centre, then a point on the circle (or drag)."
        case .arc: "3 Point Arc: click the start, the end, then a point the arc passes through."
        case .point: "Point: click to place a point."
        case .fillet: "Sketch Fillet: click a corner where two lines meet (radius in the panel on the right)."
        case .trim: "Trim: click the piece of a curve to remove (up to the curves crossing it)."
        }
    }
}

/// What the cursor snapped to while sketching.
enum SnapKind: Equatable {
    case none, point, horizontal, vertical
}

/// Rubber-band preview of the geometry the next click would create, in sketch coordinates.
struct SketchPreview {
    var polylines: [[Point2]] = []
    var marker: Point2?
    var snap: SnapKind = .none
}

/// Sketch-mode state kept by the app model.
struct SketchUIState {
    var tool: SketchTool?
    var pending: [Point2] = []
    /// First point of the current line chain: clicking it again closes the chain.
    var chainStart: Point2?
    var preview: SketchPreview?
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
        sketchState.chainStart = nil
        clearPreview()
    }

    func clearPreview() {
        sketchState.preview = nil
        hoverLabel = nil
        overlayVersion += 1
    }

    /// Snap to an existing point, else (drawing a line) to exact horizontal/vertical within 3°
    /// of the start — which relation inference then turns into a horizontal/vertical relation.
    func snapped(_ raw: Point2, tolerance: Double) -> (Point2, SnapKind) {
        var best: (Point2, Double)?
        for q in sketchState.points {
            let d = hypot(q.u - raw.u, q.v - raw.v)
            if d <= tolerance && (best == nil || d < best!.1) { best = (Point2(q.u, q.v), d) }
        }
        if let b = best { return (b.0, .point) }
        if sketchState.tool == .line, let s = sketchState.pending.last {
            let dx = raw.u - s.u, dy = raw.v - s.v
            let t = tan(3 * Double.pi / 180)
            if abs(dy) <= abs(dx) * t { return (Point2(raw.u, s.v), .horizontal) }
            if abs(dx) <= abs(dy) * t { return (Point2(s.u, raw.v), .vertical) }
        }
        return (raw, .none)
    }

    /// Cursor moved over the sketch plane (nil: left the viewport). Updates the preview and
    /// the label shown next to the cursor.
    func sketchHover(_ raw: Point2?, tolerance: Double, viewPoint: CGPoint) {
        guard let tool = sketchState.tool, let raw else {
            if sketchState.preview != nil { clearPreview() }
            return
        }
        let (p, kind) = snapped(raw, tolerance: tolerance)
        var pv = SketchPreview(marker: kind == .point ? p : nil, snap: kind)
        var label: String?
        let pending = sketchState.pending
        func fmt(_ x: Double) -> String { String(format: "%.2f", x) }
        switch tool {
        case .line:
            if let a = pending.last {
                pv.polylines = [[a, p]]
                let len = hypot(p.u - a.u, p.v - a.v)
                var ang = atan2(p.v - a.v, p.u - a.u) * 180 / .pi
                if ang < 0 { ang += 360 }
                label = "L \(fmt(len))  ∠ \(String(format: "%.1f", ang))°" + (kind == .horizontal ? "  H" : kind == .vertical ? "  V" : "")
            }
        case .rectangle:
            if let a = pending.first {
                pv.polylines = [[a, Point2(p.u, a.v), p, Point2(a.u, p.v), a]]
                label = "\(fmt(abs(p.u - a.u))) × \(fmt(abs(p.v - a.v)))"
            }
        case .circle:
            if let c = pending.first {
                let r = hypot(p.u - c.u, p.v - c.v)
                pv.polylines = [(0...72).map { i in
                    let t = 2 * Double.pi * Double(i) / 72
                    return Point2(c.u + r * cos(t), c.v + r * sin(t))
                }]
                label = "R \(fmt(r))"
            }
        case .arc:
            if pending.count == 1 {
                pv.polylines = [[pending[0], p]]
            } else if pending.count == 2 {
                pv.polylines = [Self.arcThrough(pending[0], p, pending[1])]
                if let cc = try? Sketch.circumcircle(pending[0].tuple, p.tuple, pending[1].tuple) { label = "R \(fmt(cc.radius))" }
            }
        case .point, .fillet, .trim:
            break
        }
        if pv.polylines.isEmpty && label == nil { label = "\(fmt(p.u)), \(fmt(p.v))" }
        sketchState.preview = pv
        hoverLabel = label
        hoverViewPoint = viewPoint
        overlayVersion += 1
    }

    /// Polyline of the arc from a to b passing through m (a straight segment if collinear).
    static func arcThrough(_ a: Point2, _ m: Point2, _ b: Point2) -> [Point2] {
        guard let cc = try? Sketch.circumcircle(a.tuple, m.tuple, b.tuple) else { return [a, b] }
        let (c, r) = (cc.center, cc.radius)
        func ang(_ p: Point2) -> Double { atan2(p.v - c.1, p.u - c.0) }
        let a0 = ang(a)
        func ccw(_ t: Double) -> Double { var x = t - a0; while x < 0 { x += 2 * .pi }; while x >= 2 * .pi { x -= 2 * .pi }; return x }
        var sweep = ccw(ang(b))
        if ccw(ang(m)) > sweep { sweep -= 2 * .pi }  // the arc through m runs clockwise
        return (0...48).map { i in
            let t = a0 + sweep * Double(i) / 48
            return Point2(c.0 + r * cos(t), c.1 + r * sin(t))
        }
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

    /// A click on the sketch plane with a tool active. `curve` is the sketch curve under the
    /// cursor, if any (used by trim).
    func sketchClick(_ raw: Point2, tolerance: Double, curve: String?, clickCount: Int = 1) async {
        guard let tool = sketchState.tool else { return }
        if clickCount >= 2 && tool == .line {
            // Double-click ends the chain (the first click already placed the point).
            sketchState.pending = []
            sketchState.chainStart = nil
            clearPreview()
            return
        }
        let p = snapped(raw, tolerance: tolerance).0
        func pt(_ q: Point2) -> JSONValue { [.number(q.u), .number(q.v)] }
        switch tool {
        case .point:
            await run("sketch.add_point", ["at": pt(p)])
        case .line:
            if let start = sketchState.pending.last {
                guard start != p else { return }
                await run("sketch.add_line", ["start": pt(start), "end": pt(p)])
                if let first = sketchState.chainStart, first == p {
                    // Back at the chain's first point: the profile is closed, start afresh.
                    sketchState.pending = []
                    sketchState.chainStart = nil
                    clearPreview()
                    await refreshSketchState()
                    return
                }
            } else {
                sketchState.chainStart = p
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
        sketchState.chainStart = nil
        clearPreview()
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

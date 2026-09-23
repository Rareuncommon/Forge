// Sketch editing. Every action is a command on the bus; the UI only turns clicks into sketch
// coordinates (and, for trim/extend, the curve under the cursor) and chooses the command.

import ForgeCommands
import ForgeCore
import ForgeRender
import ForgeSketch
import SwiftUI

enum SketchTool: String, CaseIterable, Identifiable {
    case line, centerline, rectangle, circle, arc, slot, polygon, spline, ellipse, point
    case fillet, chamfer, trim, extend
    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: "Line"
        case .centerline: "Centerline"
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .arc: "3-Point Arc"
        case .slot: "Slot"
        case .polygon: "Polygon"
        case .spline: "Spline"
        case .ellipse: "Ellipse"
        case .point: "Point"
        case .fillet: "Fillet"
        case .chamfer: "Chamfer"
        case .trim: "Trim\nEntities"
        case .extend: "Extend"
        }
    }

    var icon: ForgeIcon {
        switch self {
        case .line: .line
        case .centerline: .centerline
        case .rectangle: .rectangle
        case .circle: .circle
        case .arc: .arc
        case .slot: .slot
        case .polygon: .polygon
        case .spline: .spline
        case .ellipse: .ellipse
        case .point: .point
        case .fillet: .sketchFillet
        case .chamfer: .sketchChamfer
        case .trim: .trim
        case .extend: .extend
        }
    }

    var hint: String {
        switch self {
        case .line: "Line: click or drag; lines chain on. Click the first point to close, double-click or Esc to stop."
        case .centerline: "Centerline: construction line for mirrors and symmetry. Click two points."
        case .rectangle: "Rectangle: click (or drag between) two opposite corners."
        case .circle: "Circle: click the centre, then a point on the circle."
        case .arc: "3-Point Arc: click the start, the end, then a point the arc passes through."
        case .slot: "Slot: click the two centres, then the width."
        case .polygon: "Polygon: click the centre, then a vertex. Sides are set in the PropertyManager."
        case .spline: "Spline: click the points it passes through; double-click to finish."
        case .ellipse: "Ellipse: click the centre, the end of the major axis, then a point for the minor axis."
        case .point: "Point: click to place a point."
        case .fillet: "Sketch Fillet: click a corner where two lines meet (radius in the PropertyManager)."
        case .chamfer: "Sketch Chamfer: click a corner where two lines meet (distance in the PropertyManager)."
        case .trim: "Trim: click the piece of a curve to remove (up to the curves crossing it)."
        case .extend: "Extend: click a curve near the end to extend it to the next curve."
        }
    }

    /// Tools that chain clicks into one entity and use the rubber-band preview.
    var draws: Bool { ![.fillet, .chamfer, .trim, .extend, .point].contains(self) }
}

/// What the cursor snapped to while sketching.
enum SnapKind: Equatable {
    case none, point, horizontal, vertical

    var tag: String? {
        switch self {
        case .none: nil
        case .point: "⊙"
        case .horizontal: "H"
        case .vertical: "V"
        }
    }
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
    var chamferDistance = 2.0
    var polygonSides = 6
    var rectangleFromCenter = false
    /// Snap targets: sketch point positions (u, v) by id, refreshed after each command.
    var points: [(id: String, u: Double, v: Double)] = []
    var plane: SketchPlane?
    /// The sketch being edited (a value copy, refreshed after each command).
    var sketch: Sketch?
}

/// A dimension or relation glyph shown in the viewport for the sketch being edited.
struct SketchAnnotation: Identifiable, Equatable {
    enum Kind { case dimension, relation }
    var id: String
    var kind: Kind
    var text: String
    var anchor: Vec3
    /// Glyphs sharing an anchor are laid side by side.
    var slot: Int
    var driven: Bool
    var problem: Bool
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
        if operation?.isSketchOperation == true { operation = nil }
        await run("sketch.exit")
    }

    func chooseTool(_ tool: SketchTool?) {
        sketchState.tool = tool
        sketchState.pending = []
        sketchState.chainStart = nil
        if tool != nil, operation?.isSketchOperation == true { operation = nil }
        clearPreview()
    }

    func clearPreview() {
        sketchState.preview = nil
        hoverLines = []
        overlayVersion += 1
    }

    /// Local ids of the selected entities of the sketch being edited.
    var sketchSelection: [String] {
        guard let id = activeSketch else { return [] }
        return selection.compactMap { $0.hasPrefix(id + "/") ? String($0.dropFirst(id.count + 1)) : nil }
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
        if sketchState.tool == .line || sketchState.tool == .centerline, let s = sketchState.pending.last {
            let dx = raw.u - s.u, dy = raw.v - s.v
            let t = tan(3 * Double.pi / 180)
            if abs(dy) <= abs(dx) * t { return (Point2(raw.u, s.v), .horizontal) }
            if abs(dx) <= abs(dy) * t { return (Point2(s.u, raw.v), .vertical) }
        }
        return (raw, .none)
    }

    /// Cursor moved over the sketch plane (nil: left the viewport). Updates the preview and
    /// the tooltip shown next to the cursor.
    func sketchHover(_ raw: Point2?, tolerance: Double, viewPoint: CGPoint) {
        guard let tool = sketchState.tool, let raw else {
            cursorSketchPoint = nil
            if sketchState.preview != nil { clearPreview() }
            return
        }
        let (p, kind) = snapped(raw, tolerance: tolerance)
        cursorSketchPoint = p
        var pv = SketchPreview(marker: kind == .point ? p : nil, snap: kind)
        var lines: [String] = []
        let pending = sketchState.pending
        func fmt(_ x: Double) -> String { String(format: "%.2f", x) }
        func angle(_ a: Point2, _ b: Point2) -> Double {
            var ang = atan2(b.v - a.v, b.u - a.u) * 180 / .pi
            if ang < 0 { ang += 360 }
            return ang
        }
        switch tool {
        case .line, .centerline:
            if let a = pending.last {
                pv.polylines = [[a, p]]
                lines = ["L  \(fmt(hypot(p.u - a.u, p.v - a.v)))", "∠  \(String(format: "%.1f", angle(a, p)))°"]
            }
        case .rectangle:
            if let a = pending.first {
                let (c0, c1) = sketchState.rectangleFromCenter ? (Point2(2 * a.u - p.u, 2 * a.v - p.v), p) : (a, p)
                pv.polylines = [[c0, Point2(c1.u, c0.v), c1, Point2(c0.u, c1.v), c0]]
                lines = ["W  \(fmt(abs(c1.u - c0.u)))", "H  \(fmt(abs(c1.v - c0.v)))"]
            }
        case .circle:
            if let c = pending.first {
                let r = hypot(p.u - c.u, p.v - c.v)
                pv.polylines = [Self.ellipsePolyline(c, r, r, 0)]
                lines = ["R  \(fmt(r))"]
            }
        case .arc:
            if pending.count == 1 {
                pv.polylines = [[pending[0], p]]
            } else if pending.count == 2 {
                pv.polylines = [Self.arcThrough(pending[0], p, pending[1])]
                if let cc = try? Sketch.circumcircle(pending[0].tuple, p.tuple, pending[1].tuple) { lines = ["R  \(fmt(cc.radius))"] }
            }
        case .slot:
            if pending.count == 1 {
                pv.polylines = [[pending[0], p]]
                lines = ["L  \(fmt(hypot(p.u - pending[0].u, p.v - pending[0].v)))"]
            } else if pending.count == 2 {
                let w = 2 * Self.distanceToLine(p, pending[0], pending[1])
                pv.polylines = [Self.slotOutline(pending[0], pending[1], w / 2)]
                lines = ["W  \(fmt(w))"]
            }
        case .polygon:
            if let c = pending.first {
                let r = hypot(p.u - c.u, p.v - c.v)
                let n = max(3, sketchState.polygonSides)
                let a0 = atan2(p.v - c.v, p.u - c.u)
                pv.polylines = [(0...n).map { i in
                    let t = a0 + 2 * Double.pi * Double(i) / Double(n)
                    return Point2(c.u + r * cos(t), c.v + r * sin(t))
                }]
                lines = ["R  \(fmt(r))", "\(n) sides"]
            }
        case .spline:
            if !pending.isEmpty {
                pv.polylines = [pending + [p]]
                lines = ["\(pending.count + 1) points"]
            }
        case .ellipse:
            if pending.count == 1 {
                let r = hypot(p.u - pending[0].u, p.v - pending[0].v)
                pv.polylines = [[pending[0], p], Self.ellipsePolyline(pending[0], r, r * 0.5, atan2(p.v - pending[0].v, p.u - pending[0].u))]
                lines = ["a  \(fmt(r))"]
            } else if pending.count == 2 {
                let c = pending[0], m = pending[1]
                let a = hypot(m.u - c.u, m.v - c.v), rot = atan2(m.v - c.v, m.u - c.u)
                let b = Self.distanceToLine(p, c, m)
                pv.polylines = [Self.ellipsePolyline(c, a, b, rot)]
                lines = ["a  \(fmt(a))", "b  \(fmt(b))"]
            }
        case .point, .fillet, .chamfer, .trim, .extend:
            break
        }
        sketchState.preview = pv
        hoverLines = lines
        hoverViewPoint = viewPoint
        overlayVersion += 1
    }

    static func ellipsePolyline(_ c: Point2, _ a: Double, _ b: Double, _ rot: Double) -> [Point2] {
        (0...72).map { i in
            let t = 2 * Double.pi * Double(i) / 72
            let x = a * cos(t), y = b * sin(t)
            return Point2(c.u + x * cos(rot) - y * sin(rot), c.v + x * sin(rot) + y * cos(rot))
        }
    }

    static func distanceToLine(_ p: Point2, _ a: Point2, _ b: Point2) -> Double {
        let dx = b.u - a.u, dy = b.v - a.v
        let len = hypot(dx, dy)
        guard len > 0 else { return hypot(p.u - a.u, p.v - a.v) }
        return abs((p.u - a.u) * dy - (p.v - a.v) * dx) / len
    }

    static func slotOutline(_ a: Point2, _ b: Point2, _ r: Double) -> [Point2] {
        let ang = atan2(b.v - a.v, b.u - a.u)
        var out: [Point2] = []
        for i in 0...24 {
            let t = ang - .pi / 2 + .pi * Double(i) / 24
            out.append(Point2(b.u + r * cos(t), b.v + r * sin(t)))
        }
        for i in 0...24 {
            let t = ang + .pi / 2 + .pi * Double(i) / 24
            out.append(Point2(a.u + r * cos(t), a.v + r * sin(t)))
        }
        return out + [out[0]]
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
            sketchState.sketch = nil
            sketchState.tool = nil
            annotations = []
            return
        }
        activeSketch = id
        sketchState.plane = sk.plane
        sketchState.sketch = sk
        sketchState.points = sk.orderedEntities.filter { $0.kind == .point }.map { e in
            let (u, v) = sk.point(e.id)
            return (e.id, u, v)
        }
        annotations = Self.annotations(sk)
    }

    /// Dimension labels and relation glyphs for a sketch.
    static func annotations(_ sk: Sketch) -> [SketchAnnotation] {
        let problems = Set((sk.report?.conflicting ?? []) + (sk.report?.redundant ?? []))
        var out: [SketchAnnotation] = []
        var used: [String: Int] = [:]
        for c in sk.userConstraints {
            let anchors = c.entities.compactMap { anchor(sk, $0) }
            guard !anchors.isEmpty else { continue }
            if c.kind.isDimension, let value = c.value {
                let u = anchors.map(\.u).reduce(0, +) / Double(anchors.count)
                let v = anchors.map(\.v).reduce(0, +) / Double(anchors.count)
                var text: String
                switch c.kind {
                case .angle: text = String(format: "%.1f°", value * 180 / .pi)
                case .radius: text = String(format: "R%.2f", value)
                case .diameter: text = String(format: "⌀%.2f", value)
                default: text = String(format: "%.2f", value)
                }
                if c.driven { text = "(\(text))" }
                out.append(SketchAnnotation(
                    id: c.id, kind: .dimension, text: text, anchor: sk.plane.point(u, v), slot: 0, driven: c.driven, problem: problems.contains(c.id)))
            } else if let glyph = glyph(c.kind), let first = c.entities.first, let a = anchor(sk, first) {
                let slot = used[first, default: 0]
                used[first] = slot + 1
                out.append(SketchAnnotation(
                    id: c.id, kind: .relation, text: glyph, anchor: sk.plane.point(a.u, a.v), slot: slot, driven: false, problem: problems.contains(c.id)))
            }
        }
        return out
    }

    static func glyph(_ k: ConstraintKind) -> String? {
        switch k {
        case .horizontal: "H"
        case .vertical: "V"
        case .parallel: "∥"
        case .perpendicular: "⊥"
        case .tangent: "T"
        case .equal: "="
        case .concentric: "◎"
        case .midpoint: "M"
        case .fix: "F"
        case .collinear: "C"
        case .symmetric: "S"
        case .coradial: "R"
        default: nil
        }
    }

    /// Where an entity's annotations sit, in sketch coordinates.
    static func anchor(_ sk: Sketch, _ id: String) -> Point2? {
        guard let e = sk.entities[id] else { return nil }
        func p(_ pid: String) -> Point2 { let (u, v) = sk.point(pid); return Point2(u, v) }
        switch e.kind {
        case .point:
            return p(e.id)
        case .line:
            let a = p(e.points[0]), b = p(e.points[1])
            return Point2((a.u + b.u) / 2, (a.v + b.v) / 2)
        case .circle:
            let c = p(e.points[0]), r = sk.params[e.params[0]]
            return Point2(c.u + r * 0.7071, c.v + r * 0.7071)
        case .arc:
            let c = p(e.points[0]), s = p(e.points[1]), en = p(e.points[2])
            let r = hypot(s.u - c.u, s.v - c.v)
            let a0 = atan2(s.v - c.v, s.u - c.u)
            var a1 = atan2(en.v - c.v, en.u - c.u)
            if a1 <= a0 { a1 += 2 * .pi }
            let m = (a0 + a1) / 2
            return Point2(c.u + r * cos(m), c.v + r * sin(m))
        case .ellipse, .ellipseArc:
            let c = p(e.points[0]), a = sk.params[e.params[0]], rot = sk.params[e.params[2]]
            return Point2(c.u + a * cos(rot), c.v + a * sin(rot))
        case .spline:
            return e.points.first.map(p)
        }
    }

    /// A click on the sketch plane with a tool active. `curve` is the sketch curve under the
    /// cursor, if any (used by trim and extend).
    func sketchClick(_ raw: Point2, tolerance: Double, curve: String?, clickCount: Int = 1) async {
        guard let tool = sketchState.tool else { return }
        if clickCount >= 2 {
            switch tool {
            case .line, .centerline:
                // Double-click ends the chain (the first click already placed the point).
                sketchState.pending = []
                sketchState.chainStart = nil
                clearPreview()
                return
            case .spline:
                let through = sketchState.pending
                sketchState.pending = []
                clearPreview()
                if through.count >= 2 { await run("sketch.add_spline", ["through": .array(through.map(pt))]) }
                await refreshSketchState()
                return
            default:
                break
            }
        }
        let p = snapped(raw, tolerance: tolerance).0
        switch tool {
        case .point:
            await run("sketch.add_point", ["at": pt(p)])
        case .line, .centerline:
            if let start = sketchState.pending.last {
                guard start != p else { return }
                await run("sketch.add_line", ["start": pt(start), "end": pt(p), "construction": .bool(tool == .centerline)])
                if tool == .centerline || sketchState.chainStart == p {
                    // A centerline is one segment; back at a chain's first point the profile is closed.
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
                if sketchState.rectangleFromCenter {
                    await run("sketch.add_rectangle", ["mode": "center", "points": [pt(a), pt(p)]])
                } else {
                    await run("sketch.add_rectangle", ["points": [pt(a), pt(p)]])
                }
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
        case .slot:
            sketchState.pending.append(p)
            if sketchState.pending.count == 3 {
                let (a, b) = (sketchState.pending[0], sketchState.pending[1])
                sketchState.pending = []
                let w = 2 * Self.distanceToLine(p, a, b)
                if w > 0 { await run("sketch.add_slot", ["start": pt(a), "end": pt(b), "width": .number(w)]) }
            }
        case .polygon:
            if let c = sketchState.pending.first {
                sketchState.pending = []
                let r = hypot(p.u - c.u, p.v - c.v)
                let rot = atan2(p.v - c.v, p.u - c.u) * 180 / .pi
                if r > 0 {
                    await run("sketch.add_polygon", [
                        "center": pt(c), "sides": .number(Double(max(3, sketchState.polygonSides))), "radius": .number(r),
                        "inscribed": true, "rotation": .string(String(format: "%.6f deg", rot)),
                    ])
                }
            } else {
                sketchState.pending = [p]
            }
        case .spline:
            if sketchState.pending.last != p { sketchState.pending.append(p) }
        case .ellipse:
            sketchState.pending.append(p)
            if sketchState.pending.count == 3 {
                let c = sketchState.pending[0], m = sketchState.pending[1]
                sketchState.pending = []
                var a = hypot(m.u - c.u, m.v - c.v), b = Self.distanceToLine(p, c, m)
                var rot = atan2(m.v - c.v, m.u - c.u)
                if b > a { swap(&a, &b); rot += .pi / 2 }
                if b > 0 {
                    await run("sketch.add_ellipse", [
                        "center": pt(c), "major_radius": .number(a), "minor_radius": .number(b),
                        "rotation": .string(String(format: "%.6f deg", rot * 180 / .pi)),
                    ])
                }
            }
        case .fillet, .chamfer:
            guard let corner = sketchState.points.first(where: { $0.u == p.u && $0.v == p.v }) else {
                lastError = ForgeError(.invalidParams, "click exactly on a corner point (it snaps when close)")
                return
            }
            if tool == .fillet {
                await run("sketch.fillet", ["corner": .string(corner.id), "radius": .number(sketchState.filletRadius)])
            } else {
                let lines = linesMeeting(at: corner.id)
                guard lines.count == 2 else {
                    lastError = ForgeError(.invalidParams, "a chamfer needs exactly two lines meeting at the corner")
                    return
                }
                await run("sketch.chamfer", ["lines": .array(lines.map { .string($0) }), "distance": .number(sketchState.chamferDistance)])
            }
        case .trim, .extend:
            guard let curve, let local = curve.split(separator: "/").last else {
                lastError = ForgeError(.invalidParams, tool == .trim ? "click on the curve piece to remove" : "click on the curve near the end to extend")
                return
            }
            if tool == .trim {
                await run("sketch.trim", ["entity": .string(String(local)), "at": pt(raw)])
            } else {
                await run("sketch.extend", ["entity": .string(String(local)), "near": pt(raw)])
            }
        }
        await refreshSketchState()
    }

    private func pt(_ q: Point2) -> JSONValue { [.number(q.u), .number(q.v)] }

    /// Lines with an endpoint coincident with a point (sharing it, or at the same place).
    func linesMeeting(at pointID: String) -> [String] {
        guard let sk = sketchState.sketch else { return [] }
        let (u, v) = sk.point(pointID)
        return sk.orderedEntities.filter { e in
            e.kind == .line && !e.construction && e.points.contains { q in
                q == pointID || { let (a, b) = sk.point(q); return abs(a - u) < 1e-9 && abs(b - v) < 1e-9 }()
            }
        }.map(\.id)
    }

    func cancelSketchOperation() {
        if operation != nil && sketchState.pending.isEmpty {
            cancelOperation()
            return
        }
        if sketchState.pending.isEmpty { sketchState.tool = nil }
        sketchState.pending = []
        sketchState.chainStart = nil
        clearPreview()
    }

    /// Kinds of the selected sketch entities, in selection order.
    var sketchSelectionKinds: [SketchEntityKind] {
        guard let sk = sketchState.sketch else { return [] }
        return sketchSelection.compactMap { sk.entities[$0]?.kind }
    }

    /// Smart dimension from the current selection (SPEC 7.1): one line → length, one circle →
    /// diameter, one arc → radius, two lines → angle, otherwise distance.
    func smartDimension(value: String) async {
        let local = sketchSelection
        guard !local.isEmpty else {
            lastError = ForgeError(.invalidParams, "select the sketch curves to dimension first (click them with no tool active; ⇧-click adds)")
            return
        }
        let type: String
        switch sketchSelectionKinds {
        case [.line]: type = "distance"
        case [.circle]: type = "diameter"
        case [.arc]: type = "radius"
        case [.line, .line]: type = "angle"
        default: type = "distance"
        }
        var params: [String: JSONValue] = ["type": .string(type), "entities": .array(local.map { .string($0) })]
        let v = value.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { params["value"] = Double(v).map { .number($0) } ?? .string(v) }
        await run("sketch.add_dimension", .object(params))
    }

    /// Change a dimension's value (double-click on its label).
    func setDimension(_ constraint: String, to value: String) async {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        await run("sketch.set_dimension", ["constraint": .string(constraint), "value": Double(v).map { .number($0) } ?? .string(v)])
    }

    /// Relations that make sense for the current selection (the command still validates).
    var applicableRelations: [RelationType] {
        let kinds = sketchSelectionKinds
        let curves: Set<SketchEntityKind> = [.circle, .arc]
        let lines = kinds.filter { $0 == .line }.count, points = kinds.filter { $0 == .point }.count
        let round = kinds.filter { curves.contains($0) }.count
        switch kinds.count {
        case 1:
            return kinds[0] == .line ? [.horizontal, .vertical, .fix] : [.fix]
        case 2:
            if lines == 2 { return [.parallel, .perpendicular, .equal, .collinear] }
            if round == 2 { return [.equal, .concentric, .tangent, .coradial] }
            if lines == 1 && round == 1 { return [.tangent] }
            if points == 2 { return [.coincident, .horizontal, .vertical] }
            if points == 1 && lines == 1 { return [.onEntity, .midpoint] }
            if points == 1 { return [.onEntity] }
            return []
        case 3:
            return lines >= 1 ? [.symmetric] : []
        default:
            return lines == kinds.count ? [.parallel, .equal] : []
        }
    }

    func addRelation(_ type: RelationType) async {
        var ids = sketchSelection
        // Points first: "point on line", "midpoint of line"; the axis last for symmetry.
        if let sk = sketchState.sketch {
            ids.sort { (sk.entities[$0]?.kind == .point ? 0 : 1) < (sk.entities[$1]?.kind == .point ? 0 : 1) }
            if type == .symmetric, let axis = ids.last(where: { sk.entities[$0]?.kind == .line }) {
                ids.removeAll { $0 == axis }
                ids.append(axis)
            }
        }
        await run("sketch.add_relation", ["type": .string(type.rawValue), "entities": .array(ids.map { .string($0) })])
    }

    func toggleConstruction() async {
        let ids = sketchSelection
        guard let sk = sketchState.sketch, let first = ids.first, let e = sk.entities[first] else { return }
        await run("sketch.set_construction", ["entities": .array(ids.map { .string($0) }), "construction": .bool(!e.construction)])
    }

    func deleteSketchSelection() async {
        let ids = sketchSelection
        guard !ids.isEmpty else { return }
        await run("sketch.delete", ["items": .array(ids.map { .string($0) })])
    }
}

extension Operation {
    var isSketchOperation: Bool {
        switch self {
        case .dimension, .addRelation, .sketchOffset, .sketchMirror, .sketchLinearPattern, .sketchCircularPattern: true
        default: false
        }
    }
}

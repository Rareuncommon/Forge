// Sketch editing, modelled on SolidWorks (docs/research/solidworks.md §1.12, §2.1). Every
// action is a command on the bus; the UI turns clicks into sketch coordinates (with
// SolidWorks-style inference: endpoints, midpoints, curves, horizontal/vertical, dotted
// alignment guides) and picks the command.

import AppKit
import ForgeCommands
import ForgeCore
import ForgeRender
import ForgeSketch
import SwiftUI

/// A sketch tool. Tools with variants (rectangle types, arc types…) keep the variant in
/// SketchUIState and show it in their PropertyManager page, as SolidWorks does.
enum SketchTool: String, CaseIterable, Identifiable {
    case line, rectangle, circle, arc, slot, polygon, spline, ellipse, point
    case fillet, chamfer, trim, extend, dimension
    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .arc: "Arc"
        case .slot: "Slot"
        case .polygon: "Polygon"
        case .spline: "Spline"
        case .ellipse: "Ellipse"
        case .point: "Point"
        case .fillet: "Sketch Fillet"
        case .chamfer: "Sketch Chamfer"
        case .trim: "Trim Entities"
        case .extend: "Extend Entities"
        case .dimension: "Smart Dimension"
        }
    }

    var icon: ForgeIcon {
        switch self {
        case .line: .line
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
        case .dimension: .smartDimension
        }
    }
}

enum LineKind: String, CaseIterable { case line = "Line", centerline = "Centerline", midpoint = "Midpoint Line" }
enum LineOrientation: String, CaseIterable { case asSketched = "As sketched", horizontal = "Horizontal", vertical = "Vertical" }
enum RectangleType: String, CaseIterable {
    case corner = "Corner Rectangle", center = "Center Rectangle", threePoint = "3 Point Corner Rectangle", parallelogram = "Parallelogram"
}
enum CircleType: String, CaseIterable { case center = "Circle", perimeter = "Perimeter Circle" }
enum ArcType: String, CaseIterable { case center = "Centerpoint Arc", tangent = "Tangent Arc", threePoint = "3 Point Arc" }
enum SlotType: String, CaseIterable { case straight = "Straight Slot", center = "Centerpoint Straight Slot" }
enum EllipseType: String, CaseIterable { case full = "Ellipse", partial = "Partial Ellipse" }
enum ChamferType: String, CaseIterable { case angleDistance = "Angle-distance", distanceDistance = "Distance-distance" }
enum TrimMode: String, CaseIterable { case power = "Power trim", closest = "Trim to closest" }

/// Rubber-band preview of the geometry the next click would create, in sketch coordinates,
/// with the inference the cursor found.
struct SketchPreview {
    var polylines: [[Point2]] = []
    var marker: Point2?
    var snap: SketchSnap.Kind = .none
    /// Dotted alignment guides (visual only, like SolidWorks' blue inference lines).
    var guides: [SketchSnap.Guide] = []
    /// A dotted relation line from the start point (horizontal/vertical: becomes a relation).
    var relationGuide: SketchSnap.Guide?
}

extension SketchSnap.Kind {
    /// Pointer glyph shown next to the cursor.
    var tag: String? {
        switch self {
        case .none, .aligned: nil
        case .point: "⊙"
        case .midpoint: "M"
        case .onCurve: "◡"
        case .horizontal: "H"
        case .vertical: "V"
        }
    }
}

/// Sketch-mode state kept by the app model.
struct SketchUIState {
    var tool: SketchTool?
    var pending: [Point2] = []
    /// Ids of existing points the pending clicks landed on (for relations such as midpoint).
    var pendingTargets: [String?] = []
    /// First point of the current line chain: clicking it again closes the chain.
    var chainStart: Point2?
    var preview: SketchPreview?
    // Tool options (the PropertyManager page of each tool).
    var lineKind = LineKind.line
    var lineOrientation = LineOrientation.asSketched
    var rectangleType = RectangleType.corner
    var circleType = CircleType.center
    var arcType = ArcType.center
    var slotType = SlotType.straight
    var ellipseType = EllipseType.full
    var chamferType = ChamferType.distanceDistance
    var trimMode = TrimMode.power
    var forConstruction = false
    var filletRadius = 2.0
    var chamferDistance = 2.0
    var chamferDistance2 = 2.0
    var chamferEqual = true
    var chamferAngle = 45.0
    var polygonSides = 6
    var polygonInscribed = true
    /// Snap targets: sketch point positions (u, v) by id, refreshed after each command.
    var points: [(id: String, u: Double, v: Double)] = []
    var plane: SketchPlane?
    /// The sketch being edited (a value copy, refreshed after each command).
    var sketch: Sketch?
    /// Tangent arc: the line or arc it continues from.
    var tangentBase: String?
    /// Curves already trimmed during the current power-trim drag.
    var trimmedInDrag: Set<String> = []
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
        sketchEditCount = 0
        if await run("sketch.create", ["plane": .string(plane.rawValue)]) != nil {
            setOrientation(plane == .front ? .front : plane == .top ? .top : .right)
            chooseTool(.line)
        }
    }

    func editSketch(_ id: String) async {
        operation = nil
        if await run("sketch.edit", ["sketch": .string(id)]) != nil {
            sketchEditCount = 0
            normalToSketch()
        }
    }

    func exitSketch() async {
        sketchState.tool = nil
        sketchState.pending = []
        dimensionEdit = nil
        if operation?.isSketchOperation == true { operation = nil }
        await run("sketch.exit")
        sketchEditCount = 0
    }

    /// Cancel Sketch (confirmation corner ✗): undo every change made since the sketch was
    /// opened, then leave it — a new sketch disappears.
    func cancelSketch() async {
        let alert = NSAlert()
        alert.messageText = "Discard the changes to this sketch?"
        alert.informativeText = sketchEditCount == 0 ? "There are no changes." : "\(sketchEditCount) change\(sketchEditCount == 1 ? "" : "s") will be undone."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let n = sketchEditCount
        sketchState.tool = nil
        sketchState.pending = []
        dimensionEdit = nil
        operation = nil
        for _ in 0..<n { await run("edit.undo") }
        if activeSketch != nil { await run("sketch.exit") }
        sketchEditCount = 0
    }

    func chooseTool(_ tool: SketchTool?) {
        sketchState.tool = tool
        sketchState.pending = []
        sketchState.pendingTargets = []
        sketchState.chainStart = nil
        sketchState.tangentBase = nil
        dimensionEdit = nil
        if tool != nil { lastSketchTool = tool }
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

    /// The inference the cursor finds (docs/research §1.12), honouring the line orientation.
    func snapped(_ raw: Point2, tolerance: Double) -> SketchSnap {
        guard let sk = sketchState.sketch else { return SketchSnap(point: raw, kind: .none) }
        let tool = sketchState.tool
        let drawingLine = tool == .line && !sketchState.pending.isEmpty
        let from = drawingLine || tool == .rectangle && sketchState.rectangleType != .corner ? sketchState.pending.last : nil
        var s = sk.snap(raw, tolerance: tolerance, from: from, extra: sketchState.pending)
        if drawingLine, let a = sketchState.pending.last {
            switch sketchState.lineOrientation {
            case .horizontal: s = SketchSnap(point: Point2(s.point.u, a.v), kind: .horizontal)
            case .vertical: s = SketchSnap(point: Point2(a.u, s.point.v), kind: .vertical)
            case .asSketched: break
            }
        }
        return s
    }

    /// Cursor moved over the sketch plane (nil: left the viewport). Updates the preview and
    /// the tooltip shown next to the cursor.
    func sketchHover(_ raw: Point2?, tolerance: Double, viewPoint: CGPoint) {
        guard let tool = sketchState.tool, let raw else {
            cursorSketchPoint = nil
            if sketchState.preview != nil { clearPreview() }
            return
        }
        let snap = snapped(raw, tolerance: tolerance)
        let p = snap.point
        cursorSketchPoint = p
        var pv = SketchPreview(marker: [SketchSnap.Kind.point, .midpoint, .onCurve].contains(snap.kind) ? p : nil, snap: snap.kind, guides: snap.guides)
        var lines: [String] = []
        let pending = sketchState.pending
        func fmt(_ x: Double) -> String { String(format: "%.2f", x) }
        func angle(_ a: Point2, _ b: Point2) -> Double {
            var ang = atan2(b.v - a.v, b.u - a.u) * 180 / .pi
            if ang < 0 { ang += 360 }
            return ang
        }
        switch tool {
        case .line:
            if let a = pending.last {
                let start = sketchState.lineKind == .midpoint ? Point2(2 * a.u - p.u, 2 * a.v - p.v) : a
                pv.polylines = [[start, p]]
                if snap.kind == .horizontal || snap.kind == .vertical { pv.relationGuide = .init(from: a, to: p) }
                lines = ["L  \(fmt(hypot(p.u - start.u, p.v - start.v)))", "∠  \(String(format: "%.1f", angle(start, p)))°"]
            }
        case .rectangle:
            if let corners = rectangleCorners(pending + [p]) {
                pv.polylines = [corners + [corners[0]]]
                let w = hypot(corners[1].u - corners[0].u, corners[1].v - corners[0].v)
                let h = hypot(corners[2].u - corners[1].u, corners[2].v - corners[1].v)
                lines = ["W  \(fmt(w))", "H  \(fmt(h))"]
            } else if let a = pending.first {
                pv.polylines = [[a, p]]
            }
        case .circle:
            switch sketchState.circleType {
            case .center:
                if let c = pending.first {
                    let r = hypot(p.u - c.u, p.v - c.v)
                    pv.polylines = [Self.ellipsePolyline(c, r, r, 0), [c, p]]
                    lines = ["R  \(fmt(r))"]
                }
            case .perimeter:
                if pending.count == 1 {
                    pv.polylines = [[pending[0], p]]
                } else if pending.count == 2, let cc = try? Sketch.circumcircle(pending[0].tuple, pending[1].tuple, p.tuple) {
                    pv.polylines = [Self.ellipsePolyline(Point2(cc.center.0, cc.center.1), cc.radius, cc.radius, 0)]
                    lines = ["R  \(fmt(cc.radius))"]
                }
            }
        case .arc:
            switch sketchState.arcType {
            case .center:
                if pending.count == 1 {
                    pv.polylines = [[pending[0], p]]
                    lines = ["R  \(fmt(hypot(p.u - pending[0].u, p.v - pending[0].v)))"]
                } else if pending.count == 2 {
                    let c = pending[0], s = pending[1]
                    let r = hypot(s.u - c.u, s.v - c.v)
                    let a0 = atan2(s.v - c.v, s.u - c.u)
                    var a1 = atan2(p.v - c.v, p.u - c.u)
                    if a1 <= a0 { a1 += 2 * .pi }
                    pv.polylines = [(0...48).map { i in
                        let t = a0 + (a1 - a0) * Double(i) / 48
                        return Point2(c.u + r * cos(t), c.v + r * sin(t))
                    }]
                    lines = ["R  \(fmt(r))", "∠  \(String(format: "%.1f", (a1 - a0) * 180 / .pi))°"]
                }
            case .tangent:
                if let base = sketchState.tangentBase, let arc = tangentArcPreview(base: base, to: p) {
                    pv.polylines = [arc.points]
                    lines = ["R  \(fmt(arc.radius))"]
                }
            case .threePoint:
                if pending.count == 1 {
                    pv.polylines = [[pending[0], p]]
                } else if pending.count == 2 {
                    pv.polylines = [Self.arcThrough(pending[0], p, pending[1])]
                    if let cc = try? Sketch.circumcircle(pending[0].tuple, p.tuple, pending[1].tuple) { lines = ["R  \(fmt(cc.radius))"] }
                }
            }
        case .slot:
            if pending.count == 1 {
                let a = sketchState.slotType == .center ? Point2(2 * pending[0].u - p.u, 2 * pending[0].v - p.v) : pending[0]
                pv.polylines = [[a, p]]
                lines = ["L  \(fmt(hypot(p.u - a.u, p.v - a.v)))"]
            } else if pending.count == 2 {
                let (a, b) = slotCentres(pending[0], pending[1])
                let w = 2 * Self.distanceToLine(p, a, b)
                pv.polylines = [Self.slotOutline(a, b, w / 2)]
                lines = ["W  \(fmt(w))"]
            }
        case .polygon:
            if let c = pending.first {
                let r = hypot(p.u - c.u, p.v - c.v)
                let n = max(3, sketchState.polygonSides)
                let a0 = atan2(p.v - c.v, p.u - c.u)
                // Inscribed: the cursor is a vertex; circumscribed: the middle of a side.
                let rv = sketchState.polygonInscribed ? r : r / cos(.pi / Double(n))
                let off = sketchState.polygonInscribed ? 0 : .pi / Double(n)
                pv.polylines = [(0...n).map { i in
                    let t = a0 + off + 2 * Double.pi * Double(i) / Double(n)
                    return Point2(c.u + rv * cos(t), c.v + rv * sin(t))
                }, Self.ellipsePolyline(c, r, r, 0)]
                lines = [sketchState.polygonInscribed ? "R  \(fmt(r))" : "r  \(fmt(r))", "\(n) sides"]
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
            } else if pending.count >= 2 {
                let c = pending[0], m = pending[1]
                let a = hypot(m.u - c.u, m.v - c.v), rot = atan2(m.v - c.v, m.u - c.u)
                let b = pending.count == 2 ? Self.distanceToLine(p, c, m) : Self.distanceToLine(pending[2], c, m)
                pv.polylines = [Self.ellipsePolyline(c, a, b, rot)]
                lines = pending.count == 2 ? ["a  \(fmt(a))", "b  \(fmt(b))"] : ["Click the end of the arc"]
            }
        case .point, .fillet, .chamfer, .trim, .extend, .dimension:
            break
        }
        sketchState.preview = pv
        hoverLines = lines
        hoverViewPoint = viewPoint
        overlayVersion += 1
    }

    /// Corners of the rectangle being drawn (2 clicks for corner/center, 3 for the others).
    func rectangleCorners(_ pts: [Point2]) -> [Point2]? {
        switch sketchState.rectangleType {
        case .corner:
            guard pts.count >= 2 else { return nil }
            let (a, c) = (pts[0], pts[1])
            return [a, Point2(c.u, a.v), c, Point2(a.u, c.v)]
        case .center:
            guard pts.count >= 2 else { return nil }
            let (m, c) = (pts[0], pts[1])
            let a = Point2(2 * m.u - c.u, 2 * m.v - c.v)
            return [a, Point2(c.u, a.v), c, Point2(a.u, c.v)]
        case .threePoint:
            guard pts.count >= 3 else { return nil }
            let (a, b, p) = (pts[0], pts[1], pts[2])
            let dx = b.u - a.u, dy = b.v - a.v, len = hypot(dx, dy)
            guard len > 0 else { return nil }
            let (nx, ny) = (-dy / len, dx / len)
            let h = (p.u - b.u) * nx + (p.v - b.v) * ny
            return [a, b, Point2(b.u + nx * h, b.v + ny * h), Point2(a.u + nx * h, a.v + ny * h)]
        case .parallelogram:
            guard pts.count >= 3 else { return nil }
            let (a, b, c) = (pts[0], pts[1], pts[2])
            return [a, b, c, Point2(a.u + c.u - b.u, a.v + c.v - b.v)]
        }
    }

    /// Slot arc centres from the two clicks (centerpoint slot: the first click is the middle).
    func slotCentres(_ p0: Point2, _ p1: Point2) -> (Point2, Point2) {
        sketchState.slotType == .center ? (Point2(2 * p0.u - p1.u, 2 * p0.v - p1.v), p1) : (p0, p1)
    }

    /// Where a tangent arc from the end of `base` to `p` runs (mirrors sketch.add_arc tangent).
    func tangentArcPreview(base: String, to p: Point2) -> (points: [Point2], radius: Double)? {
        guard let sk = sketchState.sketch, let e = sk.entities[base] else { return nil }
        let P: (Double, Double), t: (Double, Double)
        switch e.kind {
        case .line:
            let a = sk.point(e.points[0]), b = sk.point(e.points[1])
            (P, t) = (b, (b.0 - a.0, b.1 - a.1))
        case .arc:
            let c = sk.point(e.points[0]), en = sk.point(e.points[2])
            (P, t) = (en, (-(en.1 - c.1), en.0 - c.0))
        default:
            return nil
        }
        let tl = hypot(t.0, t.1)
        guard tl > 0 else { return nil }
        let n = (-t.1 / tl, t.0 / tl)
        let w = (p.u - P.0, p.v - P.1)
        let wn = w.0 * n.0 + w.1 * n.1
        guard abs(wn) > 1e-9 else { return ([Point2(P.0, P.1), p], .infinity) }
        let r = (w.0 * w.0 + w.1 * w.1) / (2 * wn)
        let c = (P.0 + n.0 * r, P.1 + n.1 * r)
        let a0 = atan2(P.1 - c.1, P.0 - c.0), a1 = atan2(p.v - c.1, p.u - c.0)
        var sweep = a1 - a0
        if r > 0 { while sweep <= 0 { sweep += 2 * .pi } } else { while sweep >= 0 { sweep -= 2 * .pi } }
        let pts = (0...48).map { i in
            let a = a0 + sweep * Double(i) / 48
            return Point2(c.0 + abs(r) * cos(a), c.1 + abs(r) * sin(a))
        }
        return (pts, abs(r))
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
            dimensionEdit = nil
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
    /// cursor, if any (trim, extend, tangent arc, Smart Dimension).
    func sketchClick(_ raw: Point2, tolerance: Double, curve: String?, clickCount: Int = 1, viewPoint: CGPoint = .zero) async {
        guard let tool = sketchState.tool else { return }
        let local = curve.flatMap { $0.split(separator: "/").last.map(String.init) }
        if clickCount >= 2 {
            switch tool {
            case .line:
                // Double-click ends the chain (the first click already placed the point).
                resetPending()
                return
            case .spline:
                let through = sketchState.pending
                resetPending()
                if through.count >= 2 { await run("sketch.add_spline", ["through": .array(through.map(pt)), "construction": .bool(sketchState.forConstruction)]) }
                await refreshSketchState()
                return
            default:
                break
            }
        }
        let snap = snapped(raw, tolerance: tolerance)
        let p = snap.point
        let construction = JSONValue.bool(sketchState.forConstruction || (tool == .line && sketchState.lineKind == .centerline))
        switch tool {
        case .point:
            await run("sketch.add_point", ["at": pt(p)])
        case .line:
            if let a = sketchState.pending.last {
                guard a != p else { return }
                if sketchState.lineKind == .midpoint {
                    let start = Point2(2 * a.u - p.u, 2 * a.v - p.v)
                    if let o = await run("sketch.add_line", ["start": pt(start), "end": pt(p), "construction": construction]),
                        let line = o.changes.created.first(where: { $0.contains("line-") }), let mid = sketchState.pendingTargets.first ?? nil
                    {
                        await run("sketch.add_relation", ["type": "midpoint", "entities": [.string(mid), .string(Self.localID(line))]])
                    }
                    resetPending()
                    await refreshSketchState()
                    return
                }
                await run("sketch.add_line", ["start": pt(a), "end": pt(p), "construction": construction])
                if sketchState.lineKind == .centerline || sketchState.chainStart == p {
                    // A centerline is one segment; back at a chain's first point the profile is closed.
                    resetPending()
                    await refreshSketchState()
                    return
                }
            } else {
                sketchState.chainStart = p
            }
            sketchState.pending = [p]
            sketchState.pendingTargets = [snap.kind == .point ? snap.target : nil]
        case .rectangle:
            sketchState.pending.append(p)
            let need = sketchState.rectangleType == .corner || sketchState.rectangleType == .center ? 2 : 3
            if sketchState.pending.count == need {
                let pts = sketchState.pending
                resetPending()
                let mode: String
                var points = pts
                switch sketchState.rectangleType {
                case .corner: mode = "corner"
                case .center: mode = "center"
                case .threePoint:
                    mode = "three_point"
                    if let c = rectangleCorners(pts) { points = Array(c.prefix(3)) }
                case .parallelogram: mode = "parallelogram"
                }
                await run("sketch.add_rectangle", ["mode": .string(mode), "points": .array(points.map(pt)), "construction": construction])
            }
        case .circle:
            sketchState.pending.append(p)
            switch sketchState.circleType {
            case .center where sketchState.pending.count == 2:
                let c = sketchState.pending[0]
                resetPending()
                let r = hypot(p.u - c.u, p.v - c.v)
                if r > 0 { await run("sketch.add_circle", ["center": pt(c), "radius": .number(r), "construction": construction]) }
            case .perimeter where sketchState.pending.count == 3:
                let pts = sketchState.pending
                resetPending()
                await run("sketch.add_circle", ["through": .array(pts.map(pt)), "construction": construction])
            default:
                break
            }
        case .arc:
            switch sketchState.arcType {
            case .center:
                sketchState.pending.append(p)
                if sketchState.pending.count == 3 {
                    let (c, s) = (sketchState.pending[0], sketchState.pending[1])
                    resetPending()
                    await run("sketch.add_arc", ["mode": "center", "center": pt(c), "start": pt(s), "end": pt(p), "construction": construction])
                }
            case .tangent:
                if let base = sketchState.tangentBase {
                    resetPending()
                    await run("sketch.add_arc", ["mode": "tangent", "tangent_to": .string(base), "end": pt(p), "construction": construction])
                } else if let base = tangentBaseEnding(at: p) {
                    sketchState.tangentBase = base
                    sketchState.pending = [p]
                } else {
                    lastError = ForgeError(.invalidParams, "start a tangent arc on the end of a line or arc")
                }
            case .threePoint:
                sketchState.pending.append(p)
                if sketchState.pending.count == 3 {
                    let (s, e) = (sketchState.pending[0], sketchState.pending[1])
                    resetPending()
                    await run("sketch.add_arc", ["mode": "three_point", "start": pt(s), "end": pt(e), "through": pt(p), "construction": construction])
                }
            }
        case .slot:
            sketchState.pending.append(p)
            if sketchState.pending.count == 3 {
                let (p0, p1) = (sketchState.pending[0], sketchState.pending[1])
                let (a, b) = slotCentres(p0, p1)
                resetPending()
                let w = 2 * Self.distanceToLine(p, a, b)
                if w > 0 {
                    let mode = sketchState.slotType == .center ? "center" : "straight"
                    let start = sketchState.slotType == .center ? p0 : a
                    await run("sketch.add_slot", ["mode": .string(mode), "start": pt(start), "end": pt(b), "width": .number(w)])
                }
            }
        case .polygon:
            if let c = sketchState.pending.first {
                resetPending()
                let r = hypot(p.u - c.u, p.v - c.v)
                let n = max(3, sketchState.polygonSides)
                var rot = atan2(p.v - c.v, p.u - c.u)
                if !sketchState.polygonInscribed { rot += .pi / Double(n) }
                if r > 0 {
                    await run("sketch.add_polygon", [
                        "center": pt(c), "sides": .number(Double(n)), "radius": .number(r), "inscribed": .bool(sketchState.polygonInscribed),
                        "rotation": .string(String(format: "%.6f deg", rot * 180 / .pi)),
                    ])
                }
            } else {
                sketchState.pending = [p]
            }
        case .spline:
            if sketchState.pending.last != p { sketchState.pending.append(p) }
        case .ellipse:
            sketchState.pending.append(p)
            let need = sketchState.ellipseType == .full ? 3 : 4
            if sketchState.pending.count == need {
                let pts = sketchState.pending
                resetPending()
                let c = pts[0], m = pts[1]
                var a = hypot(m.u - c.u, m.v - c.v), b = Self.distanceToLine(pts[2], c, m)
                var rot = atan2(m.v - c.v, m.u - c.u)
                if b > a { swap(&a, &b); rot += .pi / 2 }
                guard b > 0 else { break }
                var params: [String: JSONValue] = [
                    "center": pt(c), "major_radius": .number(a), "minor_radius": .number(b),
                    "rotation": .string(String(format: "%.6f deg", rot * 180 / .pi)),
                ]
                if sketchState.ellipseType == .partial {
                    params["start"] = pt(pts[2])
                    params["end"] = pt(pts[3])
                }
                await run("sketch.add_ellipse", .object(params))
            }
        case .fillet, .chamfer:
            guard snap.kind == .point, let corner = snap.target else {
                lastError = ForgeError(.invalidParams, "click a corner point where two lines meet")
                return
            }
            if tool == .fillet {
                await run("sketch.fillet", ["corner": .string(corner), "radius": .number(sketchState.filletRadius)])
            } else {
                let lines = linesMeeting(at: corner)
                guard lines.count == 2 else {
                    lastError = ForgeError(.invalidParams, "a chamfer needs exactly two lines meeting at the corner")
                    return
                }
                var params: [String: JSONValue] = ["lines": .array(lines.map { .string($0) }), "distance": .number(sketchState.chamferDistance)]
                switch sketchState.chamferType {
                case .angleDistance: params["angle"] = .string("\(sketchState.chamferAngle) deg")
                case .distanceDistance where !sketchState.chamferEqual: params["distance2"] = .number(sketchState.chamferDistance2)
                default: break
                }
                await run("sketch.chamfer", .object(params))
            }
        case .trim, .extend:
            guard let local else {
                lastError = ForgeError(.invalidParams, tool == .trim ? "click the piece of a curve to remove" : "click a curve near the end to extend")
                return
            }
            if tool == .trim {
                sketchState.trimmedInDrag = [local]
                await run("sketch.trim", ["entity": .string(local), "at": pt(raw)])
            } else {
                await run("sketch.extend", ["entity": .string(local), "near": pt(raw)])
            }
        case .dimension:
            let pick = snap.kind == .point ? snap.target : local
            guard let pick else {
                lastError = ForgeError(.invalidParams, "click a line, circle, arc or point to dimension")
                return
            }
            dimensionPick(pick, at: viewPoint)
            return
        }
        await refreshSketchState()
    }

    /// Power trim: dragging across curves trims each piece the pointer crosses.
    func sketchDrag(_ raw: Point2, curve: String?) async {
        guard sketchState.tool == .trim, sketchState.trimMode == .power,
            let local = curve.flatMap({ $0.split(separator: "/").last.map(String.init) }), !sketchState.trimmedInDrag.contains(local)
        else { return }
        sketchState.trimmedInDrag.insert(local)
        await run("sketch.trim", ["entity": .string(local), "at": pt(raw)])
        await refreshSketchState()
    }

    private func resetPending() {
        sketchState.pending = []
        sketchState.pendingTargets = []
        sketchState.chainStart = nil
        sketchState.tangentBase = nil
        clearPreview()
    }

    static func localID(_ ref: String) -> String { ref.split(separator: "/").last.map(String.init) ?? ref }

    private func pt(_ q: Point2) -> JSONValue { [.number(q.u), .number(q.v)] }

    /// The line or arc whose end is at `p` (where a tangent arc can start).
    func tangentBaseEnding(at p: Point2) -> String? {
        guard let sk = sketchState.sketch else { return nil }
        for e in sk.orderedEntities.reversed() where e.kind == .line || e.kind == .arc {
            let end = sk.point(e.kind == .line ? e.points[1] : e.points[2])
            if abs(end.0 - p.u) < 1e-9 && abs(end.1 - p.v) < 1e-9 { return e.id }
        }
        return nil
    }

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

    /// Esc: cancel the pending entity, then the tool, then the operation.
    func cancelSketchOperation() {
        if dimensionEdit != nil {
            dimensionEdit = nil
            return
        }
        if operation != nil && sketchState.pending.isEmpty {
            cancelOperation()
            return
        }
        if sketchState.pending.isEmpty { sketchState.tool = nil }
        resetPending()
    }

    /// Kinds of the selected sketch entities, in selection order.
    var sketchSelectionKinds: [SketchEntityKind] {
        guard let sk = sketchState.sketch else { return [] }
        return sketchSelection.compactMap { sk.entities[$0]?.kind }
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
        case .addRelation, .displayRelations, .sketchOffset, .sketchMirror, .sketchLinearPattern, .sketchCircularPattern,
            .sketchMove, .sketchRotate, .sketchScale:
            true
        default: false
        }
    }
}

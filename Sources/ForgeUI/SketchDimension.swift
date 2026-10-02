// Smart Dimension as SolidWorks does it (docs/research §2.1 "Dimensions"):
// - With the tool active, click one entity (line → length, circle → diameter, arc → radius) or
//   two (angle, distance).
// - The dimension then follows the pointer. Pulling it beside a slanted line or two points gives
//   an aligned dimension; above or below gives horizontal, left or right gives vertical.
// - Click to place it. The Modify box opens there with the current value selected.
// - Type a value (units and expressions such as "1 in" work) and press Return; Esc cancels.
// - The sketch's first length dimension scales the whole sketch, so the profile keeps its shape
//   (and the view is refitted), instead of one entity shrinking alone.

import ForgeCommands
import ForgeCore
import ForgeSketch
import Foundation

package struct DimensionEdit: Equatable {
    package var entities: [String]
    /// For a line or two points: aligned, horizontal or vertical distance.
    package var mode: ConstraintKind = .distance
    /// Chosen in the Modify box: the pointer no longer picks the orientation.
    package var modeFixed = false
    package var text: String = ""
    /// Where the Modify box opens (view coordinates).
    package var position: CGPoint
    /// Where the value goes, in sketch coordinates: follows the pointer until placed.
    package var label: Point2? = nil
    /// The value is placed and the Modify box is open.
    package var placed = false
    /// Bumped to re-focus the value field after another pick.
    package var focusToken = 0

    package var measurement: SketchMeasurement? = nil
}

extension AppModel {
    /// A click with the Smart Dimension tool: `id` is the entity under the pointer (nil: empty
    /// space), `point` the click in sketch coordinates.
    package func dimensionClick(_ id: String?, at point: Point2, viewPoint: CGPoint) async {
        if let edit = dimensionEdit {
            if edit.placed {
                // A click elsewhere while the Modify box is open accepts it (as in SolidWorks).
                await commitDimension()
                if dimensionEdit != nil { return }  // the value was rejected: stay in the box
                if id == nil { return }
            } else if edit.measurement != nil, id == nil || edit.entities.contains(id!) || edit.entities.count >= 2 || !canAdd(id!, to: edit) {
                placeDimension(at: point, viewPoint: viewPoint)
                return
            }
        }
        guard let id else {
            lastError = ForgeError(.invalidParams, dimensionEdit == nil ? "click a line, circle, arc or point to dimension" : "click a second entity to dimension to")
            return
        }
        dimensionPick(id, at: viewPoint, point: point)
    }

    /// Whether `id` can join the entities picked so far (a measurable pair).
    private func canAdd(_ id: String, to edit: DimensionEdit) -> Bool {
        guard let sk = sketchState.sketch, edit.entities.count == 1 else { return false }
        return sk.measure(edit.entities + [id]) != nil
    }

    /// Pick an entity for the dimension being made (a second pick while one is pending adds to it).
    package func dimensionPick(_ id: String, at viewPoint: CGPoint, point: Point2? = nil) {
        guard let sk = sketchState.sketch else { return }
        var edit = dimensionEdit ?? DimensionEdit(entities: [], position: viewPoint)
        if edit.entities.contains(id) { return }
        if edit.entities.count >= 2 || edit.placed { edit = DimensionEdit(entities: [], position: viewPoint) }
        edit.entities.append(id)
        edit.position = viewPoint
        edit.label = point
        if !edit.modeFixed { edit.mode = autoMode(sk, edit) }
        edit.measurement = sk.measure(edit.entities, mode: edit.mode)
        // One point alone is not a dimension yet: wait for the second pick.
        edit.text = edit.measurement.map(Self.format) ?? ""
        dimensionEdit = edit
        Task { await select(sketchRefs(edit.entities)) }
    }

    /// The pointer moved while a dimension is being placed: it follows.
    package func dimensionHover(_ p: Point2) {
        guard var edit = dimensionEdit, !edit.placed, let sk = sketchState.sketch else { return }
        edit.label = p
        if !edit.modeFixed { edit.mode = autoMode(sk, edit) }
        edit.measurement = sk.measure(edit.entities, mode: edit.mode)
        edit.text = edit.measurement.map(Self.format) ?? ""
        if edit != dimensionEdit { dimensionEdit = edit }
    }

    /// Place the value at `point`: the Modify box opens there.
    package func placeDimension(at point: Point2, viewPoint: CGPoint) {
        guard var edit = dimensionEdit, edit.measurement != nil else { return }
        dimensionHover(point)
        edit = dimensionEdit ?? edit
        edit.label = point
        edit.position = viewPoint
        edit.placed = true
        edit.focusToken += 1
        dimensionEdit = edit
    }

    /// The orientation a line's or two points' dimension takes from where the value is pulled:
    /// beside the segment → aligned; above or below it → horizontal; left or right → vertical.
    package func autoMode(_ sk: Sketch, _ edit: DimensionEdit) -> ConstraintKind {
        guard let l = edit.label, let (a, b) = orientable(sk, edit.entities) else { return .distance }
        let du = b.u - a.u, dv = b.v - a.v, len2 = du * du + dv * dv
        guard len2 > 0 else { return .distance }
        let t = ((l.u - a.u) * du + (l.v - a.v) * dv) / len2
        if t >= 0 && t <= 1 { return .distance }
        let inU = l.u >= min(a.u, b.u) && l.u <= max(a.u, b.u)
        let inV = l.v >= min(a.v, b.v) && l.v <= max(a.v, b.v)
        if inU && !inV { return .horizontalDistance }
        if inV && !inU { return .verticalDistance }
        return .distance
    }

    /// The two points of a dimension that can be horizontal or vertical: a line's ends or two
    /// points (what the solver's horizontal / vertical distances take).
    private func orientable(_ sk: Sketch, _ ids: [String]) -> (Point2, Point2)? {
        let es = ids.compactMap { sk.entities[$0] }
        guard es.count == ids.count else { return nil }
        func p(_ id: String) -> Point2 { let (u, v) = sk.point(id); return Point2(u, v) }
        if es.count == 1, es[0].kind == .line { return (p(es[0].points[0]), p(es[0].points[1])) }
        if es.count == 2, es.allSatisfy({ $0.kind == .point }) { return (p(ids[0]), p(ids[1])) }
        return nil
    }

    /// The dimension being made, drawn at the pointer (or where it was placed).
    package var dimensionPreview: SketchAnnotation? {
        guard let edit = dimensionEdit, let m = edit.measurement, let sk = sketchState.sketch,
              let l = sk.dimensionLayout(m.kind, edit.entities, label: edit.label)
        else { return nil }
        var a = SketchAnnotation(
            id: "dimension-preview", kind: .dimension, text: Self.dimensionText(m.kind, m.value), anchor: sk.plane.point(l.text.u, l.text.v),
            slot: 0, driven: false, problem: false)
        a.drawing = DimensionDrawing(l, on: sk.plane)
        return a
    }

    /// Start a dimension on the current selection (Smart Dimension with entities preselected).
    package func dimensionSelection() {
        chooseTool(.dimension)
        let ids = sketchSelection
        guard !ids.isEmpty, let sk = sketchState.sketch else { return }
        let anchor = ids.compactMap { Self.anchor(sk, $0) }.first
        let at = anchor.flatMap { a in projection?.point(sk.plane.point(a.u, a.v)) } ?? CGPoint(x: 300, y: 200)
        var edit = DimensionEdit(entities: Array(ids.prefix(2)), position: at)
        edit.measurement = sk.measure(edit.entities)
        edit.text = edit.measurement.map(Self.format) ?? ""
        // The value follows the pointer from here, as after picking the entities.
        dimensionEdit = edit
    }

    package func setDimensionMode(_ mode: ConstraintKind) {
        guard var edit = dimensionEdit, let sk = sketchState.sketch else { return }
        edit.mode = mode
        edit.modeFixed = true
        edit.measurement = sk.measure(edit.entities, mode: mode)
        edit.text = edit.measurement.map(Self.format) ?? edit.text
        dimensionEdit = edit
    }

    package static func format(_ m: SketchMeasurement) -> String {
        m.kind == .angle ? String(format: "%.2f°", m.value * 180 / .pi) : String(format: "%.2f", m.value)
    }

    package func commitDimension() async {
        guard let edit = dimensionEdit, let m = edit.measurement else { return }
        var params: [String: JSONValue] = [
            "type": .string(m.kind.rawValue), "entities": .array(edit.entities.map { .string($0) }), "scale_sketch": true,
        ]
        if let l = edit.label { params["label_at"] = .array([.number(l.u), .number(l.v)]) }
        let typed = edit.text.trimmingCharacters(in: .whitespaces)
        // Unchanged text keeps the current size; otherwise the typed value (with units).
        if !typed.isEmpty && typed != Self.format(m) {
            let bare = typed.hasSuffix("°") ? String(typed.dropLast()) : typed
            if m.kind == .angle {
                params["value"] = .string(Double(bare) != nil ? bare + " deg" : bare)
            } else {
                params["value"] = Double(bare).map { .number($0) } ?? .string(bare)
            }
        }
        if let o = await run("sketch.add_dimension", .object(params)) {
            dimensionEdit = nil
            // The first dimension scaled the sketch: fit the view to it, so it neither shrinks
            // to a speck nor overflows the window.
            if o.result["scaled_by"]?.doubleValue != nil { zoomToFit() }
            await select(nil, extend: false)
        }
    }

    private func sketchRefs(_ ids: [String]) -> [String] {
        guard let s = activeSketch else { return [] }
        return ids.map { "\(s)/\($0)" }
    }

    package func select(_ refs: [String]) async {
        await run("selection.set", ["entities": .array(refs.map { .string($0) }), "mode": "replace"])
    }
}

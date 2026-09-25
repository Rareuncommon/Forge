// Smart Dimension as SolidWorks does it (docs/research §2.1 "Dimensions"): with the tool
// active, click one entity (line → length, circle → diameter, arc → radius) or two (angle,
// distance); the Modify box opens at the pointer with the current value selected. Type a
// value (units and expressions such as "1 in" work) and press Return; Esc cancels. Clicking
// another entity while the box is open adds it to the dimension.

import ForgeCommands
import ForgeCore
import ForgeSketch
import Foundation

package struct DimensionEdit: Equatable {
    package var entities: [String]
    /// For two points: aligned, horizontal or vertical distance.
    package var mode: ConstraintKind = .distance
    package var text: String = ""
    package var position: CGPoint
    /// Bumped to re-focus the value field after another pick.
    package var focusToken = 0

    package var measurement: SketchMeasurement? = nil
}

extension AppModel {
    /// A pick with the Smart Dimension tool.
    package func dimensionPick(_ id: String, at viewPoint: CGPoint) {
        guard let sk = sketchState.sketch else { return }
        var edit = dimensionEdit ?? DimensionEdit(entities: [], position: viewPoint)
        if edit.entities.contains(id) { return }
        if edit.entities.count >= 2 { edit = DimensionEdit(entities: [], position: viewPoint) }
        edit.entities.append(id)
        edit.position = viewPoint
        edit.focusToken += 1
        edit.measurement = sk.measure(edit.entities, mode: edit.mode)
        // One point alone is not a dimension yet: wait for the second pick.
        if let m = edit.measurement { edit.text = Self.format(m) } else { edit.text = "" }
        dimensionEdit = edit
        Task { await select(sketchRefs(edit.entities)) }
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
        dimensionEdit = edit
    }

    package func setDimensionMode(_ mode: ConstraintKind) {
        guard var edit = dimensionEdit, let sk = sketchState.sketch else { return }
        edit.mode = mode
        edit.measurement = sk.measure(edit.entities, mode: mode)
        edit.text = edit.measurement.map(Self.format) ?? edit.text
        dimensionEdit = edit
    }

    package static func format(_ m: SketchMeasurement) -> String {
        m.kind == .angle ? String(format: "%.2f°", m.value * 180 / .pi) : String(format: "%.2f", m.value)
    }

    package func commitDimension() async {
        guard let edit = dimensionEdit, let m = edit.measurement else { return }
        var params: [String: JSONValue] = ["type": .string(m.kind.rawValue), "entities": .array(edit.entities.map { .string($0) })]
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
        if await run("sketch.add_dimension", .object(params)) != nil {
            dimensionEdit = nil
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

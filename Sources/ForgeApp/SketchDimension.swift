// Smart Dimension as SolidWorks does it (docs/research §2.1 "Dimensions"): with the tool
// active, click one entity (line → length, circle → diameter, arc → radius) or two (angle,
// distance); the Modify box opens at the pointer with the current value selected. Type a
// value (units and expressions such as "1 in" work) and press Return; Esc cancels. Clicking
// another entity while the box is open adds it to the dimension.

import ForgeCommands
import ForgeCore
import ForgeSketch
import SwiftUI

struct DimensionEdit: Equatable {
    var entities: [String]
    /// For two points: aligned, horizontal or vertical distance.
    var mode: ConstraintKind = .distance
    var text: String = ""
    var position: CGPoint
    /// Bumped to re-focus the value field after another pick.
    var focusToken = 0

    var measurement: SketchMeasurement? = nil
}

extension AppModel {
    /// A pick with the Smart Dimension tool.
    func dimensionPick(_ id: String, at viewPoint: CGPoint) {
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
    func dimensionSelection() {
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

    func setDimensionMode(_ mode: ConstraintKind) {
        guard var edit = dimensionEdit, let sk = sketchState.sketch else { return }
        edit.mode = mode
        edit.measurement = sk.measure(edit.entities, mode: mode)
        edit.text = edit.measurement.map(Self.format) ?? edit.text
        dimensionEdit = edit
    }

    static func format(_ m: SketchMeasurement) -> String {
        m.kind == .angle ? String(format: "%.2f°", m.value * 180 / .pi) : String(format: "%.2f", m.value)
    }

    func commitDimension() async {
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

    func select(_ refs: [String]) async {
        await run("selection.set", ["entities": .array(refs.map { .string($0) }), "mode": "replace"])
    }
}

/// SolidWorks' Modify box: value field, ✓ and ✗, at the pointer.
struct ModifyBox: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        if let edit = model.dimensionEdit {
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        IconView(icon: .smartDimension, size: 15, accent: Theme.accent).foregroundStyle(Theme.text2)
                        Text(edit.measurement == nil ? "Select a second entity" : title(edit))
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text2)
                    }
                    if edit.measurement != nil {
                        HStack(spacing: 6) {
                            TextField("Value", text: Binding(get: { model.dimensionEdit?.text ?? "" }, set: { model.dimensionEdit?.text = $0 }))
                                .textFieldStyle(.plain)
                                .font(Theme.mono)
                                .padding(.horizontal, 7)
                                .frame(width: 110, height: 26)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1.5))
                                .focused($focused)
                                .onSubmit { Task { await model.commitDimension() } }
                                .onExitCommand { model.dimensionEdit = nil }
                            Button { Task { await model.commitDimension() } } label: {
                                IconView(icon: .check, size: 15).foregroundStyle(.white).frame(width: 28, height: 26)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent))
                            }
                            .buttonStyle(.plain)
                            .help("OK (Return)")
                            Button { model.dimensionEdit = nil } label: {
                                IconView(icon: .xmark, size: 15).foregroundStyle(Theme.text2).frame(width: 28, height: 26)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                            }
                            .buttonStyle(.plain)
                            .help("Cancel (Esc)")
                        }
                        if isPointPair(edit) {
                            Picker("", selection: Binding(get: { model.dimensionEdit?.mode ?? .distance }, set: { model.setDimensionMode($0) })) {
                                Text("Aligned").tag(ConstraintKind.distance)
                                Text("Horizontal").tag(ConstraintKind.horizontalDistance)
                                Text("Vertical").tag(ConstraintKind.verticalDistance)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .controlSize(.small)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
                .shadow(color: Theme.shadowColor, radius: 12, y: 4)
                .fixedSize()
                .offset(x: edit.position.x + 16, y: edit.position.y + 12)
            }
            .onAppear { focused = true }
            .onChange(of: edit.focusToken) { _, _ in focused = true }
        }
    }

    private func title(_ e: DimensionEdit) -> String {
        switch e.measurement?.kind {
        case .angle: "Angle"
        case .diameter: "Diameter"
        case .radius: "Radius"
        case .horizontalDistance: "Horizontal distance"
        case .verticalDistance: "Vertical distance"
        default: e.entities.count == 1 ? "Length" : "Distance"
        }
    }

    private func isPointPair(_ e: DimensionEdit) -> Bool {
        guard e.entities.count == 2, let sk = model.sketchState.sketch else { return false }
        return e.entities.allSatisfy { id in [.point, .circle, .arc].contains(sk.entities[id]?.kind) }
    }
}

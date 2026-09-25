import ForgeCommands
import ForgeCore
import ForgeSketch
import ForgeUI
import SwiftUI

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

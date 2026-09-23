// Feature tree (SolidWorks' FeatureManager): origin planes, sketches and bodies. Until the M2
// feature tree exists (docs/adr/0011) this lists the document's sketches and bodies; every
// row action is a command.

import ForgeCommands
import ForgeCore
import ForgeSketch
import SwiftUI

struct FeatureTreeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Label(model.documentName, systemImage: "shippingbox")
                .font(.headline)
            Section("Origin") {
                ForEach(StandardPlane.allCases, id: \.self) { p in
                    TreeRow(title: "\(p.rawValue.capitalized) Plane", systemImage: "square.dashed", selected: false)
                        .contextMenu {
                            Button("Sketch on \(p.rawValue.capitalized) Plane") { Task { await model.newSketch(on: p) } }
                        }
                        .onTapGesture(count: 2) { Task { await model.newSketch(on: p) } }
                        .help("Double-click or right-click to sketch on this plane")
                }
            }
            if !model.sketches.isEmpty {
                Section("Sketches") {
                    ForEach(model.sketches) { s in
                        let editing = model.activeSketch == s.id
                        TreeRow(
                            title: s.name + (editing ? "  (editing)" : ""), systemImage: "pencil.and.outline",
                            subtitle: "\(s.plane) · \(statusText(s))", tint: statusColor(s), selected: model.selection.contains(s.id)
                        )
                        .onTapGesture(count: 2) { Task { await model.editSketch(s.id) } }
                        .onTapGesture { Task { await model.select(s.id, extend: NSEvent.modifierFlags.contains(.shift)) } }
                        .contextMenu {
                            if editing {
                                Button("Exit Sketch") { Task { await model.exitSketch() } }
                            } else {
                                Button("Edit Sketch") { Task { await model.editSketch(s.id) } }
                            }
                            Button("Extrude…") {
                                model.operationSketch = s.id
                                model.begin(.extrude)
                            }
                            Divider()
                            Button("Delete", role: .destructive) { Task { await model.run("sketch.remove", ["sketch": .string(s.id)]) } }
                        }
                    }
                }
            }
            if !model.bodies.isEmpty {
                Section("Bodies") {
                    ForEach(model.bodies, id: \.id) { b in
                        TreeRow(
                            title: b.name, systemImage: "cube.fill",
                            subtitle: "\(b.topology.faces) faces · \(String(format: "%.1f", b.volumeMM3)) mm³",
                            selected: model.selection.contains(b.id)
                        )
                        .onTapGesture { Task { await model.select(b.id, extend: NSEvent.modifierFlags.contains(.shift)) } }
                        .contextMenu {
                            Button("Mass Properties") {
                                Task {
                                    await model.select(b.id, extend: false)
                                    model.begin(.massProperties)
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) { Task { await model.run("body.delete", ["body": .string(b.id)]) } }
                        }
                        .accessibilityLabel("\(b.name), \(b.topology.faces) faces")
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func statusText(_ s: SketchRow) -> String {
        switch s.status {
        case .fullyDefined: "fully defined"
        case .underDefined: "under defined (\(s.dof))"
        case .redundant, .conflicting: "over defined"
        case .failed: "cannot solve"
        case nil: ""
        }
    }

    private func statusColor(_ s: SketchRow) -> Color {
        switch s.status {
        case .fullyDefined: .primary
        case .underDefined: .blue
        default: .red
        }
    }
}

struct TreeRow: View {
    let title: String
    let systemImage: String
    var subtitle: String? = nil
    var tint: Color = .primary
    var selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }
}

// Feature tree (SolidWorks' FeatureManager; docs/design): the part, its solid bodies, the
// origin planes and the sketches with their state. Until the M2 feature tree exists
// (docs/adr/0011) it lists the document's sketches and bodies; every row action is a command.

import ForgeCommands
import ForgeCore
import ForgeSketch
import SwiftUI

struct FeatureTreeView: View {
    @Environment(AppModel.self) private var model
    @State private var bodiesOpen = true
    @State private var rootOpen = true

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                IconView(icon: .search, size: 14).foregroundStyle(Theme.text3)
                TextField("Filter features", text: $model.treeFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            .padding(10)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    TreeRow(icon: .part, title: model.documentName, disclosure: rootOpen, bold: true) { rootOpen.toggle() }
                    if rootOpen { rows }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .background(Theme.panel)
    }

    private func matches(_ name: String) -> Bool {
        let f = model.treeFilter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty || name.localizedCaseInsensitiveContains(f)
    }

    @ViewBuilder private var rows: some View {
        if !model.bodies.isEmpty {
            TreeRow(icon: .folder, title: "Solid Bodies (\(model.bodies.count))", depth: 1, disclosure: bodiesOpen) { bodiesOpen.toggle() }
            if bodiesOpen {
                ForEach(model.bodies.filter { matches($0.name) }, id: \.id) { b in
                    TreeRow(icon: .part, title: b.name, depth: 2, selected: model.selection.contains(b.id),
                            trailing: "\(b.topology.faces) faces") {
                        Task { await model.select(b.id, extend: NSEvent.modifierFlags.contains(.shift)) }
                    }
                    .contextMenu {
                        Button("Mass Properties") {
                            Task {
                                await model.select(b.id, extend: false)
                                model.begin(.massProperties)
                            }
                        }
                        Button("Export STEP…") {
                            Task {
                                await model.select(b.id, extend: false)
                                model.export("step")
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { Task { await model.run("body.delete", ["body": .string(b.id)]) } }
                    }
                    .help("\(b.name): \(b.topology.faces) faces, \(String(format: "%.1f", b.volumeMM3)) mm³")
                }
            }
        }
        ForEach(StandardPlane.allCases.filter { matches($0.rawValue + " plane") }, id: \.self) { p in
            TreeRow(icon: .plane, title: "\(p.rawValue.capitalized) Plane", depth: 1, iconTint: Theme.text3,
                    doubleAction: { Task { await model.newSketch(on: p) } }) {}
                .contextMenu {
                    Button("Sketch on \(p.rawValue.capitalized) Plane") { Task { await model.newSketch(on: p) } }
                }
                .help("Double-click to sketch on this plane")
        }
        if matches("origin") {
            TreeRow(icon: .origin, title: "Origin", depth: 1, iconTint: Theme.axisX) {}
        }
        ForEach(model.sketches.filter { matches($0.name) }) { s in
            let editing = model.activeSketch == s.id
            // SolidWorks' status prefixes: (-) under defined, (+) over defined, (?) cannot solve.
            let prefix = s.status == .underDefined ? "(-) " : s.status == .redundant || s.status == .conflicting ? "(+) " : s.status == .failed ? "(?) " : ""
            TreeRow(icon: .sketch, title: prefix + s.name, depth: 1, selected: model.selection.contains(s.id) || editing,
                    iconTint: SketchStatusBadge.color(s.status), statusLabel: SketchStatusBadge.text(s),
                    doubleAction: { Task { await model.editSketch(s.id) } }) {
                Task { await model.select(s.id, extend: NSEvent.modifierFlags.contains(.shift)) }
            }
            .contextMenu {
                if editing {
                    Button("Exit Sketch") { Task { await model.exitSketch() } }
                } else {
                    Button("Edit Sketch") { Task { await model.editSketch(s.id) } }
                }
                Button("Extruded Boss/Base…") {
                    model.operationSketch = s.id
                    model.begin(.extrude)
                }
                Button("Revolved Boss/Base…") {
                    model.operationSketch = s.id
                    model.begin(.revolve)
                }
                Divider()
                Button("Delete", role: .destructive) { Task { await model.run("sketch.remove", ["sketch": .string(s.id)]) } }
            }
            .help("\(s.name) on \(s.plane) · \(SketchStatusBadge.text(s)). Double-click to edit.")
        }
    }
}

struct TreeRow: View {
    let icon: ForgeIcon
    let title: String
    var depth = 0
    var disclosure: Bool? = nil
    var selected = false
    var bold = false
    var muted = false
    var iconTint: Color? = nil
    var trailing: String? = nil
    var status: Color? = nil
    var statusLabel = ""
    var doubleAction: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        clickable
            .onHover { hovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    /// Double-click handling delays single clicks, so only rows with a double action have it.
    @ViewBuilder private var clickable: some View {
        if let doubleAction {
            label.onTapGesture(count: 2) { doubleAction() }.onTapGesture { action() }
        } else {
            label.onTapGesture { action() }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Group {
                if let open = disclosure {
                    IconView(icon: open ? .chevronDown : .chevronRight, size: 11)
                } else {
                    Color.clear
                }
            }
            .frame(width: 11, height: 11)
            .foregroundStyle(Theme.text3)
            IconView(icon: icon, size: 17, accent: iconTint ?? Theme.accent)
                .foregroundStyle(selected ? Theme.accentText : Theme.text2)
            Text(title)
                .font(.system(size: 12.5, weight: bold ? .semibold : .regular))
                .foregroundStyle(muted ? Theme.text3 : selected ? Theme.accentText : Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            if let status {
                Circle().fill(status).frame(width: 7, height: 7).accessibilityLabel(statusLabel)
            }
        }
        .padding(.leading, 6 + CGFloat(depth) * 16)
        .padding(.trailing, 8)
        .frame(height: 25)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Theme.accentSoft : hovering ? Theme.hover.opacity(0.6) : .clear))
        .contentShape(Rectangle())
    }
}

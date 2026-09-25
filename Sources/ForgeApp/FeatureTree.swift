// Feature tree (SolidWorks' FeatureManager; docs/design): the part, its solid bodies, the
// origin planes and the sketches with their state. Until the M2 feature tree exists
// (docs/adr/0011) it lists the document's sketches and bodies; every row action is a command.

import ForgeCommands
import ForgeCore
import ForgeSketch
import ForgeUI
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

    /// Sketches used by a feature are shown under it (absorbed), as in SolidWorks.
    private var absorbed: Set<String> {
        Set(model.features.filter { !$0.isSketch }.compactMap { $0.sketchID })
    }

    @ViewBuilder private var rows: some View {
        if !model.bodies.isEmpty {
            TreeRow(icon: .folder, title: "Solid Bodies (\(model.bodies.count))", depth: 1, disclosure: bodiesOpen) { bodiesOpen.toggle() }
            if bodiesOpen {
                ForEach(model.bodies.filter { matches($0.name) }, id: \.id) { b in
                    TreeRow(icon: .part, title: b.name, depth: 2, selected: model.selection.contains(b.id)) {
                        Task { await model.select(b.id, extend: !NSEvent.modifierFlags.intersection([.shift, .command, .control]).isEmpty) }
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
        let active = model.rollback ?? model.features.count
        ForEach(Array(model.features.enumerated()), id: \.element.id) { index, f in
            if index == active { RollbackBar() }
            if !(f.isSketch && absorbed.contains(f.sketchID ?? "")) && matches(f.name) {
                FeatureNode(feature: f, rolledBack: index >= active)
            }
        }
        if active >= model.features.count && !model.features.isEmpty { RollbackBar() }
        // Sketches from files written before the feature tree have no feature of their own.
        ForEach(model.sketches.filter { s in !model.features.contains { $0.isSketch && $0.sketchID == s.id } && matches(s.name) }) { s in
            FeatureChild(sketch: s, feature: nil)
        }
    }
}

/// The rollback bar: drag it or use its menu to roll back or forward.
private struct RollbackBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Capsule().fill(Theme.accent).frame(height: 3)
        }
        .padding(.horizontal, 8)
        .frame(height: 12)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Roll to Previous") {
                let active = model.rollback ?? model.features.count
                if active > 0 { Task { await model.run("feature.rollback", ["before": .string(model.features[active - 1].id)]) } }
            }
            Button("Roll to End") { Task { await model.run("feature.rollback") } }
        }
        .help("Rollback bar: features below it are not rebuilt. Right-click to move it.")
        .accessibilityLabel("Rollback bar")
    }
}

/// One feature in the tree: status, its absorbed sketch as a child, and SolidWorks' menu.
private struct FeatureNode: View {
    @Environment(AppModel.self) private var model
    let feature: FeatureRow
    let rolledBack: Bool
    @State private var open = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        let sketch = feature.isSketch ? nil : feature.sketchID.flatMap { id in model.sketches.first { $0.id == id } }
        let bodySelected = feature.createdBodies.contains { model.selection.contains($0) }
        TreeRow(
            icon: feature.icon, title: title, depth: 1, disclosure: sketch == nil ? nil : open,
            selected: bodySelected || (feature.isSketch && (model.selection.contains(feature.sketchID ?? "") || model.activeSketch == feature.sketchID)),
            muted: rolledBack || feature.suppressed, iconTint: feature.isSketch ? sketchTint : nil,
            status: statusColor, statusLabel: feature.error ?? "",
            doubleAction: { activate() }
        ) {
            if sketch != nil { open.toggle() }
            select()
        }
        .contextMenu { menu }
        .help(feature.error.map { "\(feature.name): \($0)" } ?? (feature.command == "plane.create" ? "\(feature.name) — double-click to sketch on it" : "\(feature.name) — double-click to edit"))
        .popover(isPresented: $renaming) {
            HStack {
                TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit { rename() }
                Button("Rename") { rename() }.buttonStyle(PanelButtonStyle(prominent: true))
            }
            .padding(10)
        }
        if let sketch, open || sketch.id == model.activeSketch {
            let row = model.features.first { $0.isSketch && $0.sketchID == sketch.id }
            FeatureChild(sketch: sketch, feature: row)
        }
    }

    private var title: String {
        guard feature.isSketch, let s = model.sketches.first(where: { $0.id == feature.sketchID }) else { return feature.name }
        return prefix(s.status) + feature.name
    }

    private func prefix(_ s: SolveStatus?) -> String {
        switch s {
        case .underDefined: "(-) "
        case .redundant, .conflicting: "(+) "
        case .failed: "(?) "
        default: ""
        }
    }

    private var sketchTint: Color {
        SketchStatusBadge.color(model.sketches.first { $0.id == feature.sketchID }?.status)
    }

    private var statusColor: Color? {
        switch feature.state {
        case .error: Theme.overDefined
        case .warning: Theme.preview
        default: nil
        }
    }

    private func select() {
        // With a pattern or mirror open, clicking a feature adds or removes it as a seed.
        if let op = model.operation, [Operation.linearPattern, .circularPattern, .mirror].contains(op), !feature.isSketch {
            if let i = model.form.seeds.firstIndex(of: feature.id) { model.form.seeds.remove(at: i) } else { model.form.seeds.append(feature.id) }
            return
        }
        if feature.isSketch, let s = feature.sketchID {
            Task { await model.select(s, extend: !NSEvent.modifierFlags.intersection([.shift, .command, .control]).isEmpty) }
        } else if !feature.createdBodies.isEmpty && feature.command != "plane.create" {
            Task { await model.select(feature.createdBodies) }
        }
    }

    private func activate() {
        if feature.command == "plane.create", let plane = feature.createdBodies.first {
            Task { await model.newSketch(onPlaneOrFace: plane) }
        } else if feature.isSketch, let s = feature.sketchID {
            Task { await model.editSketch(s) }
        } else if feature.operation != nil {
            model.editFeature(feature)
        }
    }

    private func rename() {
        renaming = false
        let n = newName
        Task { await model.run("feature.rename", ["feature": .string(feature.id), "name": .string(n)]) }
    }

    @ViewBuilder private var menu: some View {
        if feature.command == "plane.create", let plane = feature.createdBodies.first {
            Button("Sketch") { Task { await model.newSketch(onPlaneOrFace: plane) } }
            Button("Edit Feature") { model.editFeature(feature) }
        } else if feature.isSketch, let s = feature.sketchID {
            Button("Edit Sketch") { Task { await model.editSketch(s) } }
        } else {
            if feature.operation != nil { Button("Edit Feature") { model.editFeature(feature) } }
            if let s = feature.sketchID { Button("Edit Sketch") { Task { await model.editSketch(s) } } }
        }
        Divider()
        Button(feature.suppressed ? "Unsuppress" : "Suppress") {
            Task { await model.run("feature.suppress", ["feature": .string(feature.id), "suppressed": .bool(!feature.suppressed)]) }
        }
        Button("Rollback") { Task { await model.run("feature.rollback", ["before": .string(feature.id)]) } }
        Button("Rename") {
            newName = feature.name
            renaming = true
        }
        if let e = feature.error {
            Divider()
            Button("What's Wrong?") { model.lastError = ForgeError(.referenceLost, "\(feature.name): \(e)") }
        }
        Divider()
        Button("Delete", role: .destructive) { Task { await model.run("feature.delete", ["feature": .string(feature.id)]) } }
    }
}

/// The sketch absorbed by a feature, shown under it.
private struct FeatureChild: View {
    @Environment(AppModel.self) private var model
    let sketch: SketchRow
    let feature: FeatureRow?

    var body: some View {
        let prefix = sketch.status == .underDefined ? "(-) " : sketch.status == .redundant || sketch.status == .conflicting ? "(+) " : sketch.status == .failed ? "(?) " : ""
        TreeRow(icon: .sketch, title: prefix + sketch.name, depth: 2, selected: model.selection.contains(sketch.id) || model.activeSketch == sketch.id,
                iconTint: SketchStatusBadge.color(sketch.status), doubleAction: { Task { await model.editSketch(sketch.id) } }) {
            Task { await model.select(sketch.id, extend: false) }
        }
        .contextMenu {
            Button("Edit Sketch") { Task { await model.editSketch(sketch.id) } }
            if let feature {
                Button("Delete", role: .destructive) { Task { await model.run("feature.delete", ["feature": .string(feature.id)]) } }
            }
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

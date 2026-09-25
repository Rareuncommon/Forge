// The FeatureManager tree as data (nodes with their children, actions and context menu), for
// front ends without SwiftUI (Windows). Mirrors Sources/ForgeApp/FeatureTree.swift: bodies
// folder, standard planes, origin, the features in order with their absorbed sketches, and the
// rollback bar.

import ForgeCommands
import ForgeCore
import ForgeSketch

package struct TreeNode {
    package enum State { case normal, suppressed, rolledBack, warning, error }

    package var id: String
    package var icon: ForgeIcon
    package var title: String
    package var tooltip: String
    package var selected: Bool
    package var state: State
    /// The rollback bar (drawn as a separator line).
    package var isRollbackBar: Bool
    package var children: [TreeNode]
    /// Click; `extend` = ⇧/Ctrl held.
    package var select: ((_ extend: Bool) -> Void)?
    /// Double-click (edit the feature or sketch, sketch on the plane).
    package var activate: (() -> Void)?
    package var menu: [(title: String, action: () -> Void)]

    package init(id: String, icon: ForgeIcon, title: String, tooltip: String = "", selected: Bool = false, state: State = .normal, isRollbackBar: Bool = false,
         children: [TreeNode] = [], select: ((Bool) -> Void)? = nil, activate: (() -> Void)? = nil, menu: [(title: String, action: () -> Void)] = []) {
        self.id = id
        self.icon = icon
        self.title = title
        self.tooltip = tooltip
        self.selected = selected
        self.state = state
        self.isRollbackBar = isRollbackBar
        self.children = children
        self.select = select
        self.activate = activate
        self.menu = menu
    }

    /// Everything a native tree shows (for deciding whether to rebuild it).
    package var signature: String {
        "\(id)|\(title)|\(selected)|\(state)|\(isRollbackBar)|\(menu.map(\.title))[" + children.map(\.signature).joined(separator: ",") + "]"
    }
}

extension AppModel {
    /// The tree's top-level nodes (under the part).
    package var treeNodes: [TreeNode] {
        let filter = treeFilter.trimmingCharacters(in: .whitespaces)
        func matches(_ name: String) -> Bool { filter.isEmpty || name.localizedCaseInsensitiveContains(filter) }
        var out: [TreeNode] = []
        if !bodies.isEmpty {
            let kids = bodies.filter { matches($0.name) }.map { b in
                TreeNode(
                    id: b.id, icon: .part, title: b.name, tooltip: "\(b.name): \(b.topology.faces) faces, \(String(format: "%.1f", b.volumeMM3)) mm³",
                    selected: selection.contains(b.id), select: { [unowned self] extend in Task { await select(b.id, extend: extend) } },
                    menu: [
                        ("Mass Properties", { [unowned self] in Task { await select(b.id, extend: false); begin(.massProperties) } }),
                        ("Export STEP…", { [unowned self] in Task { await select(b.id, extend: false); export("step") } }),
                        ("Export STL…", { [unowned self] in Task { await select(b.id, extend: false); export("stl") } }),
                    ])
            }
            out.append(TreeNode(id: "bodies", icon: .folder, title: "Solid Bodies (\(bodies.count))", children: kids))
        }
        for p in StandardPlane.allCases where matches(p.rawValue + " plane") {
            let name = "\(p.rawValue.capitalized) Plane"
            out.append(TreeNode(
                id: "plane-" + p.rawValue, icon: .plane, title: name, tooltip: "Double-click to sketch on this plane",
                activate: { [unowned self] in Task { await newSketch(on: p) } }, menu: [("Sketch on \(name)", { [unowned self] in Task { await newSketch(on: p) } })]))
        }
        if matches("origin") { out.append(TreeNode(id: "origin", icon: .origin, title: "Origin")) }
        let absorbed = Set(features.filter { !$0.isSketch }.compactMap(\.sketchID))
        let active = rollback ?? features.count
        for (index, f) in features.enumerated() {
            if index == active { out.append(rollbackBar) }
            if !(f.isSketch && absorbed.contains(f.sketchID ?? "")) && matches(f.name) {
                out.append(featureNode(f, rolledBack: index >= active))
            }
        }
        if active >= features.count && !features.isEmpty { out.append(rollbackBar) }
        // Sketches from files written before the feature tree have no feature of their own.
        for s in sketches where !features.contains(where: { $0.isSketch && $0.sketchID == s.id }) && matches(s.name) {
            out.append(sketchNode(s, feature: nil))
        }
        return out
    }

    private var rollbackBar: TreeNode {
        TreeNode(
            id: "rollback", icon: .history, title: "Rollback bar", tooltip: "Features below it are not rebuilt. Right-click to move it.", isRollbackBar: true,
            menu: [
                ("Roll to Previous", { [unowned self] in
                    let active = rollback ?? features.count
                    if active > 0 { Task { await run("feature.rollback", ["before": .string(features[active - 1].id)]) } }
                }),
                ("Roll to End", { [unowned self] in Task { await run("feature.rollback") } }),
            ])
    }

    /// "(-) Sketch1" for under defined sketches, as SolidWorks prefixes them.
    private func sketchNode(_ s: SketchRow, feature: FeatureRow?) -> TreeNode {
        let prefix = s.status == .underDefined ? "(-) " : s.status == .redundant || s.status == .conflicting ? "(+) " : s.status == .failed ? "(?) " : ""
        var menu: [(title: String, action: () -> Void)] = [("Edit Sketch", { [unowned self] in Task { await editSketch(s.id) } })]
        if let feature { menu.append(("Delete", { [unowned self] in Task { await run("feature.delete", ["feature": .string(feature.id)]) } })) }
        return TreeNode(
            id: s.id, icon: .sketch, title: prefix + s.name, selected: selection.contains(s.id) || activeSketch == s.id,
            state: s.status == .conflicting || s.status == .failed ? .warning : .normal,
            select: { [unowned self] extend in Task { await select(s.id, extend: extend) } }, activate: { [unowned self] in Task { await editSketch(s.id) } }, menu: menu)
    }

    private func featureNode(_ f: FeatureRow, rolledBack: Bool) -> TreeNode {
        let state: TreeNode.State = rolledBack ? .rolledBack : f.suppressed ? .suppressed : f.state == .error ? .error : f.state == .warning ? .warning : .normal
        var menu: [(title: String, action: () -> Void)] = []
        if f.command == "plane.create", let plane = f.createdBodies.first {
            menu.append(("Sketch", { [unowned self] in Task { await newSketch(onPlaneOrFace: plane) } }))
            menu.append(("Edit Feature", { [unowned self] in editFeature(f) }))
        } else if f.isSketch, let s = f.sketchID {
            menu.append(("Edit Sketch", { [unowned self] in Task { await editSketch(s) } }))
        } else {
            if f.operation != nil { menu.append(("Edit Feature", { [unowned self] in editFeature(f) })) }
            if let s = f.sketchID { menu.append(("Edit Sketch", { [unowned self] in Task { await editSketch(s) } })) }
        }
        menu.append((f.suppressed ? "Unsuppress" : "Suppress", { [unowned self] in
            Task { await run("feature.suppress", ["feature": .string(f.id), "suppressed": .bool(!f.suppressed)]) }
        }))
        menu.append(("Rollback", { [unowned self] in Task { await run("feature.rollback", ["before": .string(f.id)]) } }))
        if let e = f.error { menu.append(("What's Wrong?", { [unowned self] in lastError = ForgeError(.referenceLost, "\(f.name): \(e)") })) }
        menu.append(("Delete", { [unowned self] in Task { await run("feature.delete", ["feature": .string(f.id)]) } }))
        var children: [TreeNode] = []
        if !f.isSketch, let sid = f.sketchID, let s = sketches.first(where: { $0.id == sid }) {
            children.append(sketchNode(s, feature: features.first { $0.isSketch && $0.sketchID == sid }))
        }
        if f.isSketch, let sid = f.sketchID, let s = sketches.first(where: { $0.id == sid }) {
            var node = sketchNode(s, feature: f)
            node.id = f.id
            node.state = rolledBack ? .rolledBack : f.suppressed ? .suppressed : node.state
            node.menu = menu
            return node
        }
        let bodySelected = f.createdBodies.contains { selection.contains($0) }
        return TreeNode(
            id: f.id, icon: f.icon, title: f.name, tooltip: f.error ?? "", selected: bodySelected, state: state, children: children,
            select: { [unowned self] _ in treeSelect(f) }, activate: { [unowned self] in treeActivate(f) }, menu: menu)
    }

    /// Click on a feature: toggles it as a seed while a pattern or mirror is open, otherwise
    /// selects its bodies.
    package func treeSelect(_ f: FeatureRow) {
        if let op = operation, [Operation.linearPattern, .circularPattern, .mirror].contains(op), !f.isSketch {
            if let i = form.seeds.firstIndex(of: f.id) { form.seeds.remove(at: i) } else { form.seeds.append(f.id) }
            return
        }
        if !f.createdBodies.isEmpty && f.command != "plane.create" {
            Task { await select(f.createdBodies) }
        }
    }

    /// Double-click on a feature: sketch on a plane, edit a sketch, or edit the feature.
    package func treeActivate(_ f: FeatureRow) {
        if f.command == "plane.create", let plane = f.createdBodies.first {
            Task { await newSketch(onPlaneOrFace: plane) }
        } else if f.isSketch, let s = f.sketchID {
            Task { await editSketch(s) }
        } else if f.operation != nil {
            editFeature(f)
        }
    }
}

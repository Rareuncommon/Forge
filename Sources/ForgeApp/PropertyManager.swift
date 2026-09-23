// PropertyManager (docs/design): the options of the operation in progress with OK / Cancel and
// collapsible groups; otherwise the sketch being edited or the selection. OK runs commands on
// the bus.

import ForgeCommands
import ForgeCore
import ForgeSketch
import SwiftUI

/// Values being edited in the PropertyManager. Lengths are text so units work ("0.5 in").
struct OperationForm {
    var depth = "10"
    var direction = "normal"
    var axis = ""
    var angle = "360"
    var radius = "2"
    var combine = "fuse"
    var target = ""
    var tool = ""
    var width = "50", height = "30", boxDepth = "20"
    var cylRadius = "10", cylHeight = "40"
    var sphereRadius = "15"
    var coneBase = "10", coneTop = "0", coneHeight = "20"
    var torusMajor = "20", torusMinor = "4"
    var dimensionValue = ""
    var offsetDistance = "2", offsetReverse = false, offsetBoth = false, offsetCaps = false
    var mirrorAxis = ""
    var patternCount = "3", patternSpacing = "10", patternDirection = "0"
    var patternCount2 = "1", patternSpacing2 = "10"
    var circularCount = "6", circularAngle = "360", circularCenter = "0, 0"
    var result: JSONValue?
}

extension AppModel {
    /// Start an operation: its options appear in the PropertyManager.
    func begin(_ op: Operation) {
        form.result = nil
        switch op {
        case .extrude, .revolve, .cutExtrude:
            if operationSketch == nil || !sketches.contains(where: { $0.id == operationSketch }) {
                operationSketch = activeSketch ?? selection.first(where: { $0.hasPrefix("sketch-") && !$0.contains("/") }) ?? sketches.last?.id
            }
            if op == .cutExtrude, !bodies.contains(where: { $0.id == form.target }) {
                form.target = selectedBodies.first ?? bodies.last?.id ?? ""
            }
        case .combine where bodies.count >= 2:
            form.target = selectedBodies.first ?? bodies[0].id
            form.tool = selectedBodies.dropFirst().first ?? bodies.first { $0.id != form.target }?.id ?? ""
        case .sketchMirror:
            if let sk = sketchState.sketch {
                form.mirrorAxis = sketchSelection.last(where: { sk.entities[$0]?.kind == .line }) ?? ""
            }
        default:
            break
        }
        if op.isSketchOperation { sketchState.tool = nil; clearPreview() }
        operation = op
        switch op {
        case .massProperties: Task { await computeMassProperties() }
        case .measure: Task { await computeMeasure() }
        case .check: Task { await computeCheck() }
        default: break
        }
    }

    func cancelOperation() {
        operation = nil
        form.result = nil
    }

    /// Number when it parses, otherwise the text (a quantity with units, e.g. "0.5 in").
    func quantity(_ text: String) -> JSONValue {
        let t = text.trimmingCharacters(in: .whitespaces)
        return Double(t).map { .number($0) } ?? .string(t)
    }

    func angleQuantity(_ text: String) -> JSONValue {
        let t = text.trimmingCharacters(in: .whitespaces)
        return .string(Double(t) != nil ? t + " deg" : t)
    }

    private func count(_ text: String) -> JSONValue { .number(Double(Int(text.trimmingCharacters(in: .whitespaces)) ?? 1)) }

    func commitOperation() async {
        guard let op = operation else { return }
        var ok: CommandOutcome?
        let local = sketchSelection
        switch op {
        case .extrude:
            guard let sk = operationSketch else { return }
            if activeSketch != nil { await exitSketch() }
            ok = await run("body.extrude", ["sketch": .string(sk), "depth": quantity(form.depth), "direction": .string(form.direction)])
        case .cutExtrude:
            guard let sk = operationSketch, !form.target.isEmpty else { return }
            if activeSketch != nil { await exitSketch() }
            // One undo step: the tool body and the subtraction.
            guard await run("transaction.begin", ["label": "Cut-Extrude"]) != nil else { return }
            if let tool = await run("body.extrude", ["sketch": .string(sk), "depth": quantity(form.depth), "direction": .string(form.direction)]),
                let id = tool.changes.created.first(where: { $0.hasPrefix("body-") }),
                await run("body.boolean", ["operation": "cut", "target": .string(form.target), "tool": .string(id)]) != nil
            {
                ok = await run("transaction.commit")
            } else {
                let error = lastError
                await run("transaction.rollback")
                lastError = error
            }
        case .revolve:
            guard let sk = operationSketch else { return }
            if activeSketch != nil { await exitSketch() }
            ok = await run("body.revolve", ["sketch": .string(sk), "axis": .string(form.axis), "angle": angleQuantity(form.angle)])
        case .fillet:
            let edges = selectedEdges
            guard let body = edges.first?.split(separator: "/").first else {
                lastError = ForgeError(.invalidParams, "select the edges to fillet in the viewport first")
                return
            }
            ok = await run("body.fillet_edges", ["body": .string(String(body)), "edges": .array(edges.map { .string($0) }), "radius": quantity(form.radius)])
        case .combine:
            ok = await run("body.boolean", ["operation": .string(form.combine), "target": .string(form.target), "tool": .string(form.tool)])
        case .primitive(let p):
            switch p {
            case .box: ok = await run("body.create_box", ["width": quantity(form.width), "height": quantity(form.height), "depth": quantity(form.boxDepth)])
            case .cylinder: ok = await run("body.create_cylinder", ["radius": quantity(form.cylRadius), "height": quantity(form.cylHeight)])
            case .sphere: ok = await run("body.create_sphere", ["radius": quantity(form.sphereRadius)])
            case .cone:
                ok = await run("body.create_cone", ["base_radius": quantity(form.coneBase), "top_radius": quantity(form.coneTop), "height": quantity(form.coneHeight)])
            case .torus: ok = await run("body.create_torus", ["major_radius": quantity(form.torusMajor), "minor_radius": quantity(form.torusMinor)])
            }
        case .massProperties, .measure, .check:
            operation = nil
            return
        case .dimension:
            await smartDimension(value: form.dimensionValue)
            if lastError == nil { form.dimensionValue = ""; operation = nil }
            return
        case .addRelation:
            operation = nil
            return
        case .sketchOffset:
            ok = await run("sketch.offset", [
                "entities": .array(local.map { .string($0) }), "distance": quantity(form.offsetDistance), "reverse": .bool(form.offsetReverse),
                "bidirectional": .bool(form.offsetBoth), "cap_ends": .bool(form.offsetCaps),
            ])
        case .sketchMirror:
            let entities = local.filter { $0 != form.mirrorAxis }
            ok = await run("sketch.mirror", ["entities": .array(entities.map { .string($0) }), "axis": .string(form.mirrorAxis)])
        case .sketchLinearPattern:
            var p: [String: JSONValue] = [
                "entities": .array(local.map { .string($0) }), "count": count(form.patternCount), "spacing": quantity(form.patternSpacing),
                "direction": angleQuantity(form.patternDirection),
            ]
            if (Int(form.patternCount2) ?? 1) > 1 {
                p["count2"] = count(form.patternCount2)
                p["spacing2"] = quantity(form.patternSpacing2)
            }
            ok = await run("sketch.pattern_linear", .object(p))
        case .sketchCircularPattern:
            let c = form.circularCenter.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            var p: [String: JSONValue] = ["entities": .array(local.map { .string($0) }), "count": count(form.circularCount), "angle": angleQuantity(form.circularAngle)]
            if c.count == 2 { p["center"] = [.number(c[0]), .number(c[1])] }
            ok = await run("sketch.pattern_circular", .object(p))
        }
        if ok != nil {
            let wasSketchOp = op.isSketchOperation
            operation = nil
            if !wasSketchOp { zoomToFit() }
        }
    }

    func computeMassProperties() async {
        guard let b = selectedBodies.first ?? bodies.first?.id else { return }
        form.result = try? await engine.execute("query.mass_properties", ["body": .string(b)]).result
    }

    func computeMeasure() async {
        let refs = selection.filter { !$0.hasPrefix("sketch-") }
        guard refs.count == 2 else {
            form.result = nil
            return
        }
        form.result = try? await engine.execute("query.measure", ["from": .string(refs[0]), "to": .string(refs[1])]).result
    }

    func computeCheck() async {
        var p: [String: JSONValue] = [:]
        if let b = selectedBodies.first { p["body"] = .string(b) }
        form.result = try? await engine.execute("query.validate", .object(p)).result
    }

    /// Lines of the sketch used by the operation (revolve axes).
    func sketchLines(_ sketch: String?) async -> [String] {
        guard let id = sketch, let doc = await engine.activeDocument, let sk = doc.sketches[id] else { return [] }
        return sk.orderedEntities.filter { $0.kind == .line }.map(\.id)
    }
}

struct PropertyManagerView: View {
    @Environment(AppModel.self) private var model
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let op = model.operation {
                        OperationPanel(op: op)
                    } else if model.activeSketch != nil {
                        SketchPanel()
                    } else {
                        SelectionPanel()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Theme.line2).frame(height: 1)
            PMGroup("History", isOpen: $showHistory) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.log.suffix(60).enumerated().reversed()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .background(Theme.panel)
    }
}

// MARK: components

struct PMHeader: View {
    let icon: ForgeIcon
    let title: String
    var subtitle: String = ""
    var onOK: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var okEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                IconView(icon: icon, size: 22, accent: Theme.accent)
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(2) }
                }
            }
            if onOK != nil || onCancel != nil {
                HStack(spacing: 6) {
                    if let onOK {
                        Button(action: onOK) {
                            IconView(icon: .check, size: 17).foregroundStyle(.white)
                                .frame(width: 34, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!okEnabled)
                        .opacity(okEnabled ? 1 : 0.45)
                        .help("OK (↩)")
                    }
                    if let onCancel {
                        Button(action: onCancel) {
                            IconView(icon: .xmark, size: 17).foregroundStyle(Theme.text2)
                                .frame(width: 34, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .help("Cancel (Esc)")
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// A collapsible group box.
struct PMGroup<Content: View>: View {
    let title: String
    @Binding var isOpen: Bool
    @ViewBuilder let content: Content

    init(_ title: String, isOpen: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isOpen = isOpen
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 7) {
                    IconView(icon: isOpen ? .chevronDown : .chevronRight, size: 12).foregroundStyle(Theme.text3)
                    Text(title).font(Theme.groupTitle).foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 9) { content }
                    .padding(EdgeInsets(top: 2, leading: 14, bottom: 14, trailing: 14))
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line2).frame(height: 1) }
    }
}

/// A group that stays open (most option groups).
struct PMSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @State private var open = true

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        PMGroup(title, isOpen: $open) { content }
    }
}

struct PMField: View {
    let label: String
    @Binding var text: String
    var unit = ""
    var icon: ForgeIcon? = nil
    var help = ""

    var body: some View {
        HStack(spacing: 8) {
            if let icon { IconView(icon: icon, size: 16, accent: Theme.accent).foregroundStyle(Theme.text2) }
            Text(label).font(Theme.label).foregroundStyle(Theme.text2).frame(width: 74, alignment: .leading)
            HStack(spacing: 4) {
                TextField(label, text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.text)
                    .labelsHidden()
                if !unit.isEmpty { Text(unit).font(.system(size: 11.5)).foregroundStyle(Theme.text3) }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.fieldLine))
        }
        .help(help)
    }
}

struct PMPicker<Value: Hashable, Options: View>: View {
    let label: String
    @Binding var selection: Value
    var icon: ForgeIcon? = nil
    @ViewBuilder let options: Options

    var body: some View {
        HStack(spacing: 8) {
            if let icon { IconView(icon: icon, size: 16, accent: Theme.accent).foregroundStyle(Theme.text2) }
            if !label.isEmpty { Text(label).font(Theme.label).foregroundStyle(Theme.text2).frame(width: 74, alignment: .leading) }
            Picker(label, selection: $selection) { options }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
        }
    }
}

struct PMCheckbox: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.text) }
            .toggleStyle(.checkbox)
    }
}

/// A selection box: the entities an operation acts on, outlined in the accent colour.
struct PMSelectionBox: View {
    let items: [(icon: ForgeIcon, text: String)]
    var placeholder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.isEmpty {
                Text(placeholder).font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    IconView(icon: item.icon, size: 14, accent: Theme.accent)
                    Text(item.text).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accentSoft))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(items.isEmpty ? Theme.line : Theme.accent, lineWidth: 1.5))
    }
}

struct PMNote: View {
    let text: String
    var warning = false

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(warning ? Theme.overDefined : Theme.text2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chrome2))
    }
}

// MARK: panels

private func entityIcon(_ ref: String) -> ForgeIcon {
    if ref.contains("/face-") { return .plane }
    if ref.contains("/edge-") { return .line }
    if ref.contains("/vertex-") { return .point }
    if ref.hasPrefix("sketch-") {
        let local = ref.split(separator: "/").last.map(String.init) ?? ""
        for (prefix, icon) in [("line", ForgeIcon.line), ("circle", .circle), ("arc", .arc), ("point", .point), ("spline", .spline), ("ellipse", .ellipse)]
        where local.hasPrefix(prefix) {
            return icon
        }
        return .sketch
    }
    return .part
}

private func shortName(_ ref: String) -> String {
    ref.split(separator: "/").map(String.init).joined(separator: " · ")
}

private struct OperationPanel: View {
    @Environment(AppModel.self) private var model
    let op: Operation
    @State private var lines: [String] = []

    var body: some View {
        @Bindable var model = model
        let commit: (() -> Void)? = op.isReport || op == .addRelation ? nil : { Task { await model.commitOperation() } }
        PMHeader(icon: op.icon, title: op.title, subtitle: subtitle, onOK: commit, onCancel: { model.cancelOperation() })
        switch op {
        case .extrude, .cutExtrude, .revolve:
            PMSection("Profile") {
                PMPicker(label: "Sketch", selection: Binding(get: { model.operationSketch ?? "" }, set: { model.operationSketch = $0 }), icon: .sketch) {
                    ForEach(model.sketches) { Text($0.name).tag($0.id) }
                }
            }
            if op == .revolve {
                PMSection("Axis") {
                    PMPicker(label: "Axis", selection: $model.form.axis, icon: .axis) {
                        Text("Choose a sketch line").tag("")
                        ForEach(lines, id: \.self) { Text($0).tag($0) }
                    }
                    .task(id: model.operationSketch) { lines = await model.sketchLines(model.operationSketch) }
                }
                PMSection("Direction 1") {
                    PMField(label: "Angle", text: $model.form.angle, unit: "°", icon: .arc)
                }
            } else {
                PMSection("Direction 1") {
                    PMPicker(label: "", selection: $model.form.direction, icon: op.icon) {
                        Text("Blind").tag("normal")
                        Text("Blind, reversed").tag("reverse")
                        Text("Mid Plane").tag("mid_plane")
                    }
                    PMField(label: "Depth", text: $model.form.depth, unit: "mm", icon: .smartDimension, help: "mm, or with units: 0.5 in")
                }
            }
            if op == .cutExtrude {
                PMSection("Feature Scope") {
                    PMPicker(label: "Cut body", selection: $model.form.target, icon: .part) {
                        ForEach(model.bodies, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
            }
            PMNote(text: "Uses the sketch's closed profile; holes and islands are kept. Units work anywhere: 25, 1 in, 12.5 mm.")
                .padding(14)
        case .fillet:
            PMSection("Items to Fillet") {
                PMSelectionBox(items: model.selectedEdges.map { (icon: ForgeIcon.line, text: shortName($0)) }, placeholder: "Select edges in the view (⇧-click adds)")
                PMField(label: "Radius", text: $model.form.radius, unit: "mm", icon: .smartDimension)
            }
        case .combine:
            PMSection("Operation Type") {
                PMPicker(label: "", selection: $model.form.combine, icon: .combine) {
                    Text("Add").tag("fuse")
                    Text("Subtract").tag("cut")
                    Text("Common").tag("common")
                }
            }
            PMSection("Bodies") {
                PMPicker(label: "Main body", selection: $model.form.target) {
                    ForEach(model.bodies, id: \.id) { Text($0.name).tag($0.id) }
                }
                PMPicker(label: model.form.combine == "cut" ? "Subtract" : "With", selection: $model.form.tool) {
                    ForEach(model.bodies, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
        case .primitive(let p):
            PMSection("Size") {
                switch p {
                case .box:
                    PMField(label: "Width", text: $model.form.width, unit: "mm")
                    PMField(label: "Height", text: $model.form.height, unit: "mm")
                    PMField(label: "Depth", text: $model.form.boxDepth, unit: "mm")
                case .cylinder:
                    PMField(label: "Radius", text: $model.form.cylRadius, unit: "mm")
                    PMField(label: "Height", text: $model.form.cylHeight, unit: "mm")
                case .sphere:
                    PMField(label: "Radius", text: $model.form.sphereRadius, unit: "mm")
                case .cone:
                    PMField(label: "Base radius", text: $model.form.coneBase, unit: "mm")
                    PMField(label: "Top radius", text: $model.form.coneTop, unit: "mm")
                    PMField(label: "Height", text: $model.form.coneHeight, unit: "mm")
                case .torus:
                    PMField(label: "Major radius", text: $model.form.torusMajor, unit: "mm")
                    PMField(label: "Minor radius", text: $model.form.torusMinor, unit: "mm")
                }
            }
        case .massProperties, .measure, .check:
            PMSection("Results") {
                if let r = model.form.result {
                    KeyValueList(value: r)
                } else {
                    Text(op == .measure ? "Select two faces, edges, vertices or bodies." : "Select a body.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
            .task(id: model.selection) {
                switch op {
                case .measure: await model.computeMeasure()
                case .massProperties: await model.computeMassProperties()
                case .check: await model.computeCheck()
                default: break
                }
            }
        case .dimension:
            SelectedEntities()
            PMSection("Value") {
                PMField(label: "Value", text: $model.form.dimensionValue, icon: .smartDimension, help: "Empty keeps the current size; units work: 1 in, 30 deg")
                PMNote(text: "One line → length · circle → diameter · arc → radius · two lines → angle · two points → distance.")
            }
        case .addRelation:
            SelectedEntities()
            RelationButtons()
        case .sketchOffset:
            SelectedEntities()
            PMSection("Parameters") {
                PMField(label: "Distance", text: $model.form.offsetDistance, unit: "mm", icon: .smartDimension)
                PMCheckbox(label: "Reverse", isOn: $model.form.offsetReverse)
                PMCheckbox(label: "Both directions", isOn: $model.form.offsetBoth)
                PMCheckbox(label: "Cap ends", isOn: $model.form.offsetCaps)
            }
        case .sketchMirror:
            SelectedEntities()
            PMSection("Mirror About") {
                PMPicker(label: "Axis", selection: $model.form.mirrorAxis, icon: .centerline) {
                    Text("Choose a selected line").tag("")
                    ForEach(model.sketchSelection.filter { model.sketchState.sketch?.entities[$0]?.kind == .line }, id: \.self) { Text($0).tag($0) }
                }
            }
        case .sketchLinearPattern:
            SelectedEntities()
            PMSection("Direction 1") {
                PMField(label: "Instances", text: $model.form.patternCount, icon: .linearPattern)
                PMField(label: "Spacing", text: $model.form.patternSpacing, unit: "mm", icon: .smartDimension)
                PMField(label: "Angle", text: $model.form.patternDirection, unit: "°", icon: .arc)
            }
            PMSection("Direction 2") {
                PMField(label: "Instances", text: $model.form.patternCount2, icon: .linearPattern)
                PMField(label: "Spacing", text: $model.form.patternSpacing2, unit: "mm", icon: .smartDimension)
            }
        case .sketchCircularPattern:
            SelectedEntities()
            PMSection("Parameters") {
                PMField(label: "Instances", text: $model.form.circularCount, icon: .circularPattern)
                PMField(label: "Total angle", text: $model.form.circularAngle, unit: "°", icon: .arc)
                PMField(label: "Centre", text: $model.form.circularCenter, unit: "u, v", icon: .point)
            }
        }
    }

    private var subtitle: String {
        switch op {
        case .extrude, .cutExtrude, .revolve: model.sketches.first { $0.id == model.operationSketch }?.name ?? "Choose a sketch"
        case .fillet: "Constant radius"
        case .dimension, .addRelation, .sketchOffset, .sketchMirror, .sketchLinearPattern, .sketchCircularPattern:
            "\(model.sketchSelection.count) selected"
        default: ""
        }
    }
}

private struct SelectedEntities: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PMSection("Selected Entities") {
            PMSelectionBox(
                items: model.sketchSelection.map { (icon: entityIcon("sketch-x/" + $0), text: $0) },
                placeholder: "Click sketch entities in the view (⇧-click adds)")
        }
    }
}

private struct RelationButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PMSection("Add Relations") {
            let options = model.applicableRelations
            if options.isEmpty {
                Text(model.sketchSelection.isEmpty ? "Select sketch entities to relate." : "No relation applies to this selection.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
            } else {
                FlowRow(spacing: 6) {
                    ForEach(options, id: \.self) { r in
                        Button(r.title) { Task { await model.addRelation(r) } }
                            .buttonStyle(PanelButtonStyle())
                    }
                }
            }
        }
    }
}

extension RelationType {
    var title: String {
        switch self {
        case .onEntity: "On Entity"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// Wraps children onto new lines (relation buttons).
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

private struct SketchPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let row = model.sketches.first { $0.id == model.activeSketch }
        if let tool = model.sketchState.tool {
            PMHeader(icon: tool.icon, title: tool.title.replacingOccurrences(of: "\n", with: " "), subtitle: tool.hint,
                     onCancel: { model.chooseTool(nil) })
        } else {
            PMHeader(icon: .sketch, title: row?.name ?? "Sketch", subtitle: "on \(row?.plane ?? "") Plane",
                     onOK: { Task { await model.exitSketch() } })
        }
        if let row { DOFCard(row: row).padding(EdgeInsets(top: 12, leading: 14, bottom: 4, trailing: 14)) }
        if let tool = model.sketchState.tool {
            switch tool {
            case .fillet:
                PMSection("Fillet Parameters") {
                    PMField(label: "Radius", text: numberBinding(\.filletRadius), unit: "mm", icon: .smartDimension)
                }
            case .chamfer:
                PMSection("Chamfer Parameters") {
                    PMField(label: "Distance", text: numberBinding(\.chamferDistance), unit: "mm", icon: .smartDimension)
                }
            case .polygon:
                PMSection("Parameters") {
                    PMField(label: "Sides", text: Binding(get: { String(model.sketchState.polygonSides) },
                                                          set: { model.sketchState.polygonSides = max(3, Int($0) ?? model.sketchState.polygonSides) }),
                            icon: .polygon)
                }
            case .rectangle:
                PMSection("Rectangle Type") {
                    PMPicker(label: "", selection: $model.sketchState.rectangleFromCenter, icon: .rectangle) {
                        Text("Corner rectangle").tag(false)
                        Text("Center rectangle").tag(true)
                    }
                }
            default:
                EmptyView()
            }
        }
        if !model.sketchSelection.isEmpty {
            SelectedEntities()
            ExistingRelations()
            RelationButtons()
            PMSection("Actions") {
                FlowRow(spacing: 6) {
                    Button("Smart Dimension") { model.begin(.dimension) }.buttonStyle(PanelButtonStyle())
                    Button("Construction") { Task { await model.toggleConstruction() } }.buttonStyle(PanelButtonStyle())
                    Button("Delete") { Task { await model.deleteSketchSelection() } }.buttonStyle(PanelButtonStyle())
                }
            }
        } else if model.sketchState.tool == nil {
            PMNote(text: "Pick a tool in the Sketch tab, or click curves to select them and add relations and dimensions. Double-click a dimension in the view to change it.")
                .padding(14)
        }
    }

    private func numberBinding(_ key: WritableKeyPath<SketchUIState, Double>) -> Binding<String> {
        Binding(
            get: { String(format: "%g", model.sketchState[keyPath: key]) },
            set: { if let v = Double($0), v > 0 { model.sketchState[keyPath: key] = v } })
    }
}

/// Status and remaining freedom of the sketch being edited.
struct DOFCard: View {
    let row: SketchRow

    var body: some View {
        let color = SketchStatusBadge.color(row.status)
        let fixed = max(0, row.unknowns - row.dof)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(row.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                StatusDotLabel(text: SketchStatusBadge.text(row).components(separatedBy: " · ").first ?? "", color: color)
                    .font(.system(size: 11.5))
            }
            if row.unknowns > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        Capsule().fill(color).frame(width: g.size.width * CGFloat(fixed) / CGFloat(max(1, row.unknowns)))
                    }
                }
                .frame(height: 5)
            }
            HStack {
                Text(row.status == .underDefined ? "\(row.dof) degree\(row.dof == 1 ? "" : "s") of freedom left" : SketchStatusBadge.text(row))
                Spacer()
                if row.unknowns > 0 { Text("\(fixed) / \(row.unknowns)").font(.system(size: 11.5, design: .monospaced)) }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.text2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

private struct ExistingRelations: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let picked = Set(model.sketchSelection)
        let related = (model.sketchState.sketch?.userConstraints ?? []).filter { c in c.entities.contains { picked.contains($0) } }
        if !related.isEmpty {
            PMSection("Existing Relations") {
                ForEach(related, id: \.id) { c in
                    HStack(spacing: 8) {
                        Text(AppModel.glyph(c.kind) ?? (c.kind.isDimension ? "↔" : "•"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.relation)
                            .frame(width: 16, height: 16)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.relation, lineWidth: 1.2))
                        Text(c.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized + (c.value.map { v in c.kind == .angle ? String(format: " %.1f°", v * 180 / .pi) : String(format: " %.2f", v) } ?? ""))
                            .font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer()
                        Button {
                            Task { await model.run("sketch.delete", ["items": [.string(c.id)]]) }
                        } label: { IconView(icon: .xmark, size: 12).foregroundStyle(Theme.text3) }
                            .buttonStyle(.plain)
                            .help("Delete this relation")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field))
                }
            }
        }
    }
}

private struct SelectionPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selection.isEmpty {
            PMHeader(icon: .part, title: model.documentName, subtitle: "\(model.bodies.count) bodies · \(model.sketches.count) sketches")
            PMNote(text: "Click a face, edge or body to inspect it. Start a sketch by double-clicking a plane in the tree, or add a primitive from the Features tab.")
                .padding(14)
        } else {
            PMHeader(icon: entityIcon(model.selection[0]), title: model.selection.count == 1 ? shortName(model.selection[0]) : "\(model.selection.count) selected",
                     subtitle: "Selection")
            PMSection("Selected") {
                PMSelectionBox(items: model.selection.map { (icon: entityIcon($0), text: shortName($0)) })
            }
            if let info = model.inspector {
                PMSection("Properties") { KeyValueList(value: info) }
            }
        }
    }
}

/// A JSON result as readable rows (nested objects flattened, numbers rounded).
struct KeyValueList: View {
    let value: JSONValue

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(Array(rows(value, prefix: "").enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(Theme.text2)
                    Text(row.1).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled)
                }
                .font(.system(size: 11.5))
            }
        }
    }

    private func rows(_ v: JSONValue, prefix: String) -> [(String, String)] {
        switch v {
        case .object(let o):
            return o.keys.sorted().flatMap { k in rows(o[k]!, prefix: prefix.isEmpty ? k : "\(prefix).\(k)") }
        default:
            return [(prefix.replacingOccurrences(of: "_", with: " "), format(v))]
        }
    }

    private func format(_ v: JSONValue) -> String {
        switch v {
        case .number(let d): return d == d.rounded() && abs(d) < 1e12 ? String(Int(d)) : String(format: "%.4g", d)
        case .string(let s): return s
        case .bool(let b): return b ? "yes" : "no"
        case .array(let a): return "(" + a.map(format).joined(separator: ", ") + ")"
        case .null: return "—"
        case .object: return "…"
        }
    }
}

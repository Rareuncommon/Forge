// Property panel (SolidWorks' PropertyManager): the options of the operation in progress with
// OK / Cancel, otherwise sketch or selection details. OK runs one command on the bus.

import ForgeCommands
import ForgeCore
import ForgeSketch
import SwiftUI

/// Values being edited in the property panel. Lengths are text so units work ("0.5 in").
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
    var result: JSONValue?
}

extension AppModel {
    /// Start an operation: its options appear in the property panel.
    func begin(_ op: Operation) {
        form.result = nil
        if op == .extrude || op == .revolve {
            if operationSketch == nil || !sketches.contains(where: { $0.id == operationSketch }) {
                operationSketch = activeSketch ?? selection.first(where: { $0.hasPrefix("sketch-") && !$0.contains("/") }) ?? sketches.last?.id
            }
        }
        if op == .combine, bodies.count >= 2 {
            form.target = selectedBodies.first ?? bodies[0].id
            form.tool = selectedBodies.dropFirst().first ?? bodies.first { $0.id != form.target }?.id ?? ""
        }
        operation = op
        if op == .massProperties { Task { await computeMassProperties() } }
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

    func commitOperation() async {
        guard let op = operation else { return }
        var ok: CommandOutcome?
        switch op {
        case .extrude:
            guard let sk = operationSketch else { return }
            if activeSketch != nil { await exitSketch() }
            ok = await run("body.extrude", ["sketch": .string(sk), "depth": quantity(form.depth), "direction": .string(form.direction)])
        case .revolve:
            guard let sk = operationSketch else { return }
            if activeSketch != nil { await exitSketch() }
            ok = await run("body.revolve", ["sketch": .string(sk), "axis": .string(form.axis), "angle": .string(form.angle + " deg")])
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
            }
        case .massProperties:
            operation = nil
            return
        }
        if ok != nil {
            operation = nil
            zoomToFit()
        }
    }

    func computeMassProperties() async {
        guard let b = selectedBodies.first ?? bodies.first?.id else { return }
        form.result = try? await engine.execute("query.mass_properties", ["body": .string(b)]).result
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
                VStack(alignment: .leading, spacing: 12) {
                    if let op = model.operation {
                        OperationPanel(op: op)
                    } else if model.activeSketch != nil {
                        SketchPanel()
                    } else {
                        SelectionPanel()
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            DisclosureGroup("History", isExpanded: $showHistory) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.suffix(40).enumerated().reversed()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct PanelHeader: View {
    let title: String
    var systemImage: String = "slider.horizontal.3"

    var body: some View {
        Label(title, systemImage: systemImage).font(.headline)
    }
}

private struct OperationPanel: View {
    @Environment(AppModel.self) private var model
    let op: Operation
    @State private var lines: [String] = []

    var body: some View {
        @Bindable var model = model
        PanelHeader(title: op.title)
        HStack {
            Button {
                Task { await model.commitOperation() }
            } label: {
                Label("OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(op == .massProperties)
            Button {
                model.cancelOperation()
            } label: {
                Label("Cancel", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            .keyboardShortcut(.cancelAction)
        }
        Divider()
        switch op {
        case .extrude, .revolve:
            Picker("Sketch", selection: Binding(get: { model.operationSketch ?? "" }, set: { model.operationSketch = $0 })) {
                ForEach(model.sketches) { Text($0.name).tag($0.id) }
            }
            if op == .extrude {
                LabeledField("Depth", text: $model.form.depth, help: "mm, or with units: 0.5 in")
                Picker("Direction", selection: $model.form.direction) {
                    Text("Blind").tag("normal")
                    Text("Reverse").tag("reverse")
                    Text("Mid Plane").tag("mid_plane")
                }
            } else {
                Picker("Axis", selection: $model.form.axis) {
                    Text("Choose a sketch line").tag("")
                    ForEach(lines, id: \.self) { Text($0).tag($0) }
                }
                .task(id: model.operationSketch) { lines = await model.sketchLines(model.operationSketch) }
                LabeledField("Angle (°)", text: $model.form.angle)
            }
            Text("Uses the sketch's closed profile; holes and islands are kept.").font(.caption).foregroundStyle(.secondary)
        case .fillet:
            LabeledField("Radius", text: $model.form.radius, help: "mm, or with units")
            Text(model.selectedEdges.isEmpty ? "Select edges in the viewport (⇧-click to add)." : "\(model.selectedEdges.count) edge(s) selected")
                .font(.caption).foregroundStyle(model.selectedEdges.isEmpty ? .orange : .secondary)
        case .combine:
            Picker("Operation", selection: $model.form.combine) {
                Text("Add").tag("fuse")
                Text("Subtract").tag("cut")
                Text("Common").tag("common")
            }
            Picker("Main body", selection: $model.form.target) {
                ForEach(model.bodies, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker(model.form.combine == "cut" ? "Subtract" : "With", selection: $model.form.tool) {
                ForEach(model.bodies, id: \.id) { Text($0.name).tag($0.id) }
            }
        case .primitive(let p):
            switch p {
            case .box:
                LabeledField("Width", text: $model.form.width)
                LabeledField("Height", text: $model.form.height)
                LabeledField("Depth", text: $model.form.boxDepth)
            case .cylinder:
                LabeledField("Radius", text: $model.form.cylRadius)
                LabeledField("Height", text: $model.form.cylHeight)
            case .sphere:
                LabeledField("Radius", text: $model.form.sphereRadius)
            }
        case .massProperties:
            if let r = model.form.result {
                KeyValueList(value: r)
            } else {
                Text("Select a body.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct SketchPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let row = model.sketches.first { $0.id == model.activeSketch }
        PanelHeader(title: row?.name ?? "Sketch", systemImage: "pencil.and.outline")
        if let row { SketchStatusBadge(row: row) }
        if let tool = model.sketchState.tool {
            Divider()
            Text(tool.title.replacingOccurrences(of: "\n", with: " ")).font(.subheadline.bold())
            Text(tool.hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if tool == .fillet {
                LabeledField("Radius", text: Binding(get: { String(model.sketchState.filletRadius) }, set: { model.sketchState.filletRadius = Double($0) ?? model.sketchState.filletRadius }))
            }
        }
        Divider()
        Text("Selected").font(.subheadline.bold())
        let picked = model.selection.filter { $0.hasPrefix((model.activeSketch ?? "") + "/") }
        if picked.isEmpty {
            Text("Click curves with no tool active to select them, then use Smart Dimension.").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(picked, id: \.self) { Text($0.split(separator: "/").last.map(String.init) ?? $0).font(.callout.monospaced()) }
        }
        Divider()
        Button("Exit Sketch") { Task { await model.exitSketch() } }
    }
}

private struct SelectionPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PanelHeader(title: "Selection", systemImage: "cursorarrow.click")
        if model.selection.isEmpty {
            Text("Nothing selected. Click a face, edge or body in the viewport or tree.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(model.selection, id: \.self) { Text($0).font(.callout.monospaced()) }
        }
        if let info = model.inspector {
            Divider()
            KeyValueList(value: info)
        }
    }
}

/// A JSON result as readable rows (nested objects flattened, numbers rounded).
struct KeyValueList: View {
    let value: JSONValue

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(Array(rows(value, prefix: "").enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1).textSelection(.enabled)
                }
                .font(.caption)
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

struct LabeledField: View {
    let label: String
    @Binding var text: String
    var help: String = ""

    init(_ label: String, text: Binding<String>, help: String = "") {
        self.label = label
        self._text = text
        self.help = help
    }

    var body: some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
        .help(help)
    }
}

// PropertyManager (docs/research §1.3): the page of the operation or tool in progress, the
// sketch being edited, or the selection. OK runs commands on the bus; while an operation is
// open its result is previewed live (Engine.preview) in the viewport.

import ForgeCommands
import ForgeCore
import ForgeRender
import ForgeSketch
import SwiftUI

/// SolidWorks' end conditions as shown in the Extrude page (the engine's body.extrude names).
enum EndConditionUI: String, CaseIterable {
    case blind = "Blind", throughAll = "Through All", throughAllBoth = "Through All - Both", midPlane = "Mid Plane"

    var param: String {
        switch self {
        case .blind: "blind"
        case .throughAll: "through_all"
        case .throughAllBoth: "through_all_both"
        case .midPlane: "mid_plane"
        }
    }

    init?(param: String) {
        guard let v = Self.allCases.first(where: { $0.param == param }) else { return nil }
        self = v
    }

    var needsDepth: Bool { self == .blind || self == .midPlane }
}

/// Values being edited in the PropertyManager. Lengths are text so units work ("0.5 in").
struct OperationForm {
    var depth = "10"
    var endCondition = EndConditionUI.blind
    var reverse = false
    var direction2 = false, endCondition2 = EndConditionUI.blind, depth2 = "10"
    var merge = true
    /// Cut / merge scope: empty = all bodies.
    var scope: [String] = []
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
    var offsetDistance = "2", offsetReverse = false, offsetBoth = false, offsetCaps = false, offsetBaseConstruction = false
    var mirrorAxis = ""
    var patternCount = "3", patternSpacing = "10", patternDirection = "0"
    var patternDirection2On = false, patternCount2 = "2", patternSpacing2 = "10", patternDirection2 = "90"
    var circularCount = "6", circularAngle = "360", circularCenter = "0, 0"
    var moveDX = "10", moveDY = "0", copy = false, keepRelations = true
    var rotateAngle = "90", rotateCenter = "0, 0"
    var scaleFactor = "2", scaleCenter = "0, 0"
    var result: JSONValue?


}

extension AppModel {
    /// Start an operation: its page appears in the PropertyManager.
    func begin(_ op: Operation) {
        form.result = nil
        switch op {
        case .extrude, .revolve, .cutExtrude:
            if operationSketch == nil || !sketches.contains(where: { $0.id == operationSketch }) {
                operationSketch = activeSketch ?? selection.first(where: { $0.hasPrefix("sketch-") && !$0.contains("/") }) ?? sketches.last?.id
            }
            form.direction2 = false
            form.scope = []
            if op == .cutExtrude {
                // A cut goes into the material: opposite to the sketch normal by default.
                form.reverse = true
            } else if op == .extrude {
                form.reverse = false
            }
        case .combine where bodies.count >= 2:
            form.target = selectedBodies.first ?? bodies[0].id
            form.tool = selectedBodies.dropFirst().first ?? bodies.first { $0.id != form.target }?.id ?? ""
        case .sketchMirror:
            if let sk = sketchState.sketch {
                form.mirrorAxis = sketchSelection.last(where: { sk.entities[$0]?.kind == .line && sk.entities[$0]?.construction == true })
                    ?? sketchSelection.last(where: { sk.entities[$0]?.kind == .line }) ?? ""
            }
        default:
            break
        }
        if op.isSketchOperation {
            sketchState.tool = nil
            dimensionEdit = nil
            clearPreview()
        }
        operation = op
        lastOperation = op
        contextToolbarAt = nil
        switch op {
        case .massProperties: Task { await computeMassProperties() }
        case .measure: Task { await computeMeasure() }
        case .check: Task { await computeCheck() }
        default: break
        }
    }

    func cancelOperation() {
        operation = nil
        editingFeature = nil
        form.result = nil
        clearOperationPreview()
    }

    // MARK: editing a feature (double-click in the tree): its page, filled from its params

    /// Editing a feature that made its own body (merge does not apply to it).
    var editingFeatureCreatesBody: Bool? {
        editingFeature.flatMap { id in features.first { $0.id == id } }.map { !$0.createdBodies.isEmpty }
    }

    /// Text for a parameter value in a field ("25", "0.5 in").
    static func fieldText(_ v: JSONValue?) -> String? {
        switch v {
        case .number(let d)?: String(format: "%g", d)
        case .string(let s)?: s.hasSuffix(" deg") ? String(s.dropLast(4)) : s
        default: nil
        }
    }

    func editFeature(_ f: FeatureRow) {
        guard let op = f.operation else { return }
        let p = f.params
        begin(op)
        editingFeature = f.id
        let t = Self.fieldText
        switch op {
        case .extrude, .cutExtrude:
            operationSketch = p["sketch"]?.stringValue ?? operationSketch
            let ec = p["end_condition"]?.stringValue ?? (p["direction"]?.stringValue == "mid_plane" ? "mid_plane" : "blind")
            form.endCondition = EndConditionUI(param: ec) ?? .blind
            form.depth = t(p["depth"]) ?? form.depth
            form.reverse = p["reverse"]?.boolValue ?? (p["direction"]?.stringValue == "reverse")
            if let d2 = p["direction2"], !d2.isNull {
                form.direction2 = true
                form.endCondition2 = EndConditionUI(param: d2["end_condition"]?.stringValue ?? "blind") ?? .blind
                form.depth2 = t(d2["depth"]) ?? form.depth2
            } else {
                form.direction2 = false
            }
            form.merge = p["merge"]?.boolValue ?? false
            form.scope = p["scope"]?.arrayValue?.compactMap(\.stringValue) ?? []
        case .revolve:
            operationSketch = p["sketch"]?.stringValue ?? operationSketch
            form.axis = p["axis"]?.stringValue ?? ""
            form.angle = t(p["angle"]) ?? "360"
            form.merge = p["merge"]?.boolValue ?? false
        case .fillet:
            form.radius = t(p["radius"]) ?? form.radius
            let edges = p["edges"]?.arrayValue?.compactMap(\.stringValue) ?? []
            Task { await select(edges) }
        case .combine:
            form.combine = p["operation"]?.stringValue ?? "fuse"
            form.target = p["target"]?.stringValue ?? ""
            form.tool = p["tool"]?.stringValue ?? ""
        case .primitive(let prim):
            switch prim {
            case .box:
                form.width = t(p["width"]) ?? form.width
                form.height = t(p["height"]) ?? form.height
                form.boxDepth = t(p["depth"]) ?? form.boxDepth
            case .cylinder:
                form.cylRadius = t(p["radius"]) ?? form.cylRadius
                form.cylHeight = t(p["height"]) ?? form.cylHeight
            case .sphere:
                form.sphereRadius = t(p["radius"]) ?? form.sphereRadius
            case .cone:
                form.coneBase = t(p["base_radius"]) ?? form.coneBase
                form.coneTop = t(p["top_radius"]) ?? form.coneTop
                form.coneHeight = t(p["height"]) ?? form.coneHeight
            case .torus:
                form.torusMajor = t(p["major_radius"]) ?? form.torusMajor
                form.torusMinor = t(p["minor_radius"]) ?? form.torusMinor
            }
        default:
            break
        }
        clearOperationPreview()
    }

    /// OK on a feature's page: feature.edit with the page's parameters.
    func commitFeatureEdit(_ id: String, _ op: Operation) async {
        var params: JSONValue?
        switch op {
        case .extrude, .cutExtrude, .revolve, .primitive:
            params = invocations(for: op)?.first?.params
            if case .object(var o)? = params, features.first(where: { $0.id == id })?.createdBodies.isEmpty == false {
                // A feature that made its own body keeps doing so.
                o.removeValue(forKey: "merge")
                params = .object(o)
            }
        case .fillet:
            let edges = selectedEdges
            guard let body = edges.first?.split(separator: "/").first else {
                lastError = ForgeError(.invalidParams, "select the edges to fillet")
                return
            }
            params = ["body": .string(String(body)), "edges": .array(edges.map { .string($0) }), "radius": quantity(form.radius)]
        case .combine:
            params = ["operation": .string(form.combine), "target": .string(form.target), "tool": .string(form.tool)]
        default:
            params = nil
        }
        guard let params else { return }
        let replace: Bool = op != .combine
        if await run("feature.edit", ["feature": .string(id), "params": params, "replace": .bool(replace)]) != nil {
            operation = nil
            editingFeature = nil
        }
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

    private func point(_ text: String) -> JSONValue? {
        let c = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return c.count == 2 ? [.number(c[0]), .number(c[1])] : nil
    }

    /// The commands an operation runs (also what its preview runs).
    func invocations(for op: Operation) -> [Invocation]? {
        switch op {
        case .extrude, .cutExtrude:
            guard let sk = operationSketch else { return nil }
            var p: [String: JSONValue] = ["sketch": .string(sk), "end_condition": .string(form.endCondition.param)]
            if form.endCondition.needsDepth { p["depth"] = quantity(form.depth) }
            if form.reverse && form.endCondition != .midPlane && form.endCondition != .throughAllBoth { p["reverse"] = true }
            if form.direction2 && form.endCondition != .midPlane && form.endCondition != .throughAllBoth {
                var d2: [String: JSONValue] = ["end_condition": .string(form.endCondition2.param)]
                if form.endCondition2 == .blind { d2["depth"] = quantity(form.depth2) }
                p["direction2"] = .object(d2)
            }
            if op == .cutExtrude {
                p["operation"] = "cut"
            } else if form.merge && !bodies.isEmpty {
                p["merge"] = true
            }
            if !form.scope.isEmpty { p["scope"] = .array(form.scope.map { .string($0) }) }
            return [Invocation("body.extrude", .object(p))]
        case .revolve:
            guard let sk = operationSketch, !form.axis.isEmpty else { return nil }
            var p: [String: JSONValue] = ["sketch": .string(sk), "axis": .string(form.axis), "angle": angleQuantity(form.angle)]
            if form.merge && !bodies.isEmpty { p["merge"] = true }
            return [Invocation("body.revolve", .object(p))]
        case .primitive(let p):
            switch p {
            case .box: return [Invocation("body.create_box", ["width": quantity(form.width), "height": quantity(form.height), "depth": quantity(form.boxDepth)])]
            case .cylinder: return [Invocation("body.create_cylinder", ["radius": quantity(form.cylRadius), "height": quantity(form.cylHeight)])]
            case .sphere: return [Invocation("body.create_sphere", ["radius": quantity(form.sphereRadius)])]
            case .cone:
                return [Invocation("body.create_cone", ["base_radius": quantity(form.coneBase), "top_radius": quantity(form.coneTop), "height": quantity(form.coneHeight)])]
            case .torus: return [Invocation("body.create_torus", ["major_radius": quantity(form.torusMajor), "minor_radius": quantity(form.torusMinor)])]
            }
        default:
            return nil
        }
    }

    // MARK: preview

    /// Recompute the live preview of the open operation (translucent bodies in the viewport).
    func updatePreview() async {
        guard let op = operation, editingFeature == nil, let items = invocations(for: op) else {
            clearOperationPreview()
            return
        }
        do {
            let (doc, changes) = try await engine.preview(items)
            let created = changes.created.filter { $0.hasPrefix("body-") }
            guard let doc, !created.isEmpty else { return clearOperationPreview() }
            let ds = try DocumentScene(document: doc, bodies: created, showSketches: false)
            let cut = op == .cutExtrude
            let fill = cut ? RGBA(0.90, 0.28, 0.22, 0.38) : RGBA(0.96, 0.64, 0.14, 0.40)
            let edge = cut ? RGBA(0.72, 0.16, 0.12) : RGBA(0.80, 0.47, 0.0)
            preview = PreviewBox(items: ds.scene.items.enumerated().map { i, item in
                var out = item
                out.objectID = ReferenceGeometry.firstObjectID + 100 + UInt32(i)
                out.color = fill
                out.highlightedFaces = []
                out.highlightedEdges = []
                out.highlightAll = false
                out.edgeColors = Dictionary(uniqueKeysWithValues: item.mesh.edgeIDs.map { ($0, edge) })
                return out
            })
            previewError = nil
            previewVersion += 1
        } catch {
            previewError = ForgeError.wrap(error).message
            if !preview.items.isEmpty {
                preview = PreviewBox()
                previewVersion += 1
            }
        }
    }

    func clearOperationPreview() {
        previewError = nil
        guard !preview.items.isEmpty else { return }
        preview = PreviewBox()
        previewVersion += 1
    }

    /// Changes whenever something the preview depends on changes.
    var previewKey: String {
        guard let op = operation else { return "" }
        let f = form
        return [op.title, operationSketch ?? "", f.depth, f.extrudeDirection, f.axis, f.angle, f.width, f.height, f.boxDepth, f.cylRadius, f.cylHeight,
                f.sphereRadius, f.coneBase, f.coneTop, f.coneHeight, f.torusMajor, f.torusMinor, String(sceneVersion)].joined(separator: "|")
    }

    // MARK: commit

    func commitOperation() async {
        guard let op = operation else { return }
        var ok: CommandOutcome?
        let local = sketchSelection
        if let fid = editingFeature {
            await commitFeatureEdit(fid, op)
            return
        }
        switch op {
        case .extrude, .cutExtrude, .revolve, .primitive:
            guard let items = invocations(for: op) else {
                lastError = ForgeError(.invalidParams, op == .revolve ? "choose the axis of revolution" : "choose a sketch")
                return
            }
            if activeSketch != nil { await exitSketch() }
            for i in items { ok = await run(i.command, i.params) }
        case .fillet:
            let edges = selectedEdges
            guard let body = edges.first?.split(separator: "/").first else {
                lastError = ForgeError(.invalidParams, "select the edges to fillet in the viewport first")
                return
            }
            ok = await run("body.fillet_edges", ["body": .string(String(body)), "edges": .array(edges.map { .string($0) }), "radius": quantity(form.radius)])
        case .combine:
            ok = await run("body.boolean", ["operation": .string(form.combine), "target": .string(form.target), "tool": .string(form.tool)])
        case .massProperties, .measure, .check, .addRelation, .displayRelations:
            operation = nil
            return
        case .sketchOffset:
            ok = await run("sketch.offset", [
                "entities": .array(local.map { .string($0) }), "distance": quantity(form.offsetDistance), "reverse": .bool(form.offsetReverse),
                "bidirectional": .bool(form.offsetBoth), "cap_ends": .bool(form.offsetCaps), "make_base_construction": .bool(form.offsetBaseConstruction),
            ])
        case .sketchMirror:
            let entities = local.filter { $0 != form.mirrorAxis }
            ok = await run("sketch.mirror", ["entities": .array(entities.map { .string($0) }), "axis": .string(form.mirrorAxis)])
        case .sketchLinearPattern:
            var p: [String: JSONValue] = [
                "entities": .array(local.map { .string($0) }), "count": count(form.patternCount), "spacing": quantity(form.patternSpacing),
                "direction": angleQuantity(form.patternDirection),
            ]
            if form.patternDirection2On {
                p["count2"] = count(form.patternCount2)
                p["spacing2"] = quantity(form.patternSpacing2)
                p["direction2"] = angleQuantity(form.patternDirection2)
            }
            ok = await run("sketch.pattern_linear", .object(p))
        case .sketchCircularPattern:
            var p: [String: JSONValue] = ["entities": .array(local.map { .string($0) }), "count": count(form.circularCount), "angle": angleQuantity(form.circularAngle)]
            if let c = point(form.circularCenter) { p["center"] = c }
            ok = await run("sketch.pattern_circular", .object(p))
        case .sketchMove:
            ok = await run("sketch.move", [
                "entities": .array(local.map { .string($0) }), "by": [quantity(form.moveDX), quantity(form.moveDY)],
                "copy": .bool(form.copy), "keep_relations": .bool(form.keepRelations),
            ])
        case .sketchRotate:
            var p: [String: JSONValue] = [
                "entities": .array(local.map { .string($0) }), "angle": angleQuantity(form.rotateAngle), "copy": .bool(form.copy),
                "keep_relations": .bool(form.keepRelations),
            ]
            if let c = point(form.rotateCenter) { p["center"] = c }
            ok = await run("sketch.rotate", .object(p))
        case .sketchScale:
            var p: [String: JSONValue] = [
                "entities": .array(local.map { .string($0) }), "factor": .number(Double(form.scaleFactor) ?? 1), "copy": .bool(form.copy),
                "keep_relations": .bool(form.keepRelations),
            ]
            if let c = point(form.scaleCenter) { p["center"] = c }
            ok = await run("sketch.scale", .object(p))
        }
        if ok != nil {
            let wasSketchOp = op.isSketchOperation
            operation = nil
            clearOperationPreview()
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

    /// Lines of the sketch used by the operation (revolve axes), centerlines first.
    func sketchLines(_ sketch: String?) async -> [String] {
        guard let id = sketch, let doc = await engine.activeDocument, let sk = doc.sketches[id] else { return [] }
        let lines = sk.orderedEntities.filter { $0.kind == .line }
        return (lines.filter(\.construction) + lines.filter { !$0.construction }).map(\.id)
    }

    /// Move a sketch point to typed coordinates (the Parameters group of a point or line).
    func movePoint(_ id: String, u: String, v: String) async {
        guard let x = Double(u), let y = Double(v) else { return }
        await run("sketch.drag", ["entity": .string(id), "to": [.number(x), .number(y)]])
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
                        OperationPage(op: op)
                    } else if let tool = model.sketchState.tool {
                        SketchToolPage(tool: tool)
                    } else if model.activeSketch != nil {
                        SketchPage()
                    } else {
                        SelectionPage()
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

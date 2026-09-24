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
    var draftOn = false, draftAngle = "3", draftOutward = false
    var thinOn = false, thinType = "one_direction", thinThickness = "1", thinThickness2 = "1", thinReverse = false
    var chamferType = "equal_distance", chamferDistance = "1", chamferDistance2 = "1", chamferAngle = "45"
    var shellThickness = "1", shellOutward = false, shellFaces: [String] = []
    var draftNeutral = "", draftFaces: [String] = [], draftReverse = false, draftFeatureAngle = "3"
    var planeReference = "top", planeOffset = "20", planeFlip = false
    var holeType = "counterbore", holeSize = "M6", holeFit = "normal", holeEnd = "through_all", holeDepth = "10", holeThreadDepth = "8"
    var holeReverse = false
    /// Patterns and mirror: the seed features (ids), directions and counts.
    var seeds: [String] = []
    var linDirection = "x", linSpacing = "20", linCount = "3", linReverse = false
    var linDirection2On = false, linDirection2 = "y", linSpacing2 = "20", linCount2 = "2"
    var cirAxis = "y", cirAngle = "360", cirCount = "6", cirEqual = true, cirReverse = false
    var mirrorPlane = "right"
    /// Which selection box receives picks (Draft: "neutral" or "faces").
    var activeBox = "faces"
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
        case .plane:
            form.planeReference = selectedFace ?? "top"
        case .linearPattern, .circularPattern, .mirror:
            // The last pattern-able feature is the usual seed.
            let last = features.last { ["body.extrude", "body.revolve", "body.hole"].contains($0.command) && !$0.suppressed }
            form.seeds = last.map { [$0.id] } ?? []
            if op == .mirror, let f = selectedFace { form.mirrorPlane = f }
            if let e = selectedEdges.first {
                if op == .linearPattern { form.linDirection = e } else if op == .circularPattern { form.cirAxis = e }
            }
        case .extrude, .revolve, .cutExtrude, .cutRevolve, .hole:
            if operationSketch == nil || !sketches.contains(where: { $0.id == operationSketch }) {
                operationSketch = activeSketch ?? selection.first(where: { $0.hasPrefix("sketch-") && !$0.contains("/") }) ?? sketches.last?.id
            }
            form.direction2 = false
            form.draftOn = false
            form.thinOn = false
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
        case .shell:
            form.shellFaces = selection.filter { $0.contains("/face-") }
        case .draft:
            let faces = selection.filter { $0.contains("/face-") }
            form.draftNeutral = faces.first ?? ""
            form.draftFaces = Array(faces.dropFirst())
            form.activeBox = faces.isEmpty ? "neutral" : "faces"
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
            if let d = p["draft"], !d.isNull {
                form.draftOn = true
                form.draftAngle = t(d["angle"]) ?? form.draftAngle
                form.draftOutward = d["outward"]?.boolValue ?? false
            } else {
                form.draftOn = false
            }
            if let th = p["thin"], !th.isNull {
                form.thinOn = true
                form.thinType = th["type"]?.stringValue ?? "one_direction"
                form.thinThickness = t(th["thickness"]) ?? form.thinThickness
                form.thinThickness2 = t(th["thickness2"]) ?? form.thinThickness2
                form.thinReverse = th["reverse"]?.boolValue ?? false
            } else {
                form.thinOn = false
            }
        case .linearPattern, .circularPattern, .mirror:
            form.seeds = p["features"]?.arrayValue?.compactMap(\.stringValue) ?? []
            form.linDirection = p["direction"]?.stringValue ?? form.linDirection
            form.linSpacing = t(p["spacing"]) ?? form.linSpacing
            form.linCount = p["count"]?.intValue.map(String.init) ?? form.linCount
            form.linReverse = p["reverse"]?.boolValue ?? false
            form.linDirection2On = p["direction2"] != nil
            form.linDirection2 = p["direction2"]?.stringValue ?? form.linDirection2
            form.linSpacing2 = t(p["spacing2"]) ?? form.linSpacing2
            form.linCount2 = p["count2"]?.intValue.map(String.init) ?? form.linCount2
            form.cirAxis = p["axis"]?.stringValue ?? form.cirAxis
            form.cirAngle = t(p["angle"]) ?? "360"
            form.cirCount = p["count"]?.intValue.map(String.init) ?? form.cirCount
            form.cirEqual = p["equal_spacing"]?.boolValue ?? true
            form.cirReverse = p["reverse"]?.boolValue ?? false
            form.mirrorPlane = p["plane"]?.stringValue ?? form.mirrorPlane
        case .hole:
            operationSketch = p["sketch"]?.stringValue ?? operationSketch
            form.holeType = p["type"]?.stringValue ?? "hole"
            form.holeSize = p["size"]?.stringValue ?? form.holeSize
            form.holeFit = p["fit"]?.stringValue ?? "normal"
            form.holeEnd = p["end_condition"]?.stringValue ?? "through_all"
            form.holeDepth = t(p["depth"]) ?? form.holeDepth
            form.holeThreadDepth = t(p["thread_depth"]) ?? form.holeThreadDepth
            form.holeReverse = p["reverse"]?.boolValue ?? false
        case .plane:
            form.planeReference = p["reference"]?.stringValue ?? "top"
            form.planeOffset = t(p["offset"]) ?? "0"
            form.planeFlip = p["flip"]?.boolValue ?? false
        case .revolve, .cutRevolve:
            operationSketch = p["sketch"]?.stringValue ?? operationSketch
            form.axis = p["axis"]?.stringValue ?? ""
            form.angle = t(p["angle"]) ?? "360"
            form.merge = p["merge"]?.boolValue ?? false
        case .fillet:
            form.radius = t(p["radius"]) ?? form.radius
            let edges = p["edges"]?.arrayValue?.compactMap(\.stringValue) ?? []
            Task { await select(edges) }
        case .chamfer:
            form.chamferType = p["type"]?.stringValue ?? "equal_distance"
            form.chamferDistance = t(p["distance"]) ?? form.chamferDistance
            form.chamferDistance2 = t(p["distance2"]) ?? form.chamferDistance2
            form.chamferAngle = t(p["angle"]) ?? form.chamferAngle
            let edges = p["edges"]?.arrayValue?.compactMap(\.stringValue) ?? []
            Task { await select(edges) }
        case .shell:
            form.shellThickness = t(p["thickness"]) ?? form.shellThickness
            form.shellOutward = p["outward"]?.boolValue ?? false
            form.shellFaces = p["faces"]?.arrayValue?.compactMap(\.stringValue) ?? []
        case .draft:
            form.draftNeutral = p["neutral_plane"]?.stringValue ?? ""
            form.draftFaces = p["faces"]?.arrayValue?.compactMap(\.stringValue) ?? []
            form.draftFeatureAngle = t(p["angle"]) ?? form.draftFeatureAngle
            form.draftReverse = p["reverse"]?.boolValue ?? false
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
        case .extrude, .cutExtrude, .revolve, .cutRevolve, .hole, .plane, .primitive, .fillet, .chamfer, .shell, .draft, .linearPattern,
             .circularPattern, .mirror, .combine:
            params = featureEditParams(id, op)
        default:
            params = nil
        }
        guard let params else {
            lastError = ForgeError(.invalidParams, missingInputMessage(op))
            return
        }
        let replace: Bool = op != .combine
        if await run("feature.edit", ["feature": .string(id), "params": params, "replace": .bool(replace)]) != nil {
            operation = nil
            editingFeature = nil
            clearOperationPreview()
        }
    }

    /// The parameters `feature.edit` gets from the page of feature `id`.
    func featureEditParams(_ id: String, _ op: Operation) -> JSONValue? {
        guard var params = invocations(for: op)?.first?.params else { return nil }
        if case .object(var o) = params, features.first(where: { $0.id == id })?.createdBodies.isEmpty == false {
            // A feature that made its own body keeps doing so.
            o.removeValue(forKey: "merge")
            params = .object(o)
        }
        return params
    }

    /// What OK needs before it can run (the PropertyManager's red message).
    func missingInputMessage(_ op: Operation) -> String {
        let messages: [Operation: String] = [.fillet: "select the edges or faces to fillet", .chamfer: "select the edges or faces to chamfer",
         .shell: "select a face to remove, or a body", .draft: "select the neutral plane and the faces to draft",
         .revolve: "choose the axis of revolution", .cutRevolve: "choose the axis of revolution",
         .linearPattern: "choose the features to pattern", .circularPattern: "choose the features to pattern",
         .mirror: "choose the features to mirror", .combine: "choose the main body and the body to combine with it",
         .sketchOffset: "select the sketch entities to offset", .sketchMirror: "select the entities and a line to mirror about",
         .sketchLinearPattern: "select the sketch entities to pattern", .sketchCircularPattern: "select the sketch entities to pattern",
         .sketchMove: "select the sketch entities to move", .sketchRotate: "select the sketch entities to rotate",
         .sketchScale: "select the sketch entities to scale"]
        return messages[op] ?? "choose a sketch"
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
            if form.draftOn && !form.direction2 && form.endCondition != .midPlane && form.endCondition != .throughAllBoth {
                var d: [String: JSONValue] = ["angle": angleQuantity(form.draftAngle)]
                if form.draftOutward { d["outward"] = true }
                p["draft"] = .object(d)
            }
            if form.thinOn {
                var t: [String: JSONValue] = ["type": .string(form.thinType), "thickness": quantity(form.thinThickness)]
                if form.thinType == "two_direction" { t["thickness2"] = quantity(form.thinThickness2) }
                if form.thinType == "one_direction" && form.thinReverse { t["reverse"] = true }
                p["thin"] = .object(t)
            }
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
        case .revolve, .cutRevolve:
            guard let sk = operationSketch, !form.axis.isEmpty else { return nil }
            var p: [String: JSONValue] = ["sketch": .string(sk), "axis": .string(form.axis), "angle": angleQuantity(form.angle)]
            if op == .cutRevolve { p["operation"] = "cut" } else if form.merge && !bodies.isEmpty { p["merge"] = true }
            return [Invocation("body.revolve", .object(p))]
        case .hole:
            guard let sk = operationSketch else { return nil }
            var p: [String: JSONValue] = [
                "sketch": .string(sk), "type": .string(form.holeType), "size": .string(form.holeSize), "end_condition": .string(form.holeEnd),
            ]
            if form.holeType != "tapped" { p["fit"] = .string(form.holeFit) }
            if form.holeEnd == "blind" { p["depth"] = quantity(form.holeDepth) }
            if form.holeType == "tapped" { p["thread_depth"] = quantity(form.holeThreadDepth) }
            if form.holeReverse { p["reverse"] = true }
            return [Invocation("body.hole", .object(p))]
        case .linearPattern:
            guard !form.seeds.isEmpty else { return nil }
            var p: [String: JSONValue] = [
                "features": .array(form.seeds.map { .string($0) }), "direction": .string(form.linDirection), "spacing": quantity(form.linSpacing),
                "count": .number(Double(Int(form.linCount) ?? 2)),
            ]
            if form.linReverse { p["reverse"] = true }
            if form.linDirection2On {
                p["direction2"] = .string(form.linDirection2)
                p["spacing2"] = quantity(form.linSpacing2)
                p["count2"] = .number(Double(Int(form.linCount2) ?? 1))
            }
            return [Invocation("pattern.linear", .object(p))]
        case .circularPattern:
            guard !form.seeds.isEmpty else { return nil }
            var p: [String: JSONValue] = [
                "features": .array(form.seeds.map { .string($0) }), "axis": .string(form.cirAxis), "angle": angleQuantity(form.cirAngle),
                "count": .number(Double(Int(form.cirCount) ?? 2)), "equal_spacing": .bool(form.cirEqual),
            ]
            if form.cirReverse { p["reverse"] = true }
            return [Invocation("pattern.circular", .object(p))]
        case .mirror:
            guard !form.seeds.isEmpty else { return nil }
            return [Invocation("pattern.mirror", ["features": .array(form.seeds.map { .string($0) }), "plane": .string(form.mirrorPlane)])]
        case .plane:
            var p: [String: JSONValue] = ["reference": .string(form.planeReference), "offset": quantity(form.planeOffset)]
            if form.planeFlip { p["flip"] = true }
            return [Invocation("plane.create", .object(p))]
        case .fillet:
            // Edges and faces of any number of bodies: body.fillet_edges groups them per body.
            let items = filletItems
            guard !items.isEmpty else { return nil }
            return [Invocation("body.fillet_edges", ["edges": .array(items.map { .string($0) }), "radius": quantity(form.radius)])]
        case .chamfer:
            let items = filletItems
            guard !items.isEmpty else { return nil }
            var p: [String: JSONValue] = [
                "edges": .array(items.map { .string($0) }), "type": .string(form.chamferType), "distance": quantity(form.chamferDistance),
            ]
            if form.chamferType == "distance_distance" { p["distance2"] = quantity(form.chamferDistance2) }
            if form.chamferType == "angle_distance" { p["angle"] = angleQuantity(form.chamferAngle) }
            return [Invocation("body.chamfer_edges", .object(p))]
        case .shell:
            guard let body = (form.shellFaces.first?.split(separator: "/").first).map(String.init) ?? selectedBodies.first ?? bodies.first?.id else { return nil }
            return [Invocation("body.shell", [
                "body": .string(body), "faces": .array(form.shellFaces.map { .string($0) }), "thickness": quantity(form.shellThickness),
                "outward": .bool(form.shellOutward),
            ])]
        case .draft:
            guard !form.draftNeutral.isEmpty, !form.draftFaces.isEmpty, let body = form.draftNeutral.split(separator: "/").first else { return nil }
            return [Invocation("body.draft", [
                "body": .string(String(body)), "neutral_plane": .string(form.draftNeutral), "faces": .array(form.draftFaces.map { .string($0) }),
                "angle": angleQuantity(form.draftFeatureAngle), "reverse": .bool(form.draftReverse),
            ])]
        case .combine:
            guard !form.target.isEmpty, !form.tool.isEmpty, form.target != form.tool else { return nil }
            return [Invocation("body.boolean", ["operation": .string(form.combine), "target": .string(form.target), "tool": .string(form.tool)])]
        case .sketchOffset, .sketchMirror, .sketchLinearPattern, .sketchCircularPattern, .sketchMove, .sketchRotate, .sketchScale:
            return sketchInvocation(op).map { [$0] }
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

    /// The command of a sketch operation on the selected entities of the open sketch.
    private func sketchInvocation(_ op: Operation) -> Invocation? {
        let local = sketchSelection
        guard !local.isEmpty else { return nil }
        let ents: JSONValue = .array(local.map { .string($0) })
        switch op {
        case .sketchOffset:
            return Invocation("sketch.offset", [
                "entities": ents, "distance": quantity(form.offsetDistance), "reverse": .bool(form.offsetReverse),
                "bidirectional": .bool(form.offsetBoth), "cap_ends": .bool(form.offsetCaps), "make_base_construction": .bool(form.offsetBaseConstruction),
            ])
        case .sketchMirror:
            let entities = local.filter { $0 != form.mirrorAxis }
            guard !form.mirrorAxis.isEmpty, !entities.isEmpty else { return nil }
            return Invocation("sketch.mirror", ["entities": .array(entities.map { .string($0) }), "axis": .string(form.mirrorAxis)])
        case .sketchLinearPattern:
            var p: [String: JSONValue] = [
                "entities": ents, "count": count(form.patternCount), "spacing": quantity(form.patternSpacing),
                "direction": angleQuantity(form.patternDirection),
            ]
            if form.patternDirection2On {
                p["count2"] = count(form.patternCount2)
                p["spacing2"] = quantity(form.patternSpacing2)
                p["direction2"] = angleQuantity(form.patternDirection2)
            }
            return Invocation("sketch.pattern_linear", .object(p))
        case .sketchCircularPattern:
            var p: [String: JSONValue] = ["entities": ents, "count": count(form.circularCount), "angle": angleQuantity(form.circularAngle)]
            if let c = point(form.circularCenter) { p["center"] = c }
            return Invocation("sketch.pattern_circular", .object(p))
        case .sketchMove:
            return Invocation("sketch.move", [
                "entities": ents, "by": [quantity(form.moveDX), quantity(form.moveDY)], "copy": .bool(form.copy), "keep_relations": .bool(form.keepRelations),
            ])
        case .sketchRotate:
            var p: [String: JSONValue] = ["entities": ents, "angle": angleQuantity(form.rotateAngle), "copy": .bool(form.copy), "keep_relations": .bool(form.keepRelations)]
            if let c = point(form.rotateCenter) { p["center"] = c }
            return Invocation("sketch.rotate", .object(p))
        case .sketchScale:
            var p: [String: JSONValue] = [
                "entities": ents, "factor": .number(Double(form.scaleFactor) ?? 1), "copy": .bool(form.copy), "keep_relations": .bool(form.keepRelations),
            ]
            if let c = point(form.scaleCenter) { p["center"] = c }
            return Invocation("sketch.scale", .object(p))
        default:
            return nil
        }
    }

    // MARK: preview

    /// Recompute the live preview of the open operation, or of the feature being edited:
    /// new bodies translucent (amber, red for cuts), changed bodies opaque and tinted in place of
    /// the originals, sketch operations as preview curves in the sketch.
    func updatePreview() async {
        guard let op = operation, !op.isReport, op != .addRelation, var items = invocations(for: op) else {
            clearOperationPreview()
            return
        }
        if let fid = editingFeature {
            guard let params = featureEditParams(fid, op) else { return clearOperationPreview() }
            items = [Invocation("feature.edit", ["feature": .string(fid), "params": params, "replace": .bool(op != .combine)])]
        }
        do {
            let (doc, changes) = try await engine.preview(items)
            guard let doc else { return clearOperationPreview() }
            previewError = nil
            if op.isSketchOperation {
                showSketchOperationPreview(doc)
                return
            }
            let created = changes.created.filter { $0.hasPrefix("body-") && doc.bodies[$0] != nil }
            let modified = changes.modified.filter { $0.hasPrefix("body-") && doc.bodies[$0] != nil }
            let deleted = changes.deleted.filter { $0.hasPrefix("body-") }
            guard !(created.isEmpty && modified.isEmpty && deleted.isEmpty) else { return clearOperationPreview() }
            let cut = op == .cutExtrude || op == .cutRevolve || op == .hole || (op == .combine && form.combine == "cut")
            let tint = cut ? RGBA(0.90, 0.28, 0.22) : RGBA(0.96, 0.64, 0.14)
            let edge = cut ? RGBA(0.72, 0.16, 0.12) : RGBA(0.80, 0.47, 0.0)
            var out: [RenderItem] = []
            let shown = created + modified
            if !shown.isEmpty {
                let ds = try DocumentScene(document: doc, bodies: shown, showSketches: false)
                for (i, item) in ds.scene.items.enumerated() where i < ds.bodies.count {
                    var o = item
                    o.objectID = ReferenceGeometry.firstObjectID + 100 + UInt32(out.count)
                    if created.contains(ds.bodies[i]) {
                        o.color = RGBA(tint.r, tint.g, tint.b, 0.40)
                    } else {
                        // The body as it would become, a little toward the preview colour.
                        o.color = Self.blend(item.color, tint, 0.3)
                    }
                    o.highlightedFaces = []
                    o.highlightedEdges = []
                    o.highlightAll = false
                    o.edgeColors = Dictionary(uniqueKeysWithValues: item.mesh.edgeIDs.map { ($0, edge) })
                    out.append(o)
                }
            }
            preview = PreviewBox(items: out, hidden: modified + deleted)
            previewVersion += 1
        } catch {
            previewError = ForgeError.wrap(error).message
            if !preview.items.isEmpty || !preview.hidden.isEmpty || !sketchState.opPreview.isEmpty {
                preview = PreviewBox()
                sketchState.opPreview = []
                previewVersion += 1
                overlayVersion += 1
            }
        }
    }

    static func blend(_ a: RGBA, _ b: RGBA, _ t: Float) -> RGBA {
        let s: Float = 1 - t
        let r: Float = a.r * s + b.r * t
        let g: Float = a.g * s + b.g * t
        let bl: Float = a.b * s + b.b * t
        return RGBA(r, g, bl, 1)
    }

    /// Sketch operation preview: the curves of the previewed sketch that are new or moved.
    private func showSketchOperationPreview(_ doc: Document) {
        guard let id = activeSketch, let after = doc.sketches[id] else { return clearOperationPreview() }
        let before = sketchState.sketch
        var lines: [[Point2]] = []
        for (eid, e) in after.entities where e.kind != .point {
            let pl = after.polyline(eid)
            if let before, before.entities[eid] != nil {
                let old = before.polyline(eid)
                if old.count == pl.count && zip(old, pl).allSatisfy({ abs($0.0 - $1.0) < 1e-9 && abs($0.1 - $1.1) < 1e-9 }) { continue }
            }
            lines.append(pl.map { Point2($0.0, $0.1) })
        }
        sketchState.opPreview = lines
        overlayVersion += 1
    }

    func clearOperationPreview() {
        previewError = nil
        if !sketchState.opPreview.isEmpty {
            sketchState.opPreview = []
            overlayVersion += 1
        }
        guard !preview.items.isEmpty || !preview.hidden.isEmpty else { return }
        preview = PreviewBox()
        previewVersion += 1
    }

    /// Changes whenever something the preview depends on changes.
    var previewKey: String {
        guard let op = operation else { return "" }
        let f = form
        return [op.title, operationSketch ?? "", f.depth, f.endCondition.rawValue, String(f.reverse), String(f.direction2), f.endCondition2.rawValue, f.depth2,
                String(f.merge), f.scope.joined(separator: ","), f.seeds.joined(separator: ","), f.linDirection, f.linSpacing, f.linCount, String(f.linReverse),
                String(f.linDirection2On), f.linDirection2, f.linSpacing2, f.linCount2, f.cirAxis, f.cirAngle, f.cirCount, String(f.cirEqual),
                String(f.cirReverse), f.mirrorPlane, f.holeType, f.holeSize, f.holeFit, f.holeEnd, f.holeDepth, String(f.holeReverse), String(f.draftOn), f.draftAngle, String(f.draftOutward), String(f.thinOn), f.thinType,
                f.thinThickness, f.thinThickness2, String(f.thinReverse), f.axis, f.angle, f.width, f.height, f.boxDepth, f.cylRadius, f.cylHeight,
                f.sphereRadius, f.coneBase, f.coneTop, f.coneHeight, f.torusMajor, f.torusMinor, f.chamferType, f.chamferDistance,
                f.chamferDistance2, f.chamferAngle, f.radius, f.shellThickness, String(f.shellOutward), f.shellFaces.joined(separator: ","),
                f.draftNeutral, f.draftFaces.joined(separator: ","), String(f.draftReverse), f.draftFeatureAngle, f.planeReference, f.planeOffset,
                String(f.planeFlip), f.combine, f.target, f.tool, f.offsetDistance, String(f.offsetReverse), String(f.offsetBoth), String(f.offsetCaps),
                f.mirrorAxis, f.patternCount, f.patternSpacing, f.patternDirection, String(f.patternDirection2On), f.patternCount2, f.patternSpacing2,
                f.patternDirection2, f.circularCount, f.circularAngle, f.circularCenter, f.moveDX, f.moveDY, String(f.copy), f.rotateAngle,
                f.rotateCenter, f.scaleFactor, f.scaleCenter, editingFeature ?? "", selection.joined(separator: ","), String(sceneVersion)].joined(separator: "|")
    }

    // MARK: commit

    func commitOperation() async {
        guard let op = operation else { return }
        var ok: CommandOutcome?
        if let fid = editingFeature {
            await commitFeatureEdit(fid, op)
            return
        }
        if op.isReport || op == .addRelation {
            operation = nil
            return
        }
        guard let items = invocations(for: op) else {
            lastError = ForgeError(.invalidParams, missingInputMessage(op))
            return
        }
        if activeSketch != nil && op != .plane && !op.isSketchOperation { await exitSketch() }
        if items.count > 1 { await run("transaction.begin", ["label": .string(op.title)]) }
        for i in items {
            ok = await run(i.command, i.params)
            if ok == nil { break }
        }
        if items.count > 1 { await run(ok == nil ? "transaction.rollback" : "transaction.commit") }
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

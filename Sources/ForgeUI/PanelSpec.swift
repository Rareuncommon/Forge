// The PropertyManager as data: the page for the open operation, the active sketch tool, the
// sketch being edited or the selection, described as sections of controls bound to the model.
// Front ends without SwiftUI (Windows) turn it into native controls; it mirrors the macOS pages
// (Sources/ForgeApp/PMPages.swift) and is tested headless.

import ForgeCommands
import ForgeCore
import ForgeSketch
import Foundation

/// One control. `id` is stable while the page shows the same control, so a front end can keep
/// the native control (and its focus) across updates.
package struct PanelControl {
    package enum Kind {
        /// Text field (numbers with units); `submit` runs on Return / focus loss.
        case field(label: String, unit: String, get: () -> String, set: (String) -> Void, submit: (() -> Void)?)
        case check(label: String, get: () -> Bool, set: (Bool) -> Void)
        /// Drop-down or type list (one of `options`, by tag).
        case choice(label: String, options: [(tag: String, title: String)], get: () -> String, set: (String) -> Void)
        /// Selection box: picked references; `active` = receiving picks; `activate` makes it so.
        case list(items: [String], placeholder: String, active: Bool, activate: (() -> Void)?)
        case note(String, warning: Bool)
        /// Read-only value.
        case value(label: String, value: String)
        case buttons([(title: String, action: () -> Void)])
        /// Rows with an optional delete action (relations).
        case rows([(text: String, detail: String, problem: Bool, delete: (() -> Void)?)])
    }

    package var id: String
    package var kind: Kind

    /// Shape of the control (kind, label, options), for deciding whether the native control
    /// can be reused.
    package var signature: String {
        switch kind {
        case .field(let l, let u, _, _, let s): "field:\(l):\(u):\(s != nil)"
        case .check(let l, _, _): "check:\(l)"
        case .choice(let l, let o, _, _): "choice:\(l):" + o.map { "\($0.tag)=\($0.title)" }.joined(separator: ",")
        case .list(let items, let p, let a, _): "list:\(p):\(a):" + items.joined(separator: ",")
        case .note(let t, let w): "note:\(w):\(t)"
        case .value(let l, let v): "value:\(l):\(v)"
        case .buttons(let b): "buttons:" + b.map(\.title).joined(separator: ",")
        case .rows(let r): "rows:" + r.map { "\($0.text)|\($0.detail)|\($0.problem)" }.joined(separator: ",")
        }
    }
}

package struct PanelSection {
    package var title: String
    /// A check group (Direction 2, Thin Feature): the controls show only when it is on.
    package var toggle: (get: () -> Bool, set: (Bool) -> Void)?
    package var controls: [PanelControl]

    package init(_ title: String, toggle: (get: () -> Bool, set: (Bool) -> Void)? = nil, controls: [PanelControl]) {
        self.title = title
        self.toggle = toggle
        self.controls = controls
    }
}

package struct PanelPage {
    package var icon: ForgeIcon
    package var title: String
    package var subtitle: String
    /// Yellow message box.
    package var message: String?
    package var ok: (() -> Void)?
    package var cancel: (() -> Void)?
    package var sections: [PanelSection]

    /// Structure of the page: when it changes the front end rebuilds its controls; otherwise it
    /// only refreshes their values.
    package var signature: String {
        var lines: [String] = [title, subtitle, message ?? "", String(ok != nil), String(cancel != nil)]
        for s in sections {
            let toggle: String = s.toggle.map { "[\($0.get())]" } ?? ""
            lines.append("§" + s.title + toggle)
            for c in s.controls { lines.append(c.id + "=" + c.signature) }
        }
        return lines.joined(separator: "\n")
    }
}

extension AppModel {
    /// The PropertyManager page for the current state.
    package var panelPage: PanelPage {
        if let op = operation { return operationPage(op) }
        if activeSketch != nil, let tool = sketchState.tool { return toolPage(tool) }
        if activeSketch != nil { return sketchPage }
        return selectionPage
    }

    // MARK: building blocks

    private func field(_ id: String, _ label: String, unit: String = "", _ key: WritableKeyPath<OperationForm, String>) -> PanelControl {
        PanelControl(id: id, kind: .field(label: label, unit: unit, get: { [unowned self] in form[keyPath: key] }, set: { [unowned self] in form[keyPath: key] = $0 }, submit: nil))
    }

    private func check(_ id: String, _ label: String, _ key: WritableKeyPath<OperationForm, Bool>) -> PanelControl {
        PanelControl(id: id, kind: .check(label: label, get: { [unowned self] in form[keyPath: key] }, set: { [unowned self] in form[keyPath: key] = $0 }))
    }

    private func choice(_ id: String, _ label: String, _ options: [(tag: String, title: String)], _ key: WritableKeyPath<OperationForm, String>) -> PanelControl {
        PanelControl(id: id, kind: .choice(label: label, options: options, get: { [unowned self] in form[keyPath: key] }, set: { [unowned self] in form[keyPath: key] = $0 }))
    }

    private func toolChoice<T: RawRepresentable & CaseIterable>(_ id: String, _ label: String, _ key: WritableKeyPath<SketchUIState, T>) -> PanelControl
    where T.RawValue == String {
        PanelControl(id: id, kind: .choice(
            label: label, options: T.allCases.map { (tag: $0.rawValue, title: $0.rawValue) },
            get: { [unowned self] in sketchState[keyPath: key].rawValue },
            set: { [unowned self] in if let v = T(rawValue: $0) { sketchState[keyPath: key] = v } }))
    }

    private func toolCheck(_ id: String, _ label: String, _ key: WritableKeyPath<SketchUIState, Bool>) -> PanelControl {
        PanelControl(id: id, kind: .check(label: label, get: { [unowned self] in sketchState[keyPath: key] }, set: { [unowned self] in sketchState[keyPath: key] = $0 }))
    }

    private func toolNumber(_ id: String, _ label: String, unit: String, _ key: WritableKeyPath<SketchUIState, Double>) -> PanelControl {
        PanelControl(id: id, kind: .field(
            label: label, unit: unit, get: { [unowned self] in String(format: "%g", sketchState[keyPath: key]) },
            set: { [unowned self] in if let v = Double($0), v > 0 { sketchState[keyPath: key] = v } }, submit: nil))
    }

    private func note(_ id: String, _ text: String, warning: Bool = false) -> PanelControl {
        PanelControl(id: id, kind: .note(text, warning: warning))
    }

    private var sketchChoice: PanelControl {
        PanelControl(id: "sketch", kind: .choice(
            label: "Sketch", options: sketches.map { (tag: $0.id, title: $0.name) },
            get: { [unowned self] in operationSketch ?? "" }, set: { [unowned self] in operationSketch = $0 }))
    }

    private var planeOptions: [(tag: String, title: String)] {
        [("front", "Front Plane"), ("top", "Top Plane"), ("right", "Right Plane")] + refPlanes.map { ($0.id, $0.name) }
    }

    /// Plane options plus the selected face and the current value when it is a face.
    private func planeOrFaceOptions(current: String) -> [(tag: String, title: String)] {
        var o = planeOptions
        if let f = selectedFace { o.append((f, "Selected face (\(shortName(f)))")) }
        if current.contains("/face-") && current != selectedFace { o.append((current, shortName(current))) }
        return o
    }

    private func directionChoice(_ id: String, _ key: WritableKeyPath<OperationForm, String>, axis: Bool) -> PanelControl {
        var o: [(tag: String, title: String)] = [("x", axis ? "X axis" : "X"), ("y", axis ? "Y axis" : "Y"), ("z", axis ? "Z axis" : "Z")]
        if let e = selectedEdges.first { o.append((e, "Selected edge (\(shortName(e)))")) }
        let cur = form[keyPath: key]
        if cur.contains("/") && cur != selectedEdges.first { o.append((cur, shortName(cur))) }
        return choice(id, "Direction", o, key)
    }

    private var seedSection: PanelSection {
        PanelSection("Features and Faces", controls: [
            PanelControl(id: "seeds", kind: .list(
                items: form.seeds.map { id in features.first { $0.id == id }?.name ?? id }, placeholder: "Features to pattern (click them in the tree)",
                active: true, activate: nil)),
        ])
    }

    private var endConditionOptions: [(tag: String, title: String)] {
        EndConditionUI.allCases.filter { operation == .cutExtrude || !bodies.isEmpty || $0.needsDepth }.map { ($0.rawValue, $0.rawValue) }
    }

    // MARK: operations

    private func operationPage(_ op: Operation) -> PanelPage {
        let editing = features.first { $0.id == editingFeature }
        var page = PanelPage(
            icon: op.icon, title: editing?.name ?? op.title, subtitle: editing == nil ? operationSubtitle(op) : "Editing feature",
            message: operationMessage(op), ok: op.isReport || op == .addRelation ? nil : { [unowned self] in Task { await commitOperation() } },
            cancel: { [unowned self] in cancelOperation() }, sections: [])
        let f = form
        var s: [PanelSection] = []
        switch op {
        case .extrude, .cutExtrude:
            var d1: [PanelControl] = [
                PanelControl(id: "end", kind: .choice(
                    label: "End condition", options: endConditionOptions, get: { [unowned self] in form.endCondition.rawValue },
                    set: { [unowned self] in if let v = EndConditionUI(rawValue: $0) { form.endCondition = v } })),
            ]
            if f.endCondition != .midPlane && f.endCondition != .throughAllBoth { d1.append(check("reverse", "Reverse direction", \.reverse)) }
            if f.endCondition.needsDepth { d1.append(field("depth", "Depth", unit: "mm", \.depth)) }
            if op == .extrude && !bodies.isEmpty && editingFeatureCreatesBody != true { d1.append(check("merge", "Merge result", \.merge)) }
            if !f.direction2 && f.endCondition != .midPlane && f.endCondition != .throughAllBoth {
                d1.append(check("draftOn", "Draft On/Off", \.draftOn))
                if f.draftOn {
                    d1.append(field("draftAngle", "Draft angle", unit: "°", \.draftAngle))
                    d1.append(check("draftOutward", "Draft outward", \.draftOutward))
                }
            }
            s.append(PanelSection("Direction 1", controls: d1))
            if f.endCondition != .midPlane && f.endCondition != .throughAllBoth {
                var d2: [PanelControl] = [
                    PanelControl(id: "end2", kind: .choice(
                        label: "End condition", options: [EndConditionUI.blind, .throughAll].filter { $0 == .blind || !bodies.isEmpty }.map { ($0.rawValue, $0.rawValue) },
                        get: { [unowned self] in form.endCondition2.rawValue }, set: { [unowned self] in if let v = EndConditionUI(rawValue: $0) { form.endCondition2 = v } })),
                ]
                if f.endCondition2 == .blind { d2.append(field("depth2", "Depth", unit: "mm", \.depth2)) }
                s.append(PanelSection("Direction 2", toggle: (get: { [unowned self] in form.direction2 }, set: { [unowned self] in form.direction2 = $0 }), controls: d2))
            }
            var thin = [choice("thinType", "Type", [("one_direction", "One-Direction"), ("mid_plane", "Mid-Plane"), ("two_direction", "Two-Direction")], \.thinType),
                        field("thinThickness", "Thickness", unit: "mm", \.thinThickness)]
            if f.thinType == "two_direction" { thin.append(field("thinThickness2", "Thickness 2", unit: "mm", \.thinThickness2)) }
            if f.thinType == "one_direction" { thin.append(check("thinReverse", "Reverse (inside the profile)", \.thinReverse)) }
            s.append(PanelSection("Thin Feature", toggle: (get: { [unowned self] in form.thinOn }, set: { [unowned self] in form.thinOn = $0 }), controls: thin))
            s.append(PanelSection("Selected Contours", controls: [
                sketchChoice, note("contoursNote", "All closed regions of the sketch are used; holes and islands are kept."),
            ]))
            if op == .cutExtrude || f.merge && !bodies.isEmpty {
                var scope: [PanelControl] = [
                    PanelControl(id: "scopeAll", kind: .check(label: "All bodies", get: { [unowned self] in form.scope.isEmpty }, set: { [unowned self] all in
                        form.scope = all ? [] : (selectedBodies.isEmpty ? bodies.prefix(1).map(\.id) : selectedBodies)
                    })),
                ]
                if !f.scope.isEmpty {
                    for b in bodies {
                        scope.append(PanelControl(id: "scope-" + b.id, kind: .check(label: b.name, get: { [unowned self] in form.scope.contains(b.id) }, set: { [unowned self] on in
                            if on { form.scope.append(b.id) } else { form.scope.removeAll { $0 == b.id } }
                        })))
                    }
                }
                s.append(PanelSection("Feature Scope", controls: scope))
            }
        case .revolve, .cutRevolve:
            let lines = revolveAxisOptions
            var axis = [choice("axis", "Axis", [("", "Select an axis")] + lines.map { ($0, $0) }, \.axis)]
            if lines.isEmpty { axis.append(note("axisNote", "The sketch has no line to revolve about.", warning: true)) }
            s.append(PanelSection("Axis of Revolution", controls: axis))
            var d1 = [field("angle", "Angle", unit: "°", \.angle)]
            if op == .revolve && !bodies.isEmpty && editingFeatureCreatesBody != true { d1.append(check("merge", "Merge result", \.merge)) }
            s.append(PanelSection("Direction 1", controls: d1))
            s.append(PanelSection("Selected Contours", controls: [sketchChoice]))
        case .hole:
            s.append(PanelSection("Hole Type", controls: [
                choice("holeType", "Type", [("counterbore", "Counterbore"), ("countersink", "Countersink"), ("hole", "Hole"), ("tapped", "Straight Tap")], \.holeType),
                PanelControl(id: "standard", kind: .value(label: "Standard", value: "ISO")),
            ]))
            var spec = [choice("holeSize", "Size", ["M2", "M2.5", "M3", "M4", "M5", "M6", "M8", "M10", "M12", "M16", "M20"].map { ($0, $0) }, \.holeSize)]
            if f.holeType != "tapped" { spec.append(choice("holeFit", "Fit", [("close", "Close"), ("normal", "Normal"), ("loose", "Loose")], \.holeFit)) }
            s.append(PanelSection("Hole Specifications", controls: spec))
            var end = [choice("holeEnd", "End condition", [("blind", "Blind"), ("through_all", "Through All")], \.holeEnd)]
            if f.holeEnd == "blind" { end.append(field("holeDepth", "Depth", unit: "mm", \.holeDepth)) }
            if f.holeType == "tapped" { end.append(field("threadDepth", "Thread depth", unit: "mm", \.holeThreadDepth)) }
            end.append(check("holeReverse", "Reverse direction", \.holeReverse))
            s.append(PanelSection("End Condition", controls: end))
            s.append(PanelSection("Positions", controls: [
                sketchChoice, note("holeNote", "A hole is drilled at each point of the sketch (its plane is where the holes start). Sketch the points on the face first."),
            ]))
        case .linearPattern:
            s.append(PanelSection("Direction 1", controls: [
                directionChoice("dir", \.linDirection, axis: false), check("linReverse", "Reverse direction", \.linReverse),
                field("spacing", "Spacing", unit: "mm", \.linSpacing), field("count", "Instances", \.linCount),
            ]))
            s.append(PanelSection("Direction 2", toggle: (get: { [unowned self] in form.linDirection2On }, set: { [unowned self] in form.linDirection2On = $0 }), controls: [
                directionChoice("dir2", \.linDirection2, axis: false), field("spacing2", "Spacing", unit: "mm", \.linSpacing2), field("count2", "Instances", \.linCount2),
            ]))
            s.append(seedSection)
        case .circularPattern:
            s.append(PanelSection("Direction 1", controls: [
                directionChoice("axis", \.cirAxis, axis: true), check("cirReverse", "Reverse direction", \.cirReverse),
                field("angle", "Angle", unit: "°", \.cirAngle), field("count", "Instances", \.cirCount), check("equal", "Equal spacing", \.cirEqual),
            ]))
            s.append(seedSection)
        case .mirror:
            s.append(PanelSection("Mirror Face/Plane", controls: [choice("plane", "Plane", planeOrFaceOptions(current: f.mirrorPlane), \.mirrorPlane)]))
            s.append(seedSection)
        case .plane:
            s.append(PanelSection("First Reference", controls: [
                choice("reference", "Reference", planeOrFaceOptions(current: f.planeReference), \.planeReference),
                field("offset", "Offset", unit: "mm", \.planeOffset), check("flip", "Flip offset", \.planeFlip),
            ]))
        case .fillet:
            s.append(PanelSection("Items To Fillet", controls: [
                PanelControl(id: "items", kind: .list(items: filletItems.map(shortName), placeholder: "Edges and faces", active: true, activate: nil)),
            ]))
            s.append(PanelSection("Fillet Parameters", controls: [field("radius", "Radius", unit: "mm", \.radius)]))
        case .chamfer:
            s.append(PanelSection("Chamfer Type", controls: [
                choice("chamferType", "Type", [("angle_distance", "Angle Distance"), ("distance_distance", "Distance Distance"), ("equal_distance", "Equal Distance")], \.chamferType),
            ]))
            s.append(PanelSection("Items To Chamfer", controls: [
                PanelControl(id: "items", kind: .list(items: filletItems.map(shortName), placeholder: "Edges and faces", active: true, activate: nil)),
            ]))
            var p = [field("distance", "Distance", unit: "mm", \.chamferDistance)]
            if f.chamferType == "distance_distance" { p.append(field("distance2", "Distance 2", unit: "mm", \.chamferDistance2)) }
            if f.chamferType == "angle_distance" { p.append(field("chamferAngle", "Angle", unit: "°", \.chamferAngle)) }
            s.append(PanelSection("Chamfer Parameters", controls: p))
        case .shell:
            s.append(PanelSection("Parameters", controls: [
                field("thickness", "Thickness", unit: "mm", \.shellThickness),
                PanelControl(id: "faces", kind: .list(items: f.shellFaces.map(shortName), placeholder: "Faces to Remove (none: hollow closed body)", active: true, activate: nil)),
                check("outward", "Shell outward", \.shellOutward),
            ]))
        case .draft:
            s.append(PanelSection("Draft Angle", controls: [field("angle", "Angle", unit: "°", \.draftFeatureAngle)]))
            s.append(PanelSection("Neutral Plane", controls: [
                PanelControl(id: "neutral", kind: .list(
                    items: f.draftNeutral.isEmpty ? [] : [shortName(f.draftNeutral)], placeholder: "A planar face", active: f.activeBox == "neutral",
                    activate: { [unowned self] in form.activeBox = "neutral" })),
                check("draftReverse", "Reverse direction", \.draftReverse),
            ]))
            s.append(PanelSection("Faces to Draft", controls: [
                PanelControl(id: "faces", kind: .list(
                    items: f.draftFaces.map(shortName), placeholder: "Faces", active: f.activeBox == "faces", activate: { [unowned self] in form.activeBox = "faces" })),
            ]))
        case .combine:
            let bodyOptions = bodies.map { (tag: $0.id, title: $0.name) }
            s.append(PanelSection("Operation Type", controls: [choice("combine", "Operation", [("fuse", "Add"), ("cut", "Subtract"), ("common", "Common")], \.combine)]))
            s.append(PanelSection(f.combine == "cut" ? "Main Body" : "Bodies to Combine", controls: [
                choice("target", f.combine == "cut" ? "Main body" : "Body", bodyOptions, \.target),
                choice("tool", f.combine == "cut" ? "Subtract" : "Body", bodyOptions, \.tool),
            ]))
        case .primitive(let p):
            let c: [PanelControl]
            switch p {
            case .box: c = [field("width", "Width", unit: "mm", \.width), field("height", "Height", unit: "mm", \.height), field("depth", "Depth", unit: "mm", \.boxDepth)]
            case .cylinder: c = [field("radius", "Radius", unit: "mm", \.cylRadius), field("height", "Height", unit: "mm", \.cylHeight)]
            case .sphere: c = [field("radius", "Radius", unit: "mm", \.sphereRadius)]
            case .cone:
                c = [field("base", "Base radius", unit: "mm", \.coneBase), field("top", "Top radius", unit: "mm", \.coneTop), field("height", "Height", unit: "mm", \.coneHeight)]
            case .torus: c = [field("major", "Major radius", unit: "mm", \.torusMajor), field("minor", "Minor radius", unit: "mm", \.torusMinor)]
            }
            s.append(PanelSection("Parameters", controls: c))
        case .massProperties, .measure, .check:
            let rows = form.result.map(Self.keyValues) ?? []
            s.append(PanelSection(op == .measure ? "Measure" : "Results", controls: rows.isEmpty
                ? [note("empty", op == .measure ? "Select two faces, edges, vertices or bodies." : "Select a body.")]
                : rows.enumerated().map { i, kv in PanelControl(id: "r\(i)", kind: .value(label: kv.0, value: kv.1)) }))
        case .addRelation:
            s += [selectedEntitiesSection, relationsSection(all: false), relationButtonsSection].compactMap { $0 }
        case .displayRelations:
            s += [relationsSection(all: sketchSelection.isEmpty)].compactMap { $0 }
        case .sketchOffset:
            s.append(selectedEntitiesSection)
            s.append(PanelSection("Parameters", controls: [
                field("distance", "Distance", unit: "mm", \.offsetDistance), check("reverse", "Reverse", \.offsetReverse), check("both", "Bi-directional", \.offsetBoth),
                check("caps", "Cap ends", \.offsetCaps), check("baseConstruction", "Base geometry: construction", \.offsetBaseConstruction),
            ]))
        case .sketchMirror:
            s.append(PanelSection("Entities to mirror", controls: [
                PanelControl(id: "entities", kind: .list(items: sketchSelection.filter { $0 != f.mirrorAxis }, placeholder: "Sketch entities", active: true, activate: nil)),
            ]))
            let lines = sketchSelection.filter { sketchState.sketch?.entities[$0]?.kind == .line }
            s.append(PanelSection("Mirror about", controls: [choice("axis", "Line", [("", "Select a line")] + lines.map { ($0, $0) }, \.mirrorAxis)]))
        case .sketchLinearPattern:
            s.append(selectedEntitiesSection)
            s.append(PanelSection("Direction 1", controls: [
                field("spacing", "Spacing", unit: "mm", \.patternSpacing), field("count", "Instances", \.patternCount), field("angle", "Angle", unit: "°", \.patternDirection),
            ]))
            s.append(PanelSection("Direction 2", toggle: (get: { [unowned self] in form.patternDirection2On }, set: { [unowned self] in form.patternDirection2On = $0 }), controls: [
                field("spacing2", "Spacing", unit: "mm", \.patternSpacing2), field("count2", "Instances", \.patternCount2), field("angle2", "Angle", unit: "°", \.patternDirection2),
            ]))
        case .sketchCircularPattern:
            s.append(selectedEntitiesSection)
            s.append(PanelSection("Parameters", controls: [
                field("center", "Centre", unit: "u, v", \.circularCenter), field("angle", "Angle", unit: "°", \.circularAngle), field("count", "Instances", \.circularCount),
            ]))
        case .sketchMove, .sketchRotate, .sketchScale:
            s.append(selectedEntitiesSection)
            s.append(PanelSection("Options", controls: [check("copy", "Copy", \.copy), check("keep", "Keep relations", \.keepRelations)]))
            switch op {
            case .sketchMove: s.append(PanelSection("Parameters", controls: [field("dx", "ΔX", unit: "mm", \.moveDX), field("dy", "ΔY", unit: "mm", \.moveDY)]))
            case .sketchRotate: s.append(PanelSection("Parameters", controls: [field("center", "Centre", unit: "u, v", \.rotateCenter), field("angle", "Angle", unit: "°", \.rotateAngle)]))
            default: s.append(PanelSection("Parameters", controls: [field("center", "Scale about", unit: "u, v", \.scaleCenter), field("factor", "Factor", \.scaleFactor)]))
            }
        }
        if let e = previewError, invocations(for: op) != nil {
            s.append(PanelSection("", controls: [note("previewError", "Cannot preview: \(e)", warning: true)]))
        }
        page.sections = s
        return page
    }

    private func operationSubtitle(_ op: Operation) -> String {
        switch op {
        case .extrude, .cutExtrude, .revolve, .cutRevolve, .hole: sketches.first { $0.id == operationSketch }?.name ?? "Choose a sketch"
        default: op.isSketchOperation ? "\(sketchSelection.count) selected" : ""
        }
    }

    /// The yellow message of an operation page (what to select next).
    package func operationMessage(_ op: Operation) -> String? {
        switch op {
        case _ where [Operation.extrude, .cutExtrude, .revolve, .cutRevolve].contains(op) && sketches.isEmpty: "Create a sketch with a closed profile first."
        case .revolve where form.axis.isEmpty, .cutRevolve where form.axis.isEmpty: "Select a centerline or line of the sketch as the axis of revolution."
        case .plane: "Select a planar face or choose a plane as the first reference, then the offset."
        case .hole where sketches.isEmpty: "Sketch points on a face first: each point is a hole position."
        case .linearPattern, .circularPattern, .mirror:
            "Click features in the tree to add or remove them (extrusions, revolutions, holes). Select an edge in the view for a direction or axis."
        case .fillet where filletItems.isEmpty: "Select edges or faces to fillet. Each click adds an item; click it again to remove it."
        case .chamfer where filletItems.isEmpty: "Select edges or faces to chamfer. Each click adds an item; click it again to remove it."
        case .shell: "Select the faces to remove. With none, the body becomes a closed hollow shell."
        case .draft: form.activeBox == "neutral" ? "Select the neutral plane: a planar face." : "Select the faces to draft."
        case .combine: "Click the bodies to combine in the view: the main body first."
        case .measure where selection.count != 2: "Select two entities to measure between."
        case .sketchMirror where form.mirrorAxis.isEmpty: "Select the entities to mirror and a line (ideally a centerline) to mirror about."
        case .sketchOffset, .sketchLinearPattern, .sketchCircularPattern, .sketchMove, .sketchRotate, .sketchScale:
            sketchSelection.isEmpty ? "Select the sketch entities in the view." : nil
        case .addRelation: sketchSelection.isEmpty ? "Select the sketch entities to relate." : nil
        default: nil
        }
    }

    /// Flattened key/value rows of a result (mass properties, measure, check).
    package static func keyValues(_ v: JSONValue) -> [(String, String)] {
        func text(_ v: JSONValue) -> String {
            switch v {
            case .number(let d): String(format: abs(d) >= 1e5 || (abs(d) < 1e-3 && d != 0) ? "%.4g" : "%.4f", d)
            case .string(let s): s
            case .bool(let b): b ? "yes" : "no"
            case .array(let a): a.map(text).joined(separator: ", ")
            case .object: "…"
            case .null: "—"
            }
        }
        guard case .object(let o) = v else { return [("Result", text(v))] }
        return o.keys.sorted().flatMap { k -> [(String, String)] in
            let label = k.replacingOccurrences(of: "_", with: " ").capitalized
            if case .object = o[k]! { return keyValues(o[k]!).map { ("\(label) \($0.0)", $0.1) } }
            return [(label, text(o[k]!))]
        }
    }

    // MARK: sketch

    private var selectedEntitiesSection: PanelSection {
        PanelSection("Selected Entities", controls: [
            PanelControl(id: "entities", kind: .list(items: sketchSelection, placeholder: "Sketch entities", active: true, activate: nil)),
        ])
    }

    private var relationButtonsSection: PanelSection? {
        let options = applicableRelations
        guard !options.isEmpty else { return nil }
        return PanelSection("Add Relations", controls: [
            PanelControl(id: "relations", kind: .buttons(options.map { r in
                (title: (Self.glyph(r.kind).map { $0 + " " } ?? "") + r.title, action: { [unowned self] in Task { await addRelation(r) } })
            })),
        ])
    }

    private func relationsSection(all: Bool) -> PanelSection? {
        let picked = Set(sketchSelection)
        let sk = sketchState.sketch
        let problems = Set((sk?.report?.conflicting ?? []) + (sk?.report?.redundant ?? []))
        let related = (sk?.userConstraints ?? []).filter { c in all || c.entities.contains { picked.contains($0) } }
        guard !related.isEmpty || all else { return nil }
        var controls: [PanelControl] = []
        if related.isEmpty { controls.append(note("none", "The sketch has no relations.")) }
        controls.append(PanelControl(id: "list", kind: .rows(related.map { c in
            let name = c.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
            let value = c.value.map { c.kind == .angle ? String(format: " %.1f°", $0 * 180 / .pi) : String(format: " %.2f", $0) } ?? ""
            let bad = problems.contains(c.id)
            return (text: (Self.glyph(c.kind).map { $0 + " " } ?? "") + name + value + (c.driven ? " (driven)" : ""),
                    detail: (all ? c.entities.joined(separator: ", ") + " · " : "") + (bad ? "Over Defining" : "Satisfied"),
                    problem: bad, delete: { [unowned self] in Task { await run("sketch.delete", ["items": [.string(c.id)]]) } })
        })))
        if all && related.count > 1 {
            controls.append(PanelControl(id: "deleteAll", kind: .buttons([(title: "Delete All", action: { [unowned self] in
                Task { await run("sketch.delete", ["items": .array(related.map { .string($0.id) })]) }
            })])))
        }
        return PanelSection(all ? "Relations" : "Existing Relations", controls: controls)
    }

    private var sketchActionsSection: PanelSection {
        PanelSection("Actions", controls: [
            PanelControl(id: "actions", kind: .buttons([
                (title: "Smart Dimension", action: { [unowned self] in dimensionSelection() }),
                (title: "Construction", action: { [unowned self] in Task { await toggleConstruction() } }),
                (title: "Delete", action: { [unowned self] in Task { await deleteSketchSelection() } }),
            ])),
        ])
    }

    private func toolPage(_ tool: SketchTool) -> PanelPage {
        let st = sketchState
        var s: [PanelSection] = []
        let construction = PanelSection("Options", controls: [toolCheck("construction", "For construction", \.forConstruction)])
        switch tool {
        case .line:
            s = [PanelSection("Line Type", controls: [toolChoice("kind", "Type", \.lineKind)]),
                 PanelSection("Orientation", controls: [toolChoice("orientation", "Orientation", \.lineOrientation)]), construction]
        case .rectangle: s = [PanelSection("Rectangle Type", controls: [toolChoice("type", "Type", \.rectangleType)]), construction]
        case .circle: s = [PanelSection("Circle Type", controls: [toolChoice("type", "Type", \.circleType)]), construction]
        case .arc: s = [PanelSection("Arc Type", controls: [toolChoice("type", "Type", \.arcType)]), construction]
        case .slot: s = [PanelSection("Slot Types", controls: [toolChoice("type", "Type", \.slotType)])]
        case .polygon:
            s = [PanelSection("Parameters", controls: [
                PanelControl(id: "sides", kind: .field(
                    label: "Sides", unit: "", get: { [unowned self] in String(sketchState.polygonSides) },
                    set: { [unowned self] in sketchState.polygonSides = min(40, max(3, Int($0) ?? sketchState.polygonSides)) }, submit: nil)),
                PanelControl(id: "inscribed", kind: .choice(
                    label: "Construction circle", options: [("in", "Inscribed circle"), ("out", "Circumscribed circle")],
                    get: { [unowned self] in sketchState.polygonInscribed ? "in" : "out" }, set: { [unowned self] in sketchState.polygonInscribed = $0 == "in" })),
            ])]
        case .ellipse: s = [PanelSection("Ellipse Type", controls: [toolChoice("type", "Type", \.ellipseType)])]
        case .spline: s = [construction]
        case .fillet:
            s = [PanelSection("Fillet Parameters", controls: [
                toolNumber("radius", "Radius", unit: "mm", \.filletRadius),
                note("filletNote", "Constrained corners are kept: the virtual sharp keeps its dimensions and relations."),
            ])]
        case .chamfer:
            var c = [toolChoice("type", "Type", \.chamferType)]
            if st.chamferType == .distanceDistance { c.append(toolCheck("equal", "Equal distance", \.chamferEqual)) }
            c.append(toolNumber("d1", "Distance 1", unit: "mm", \.chamferDistance))
            if st.chamferType == .angleDistance {
                c.append(toolNumber("angle", "Direction 1 angle", unit: "°", \.chamferAngle))
            } else if !st.chamferEqual {
                c.append(toolNumber("d2", "Distance 2", unit: "mm", \.chamferDistance2))
            }
            s = [PanelSection("Chamfer Parameters", controls: c)]
        case .trim: s = [PanelSection("Options", controls: [toolChoice("mode", "Mode", \.trimMode)])]
        case .point, .extend, .dimension: s = []
        }
        return PanelPage(
            icon: tool.icon, title: tool == .line ? "Insert \(st.lineKind.rawValue)" : tool.title, subtitle: "", message: toolMessage(tool), ok: nil,
            cancel: { [unowned self] in chooseTool(nil) }, sections: s)
    }

    private var sketchPage: PanelPage {
        let row = sketches.first { $0.id == activeSketch }
        let picked = sketchSelection
        if picked.count == 1, let sk = sketchState.sketch, let e = sk.entities[picked[0]] {
            return entityPage(e, sk)
        }
        if !picked.isEmpty {
            return PanelPage(
                icon: .sketch, title: "Properties", subtitle: "\(picked.count) entities", message: nil, ok: nil, cancel: nil,
                sections: [selectedEntitiesSection, relationsSection(all: false), relationButtonsSection, sketchActionsSection].compactMap { $0 })
        }
        var status: [PanelControl] = []
        if let row {
            let fixed = max(0, row.unknowns - row.dof)
            status.append(PanelControl(id: "status", kind: .value(label: "Status", value: Self.statusText(row))))
            if row.unknowns > 0 { status.append(PanelControl(id: "dof", kind: .value(label: "Defined", value: "\(fixed) / \(row.unknowns)"))) }
        }
        return PanelPage(
            icon: .sketch, title: row?.name ?? "Sketch", subtitle: "on \(row?.plane ?? "") Plane",
            message: "Pick a tool in the Sketch tab, or select entities to see their properties. Double-click a dimension to change it.", ok: nil, cancel: nil,
            sections: status.isEmpty ? [] : [PanelSection("Sketch", controls: status)])
    }

    /// "Fully defined", "Under defined · 3 DOF"…
    package static func statusText(_ row: SketchRow) -> String {
        switch row.status {
        case .fullyDefined?: "Fully defined"
        case .underDefined?: "Under defined · \(row.dof) DOF"
        case .redundant?: "Redundant relations"
        case .conflicting?: "Over defined"
        case .failed?: "Cannot be solved"
        case nil: "Not solved"
        }
    }

    private func entityPage(_ e: SketchEntity, _ sk: Sketch) -> PanelPage {
        let title: String = switch e.kind {
        case .point: "Point"
        case .line: e.construction ? "Centerline" : "Line Properties"
        case .circle: "Circle"
        case .arc: "Arc"
        case .ellipse, .ellipseArc: "Ellipse"
        case .spline: "Spline"
        }
        func p(_ id: String) -> (Double, Double) { sk.point(id) }
        func fmt(_ x: Double) -> String { String(format: "%.2f", x) }
        func value(_ id: String, _ l: String, _ v: String) -> PanelControl { PanelControl(id: id, kind: .value(label: l, value: v)) }
        var params: [PanelControl] = []
        func pointFields(_ id: String, _ xl: String, _ yl: String) {
            let (u, v) = p(id)
            let kx = id + ".x", ky = id + ".y"
            params.append(PanelControl(id: kx, kind: .field(
                label: xl, unit: "mm", get: { [unowned self] in pointEdits[kx] ?? fmt(u) }, set: { [unowned self] in pointEdits[kx] = $0 },
                submit: { [unowned self] in let x = pointEdits[kx] ?? fmt(u), y = pointEdits[ky] ?? fmt(v); pointEdits = [:]; Task { await movePoint(id, u: x, v: y) } })))
            params.append(PanelControl(id: ky, kind: .field(
                label: yl, unit: "mm", get: { [unowned self] in pointEdits[ky] ?? fmt(v) }, set: { [unowned self] in pointEdits[ky] = $0 },
                submit: { [unowned self] in let x = pointEdits[kx] ?? fmt(u), y = pointEdits[ky] ?? fmt(v); pointEdits = [:]; Task { await movePoint(id, u: x, v: y) } })))
        }
        switch e.kind {
        case .point: pointFields(e.id, "X", "Y")
        case .line:
            let a = p(e.points[0]), b = p(e.points[1])
            params.append(value("length", "Length", fmt(hypot(b.0 - a.0, b.1 - a.1))))
            params.append(value("angle", "Angle", String(format: "%.2f°", atan2(b.1 - a.1, b.0 - a.0) * 180 / .pi)))
            pointFields(e.points[0], "Start X", "Start Y")
            pointFields(e.points[1], "End X", "End Y")
        case .circle:
            params.append(value("radius", "Radius", fmt(sk.params[e.params[0]])))
            pointFields(e.points[0], "Centre X", "Centre Y")
        case .arc:
            let c = p(e.points[0]), st = p(e.points[1])
            params.append(value("radius", "Radius", fmt(hypot(st.0 - c.0, st.1 - c.1))))
            pointFields(e.points[0], "Centre X", "Centre Y")
        case .ellipse, .ellipseArc:
            params.append(value("major", "Major", fmt(sk.params[e.params[0]])))
            params.append(value("minor", "Minor", fmt(sk.params[e.params[1]])))
            pointFields(e.points[0], "Centre X", "Centre Y")
        case .spline:
            params.append(value("points", "Points", "\(e.points.count)"))
            params.append(value("degree", "Degree", "\(e.degree ?? 3)"))
        }
        let options = PanelSection("Options", controls: [
            PanelControl(id: "construction", kind: .check(label: "For construction", get: { e.construction }, set: { [unowned self] _ in Task { await toggleConstruction() } })),
        ])
        return PanelPage(
            icon: entityIcon(e.id), title: title, subtitle: e.id, message: nil, ok: nil, cancel: nil,
            sections: [relationsSection(all: false), relationButtonsSection, options, PanelSection("Parameters", controls: params), sketchActionsSection].compactMap { $0 })
    }

    // MARK: selection

    private var selectionPage: PanelPage {
        if selection.isEmpty {
            return PanelPage(
                icon: .part, title: documentName, subtitle: "\(bodies.count) bodies · \(sketches.count) sketches",
                message: "Select a face, edge or body to see its properties. Double-click a plane in the tree to start a sketch.", ok: nil, cancel: nil, sections: [])
        }
        var s = [PanelSection("Selected", controls: [PanelControl(id: "selected", kind: .list(items: selection.map(shortName), placeholder: "", active: false, activate: nil))])]
        if let info = inspector {
            s.append(PanelSection("Properties", controls: Self.keyValues(info).enumerated().map { i, kv in PanelControl(id: "p\(i)", kind: .value(label: kv.0, value: kv.1)) }))
        }
        return PanelPage(
            icon: entityIcon(selection[0]), title: selection.count == 1 ? shortName(selection[0]) : "\(selection.count) selected", subtitle: "Selection",
            message: nil, ok: nil, cancel: nil, sections: s)
    }
}

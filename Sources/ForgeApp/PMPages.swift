// PropertyManager pages, one per tool and feature, laid out as SolidWorks lays them out
// (docs/research §1.3, §2.1, §2.4, §2.5): message box, type list, option groups, parameters.
// Only options the engine implements are shown.

import ForgeCommands
import ForgeCore
import ForgeSketch
import SwiftUI

func entityIcon(_ ref: String) -> ForgeIcon {
    if ref.contains("/face-") { return .plane }
    if ref.contains("/edge-") { return .line }
    if ref.contains("/vertex-") { return .point }
    let local = ref.split(separator: "/").last.map(String.init) ?? ref
    for (prefix, icon) in [("line", ForgeIcon.line), ("circle", .circle), ("arc", .arc), ("point", .point), ("spline", .spline), ("ellipse", .ellipse)]
    where local.hasPrefix(prefix) {
        return icon
    }
    return ref.hasPrefix("sketch-") ? .sketch : .part
}

func shortName(_ ref: String) -> String {
    ref.split(separator: "/").map(String.init).joined(separator: " · ")
}

// MARK: features and sketch operations

struct OperationPage: View {
    @Environment(AppModel.self) private var model
    let op: Operation
    @State private var lines: [String] = []

    var body: some View {
        @Bindable var model = model
        let commit: (() -> Void)? = op.isReport || op == .addRelation ? nil : { Task { await model.commitOperation() } }
        let editing = model.features.first { $0.id == model.editingFeature }
        PMHeader(icon: op.icon, title: editing?.name ?? op.title, subtitle: editing == nil ? subtitle : "Editing feature", onOK: commit,
                 onCancel: { model.cancelOperation() })
        if let message { PMMessage(text: message) }
        content
            .task(id: model.previewKey) {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                await model.updatePreview()
            }
        if let e = model.previewError, model.invocations(for: op) != nil {
            PMNote(text: "Cannot preview: \(e)", warning: true).padding(14)
        }
    }

    private var message: String? {
        switch op {
        case _ where [Operation.extrude, .cutExtrude, .revolve].contains(op) && model.sketches.isEmpty: "Create a sketch with a closed profile first."
        case .revolve where model.form.axis.isEmpty: "Select a centerline or line of the sketch as the axis of revolution."
        case .fillet where model.selectedEdges.isEmpty: "Select the edges to fillet (⇧-click adds)."
        case .measure where model.selection.count != 2: "Select two entities to measure between."
        case .sketchMirror where model.form.mirrorAxis.isEmpty: "Select the entities to mirror and a line (ideally a centerline) to mirror about."
        case .sketchOffset, .sketchLinearPattern, .sketchCircularPattern, .sketchMove, .sketchRotate, .sketchScale:
            model.sketchSelection.isEmpty ? "Select the sketch entities in the view (⇧-click adds)." : nil
        case .addRelation: model.sketchSelection.isEmpty ? "Select the sketch entities to relate." : nil
        default: nil
        }
    }

    @ViewBuilder private var content: some View {
        @Bindable var model = model
        switch op {
        case .extrude, .cutExtrude:
            PMSection("From") {
                PMPicker(label: "", selection: .constant(0)) { Text("Sketch Plane").tag(0) }
            }
            PMSection("Direction 1") {
                HStack(spacing: 6) {
                    Button { model.form.reverse.toggle() } label: {
                        IconView(icon: .prevView, size: 15).foregroundStyle(model.form.reverse ? Theme.accentText : Theme.text2)
                            .frame(width: 28, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(model.form.reverse ? Theme.accentSoft : Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.fieldLine))
                    }
                    .buttonStyle(.plain)
                    .help("Reverse Direction")
                    .disabled(model.form.endCondition == .midPlane || model.form.endCondition == .throughAllBoth)
                    Picker("End condition", selection: $model.form.endCondition) {
                        ForEach(EndConditionUI.allCases.filter { op == .cutExtrude || !model.bodies.isEmpty || $0.needsDepth }, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                if model.form.endCondition.needsDepth {
                    PMField(label: "Depth", text: $model.form.depth, unit: "mm", icon: .smartDimension, help: "mm, or with units: 0.5 in")
                }
                if op == .extrude && !model.bodies.isEmpty && model.editingFeatureCreatesBody != true {
                    PMCheckbox(label: "Merge result", isOn: $model.form.merge)
                }
            }
            if model.form.endCondition != .midPlane && model.form.endCondition != .throughAllBoth {
                PMCheckGroup(title: "Direction 2", isOn: $model.form.direction2) {
                    Picker("End condition", selection: $model.form.endCondition2) {
                        ForEach([EndConditionUI.blind, .throughAll].filter { $0 == .blind || !model.bodies.isEmpty }, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    if model.form.endCondition2 == .blind {
                        PMField(label: "Depth", text: $model.form.depth2, unit: "mm", icon: .smartDimension)
                    }
                }
            }
            PMSection("Selected Contours") {
                PMPicker(label: "Sketch", selection: Binding(get: { model.operationSketch ?? "" }, set: { model.operationSketch = $0 }), icon: .sketch) {
                    ForEach(model.sketches) { Text($0.name).tag($0.id) }
                }
                PMNote(text: "All closed regions of the sketch are used; holes and islands are kept.")
            }
            if op == .cutExtrude || model.form.merge && !model.bodies.isEmpty {
                PMSection("Feature Scope") {
                    PMTypeList(options: [(value: true, icon: .part, title: "All bodies"), (value: false, icon: .part, title: "Selected bodies")],
                               selection: Binding(get: { model.form.scope.isEmpty }, set: { all in
                                   model.form.scope = all ? [] : (model.selectedBodies.isEmpty ? model.bodies.prefix(1).map(\.id) : model.selectedBodies)
                               }))
                    if !model.form.scope.isEmpty {
                        ForEach(model.bodies, id: \.id) { b in
                            PMCheckbox(label: b.name, isOn: Binding(get: { model.form.scope.contains(b.id) }, set: { on in
                                if on { model.form.scope.append(b.id) } else { model.form.scope.removeAll { $0 == b.id } }
                            }))
                        }
                    }
                }
            }
        case .revolve:
            PMSection("Axis of Revolution") {
                PMPicker(label: "", selection: $model.form.axis, icon: .axis) {
                    Text("Select an axis").tag("")
                    ForEach(lines, id: \.self) { Text($0).tag($0) }
                }
                .task(id: model.operationSketch) {
                    lines = await model.sketchLines(model.operationSketch)
                    if model.form.axis.isEmpty || !lines.contains(model.form.axis), let first = lines.first,
                        model.sketchState.sketch?.entities[first]?.construction ?? true
                    {
                        model.form.axis = first
                    }
                }
            }
            PMSection("Direction 1") {
                PMPicker(label: "", selection: .constant(0), icon: .revolve) { Text("Blind").tag(0) }
                PMField(label: "Angle", text: $model.form.angle, unit: "°", icon: .arc)
                if !model.bodies.isEmpty && model.editingFeatureCreatesBody != true {
                    PMCheckbox(label: "Merge result", isOn: $model.form.merge)
                }
            }
            PMSection("Selected Contours") {
                PMPicker(label: "Sketch", selection: Binding(get: { model.operationSketch ?? "" }, set: { model.operationSketch = $0 }), icon: .sketch) {
                    ForEach(model.sketches) { Text($0.name).tag($0.id) }
                }
            }
        case .fillet:
            PMSection("Fillet Type") {
                PMTypeList(options: [(value: 0, icon: .fillet, title: "Constant Size Fillet")], selection: .constant(0))
            }
            PMSection("Items To Fillet") {
                PMSelectionBox(items: model.selectedEdges.map { (icon: ForgeIcon.line, text: shortName($0)) }, placeholder: "Edges")
            }
            PMSection("Fillet Parameters") {
                PMPicker(label: "", selection: .constant(0)) { Text("Symmetric").tag(0) }
                PMField(label: "Radius", text: $model.form.radius, unit: "mm", icon: .smartDimension)
                PMPicker(label: "Profile", selection: .constant(0)) { Text("Circular").tag(0) }
            }
        case .combine:
            PMSection("Operation Type") {
                PMTypeList(options: [(value: "fuse", icon: .combine, title: "Add"), (value: "cut", icon: .cutExtrude, title: "Subtract"),
                                     (value: "common", icon: .interference, title: "Common")], selection: $model.form.combine)
            }
            PMSection(model.form.combine == "cut" ? "Main Body" : "Bodies to Combine") {
                PMPicker(label: "", selection: $model.form.target, icon: .part) {
                    ForEach(model.bodies, id: \.id) { Text($0.name).tag($0.id) }
                }
                PMPicker(label: "", selection: $model.form.tool, icon: .part) {
                    ForEach(model.bodies, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
        case .primitive(let p):
            PMSection("Parameters") {
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
            PMSection(op == .measure ? "Measure" : "Results") {
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
        case .addRelation:
            SelectedEntities()
            ExistingRelations(all: false)
            RelationButtons()
        case .displayRelations:
            ExistingRelations(all: model.sketchSelection.isEmpty)
        case .sketchOffset:
            SelectedEntities()
            PMSection("Parameters") {
                PMField(label: "Distance", text: $model.form.offsetDistance, unit: "mm", icon: .smartDimension)
                PMCheckbox(label: "Reverse", isOn: $model.form.offsetReverse)
                PMCheckbox(label: "Bi-directional", isOn: $model.form.offsetBoth)
                PMCheckbox(label: "Cap ends", isOn: $model.form.offsetCaps)
                PMCheckbox(label: "Base geometry: construction", isOn: $model.form.offsetBaseConstruction)
            }
        case .sketchMirror:
            PMSection("Entities to mirror") {
                PMSelectionBox(items: model.sketchSelection.filter { $0 != model.form.mirrorAxis }.map { (icon: entityIcon($0), text: $0) }, placeholder: "Sketch entities")
            }
            PMSection("Mirror about") {
                PMPicker(label: "", selection: $model.form.mirrorAxis, icon: .centerline) {
                    Text("Select a line").tag("")
                    ForEach(model.sketchSelection.filter { model.sketchState.sketch?.entities[$0]?.kind == .line }, id: \.self) { Text($0).tag($0) }
                }
            }
        case .sketchLinearPattern:
            SelectedEntities()
            PMSection("Direction 1") {
                PMField(label: "Spacing", text: $model.form.patternSpacing, unit: "mm", icon: .smartDimension)
                PMField(label: "Instances", text: $model.form.patternCount, icon: .linearPattern)
                PMField(label: "Angle", text: $model.form.patternDirection, unit: "°", icon: .arc)
            }
            PMCheckGroup(title: "Direction 2", isOn: $model.form.patternDirection2On) {
                PMField(label: "Spacing", text: $model.form.patternSpacing2, unit: "mm", icon: .smartDimension)
                PMField(label: "Instances", text: $model.form.patternCount2, icon: .linearPattern)
                PMField(label: "Angle", text: $model.form.patternDirection2, unit: "°", icon: .arc)
            }
        case .sketchCircularPattern:
            SelectedEntities()
            PMSection("Parameters") {
                PMField(label: "Centre", text: $model.form.circularCenter, unit: "u, v", icon: .point)
                PMField(label: "Angle", text: $model.form.circularAngle, unit: "°", icon: .arc)
                PMField(label: "Instances", text: $model.form.circularCount, icon: .circularPattern)
            }
        case .sketchMove:
            SelectedEntities()
            PMSection("Options") {
                PMCheckbox(label: "Copy", isOn: $model.form.copy)
                PMCheckbox(label: "Keep relations", isOn: $model.form.keepRelations)
            }
            PMSection("Parameters") {
                PMField(label: "ΔX", text: $model.form.moveDX, unit: "mm")
                PMField(label: "ΔY", text: $model.form.moveDY, unit: "mm")
            }
        case .sketchRotate:
            SelectedEntities()
            PMSection("Options") {
                PMCheckbox(label: "Copy", isOn: $model.form.copy)
                PMCheckbox(label: "Keep relations", isOn: $model.form.keepRelations)
            }
            PMSection("Parameters") {
                PMField(label: "Centre", text: $model.form.rotateCenter, unit: "u, v", icon: .point)
                PMField(label: "Angle", text: $model.form.rotateAngle, unit: "°", icon: .arc)
            }
        case .sketchScale:
            SelectedEntities()
            PMSection("Options") {
                PMCheckbox(label: "Copy", isOn: $model.form.copy)
                PMCheckbox(label: "Keep relations", isOn: $model.form.keepRelations)
            }
            PMSection("Parameters") {
                PMField(label: "Scale about", text: $model.form.scaleCenter, unit: "u, v", icon: .point)
                PMField(label: "Factor", text: $model.form.scaleFactor, icon: .zoomArea)
            }
        }
    }

    private var subtitle: String {
        switch op {
        case .extrude, .cutExtrude, .revolve: model.sketches.first { $0.id == model.operationSketch }?.name ?? "Choose a sketch"
        default: op.isSketchOperation ? "\(model.sketchSelection.count) selected" : ""
        }
    }
}

// MARK: sketch tools

/// The page of the active sketch tool (Insert Line, Rectangle, Circle…).
struct SketchToolPage: View {
    @Environment(AppModel.self) private var model
    let tool: SketchTool

    var body: some View {
        @Bindable var model = model
        let st = model.sketchState
        PMHeader(icon: tool.icon, title: tool == .line ? "Insert \(st.lineKind.rawValue)" : tool.title, onCancel: { model.chooseTool(nil) })
        PMMessage(text: message)
        switch tool {
        case .line:
            PMSection("Line Type") {
                PMTypeList(options: [(value: LineKind.line, icon: .line, title: "Line"), (value: .centerline, icon: .centerline, title: "Centerline"),
                                     (value: .midpoint, icon: .line, title: "Midpoint Line")], selection: $model.sketchState.lineKind)
            }
            PMSection("Orientation") {
                PMTypeList(options: [(value: LineOrientation.asSketched, icon: .line, title: "As sketched"), (value: .horizontal, icon: .extend, title: "Horizontal"),
                                     (value: .vertical, icon: .coordSys, title: "Vertical")], selection: $model.sketchState.lineOrientation)
            }
            PMSection("Options") { PMCheckbox(label: "For construction", isOn: $model.sketchState.forConstruction) }
        case .rectangle:
            PMSection("Rectangle Type") {
                PMTypeList(options: RectangleType.allCases.map { (value: $0, icon: ForgeIcon.rectangle, title: $0.rawValue) }, selection: $model.sketchState.rectangleType)
            }
            PMSection("Options") { PMCheckbox(label: "For construction", isOn: $model.sketchState.forConstruction) }
        case .circle:
            PMSection("Circle Type") {
                PMTypeList(options: [(value: CircleType.center, icon: .circle, title: "Circle"), (value: .perimeter, icon: .circle, title: "Perimeter Circle")],
                           selection: $model.sketchState.circleType)
            }
            PMSection("Options") { PMCheckbox(label: "For construction", isOn: $model.sketchState.forConstruction) }
        case .arc:
            PMSection("Arc Type") {
                PMTypeList(options: [(value: ArcType.center, icon: .arc, title: "Centerpoint Arc"), (value: .tangent, icon: .tangentArc, title: "Tangent Arc"),
                                     (value: .threePoint, icon: .arc, title: "3 Point Arc")], selection: $model.sketchState.arcType)
            }
            PMSection("Options") { PMCheckbox(label: "For construction", isOn: $model.sketchState.forConstruction) }
        case .slot:
            PMSection("Slot Types") {
                PMTypeList(options: [(value: SlotType.straight, icon: .slot, title: "Straight Slot"), (value: .center, icon: .slot, title: "Centerpoint Straight Slot")],
                           selection: $model.sketchState.slotType)
            }
        case .polygon:
            PMSection("Parameters") {
                PMField(label: "Sides", text: Binding(get: { String(model.sketchState.polygonSides) },
                                                      set: { model.sketchState.polygonSides = min(40, max(3, Int($0) ?? model.sketchState.polygonSides)) }),
                        icon: .polygon)
                PMTypeList(options: [(value: true, icon: .circle, title: "Inscribed circle"), (value: false, icon: .polygon, title: "Circumscribed circle")],
                           selection: $model.sketchState.polygonInscribed)
            }
        case .ellipse:
            PMSection("Ellipse Type") {
                PMTypeList(options: [(value: EllipseType.full, icon: .ellipse, title: "Ellipse"), (value: .partial, icon: .ellipse, title: "Partial Ellipse")],
                           selection: $model.sketchState.ellipseType)
            }
        case .spline:
            PMSection("Options") { PMCheckbox(label: "For construction", isOn: $model.sketchState.forConstruction) }
        case .fillet:
            PMSection("Fillet Parameters") {
                PMField(label: "Radius", text: number(\.filletRadius), unit: "mm", icon: .smartDimension)
                PMNote(text: "Constrained corners are kept: the virtual sharp keeps its dimensions and relations.")
            }
        case .chamfer:
            PMSection("Chamfer Parameters") {
                PMTypeList(options: [(value: ChamferType.angleDistance, icon: .sketchChamfer, title: "Angle-distance"),
                                     (value: .distanceDistance, icon: .sketchChamfer, title: "Distance-distance")], selection: $model.sketchState.chamferType)
                if model.sketchState.chamferType == .distanceDistance {
                    PMCheckbox(label: "Equal distance", isOn: $model.sketchState.chamferEqual)
                }
                PMField(label: "Distance 1", text: number(\.chamferDistance), unit: "mm", icon: .smartDimension)
                if model.sketchState.chamferType == .angleDistance {
                    PMField(label: "Direction 1 angle", text: number(\.chamferAngle), unit: "°", icon: .arc)
                } else if !model.sketchState.chamferEqual {
                    PMField(label: "Distance 2", text: number(\.chamferDistance2), unit: "mm", icon: .smartDimension)
                }
            }
        case .trim:
            PMSection("Options") {
                PMTypeList(options: [(value: TrimMode.power, icon: .trim, title: "Power trim"), (value: .closest, icon: .trim, title: "Trim to closest")],
                           selection: $model.sketchState.trimMode)
            }
        case .point, .extend, .dimension:
            EmptyView()
        }
    }

    private var message: String {
        let st = model.sketchState
        switch tool {
        case .line:
            switch st.lineKind {
            case .line: return "Click or drag to place lines; they chain on. Click the first point to close the profile; double-click or Esc to stop."
            case .centerline: return "Click two points. Centerlines are construction lines for mirrors, revolves and symmetry."
            case .midpoint: return "Click the midpoint, then an end. The line is symmetric about the first click."
            }
        case .rectangle:
            switch st.rectangleType {
            case .corner: return "Click two opposite corners."
            case .center: return "Click the centre, then a corner."
            case .threePoint: return "Click two corners to set one side and its angle, then the width."
            case .parallelogram: return "Click three corners."
            }
        case .circle: return st.circleType == .center ? "Click the centre, then a point on the circle." : "Click three points on the circle."
        case .arc:
            switch st.arcType {
            case .center: return "Click the centre, the start, then the end (counter-clockwise)."
            case .tangent: return "Click the end of a line or arc, then where the arc ends."
            case .threePoint: return "Click the start, the end, then a point the arc passes through."
            }
        case .slot: return st.slotType == .straight ? "Click the two arc centres, then the width." : "Click the slot centre, an arc centre, then the width."
        case .polygon: return "Click the centre, then a vertex (inscribed) or the middle of a side (circumscribed)."
        case .spline: return "Click the points the spline passes through; double-click to finish."
        case .ellipse:
            return st.ellipseType == .full
                ? "Click the centre, the end of the major axis, then a point on the minor axis."
                : "Click the centre, the major axis, the minor axis (also the start), then the end."
        case .point: return "Click to place points."
        case .fillet: return "Click a corner where two lines meet."
        case .chamfer: return "Click a corner where two lines meet."
        case .trim: return st.trimMode == .power ? "Drag across the pieces to remove, or click them." : "Click the piece of a curve to remove."
        case .extend: return "Click a curve near the end to extend it to the next curve."
        case .dimension: return "Click a line, circle or arc, or two entities. Type the value in the Modify box and press Return."
        }
    }

    private func number(_ key: WritableKeyPath<SketchUIState, Double>) -> Binding<String> {
        Binding(
            get: { String(format: "%g", model.sketchState[keyPath: key]) },
            set: { if let v = Double($0), v > 0 { model.sketchState[keyPath: key] = v } })
    }
}

// MARK: sketch (no tool): sketch status or the selected entities' properties

struct SketchPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let row = model.sketches.first { $0.id == model.activeSketch }
        let picked = model.sketchSelection
        if picked.count == 1, let sk = model.sketchState.sketch, let e = sk.entities[picked[0]] {
            EntityPage(entity: e, sketch: sk)
        } else if !picked.isEmpty {
            PMHeader(icon: .sketch, title: "Properties", subtitle: "\(picked.count) entities")
            SelectedEntities()
            ExistingRelations(all: false)
            RelationButtons()
            SketchSelectionActions()
        } else {
            PMHeader(icon: .sketch, title: row?.name ?? "Sketch", subtitle: "on \(row?.plane ?? "") Plane")
            if let row { DOFCard(row: row).padding(EdgeInsets(top: 12, leading: 14, bottom: 4, trailing: 14)) }
            PMMessage(text: "Pick a tool in the Sketch tab, or select entities to see their properties. Double-click a dimension to change it. S opens the shortcut bar.")
        }
    }
}

/// Properties of one sketch entity (Line Properties, Circle, Point…): relations, options and
/// editable parameters (moving points goes through sketch.drag, so relations are kept).
private struct EntityPage: View {
    @Environment(AppModel.self) private var model
    let entity: SketchEntity
    let sketch: Sketch
    @State private var fields: [String: String] = [:]

    var body: some View {
        PMHeader(icon: entityIcon(entity.id), title: title, subtitle: entity.id)
        ExistingRelations(all: false)
        RelationButtons()
        PMSection("Options") {
            PMCheckbox(label: "For construction", isOn: Binding(get: { entity.construction }, set: { _ in Task { await model.toggleConstruction() } }))
        }
        PMSection("Parameters") { parameters }
        SketchSelectionActions()
    }

    private var title: String {
        switch entity.kind {
        case .point: "Point"
        case .line: entity.construction ? "Centerline" : "Line Properties"
        case .circle: "Circle"
        case .arc: "Arc"
        case .ellipse, .ellipseArc: "Ellipse"
        case .spline: "Spline"
        }
    }

    private func p(_ id: String) -> (Double, Double) { sketch.point(id) }
    private func fmt(_ x: Double) -> String { String(format: "%.2f", x) }

    @ViewBuilder private var parameters: some View {
        switch entity.kind {
        case .point:
            pointFields(entity.id, "X", "Y")
        case .line:
            let a = p(entity.points[0]), b = p(entity.points[1])
            PMValue(label: "Length", value: fmt(hypot(b.0 - a.0, b.1 - a.1)), icon: .smartDimension)
            PMValue(label: "Angle", value: String(format: "%.2f°", atan2(b.1 - a.1, b.0 - a.0) * 180 / .pi), icon: .arc)
            pointFields(entity.points[0], "Start X", "Start Y")
            pointFields(entity.points[1], "End X", "End Y")
        case .circle:
            PMValue(label: "Radius", value: fmt(sketch.params[entity.params[0]]), icon: .smartDimension)
            pointFields(entity.points[0], "Centre X", "Centre Y")
        case .arc:
            let c = p(entity.points[0]), s = p(entity.points[1])
            PMValue(label: "Radius", value: fmt(hypot(s.0 - c.0, s.1 - c.1)), icon: .smartDimension)
            pointFields(entity.points[0], "Centre X", "Centre Y")
        case .ellipse, .ellipseArc:
            PMValue(label: "Major", value: fmt(sketch.params[entity.params[0]]), icon: .smartDimension)
            PMValue(label: "Minor", value: fmt(sketch.params[entity.params[1]]), icon: .smartDimension)
            pointFields(entity.points[0], "Centre X", "Centre Y")
        case .spline:
            PMValue(label: "Points", value: "\(entity.points.count)", icon: .spline)
            PMValue(label: "Degree", value: "\(entity.degree ?? 3)", icon: .spline)
        }
    }

    /// Editable X/Y of a point; Return moves it (subject to its relations).
    @ViewBuilder private func pointFields(_ id: String, _ xl: String, _ yl: String) -> some View {
        let (u, v) = p(id)
        let kx = id + ".x", ky = id + ".y"
        PMField(label: xl, text: Binding(get: { fields[kx] ?? fmt(u) }, set: { fields[kx] = $0 }), unit: "mm",
                onSubmit: { Task { await model.movePoint(id, u: fields[kx] ?? fmt(u), v: fields[ky] ?? fmt(v)); fields = [:] } })
        PMField(label: yl, text: Binding(get: { fields[ky] ?? fmt(v) }, set: { fields[ky] = $0 }), unit: "mm",
                onSubmit: { Task { await model.movePoint(id, u: fields[kx] ?? fmt(u), v: fields[ky] ?? fmt(v)); fields = [:] } })
    }
}

private struct SketchSelectionActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PMSection("Actions") {
            FlowRow(spacing: 6) {
                Button("Smart Dimension") { model.dimensionSelection() }.buttonStyle(PanelButtonStyle())
                Button("Construction") { Task { await model.toggleConstruction() } }.buttonStyle(PanelButtonStyle())
                Button("Delete") { Task { await model.deleteSketchSelection() } }.buttonStyle(PanelButtonStyle())
            }
        }
    }
}

struct SelectedEntities: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PMSection("Selected Entities") {
            PMSelectionBox(items: model.sketchSelection.map { (icon: entityIcon($0), text: $0) }, placeholder: "Sketch entities")
        }
    }
}

struct RelationButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let options = model.applicableRelations
        if !options.isEmpty {
            PMSection("Add Relations") {
                FlowRow(spacing: 6) {
                    ForEach(options, id: \.self) { r in
                        Button { Task { await model.addRelation(r) } } label: {
                            HStack(spacing: 5) {
                                Text(AppModel.glyph(r.kind) ?? "•").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.relation)
                                Text(r.title)
                            }
                        }
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

/// Relations of the selected entities (or of the whole sketch), with their status and delete.
struct ExistingRelations: View {
    @Environment(AppModel.self) private var model
    let all: Bool

    var body: some View {
        let picked = Set(model.sketchSelection)
        let sk = model.sketchState.sketch
        let problems = Set((sk?.report?.conflicting ?? []) + (sk?.report?.redundant ?? []))
        let related = (sk?.userConstraints ?? []).filter { c in all || c.entities.contains { picked.contains($0) } }
        if !related.isEmpty || all {
            PMSection(all ? "Relations" : "Existing Relations") {
                if related.isEmpty {
                    Text("The sketch has no relations.").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                ForEach(related, id: \.id) { c in
                    let bad = problems.contains(c.id)
                    HStack(spacing: 8) {
                        Text(AppModel.glyph(c.kind) ?? (c.kind.isDimension ? "↔" : "•"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(bad ? Theme.overDefined : Theme.relation)
                            .frame(width: 16, height: 16)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(bad ? Theme.overDefined : Theme.relation, lineWidth: 1.2))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(label(c)).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                            if all { Text(c.entities.joined(separator: ", ")).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(1) }
                        }
                        Spacer()
                        Text(bad ? "Over Defining" : "Satisfied").font(.system(size: 10.5)).foregroundStyle(bad ? Theme.overDefined : Theme.text3)
                        Button {
                            Task { await model.run("sketch.delete", ["items": [.string(c.id)]]) }
                        } label: { IconView(icon: .xmark, size: 12).foregroundStyle(Theme.text3) }
                            .buttonStyle(.plain)
                            .help("Delete")
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field))
                }
                if all && related.count > 1 {
                    Button("Delete All") {
                        Task { await model.run("sketch.delete", ["items": .array(related.map { .string($0.id) })]) }
                    }
                    .buttonStyle(PanelButtonStyle())
                }
            }
        }
    }

    private func label(_ c: SketchConstraint) -> String {
        let name = c.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        guard let v = c.value else { return name }
        return name + (c.kind == .angle ? String(format: " %.1f°", v * 180 / .pi) : String(format: " %.2f", v)) + (c.driven ? " (driven)" : "")
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

// MARK: part (no operation)

struct SelectionPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selection.isEmpty {
            PMHeader(icon: .part, title: model.documentName, subtitle: "\(model.bodies.count) bodies · \(model.sketches.count) sketches")
            PMMessage(text: "Select a face, edge or body to see its properties. Double-click a plane in the tree to start a sketch.")
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

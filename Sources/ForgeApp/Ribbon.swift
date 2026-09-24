// CommandManager ribbon (docs/design, "Part" and "Sketch" artboards): labelled groups of large
// icon-over-label buttons and stacks of small buttons. Every button starts an operation (its
// options appear in the PropertyManager), picks a sketch tool, or runs a command directly.

import ForgeCommands
import ForgeCore
import SwiftUI

struct RibbonView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 4) {
                switch model.ribbonTab {
                case .features: FeaturesTab()
                case .sketch: SketchTab()
                case .evaluate: EvaluateTab()
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
        .frame(height: 92, alignment: .top)
        .background(Theme.chrome2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .onChange(of: model.activeSketch) { old, now in
            // Entering a sketch shows the sketch tools; leaving it goes back to features.
            if (old == nil) != (now == nil) { model.ribbonTab = now == nil ? .features : .sketch }
        }
    }
}

// MARK: tabs

private struct FeaturesTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hasSketch = !model.sketches.isEmpty
        let hasBody = !model.bodies.isEmpty
        RibbonGroup("Boss / Base") {
            RibbonLarge(.extrude, "Extruded\nBoss/Base", active: model.operation == .extrude, enabled: hasSketch,
                        help: "Extrude a closed sketch profile into a new body") { model.begin(.extrude) }
            RibbonLarge(.revolve, "Revolved\nBoss/Base", active: model.operation == .revolve, enabled: hasSketch,
                        help: "Revolve a sketch profile about a sketch line") { model.begin(.revolve) }
        }
        RibbonSeparator()
        RibbonGroup("Cut") {
            RibbonLarge(.cutExtrude, "Extruded\nCut", active: model.operation == .cutExtrude, enabled: hasSketch && hasBody,
                        help: "Extrude a sketch profile and remove it from a body") { model.begin(.cutExtrude) }
            RibbonLarge(.cutRevolve, "Revolved\nCut", active: model.operation == .cutRevolve, enabled: hasSketch && hasBody,
                        help: "Revolve a sketch profile and remove it from a body") { model.begin(.cutRevolve) }
            RibbonLarge(.hole, "Hole\nWizard", active: model.operation == .hole, enabled: hasSketch && hasBody,
                        help: "Standard holes (ISO) at the points of a sketch") { model.begin(.hole) }
        }
        RibbonSeparator()
        RibbonGroup("Modify") {
            RibbonFlyout(icon: model.operation == .chamfer ? .chamfer : .fillet, title: model.operation == .chamfer ? "Chamfer" : "Fillet",
                         active: model.operation == .fillet || model.operation == .chamfer, enabled: hasBody, action: { model.begin(.fillet) }) {
                Button("Fillet") { model.begin(.fillet) }
                Button("Chamfer") { model.begin(.chamfer) }
            }
            RibbonStack {
                RibbonSmall(.draft, "Draft", active: model.operation == .draft, enabled: hasBody) { model.begin(.draft) }
                RibbonSmall(.shell, "Shell", active: model.operation == .shell, enabled: hasBody) { model.begin(.shell) }
            }
            RibbonStack {
                RibbonSmall(.combine, "Combine", active: model.operation == .combine, enabled: model.bodies.count >= 2) { model.begin(.combine) }
                RibbonSmall(.trash, "Delete Body", enabled: !model.selectedBodies.isEmpty) {
                    let bodies = model.selectedBodies
                    Task { for b in bodies { await model.run("body.delete", ["body": .string(b)]) } }
                }
            }
        }
        RibbonSeparator()
        RibbonGroup("Pattern") {
            RibbonFlyout(icon: model.operation == .circularPattern ? .circularPattern : .linearPattern,
                         title: model.operation == .circularPattern ? "Circular\nPattern" : "Linear\nPattern",
                         active: model.operation == .linearPattern || model.operation == .circularPattern, enabled: hasBody,
                         action: { model.begin(.linearPattern) }) {
                Button("Linear Pattern") { model.begin(.linearPattern) }
                Button("Circular Pattern") { model.begin(.circularPattern) }
            }
            RibbonLarge(.mirror, "Mirror", active: model.operation == .mirror, enabled: hasBody,
                        help: "Mirror features about a plane or planar face") { model.begin(.mirror) }
        }
        RibbonSeparator()
        RibbonGroup("Reference") {
            RibbonFlyout(icon: .plane, title: "Reference\nGeometry", active: model.operation == .plane, action: { model.begin(.plane) }) {
                Button("Plane") { model.begin(.plane) }
            }
        }
        RibbonSeparator()
        RibbonGroup("Primitives") {
            RibbonStack {
                ForEach([Primitive.box, .cylinder, .sphere]) { p in
                    RibbonSmall(p.icon, p.title, active: model.operation == .primitive(p)) { model.begin(.primitive(p)) }
                }
            }
            RibbonStack {
                ForEach([Primitive.cone, .torus]) { p in
                    RibbonSmall(p.icon, p.title, active: model.operation == .primitive(p)) { model.begin(.primitive(p)) }
                }
            }
        }
        RibbonSeparator()
        RibbonGroup("Evaluate") {
            RibbonLarge(.measure, "Measure", active: model.operation == .measure, enabled: hasBody) { model.begin(.measure) }
            RibbonLarge(.massProps, "Mass\nProperties", active: model.operation == .massProperties, enabled: hasBody) { model.begin(.massProperties) }
        }
    }
}

private struct SketchTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let editing = model.activeSketch != nil
        let picked = !model.sketchSelection.isEmpty
        let st = model.sketchState
        RibbonGroup("Sketch") {
            if editing {
                RibbonLarge(.exitSketch, "Exit\nSketch", help: "Finish editing the sketch") { Task { await model.exitSketch() } }
            } else {
                Menu {
                    ForEach(StandardPlane.allCases, id: \.self) { p in
                        Button("\(p.rawValue.capitalized) Plane") { Task { await model.newSketch(on: p) } }
                    }
                    ForEach(model.refPlanes, id: \.id) { r in
                        Button(r.name) { Task { await model.newSketch(onPlaneOrFace: r.id) } }
                    }
                    if let f = model.selectedFace {
                        Divider()
                        Button("On Selected Face") { Task { await model.newSketch(onPlaneOrFace: f) } }
                    }
                } label: {
                    RibbonLargeLabel(icon: .sketch, title: "Sketch", chevron: true)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(ToolButtonStyle(cornerRadius: 8))
                .fixedSize()
                .help("Start a sketch on a plane")
            }
            RibbonLarge(.smartDimension, "Smart\nDimension", active: st.tool == .dimension, enabled: editing,
                        help: "Dimension one or two entities; the value is typed in the Modify box") {
                if model.sketchSelection.isEmpty { model.chooseTool(st.tool == .dimension ? nil : .dimension) } else { model.dimensionSelection() }
            }
        }
        RibbonSeparator()
        RibbonGroup("Entities") {
            RibbonFlyout(icon: st.lineKind == .centerline ? .centerline : .line, title: st.lineKind == .line ? "Line" : st.lineKind.rawValue,
                         active: st.tool == .line, enabled: editing, action: { tool(.line) }) {
                ForEach(LineKind.allCases, id: \.self) { k in Button(k.rawValue) { model.sketchState.lineKind = k; model.chooseTool(.line) } }
            }
            RibbonFlyout(icon: .rectangle, title: "Rectangle", active: st.tool == .rectangle, enabled: editing, action: { tool(.rectangle) }) {
                ForEach(RectangleType.allCases, id: \.self) { k in Button(k.rawValue) { model.sketchState.rectangleType = k; model.chooseTool(.rectangle) } }
            }
            RibbonFlyout(icon: .slot, title: "Slot", active: st.tool == .slot, enabled: editing, action: { tool(.slot) }) {
                ForEach(SlotType.allCases, id: \.self) { k in Button(k.rawValue) { model.sketchState.slotType = k; model.chooseTool(.slot) } }
            }
            RibbonFlyout(icon: .circle, title: "Circle", active: st.tool == .circle, enabled: editing, action: { tool(.circle) }) {
                ForEach(CircleType.allCases, id: \.self) { k in Button(k.rawValue) { model.sketchState.circleType = k; model.chooseTool(.circle) } }
            }
            RibbonFlyout(icon: st.arcType == .tangent ? .tangentArc : .arc, title: "Arc", active: st.tool == .arc, enabled: editing, action: { tool(.arc) }) {
                ForEach(ArcType.allCases, id: \.self) { k in Button(k.rawValue) { model.sketchState.arcType = k; model.chooseTool(.arc) } }
            }
            RibbonStack {
                RibbonSmall(.polygon, "Polygon", active: st.tool == .polygon, enabled: editing) { tool(.polygon) }
                RibbonSmall(.spline, "Spline", active: st.tool == .spline, enabled: editing) { tool(.spline) }
                RibbonSmall(.point, "Point", active: st.tool == .point, enabled: editing) { tool(.point) }
            }
            RibbonStack {
                RibbonSmall(.ellipse, "Ellipse", active: st.tool == .ellipse && st.ellipseType == .full, enabled: editing) {
                    model.sketchState.ellipseType = .full; tool(.ellipse)
                }
                RibbonSmall(.ellipse, "Partial Ellipse", active: st.tool == .ellipse && st.ellipseType == .partial, enabled: editing) {
                    model.sketchState.ellipseType = .partial; tool(.ellipse)
                }
                RibbonSmall(.construction, "Construction", enabled: editing && picked, help: "Toggle construction geometry") {
                    Task { await model.toggleConstruction() }
                }
            }
        }
        RibbonSeparator()
        RibbonGroup("Tools") {
            RibbonFlyout(icon: st.tool == .chamfer ? .sketchChamfer : .sketchFillet, title: "Sketch\nFillet", active: st.tool == .fillet || st.tool == .chamfer,
                         enabled: editing, action: { tool(.fillet) }) {
                Button("Sketch Fillet") { model.chooseTool(.fillet) }
                Button("Sketch Chamfer") { model.chooseTool(.chamfer) }
            }
            RibbonFlyout(icon: st.tool == .extend ? .extend : .trim, title: "Trim\nEntities", active: st.tool == .trim || st.tool == .extend,
                         enabled: editing, action: { tool(.trim) }) {
                Button("Trim Entities") { model.chooseTool(.trim) }
                Button("Extend Entities") { model.chooseTool(.extend) }
            }
            RibbonLarge(.offset, "Offset\nEntities", active: model.operation == .sketchOffset, enabled: editing && picked) { model.begin(.sketchOffset) }
            RibbonLarge(.mirror, "Mirror\nEntities", active: model.operation == .sketchMirror, enabled: editing && picked) { model.begin(.sketchMirror) }
            RibbonFlyout(icon: .linearPattern, title: "Linear Sketch\nPattern", active: model.operation == .sketchLinearPattern || model.operation == .sketchCircularPattern,
                         enabled: editing && picked, action: { model.begin(.sketchLinearPattern) }) {
                Button("Linear Sketch Pattern") { model.begin(.sketchLinearPattern) }
                Button("Circular Sketch Pattern") { model.begin(.sketchCircularPattern) }
            }
            RibbonFlyout(icon: .move, title: "Move\nEntities", active: [Operation.sketchMove, .sketchRotate, .sketchScale].contains(model.operation ?? .check),
                         enabled: editing && picked, action: { model.begin(.sketchMove) }) {
                Button("Move Entities") { model.form.copy = false; model.begin(.sketchMove) }
                Button("Copy Entities") { model.form.copy = true; model.begin(.sketchMove) }
                Button("Rotate Entities") { model.begin(.sketchRotate) }
                Button("Scale Entities") { model.begin(.sketchScale) }
            }
        }
        RibbonSeparator()
        RibbonGroup("Relations") {
            RibbonFlyout(icon: .hideShow, title: "Display/Delete\nRelations", active: model.operation == .displayRelations || model.operation == .addRelation,
                         enabled: editing, action: { model.begin(.displayRelations) }) {
                Button("Display/Delete Relations") { model.begin(.displayRelations) }
                Button("Add Relation") { model.begin(.addRelation) }
            }
            RibbonStack {
                RibbonSmall(.addRelation, "Add Relation", active: model.operation == .addRelation, enabled: editing && picked) { model.begin(.addRelation) }
                RibbonSmall(.hideShow, "View Relations", active: model.display.relations) { model.display.relations.toggle() }
                RibbonSmall(.smartDimension, "View Dimensions", active: model.display.dimensions) { model.display.dimensions.toggle() }
            }
        }
    }

    private func tool(_ t: SketchTool) {
        model.chooseTool(model.sketchState.tool == t ? nil : t)
    }
}

private struct EvaluateTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hasBody = !model.bodies.isEmpty
        RibbonGroup("Evaluate") {
            RibbonLarge(.measure, "Measure", active: model.operation == .measure, enabled: hasBody,
                        help: "Distance between two selected entities") { model.begin(.measure) }
            RibbonLarge(.massProps, "Mass\nProperties", active: model.operation == .massProperties, enabled: hasBody,
                        help: "Volume, surface area and centre of mass") { model.begin(.massProperties) }
            RibbonLarge(.check, "Check", active: model.operation == .check, enabled: hasBody,
                        help: "Validate body geometry and topology") { model.begin(.check) }
        }
    }
}

// MARK: building blocks

struct RibbonGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 2) { content }
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text2)
                .tracking(0.2)
        }
        .frame(height: 82)
        .padding(.horizontal, 6)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct RibbonSeparator: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 70).padding(.top, 4)
    }
}

struct RibbonStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
    }
}

struct RibbonLargeLabel: View {
    let icon: ForgeIcon
    let title: String
    var chevron = false

    var body: some View {
        VStack(spacing: 5) {
            IconView(icon: icon, size: 26, accent: Theme.accent)
            Text(title)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 7)
        .frame(width: 66, height: 64, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if chevron {
                IconView(icon: .chevronDown, size: 10).foregroundStyle(Theme.text3).padding(.top, 24).padding(.trailing, 3)
            }
        }
    }
}

struct RibbonLarge: View {
    let icon: ForgeIcon
    let title: String
    var active = false
    var enabled = true
    var help = ""
    let action: () -> Void

    init(_ icon: ForgeIcon, _ title: String, active: Bool = false, enabled: Bool = true, help: String = "", action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.active = active
        self.enabled = enabled
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) { RibbonLargeLabel(icon: icon, title: title) }
            .buttonStyle(ToolButtonStyle(active: active, cornerRadius: 8))
            .disabled(!enabled)
            .help(help.isEmpty ? title.replacingOccurrences(of: "\n", with: " ") : help)
            .accessibilityLabel(title.replacingOccurrences(of: "\n", with: " "))
    }
}

/// A large button with a flyout arrow (SolidWorks' flyout tool buttons): the button runs the
/// variant shown, the arrow lists all variants.
struct RibbonFlyout<Items: View>: View {
    let icon: ForgeIcon
    let title: String
    var active = false
    var enabled = true
    let action: () -> Void
    @ViewBuilder let items: Items

    var body: some View {
        HStack(spacing: 0) {
            RibbonLarge(icon, title, active: active, enabled: enabled, action: action)
            Menu { items } label: {
                IconView(icon: .chevronDown, size: 10).foregroundStyle(Theme.text3).frame(width: 12, height: 64)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(ToolButtonStyle(cornerRadius: 5))
            .fixedSize()
            .disabled(!enabled)
        }
    }
}

struct RibbonSmall: View {
    let icon: ForgeIcon
    let title: String
    var active = false
    var enabled = true
    var help = ""
    let action: () -> Void

    init(_ icon: ForgeIcon, _ title: String, active: Bool = false, enabled: Bool = true, help: String = "", action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.active = active
        self.enabled = enabled
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                IconView(icon: icon, size: 16, accent: Theme.accent)
                Text(title).font(.system(size: 12)).lineLimit(1)
            }
            .padding(.leading, 5)
            .padding(.trailing, 8)
            .frame(height: 21)
        }
        .buttonStyle(ToolButtonStyle(active: active, cornerRadius: 5))
        .disabled(!enabled)
        .help(help.isEmpty ? title : help)
    }
}

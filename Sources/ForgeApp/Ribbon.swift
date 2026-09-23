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
        }
        RibbonSeparator()
        RibbonGroup("Modify") {
            RibbonLarge(.fillet, "Fillet", active: model.operation == .fillet, enabled: hasBody,
                        help: "Round the selected edges") { model.begin(.fillet) }
            RibbonStack {
                RibbonSmall(.combine, "Combine", active: model.operation == .combine, enabled: model.bodies.count >= 2) { model.begin(.combine) }
                RibbonSmall(.trash, "Delete Body", enabled: !model.selectedBodies.isEmpty) {
                    let bodies = model.selectedBodies
                    Task { for b in bodies { await model.run("body.delete", ["body": .string(b)]) } }
                }
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
        RibbonGroup("Sketch") {
            if editing {
                RibbonLarge(.exitSketch, "Exit\nSketch", help: "Finish editing the sketch") { Task { await model.exitSketch() } }
            } else {
                Menu {
                    ForEach(StandardPlane.allCases, id: \.self) { p in
                        Button("\(p.rawValue.capitalized) Plane") { Task { await model.newSketch(on: p) } }
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
            RibbonLarge(.smartDimension, "Smart\nDimension", active: model.operation == .dimension, enabled: editing,
                        help: "Dimension the selected curves: line → length, circle → diameter, arc → radius, two lines → angle") {
                model.begin(.dimension)
            }
        }
        RibbonSeparator()
        RibbonGroup("Draw") {
            toolLarge(.line)
            toolLarge(.rectangle)
            toolLarge(.circle)
            RibbonStack { toolSmall(.arc); toolSmall(.slot); toolSmall(.polygon) }
            RibbonStack { toolSmall(.spline); toolSmall(.ellipse); toolSmall(.point) }
            RibbonStack { toolSmall(.centerline) }
        }
        RibbonSeparator()
        RibbonGroup("Modify") {
            toolLarge(.trim)
            RibbonStack { toolSmall(.extend); toolSmall(.fillet); toolSmall(.chamfer) }
            RibbonStack {
                RibbonSmall(.offset, "Offset", active: model.operation == .sketchOffset, enabled: editing && picked) { model.begin(.sketchOffset) }
                RibbonSmall(.mirror, "Mirror", active: model.operation == .sketchMirror, enabled: editing && picked) { model.begin(.sketchMirror) }
                RibbonSmall(.construction, "Construction", enabled: editing && picked) { Task { await model.toggleConstruction() } }
            }
        }
        RibbonSeparator()
        RibbonGroup("Pattern") {
            RibbonStack {
                RibbonSmall(.linearPattern, "Linear", active: model.operation == .sketchLinearPattern, enabled: editing && picked) {
                    model.begin(.sketchLinearPattern)
                }
                RibbonSmall(.circularPattern, "Circular", active: model.operation == .sketchCircularPattern, enabled: editing && picked) {
                    model.begin(.sketchCircularPattern)
                }
            }
        }
        RibbonSeparator()
        RibbonGroup("Relations") {
            RibbonLarge(.addRelation, "Add\nRelation", active: model.operation == .addRelation, enabled: editing && picked,
                        help: "Relate the selected sketch entities") { model.begin(.addRelation) }
            RibbonStack {
                RibbonSmall(.hideShow, "Show Relations", active: model.display.relations) { model.display.relations.toggle() }
                RibbonSmall(.smartDimension, "Show Dimensions", active: model.display.dimensions) { model.display.dimensions.toggle() }
                RibbonSmall(.trash, "Delete", enabled: editing && picked) { Task { await model.deleteSketchSelection() } }
            }
        }
    }

    private func toolLarge(_ t: SketchTool) -> some View {
        RibbonLarge(t.icon, t.title, active: model.sketchState.tool == t, enabled: model.activeSketch != nil, help: t.hint) {
            model.chooseTool(model.sketchState.tool == t ? nil : t)
        }
    }

    private func toolSmall(_ t: SketchTool) -> some View {
        RibbonSmall(t.icon, t.title.replacingOccurrences(of: "\n", with: " "), active: model.sketchState.tool == t,
                    enabled: model.activeSketch != nil, help: t.hint) {
            model.chooseTool(model.sketchState.tool == t ? nil : t)
        }
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
        RibbonSeparator()
        RibbonGroup("Export") {
            RibbonStack {
                RibbonSmall(.save, "STEP…", enabled: hasBody) { model.export("step") }
                RibbonSmall(.save, "STL…", enabled: hasBody) { model.export("stl") }
            }
        }
        RibbonSeparator()
        RibbonGroup("Commands") {
            RibbonLarge(.command, "All\nCommands", help: "Search every command (⌘K)") { model.showPalette = true }
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

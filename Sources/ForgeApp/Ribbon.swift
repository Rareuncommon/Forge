// Command ribbon (SolidWorks' CommandManager): tabs of icon-over-label buttons. Every button
// either starts an operation (options in the property panel) or runs a command directly.

import ForgeCommands
import ForgeCore
import SwiftUI

struct RibbonView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: $model.ribbonTab) {
                ForEach(RibbonTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.leading, 8)
            HStack(alignment: .top, spacing: 2) {
                FileGroup()
                RibbonDivider()
                switch model.ribbonTab {
                case .features: FeaturesGroup()
                case .sketch: SketchGroup()
                case .evaluate: EvaluateGroup()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
        }
        .padding(.vertical, 6)
        .background(.bar)
        .onChange(of: model.activeSketch) { _, now in
            // Entering a sketch shows the sketch tools; leaving it goes back to features.
            model.ribbonTab = now == nil ? .features : .sketch
        }
    }
}

private struct FileGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        RibbonButton("New", "doc.badge.plus", help: "New part (⌘N)") { Task { await model.run("document.new", ["name": "Part1"]) } }
        RibbonButton("Open", "folder", help: "Open a .forgepart (⌘O)") { model.openDocument() }
        RibbonButton("Save", "square.and.arrow.down", help: "Save (⌘S)") { model.saveDocument(as: false) }
    }
}

private struct FeaturesGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hasSketch = !model.sketches.isEmpty
        RibbonButton("Extruded\nBoss/Base", "square.stack.3d.up.fill", help: "Extrude a closed sketch profile", active: model.operation == .extrude, enabled: hasSketch) {
            model.begin(.extrude)
        }
        RibbonButton("Revolved\nBoss/Base", "arrow.triangle.2.circlepath", help: "Revolve a sketch profile about a sketch line", active: model.operation == .revolve, enabled: hasSketch) {
            model.begin(.revolve)
        }
        RibbonButton("Fillet", "roundedbottom.horizontal", help: "Round the selected edges", active: model.operation == .fillet, enabled: !model.bodies.isEmpty) {
            model.begin(.fillet)
        }
        RibbonButton("Combine", "square.on.square", help: "Add, subtract or intersect bodies", active: model.operation == .combine, enabled: model.bodies.count >= 2) {
            model.begin(.combine)
        }
        RibbonDivider()
        ForEach(Primitive.allCases) { p in
            RibbonButton(p.title, p.systemImage, help: "Insert a \(p.rawValue)", active: model.operation == .primitive(p)) {
                model.begin(.primitive(p))
            }
        }
        RibbonDivider()
        RibbonButton("Delete", "trash", help: "Delete the selected bodies", enabled: !model.selectedBodies.isEmpty) {
            let bodies = model.selectedBodies
            Task { for b in bodies { await model.run("body.delete", ["body": .string(b)]) } }
        }
    }
}

private struct SketchGroup: View {
    @Environment(AppModel.self) private var model
    @State private var showDimension = false
    @State private var dimensionValue = ""

    var body: some View {
        let editing = model.activeSketch != nil
        if editing {
            RibbonButton("Exit\nSketch", "checkmark.rectangle", help: "Finish editing the sketch") { Task { await model.exitSketch() } }
        } else {
            Menu {
                ForEach(StandardPlane.allCases, id: \.self) { p in
                    Button("\(p.rawValue.capitalized) Plane") { Task { await model.newSketch(on: p) } }
                }
            } label: {
                RibbonLabel(title: "Sketch", systemImage: "pencil.and.ruler")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Start a sketch on a plane")
        }
        RibbonDivider()
        ForEach(SketchTool.allCases) { tool in
            RibbonButton(tool.title, tool.systemImage, help: tool.hint, active: model.sketchState.tool == tool, enabled: editing) {
                model.chooseTool(model.sketchState.tool == tool ? nil : tool)
            }
        }
        RibbonDivider()
        RibbonButton("Smart\nDimension", "ruler", help: "Dimension the selected sketch curves (length, diameter, radius, angle, distance)", enabled: editing) {
            showDimension = true
        }
        .popover(isPresented: $showDimension, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Smart Dimension").font(.headline)
                Text("Applies to the selected curves: one line → length, circle → diameter, arc → radius, two lines → angle, two points → distance.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Value, e.g. 25 or 1 in (empty = current)", text: $dimensionValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyDimension() }
                HStack {
                    Spacer()
                    Button("Cancel") { showDimension = false }
                    Button("Add Dimension") { applyDimension() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .frame(width: 300)
        }
    }

    private func applyDimension() {
        let v = dimensionValue
        showDimension = false
        dimensionValue = ""
        Task { await model.smartDimension(value: v) }
    }
}

private struct EvaluateGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        RibbonButton("Mass\nProperties", "scalemass", help: "Volume, surface area and centre of mass of a body", active: model.operation == .massProperties, enabled: !model.bodies.isEmpty) {
            model.begin(.massProperties)
        }
        RibbonButton("Command\nPalette", "command", help: "Run any command by name (⌘K)") { model.showPalette = true }
    }
}

struct RibbonDivider: View {
    var body: some View {
        Divider().frame(height: 46).padding(.horizontal, 4)
    }
}

struct RibbonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .frame(height: 22)
            Text(title)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 68, height: 50)
        .contentShape(Rectangle())
    }
}

struct RibbonButton: View {
    let title: String
    let systemImage: String
    var help: String = ""
    var active = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, _ systemImage: String, help: String = "", active: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.active = active
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            RibbonLabel(title: title, systemImage: systemImage)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? Color.accentColor.opacity(0.22) : hovering && enabled ? Color.primary.opacity(0.07) : .clear))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
    }
}

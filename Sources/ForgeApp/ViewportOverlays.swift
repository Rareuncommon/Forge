// Everything drawn over the Metal viewport (docs/design): the background gradient, heads-up
// view toolbar, confirmation corner, axis triad, sketch chip, sketch dimensions and relation
// glyphs, and the tooltip that follows the cursor while drawing.

import ForgeCore
import ForgeRender
import SwiftUI

struct ViewportArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.viewportTop, Theme.viewportBottom], startPoint: .top, endPoint: .bottom)
            ViewportView()
            SketchAnnotationsLayer()
            CursorTooltip()
            VStack {
                HStack(alignment: .top) {
                    if let row = model.sketches.first(where: { $0.id == model.activeSketch }) {
                        HStack(spacing: 8) {
                            IconView(icon: .sketch, size: 16, accent: Theme.accent).foregroundStyle(Theme.text)
                            Text(row.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("on \(row.plane) Plane").font(.system(size: 12)).foregroundStyle(Theme.text2)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.hud))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                    }
                    Spacer()
                    ConfirmationCorner()
                }
                .padding(14)
                Spacer()
                HStack {
                    AxisTriad()
                    Spacer()
                }
                .padding(12)
            }
            VStack {
                HeadsUpToolbar().padding(.top, 12)
                Spacer()
            }
        }
        .clipped()
    }
}

/// Floating view controls (SolidWorks' heads-up view toolbar).
struct HeadsUpToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 1) {
            HUDButton(icon: .zoomFit, help: "Zoom to fit (F)") { model.zoomToFit() }
            HUDButton(icon: .prevView, help: "Previous view") { model.previousView() }
            HUDDivider()
            Menu {
                ForEach(ViewOrientation.allCases, id: \.self) { o in
                    Button(o.rawValue.capitalized) { model.setOrientation(o) }
                }
                if model.activeSketch != nil {
                    Divider()
                    Button("Normal To Sketch") { model.normalToSketch() }
                }
            } label: { HUDMenuLabel(icon: .viewOrient) }
                .help("View orientation")
            Menu {
                Button("Shaded with Edges") { model.setStyle(.shadedWithEdges) }
                Button("Shaded") { model.setStyle(.shaded) }
                Button("Hidden Lines Removed") { model.setStyle(.hiddenLinesRemoved) }
                Button("Wireframe") { model.setStyle(.wireframe) }
            } label: { HUDMenuLabel(icon: .displayStyle) }
                .help("Display style")
            Menu {
                Toggle("Planes", isOn: Binding(get: { model.display.planes }, set: { model.display.planes = $0; Task { await model.refresh() } }))
                Toggle("Sketch Relations", isOn: Binding(get: { model.display.relations }, set: { model.display.relations = $0 }))
                Toggle("Sketch Dimensions", isOn: Binding(get: { model.display.dimensions }, set: { model.display.dimensions = $0 }))
            } label: { HUDMenuLabel(icon: .hideShow) }
                .help("Hide/show items")
            Menu {
                Toggle("Perspective", isOn: Binding(get: { model.display.perspective }, set: { model.setPerspective($0) }))
            } label: { HUDMenuLabel(icon: .viewSettings) }
                .help("View settings")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.hud))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        .shadow(color: Theme.shadowColor, radius: 12, y: 4)
        .fixedSize()
    }
}

private struct HUDButton: View {
    let icon: ForgeIcon
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconView(icon: icon, size: 19, accent: Theme.accent).padding(.horizontal, 6).frame(height: 30)
        }
        .buttonStyle(ToolButtonStyle(cornerRadius: 6))
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct HUDMenuLabel: View {
    let icon: ForgeIcon

    var body: some View {
        HStack(spacing: 1) {
            IconView(icon: icon, size: 19, accent: Theme.accent)
            IconView(icon: .chevronDown, size: 9).foregroundStyle(Theme.text3)
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 6)
        .frame(height: 30)
        .contentShape(Rectangle())
    }
}

private struct HUDDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 20).padding(.horizontal, 3)
    }
}

/// OK / Cancel in the top-right corner of the view while an operation is open, or Exit Sketch.
struct ConfirmationCorner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if let op = model.operation {
                if !op.isReport && op != .addRelation {
                    CornerButton(icon: .check, prominent: true, help: "OK") { Task { await model.commitOperation() } }
                }
                CornerButton(icon: .xmark, help: "Cancel") { model.cancelOperation() }
            } else if model.activeSketch != nil {
                CornerButton(icon: .exitSketch, prominent: true, help: "Exit Sketch") { Task { await model.exitSketch() } }
            }
        }
    }
}

private struct CornerButton: View {
    let icon: ForgeIcon
    var prominent = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconView(icon: icon, size: 22, accent: .white)
                .foregroundStyle(prominent ? Color.white : Theme.text)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(prominent ? Theme.accent : Theme.hud))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(prominent ? Color.clear : Theme.line))
                .shadow(color: Theme.shadowColor, radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// X (red), Y (green), Z (blue) as seen from the current camera.
struct AxisTriad: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let proj = model.projection {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let axes: [(Vec3, Color, String)] = [(.unitX, Theme.axisX, "X"), (.unitY, Theme.axisY, "Y"), (.unitZ, Theme.axisZ, "Z")]
                // Draw the axis pointing away from the viewer first.
                let sorted = axes.sorted { $0.0.dot(proj.camera.back) < $1.0.dot(proj.camera.back) }
                for (v, color, name) in sorted {
                    let d = proj.axis(v)
                    let len = hypot(d.dx, d.dy)
                    let end = CGPoint(x: c.x + d.dx * 24, y: c.y + d.dy * 24)
                    var path = Path()
                    path.move(to: c)
                    path.addLine(to: end)
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    if len > 0.2 {
                        let label = CGPoint(x: c.x + d.dx / len * 31 * min(1, len + 0.3), y: c.y + d.dy / len * 31 * min(1, len + 0.3))
                        ctx.draw(Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(color), at: label)
                    }
                }
            }
            .frame(width: 80, height: 80)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Dimensions and relation glyphs of the sketch being edited, at their projected anchors.
struct SketchAnnotationsLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let proj = model.projection, model.activeSketch != nil {
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                ForEach(model.annotations) { a in
                    if let p = proj.point(a.anchor), show(a) {
                        switch a.kind {
                        case .dimension:
                            DimensionLabel(annotation: a).position(x: p.x, y: p.y - 14)
                        case .relation:
                            RelationGlyph(annotation: a).position(x: p.x + 14 + CGFloat(a.slot) * 20, y: p.y + 14)
                        }
                    }
                }
            }
        }
    }

    private func show(_ a: SketchAnnotation) -> Bool {
        a.kind == .dimension ? model.display.dimensions : model.display.relations
    }
}

private struct DimensionLabel: View {
    @Environment(AppModel.self) private var model
    let annotation: SketchAnnotation
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        Text(annotation.text)
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(annotation.problem ? Theme.overDefined : annotation.driven ? Theme.text2 : Theme.text)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(annotation.problem ? Theme.overDefined : Theme.line))
            .fixedSize()
            .onTapGesture(count: 2) {
                guard !annotation.driven else { return }
                text = annotation.text.trimmingCharacters(in: CharacterSet(charactersIn: "R⌀°()"))
                editing = true
            }
            .help(annotation.driven ? "Driven dimension (reference)" : "Double-click to change")
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                HStack(spacing: 8) {
                    IconView(icon: .smartDimension, size: 16, accent: Theme.accent)
                    TextField("Value", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono)
                        .frame(width: 120)
                        .onSubmit { commit() }
                    Button { commit() } label: { IconView(icon: .check, size: 16) }
                        .buttonStyle(PanelButtonStyle(prominent: true))
                }
                .padding(10)
            }
    }

    private func commit() {
        editing = false
        let value = annotation.text.hasSuffix("°") && Double(text) != nil ? text + " deg" : text
        Task { await model.setDimension(annotation.id, to: value) }
    }
}

private struct RelationGlyph: View {
    let annotation: SketchAnnotation

    var body: some View {
        let color = annotation.problem ? Theme.overDefined : Theme.relation
        Text(annotation.text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: 1.2))
            .allowsHitTesting(false)
    }
}

/// Length/angle/radius readout next to the cursor while drawing, with the snap it found.
struct CursorTooltip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.hoverLines.isEmpty {
            ZStack(alignment: .topLeading) {
                Color.clear
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.hoverLines.enumerated()), id: \.offset) { i, line in
                            Text(line).foregroundStyle(i == 0 ? Theme.text : Theme.text2)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    if let tag = model.sketchState.preview?.snap.tag {
                        Text(tag)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .frame(minWidth: 22, minHeight: 18)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.preview))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.preview, lineWidth: 1.2))
                .fixedSize()
                .offset(x: model.hoverViewPoint.x + 18, y: model.hoverViewPoint.y + 14)
            }
            .allowsHitTesting(false)
        }
    }
}

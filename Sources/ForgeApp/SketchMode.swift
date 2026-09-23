// Sketch editing UI (M1). Every action is a command on the bus; the UI only turns clicks into
// sketch coordinates and chooses which command to run.
//
// STATUS: written without a Mac; first compile happens in the macos-app CI job.

import ForgeCommands
import ForgeCore
import ForgeRender
import ForgeSketch
import SwiftUI

enum SketchTool: String, CaseIterable, Identifiable {
    case line, rectangle, circle, point, fillet
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .point: "smallcircle.filled.circle"
        case .fillet: "arrow.turn.down.right"
        }
    }

    var hint: String {
        switch self {
        case .line: "Click points to draw connected lines; Esc ends the chain"
        case .rectangle: "Click two opposite corners"
        case .circle: "Click the centre, then a point on the circle"
        case .point: "Click to place a point"
        case .fillet: "Click a corner point to round it (radius from the field)"
        }
    }
}

/// Sketch-mode state kept by the app model.
struct SketchUIState {
    var tool: SketchTool?
    var pending: [Point2] = []
    var filletRadius = 2.0
    /// Snap targets: sketch point positions (u, v) by id, refreshed after each command.
    var points: [(id: String, u: Double, v: Double)] = []
    var plane: SketchPlane?
    var status: String = ""
}

extension AppModel {
    func newSketch(on plane: StandardPlane) async {
        if await run("sketch.create", ["plane": .string(plane.rawValue)]) != nil {
            setOrientation(plane == .front ? .front : plane == .top ? .top : .right)
        }
    }

    func exitSketch() async {
        sketchState.tool = nil
        sketchState.pending = []
        await run("sketch.exit")
    }

    func refreshSketchState() async {
        guard let doc = await engine.activeDocument, let id = doc.activeSketch, let sk = doc.sketches[id] else {
            activeSketch = nil
            sketchState.plane = nil
            sketchState.points = []
            sketchState.status = ""
            return
        }
        activeSketch = id
        sketchState.plane = sk.plane
        sketchState.points = sk.orderedEntities.filter { $0.kind == .point }.map { e in
            let (u, v) = sk.point(e.id)
            return (e.id, u, v)
        }
        let r = sk.report
        sketchState.status = "\(sk.name): \(r?.status.rawValue.replacingOccurrences(of: "_", with: " ") ?? "") · \(r?.dof ?? 0) DOF"
    }

    /// Snap to an existing sketch point within `tolerance` (sketch units), so inference makes
    /// the new geometry coincident with it.
    func snap(_ p: Point2, tolerance: Double) -> Point2 {
        var best: (Point2, Double)?
        for q in sketchState.points {
            let d = hypot(q.u - p.u, q.v - p.v)
            if d <= tolerance && (best == nil || d < best!.1) { best = (Point2(q.u, q.v), d) }
        }
        return best?.0 ?? p
    }

    func sketchClick(_ raw: Point2, tolerance: Double) async {
        guard let tool = sketchState.tool else { return }
        let p = snap(raw, tolerance: tolerance)
        func pt(_ q: Point2) -> JSONValue { [.number(q.u), .number(q.v)] }
        switch tool {
        case .point:
            await run("sketch.add_point", ["at": pt(p)])
        case .line:
            if let start = sketchState.pending.last {
                guard start != p else { return }
                await run("sketch.add_line", ["start": pt(start), "end": pt(p)])
            }
            sketchState.pending = [p]
        case .rectangle:
            if let a = sketchState.pending.first {
                sketchState.pending = []
                await run("sketch.add_rectangle", ["points": [pt(a), pt(p)]])
            } else {
                sketchState.pending = [p]
            }
        case .circle:
            if let c = sketchState.pending.first {
                sketchState.pending = []
                let r = hypot(p.u - c.u, p.v - c.v)
                if r > 0 { await run("sketch.add_circle", ["center": pt(c), "radius": .number(r)]) }
            } else {
                sketchState.pending = [p]
            }
        case .fillet:
            if let corner = sketchState.points.first(where: { $0.u == p.u && $0.v == p.v }) {
                await run("sketch.fillet", ["corner": .string(corner.id), "radius": .number(sketchState.filletRadius)])
            }
        }
        await refreshSketchState()
    }

    func cancelSketchOperation() {
        sketchState.pending = []
    }

    /// Smart dimension from the current selection (SPEC 7.1): one line → length, one circle/arc
    /// → diameter/radius, two points → distance, two lines → angle, point + line → distance.
    func smartDimension(value: String) async {
        guard let id = activeSketch, let doc = await engine.activeDocument, let sk = doc.sketches[id] else { return }
        let local = selection.compactMap { ref -> String? in
            ref.hasPrefix(id + "/") ? String(ref.dropFirst(id.count + 1)) : nil
        }
        let kinds = local.compactMap { sk.entities[$0]?.kind }
        let type: String
        switch kinds {
        case [.line]: type = "distance"
        case [.circle]: type = "diameter"
        case [.arc]: type = "radius"
        case [.line, .line]: type = "angle"
        default: type = "distance"
        }
        var params: JSONValue = ["type": .string(type), "entities": .array(local.map { .string($0) })]
        if !value.trimmingCharacters(in: .whitespaces).isEmpty, case .object(var o) = params {
            o["value"] = Double(value).map { .number($0) } ?? .string(value)
            params = .object(o)
        }
        await run("sketch.add_dimension", params)
        await refreshSketchState()
    }
}

/// Sketch toolbar shown above the viewport.
struct SketchToolbar: View {
    @Environment(AppModel.self) private var model
    @State private var dimensionValue = ""

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            if model.activeSketch == nil {
                Menu("New Sketch", systemImage: "pencil.and.ruler") {
                    ForEach(StandardPlane.allCases, id: \.self) { p in
                        Button("On \(p.rawValue.capitalized) Plane") { Task { await model.newSketch(on: p) } }
                    }
                }
            } else {
                ForEach(SketchTool.allCases) { tool in
                    Toggle(isOn: Binding(
                        get: { model.sketchState.tool == tool },
                        set: { model.sketchState.tool = $0 ? tool : nil; model.sketchState.pending = [] })
                    ) {
                        Label(tool.rawValue.capitalized, systemImage: tool.systemImage)
                    }
                    .toggleStyle(.button)
                    .help(tool.hint)
                }
                if model.sketchState.tool == .fillet {
                    TextField("Radius", value: $model.sketchState.filletRadius, format: .number)
                        .frame(width: 60)
                }
                Divider().frame(height: 18)
                TextField("Dimension (e.g. 25 mm)", text: $dimensionValue)
                    .frame(width: 150)
                    .onSubmit { Task { await model.smartDimension(value: dimensionValue); dimensionValue = "" } }
                Button("Dimension", systemImage: "ruler") {
                    Task { await model.smartDimension(value: dimensionValue); dimensionValue = "" }
                }
                .help("Dimension the selected sketch entities (line → length, circle → diameter, arc → radius, two lines → angle)")
                Spacer()
                Text(model.sketchState.status).font(.caption).foregroundStyle(.secondary)
                Button("Extrude…", systemImage: "square.3.layers.3d") { Task { await model.run("body.extrude", ["depth": 10]) } }
                Button("Exit Sketch", systemImage: "checkmark.circle") { Task { await model.exitSketch() } }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

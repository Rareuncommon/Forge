// The app model shared by every front end (macOS SwiftUI, Windows): selection, operations,
// sketch tools, previews. Front ends render it and forward input; all changes go through the
// command bus (SPEC §1.2).

import ForgeCommands
import ForgeCore
import ForgeKernel
import ForgeRender
import ForgeSketch
import Foundation
import Observation

package enum RibbonTab: String, CaseIterable, Identifiable {
    case features = "Features", sketch = "Sketch", evaluate = "Evaluate"
    package var id: String { rawValue }
}

/// The operation whose options are shown in the PropertyManager (with OK / Cancel).
package enum Operation: Hashable {
    case extrude, cutExtrude, revolve, cutRevolve, hole, fillet, chamfer, shell, draft, plane, linearPattern, circularPattern, mirror, combine
    case massProperties, measure, check
    case primitive(Primitive)
    // Sketch operations on the selected sketch entities.
    case addRelation, displayRelations, sketchOffset, sketchMirror, sketchLinearPattern, sketchCircularPattern
    case sketchMove, sketchRotate, sketchScale

    package var title: String {
        switch self {
        case .extrude: "Boss-Extrude"
        case .cutExtrude: "Cut-Extrude"
        case .revolve: "Revolve"
        case .cutRevolve: "Cut-Revolve"
        case .hole: "Hole Specification"
        case .linearPattern: "Linear Pattern"
        case .circularPattern: "Circular Pattern"
        case .mirror: "Mirror"
        case .plane: "Plane"
        case .fillet: "Fillet"
        case .chamfer: "Chamfer"
        case .shell: "Shell"
        case .draft: "Draft"
        case .combine: "Combine"
        case .massProperties: "Mass Properties"
        case .measure: "Measure"
        case .check: "Check"
        case .primitive(let p): p.title
        case .addRelation: "Add Relations"
        case .displayRelations: "Display/Delete Relations"
        case .sketchMove: "Move Entities"
        case .sketchRotate: "Rotate Entities"
        case .sketchScale: "Scale Entities"
        case .sketchOffset: "Offset Entities"
        case .sketchMirror: "Mirror Entities"
        case .sketchLinearPattern: "Linear Sketch Pattern"
        case .sketchCircularPattern: "Circular Sketch Pattern"
        }
    }

    package var icon: ForgeIcon {
        switch self {
        case .extrude: .extrude
        case .cutExtrude: .cutExtrude
        case .revolve: .revolve
        case .cutRevolve: .cutRevolve
        case .hole: .hole
        case .linearPattern: .linearPattern
        case .circularPattern: .circularPattern
        case .mirror: .mirror
        case .plane: .plane
        case .fillet: .fillet
        case .chamfer: .chamfer
        case .shell: .shell
        case .draft: .draft
        case .combine: .combine
        case .massProperties: .massProps
        case .measure: .measure
        case .check: .check
        case .primitive(let p): p.icon
        case .addRelation: .addRelation
        case .displayRelations: .hideShow
        case .sketchMove: .move
        case .sketchRotate: .circularPattern
        case .sketchScale: .zoomArea
        case .sketchOffset: .offset
        case .sketchMirror: .mirror
        case .sketchLinearPattern: .linearPattern
        case .sketchCircularPattern: .circularPattern
        }
    }

    /// Results-only panels (nothing to commit).
    package var isReport: Bool { self == .massProperties || self == .measure || self == .check || self == .displayRelations }
}

package enum Primitive: String, CaseIterable, Identifiable {
    case box, cylinder, sphere, cone, torus
    package var id: String { rawValue }
    package var title: String { rawValue.capitalized }
    package var icon: ForgeIcon {
        switch self {
        case .box: .box
        case .cylinder, .cone: .cylinder
        case .sphere, .torus: .sphere
        }
    }
}

/// A feature of the tree, as the app shows it.
package struct FeatureRow: Identifiable, Equatable {
    package var id: String
    package var name: String
    package var command: String
    package var params: JSONValue
    package var suppressed: Bool
    package var state: FeatureStatus.State
    package var error: String?
    package var createdBodies: [String]

    package var isSketch: Bool { command == "sketch.create" }
    package var sketchID: String? { params["sketch"]?.stringValue }

    package var icon: ForgeIcon {
        switch command {
        case "sketch.create": .sketch
        case "body.extrude": params["operation"]?.stringValue == "cut" ? .cutExtrude : .extrude
        case "body.revolve": params["operation"]?.stringValue == "cut" ? .cutRevolve : .revolve
        case "body.fillet_edges": .fillet
        case "body.chamfer_edges": .chamfer
        case "body.shell": .shell
        case "body.draft": .draft
        case "body.boolean": .combine
        case "body.transform": .move
        case "body.delete": .trash
        case "plane.create": .plane
        case "body.hole": .hole
        case "pattern.linear": .linearPattern
        case "pattern.circular": .circularPattern
        case "pattern.mirror": .mirror
        case "body.create_box": .box
        case "body.create_cylinder", "body.create_cone": .cylinder
        case "body.create_sphere", "body.create_torus": .sphere
        default: .part
        }
    }

    /// The PropertyManager page that edits it, if any.
    package var operation: Operation? {
        switch command {
        case "body.extrude": params["operation"]?.stringValue == "cut" ? .cutExtrude : .extrude
        case "body.revolve": params["operation"]?.stringValue == "cut" ? .cutRevolve : .revolve
        case "plane.create": .plane
        case "body.hole": .hole
        case "pattern.linear": .linearPattern
        case "pattern.circular": .circularPattern
        case "pattern.mirror": .mirror
        case "body.fillet_edges": .fillet
        case "body.chamfer_edges": .chamfer
        case "body.shell": .shell
        case "body.draft": .draft
        case "body.boolean": .combine
        case "body.create_box": .primitive(.box)
        case "body.create_cylinder": .primitive(.cylinder)
        case "body.create_sphere": .primitive(.sphere)
        case "body.create_cone": .primitive(.cone)
        case "body.create_torus": .primitive(.torus)
        default: nil
        }
    }
}

package struct SketchRow: Identifiable, Equatable {
    package var id: String
    package var name: String
    package var plane: String
    package var status: SolveStatus?
    package var dof: Int
    package var unknowns: Int
}

/// What the viewport shows besides the model.
package struct DisplayOptions {
    package var planes = true
    package var relations = true
    package var dimensions = true
    package var perspective = false
}

/// App state. Main-actor bound; talks to the Engine actor asynchronously so the UI never blocks.
@MainActor @Observable
package final class AppModel {
    package let engine = Engine()
    /// Native dialogs of the front end.
    package var platform: any PlatformServices = HeadlessPlatform()
    package var documentName = "Part1"
    package var documentPath: String?
    package var bodies: [BodySummary] = []
    package var sketches: [SketchRow] = []
    package var features: [FeatureRow] = []
    /// Reference planes (Plane features).
    package var refPlanes: [RefPlane] = []
    /// Number of active features (rollback bar position); nil = all.
    package var rollback: Int?
    /// The feature whose page is open for editing (OK runs feature.edit instead of creating).
    package var editingFeature: String?
    package var selection: [String] = []
    package var inspector: JSONValue?
    package var lastError: ForgeError?
    package var log: [String] = []
    package var showPalette = false
    package var paletteQuery = ""
    package var ribbonTab: RibbonTab = .features
    package var operation: Operation?
    /// The sketch an extrude/revolve uses, and the values being edited in the PropertyManager.
    package var operationSketch: String?
    package var form = OperationForm()
    /// Bumped whenever the scene must be re-uploaded to the GPU.
    package var sceneVersion = 0
    package var scene = DocumentSceneBox()
    package var viewportCommands = ViewportCommandQueue()
    /// The sketch being edited (mirrors document.state's active_sketch).
    package var activeSketch: String?
    package var sketchState = SketchUIState()
    /// Shown next to the cursor while sketching (length, angle, radius…), at `hoverViewPoint`
    /// (viewport coordinates, origin top-left).
    package var hoverLines: [String] = []
    package var hoverViewPoint = CGPoint.zero
    /// Cursor position on the sketch plane, for the status bar.
    package var cursorSketchPoint: Point2?
    /// Bumped when the sketch preview changes (re-upload of the viewport overlay).
    package var overlayVersion = 0
    /// Camera and viewport size, published by the viewport so overlays can place labels.
    package var projection: ViewProjection?
    /// Dimensions and relation glyphs of the sketch being edited, anchored in world space.
    package var annotations: [SketchAnnotation] = []
    package var display = DisplayOptions()
    package var isDark = false
    package var treeFilter = ""
    /// Undoable changes since the sketch was opened (Cancel Sketch undoes them).
    package var sketchEditCount = 0
    /// For Enter = repeat last command.
    package var lastSketchTool: SketchTool?
    package var lastOperation: Operation?
    /// Smart Dimension's Modify box, while open.
    package var dimensionEdit: DimensionEdit?
    /// Live preview of the operation being set up (bodies it would create).
    package var preview = PreviewBox()
    package var previewVersion = 0
    package var previewError: String?
    /// Context toolbar and shortcut bar (S key) positions in the viewport, when shown.
    package var contextToolbarAt: CGPoint?
    package var shortcutBarAt: CGPoint?
    package var orientationPaletteShown = false

    package init() {}

    package func bootstrap() async {
        await run("document.new", ["name": "Part1"])
    }

    @discardableResult
    package func run(_ command: String, _ params: JSONValue = [:]) async -> CommandOutcome? {
        do {
            let o = try await engine.execute(command, params)
            log.append("\(command) ✓")
            lastError = nil
            if activeSketch != nil || command == "sketch.create" {
                if command == "edit.undo" { sketchEditCount = max(0, sketchEditCount - 1) }
                else if command == "edit.redo" || !o.changes.isEmpty { sketchEditCount += 1 }
            }
            await refresh()
            return o
        } catch {
            let e = ForgeError.wrap(error)
            lastError = e
            log.append("\(command) ✗ \(e.message)")
            return nil
        }
    }

    package func refresh() async {
        guard let doc = await engine.activeDocument else { return }
        documentName = doc.name
        bodies = (try? doc.orderedBodies.map(BodySummary.init)) ?? []
        sketches = doc.orderedSketches.map {
            SketchRow(
                id: $0.id, name: $0.name, plane: $0.plane.name, status: $0.report?.status, dof: $0.report?.dof ?? 0,
                unknowns: max(0, $0.params.count - 2))
        }
        features = doc.features.map {
            FeatureRow(
                id: $0.id, name: $0.name, command: $0.command, params: $0.params, suppressed: $0.suppressed, state: $0.status.state,
                error: $0.status.error?.message, createdBodies: $0.createdBodies)
        }
        rollback = doc.rollback
        refPlanes = doc.orderedRefPlanes
        selection = doc.selection
        if var ds = try? DocumentScene(document: doc, highlight: doc.selection) {
            let size = max(100, (ds.scene.bounds?.diagonal ?? 0) * 1.2)
            let editing = doc.activeSketch.flatMap { doc.sketches[$0] }
            if isDark { ds.scene.items = ds.scene.items.map(Self.darkened) }
            ds.scene.items += ReferenceGeometry.items(
                size: size, sketch: editing, allSketches: doc.orderedSketches, planes: display.planes, refPlanes: doc.orderedRefPlanes, dark: isDark)
            scene = DocumentSceneBox(value: ds)
            sceneVersion += 1
        }
        await refreshSketchState()
        if let first = selection.first, !first.hasPrefix("sketch-"), let o = try? await engine.execute("query.entity", ["ref": .string(first)]) {
            inspector = o.result
        } else {
            inspector = nil
        }
    }

    /// Sketch curve colours for a dark viewport (black curves would vanish).
    private static func darkened(_ item: RenderItem) -> RenderItem {
        guard !item.edgeColors.isEmpty else { return item }
        let light = Palette.sketch(dark: false), dark = Palette.sketch(dark: true)
        var out = item
        out.edgeColors = item.edgeColors.mapValues { c in
            c == .sketchFully || c == light.fully ? dark.fully : c == .sketchUnder ? dark.under : c == .sketchOver ? dark.over : c
        }
        return out
    }

    /// Operations whose PropertyManager collects picks: a click adds to (or, on an item
    /// already picked, removes from) the selection instead of replacing it, as in SolidWorks.
    package var collectsPicks: Bool {
        guard let op = operation else { return false }
        return [Operation.fillet, .chamfer, .shell, .draft, .measure, .massProperties, .check, .combine].contains(op) || op.isSketchOperation
    }

    /// A viewport or tree pick. `extend` (⇧, ⌘ or ⌃ held) toggles the item in the selection;
    /// so does any pick while an operation collecting picks is open.
    package func select(_ ref: String?, extend: Bool) async {
        let additive = extend || collectsPicks
        if let ref {
            let mode = !additive ? "replace" : selection.contains(ref) ? "remove" : "add"
            await run("selection.set", ["entities": [.string(ref)], "mode": .string(mode)])
        } else if !additive {
            await run("selection.clear")
        }
    }

    package func setOrientation(_ o: ViewOrientation) { viewportCommands.send(.orient(o)) }
    package func zoomToFit() { viewportCommands.send(.fit) }
    package func previousView() { viewportCommands.send(.previous) }
    package func setStyle(_ s: RenderStyle) { viewportCommands.send(.style(s)) }
    package func setPerspective(_ on: Bool) {
        display.perspective = on
        viewportCommands.send(.projection(on ? .perspective : .orthographic))
    }

    /// SolidWorks keys in the graphics area (docs/research §1.8): F fit, Z / ⇧Z zoom,
    /// S shortcut bar, Space view orientation, Return repeats the last command, Delete deletes
    /// the selected sketch entities.
    package func viewportKey(_ key: String, at p: CGPoint) -> Bool {
        switch key {
        case "f": zoomToFit()
        case "z": viewportCommands.send(.zoom(1 / 1.25))
        case "Z": viewportCommands.send(.zoom(1.25))
        case "s", "S": shortcutBarAt = p
        case "space": orientationPaletteShown.toggle()
        case "return":
            if activeSketch != nil, sketchState.tool == nil, let t = lastSketchTool {
                chooseTool(t)
            } else if operation == nil, let op = lastOperation {
                begin(op)
            } else {
                return false
            }
        case "delete":
            guard activeSketch != nil, !sketchSelection.isEmpty else { return false }
            Task { await deleteSketchSelection() }
        default:
            return false
        }
        return true
    }

    package func normalToSketch() {
        if let p = sketchState.plane { viewportCommands.send(.normalTo(p)) }
    }

    /// Bodies in the selection (a face/edge selection counts for its body).
    package var selectedBodies: [String] {
        var out: [String] = []
        for ref in selection {
            let b = String(ref.split(separator: "/").first ?? "")
            if b.hasPrefix("body-"), !out.contains(b) { out.append(b) }
        }
        return out
    }

    package var selectedEdges: [String] { selection.filter { $0.contains("/edge-") } }

    /// Fillet / chamfer items: selected edges, and faces (all of a face's edges).
    package var filletItems: [String] { selection.filter { $0.contains("/edge-") || $0.contains("/face-") } }

    /// One-line guidance for the status bar.
    package var hint: String {
        if let op = operation { return "\(op.title): set the options in the PropertyManager, then OK (↩)." }
        if activeSketch != nil {
            if let t = sketchState.tool { return toolMessage(t) }
            return "Pick a sketch tool, or select curves to add relations and dimensions. Esc cancels."
        }
        if bodies.isEmpty && sketches.isEmpty {
            return "Start a sketch: double-click a plane in the tree, or choose Sketch in the Sketch tab."
        }
        return "Drag to rotate · right-drag or ⌥-drag to pan · scroll to zoom · F to fit."
    }

    // MARK: files

    package func saveDocument(as saveAs: Bool) {
        if !saveAs, let path = documentPath {
            Task { await run("document.save", ["path": .string(path), "overwrite": true]) }
            return
        }
        guard var path = platform.chooseSavePath(suggestedName: "\(documentName).forgepart") else { return }
        if !path.hasSuffix(".forgepart") { path += ".forgepart" }
        Task {
            if await run("document.save", ["path": .string(path), "overwrite": true]) != nil { documentPath = path }
        }
    }

    package func openDocument() {
        guard let path = platform.chooseOpenPath() else { return }
        Task {
            if await run("document.open", ["path": .string(path)]) != nil {
                documentPath = path
                zoomToFit()
            }
        }
    }

    /// Export the selected body (or the first) as STEP or STL.
    package func export(_ format: String) {
        guard let body = selectedBodies.first ?? bodies.first?.id else {
            lastError = ForgeError(.invalidParams, "there is no body to export")
            return
        }
        guard let path = platform.chooseSavePath(suggestedName: "\(documentName).\(format)") else { return }
        Task { await run("export.\(format)", ["path": .string(path), "body": .string(body), "overwrite": true]) }
    }
}

/// The live preview's render items (not observed item by item).
package struct PreviewBox {
    package var items: [RenderItem] = []
    /// Bodies (ids) the preview replaces on screen.
    package var hidden: [String] = []
}

/// Non-observable wrapper so large scene data doesn't participate in SwiftUI diffing.
package struct DocumentSceneBox {
    package var value: DocumentScene?
}

/// Commands from menus to the viewport, consumed in order by the viewport coordinator
/// (which remembers how many it has applied, so SwiftUI updates never mutate model state).
package struct ViewportCommandQueue {
    package enum Command { case orient(ViewOrientation), fit, previous, style(RenderStyle), projection(ProjectionKind), zoom(Double), normalTo(SketchPlane) }
    package private(set) var log: [Command] = []
    package mutating func send(_ c: Command) { log.append(c) }
}

/// A camera snapshot with the viewport size: maps world points to viewport points.
package struct ViewProjection: Equatable {
    package var camera: Camera
    package var width: Double
    package var height: Double

    package init(camera: Camera, width: Double, height: Double) {
        self.camera = camera
        self.width = width
        self.height = height
    }

    package func point(_ p: Vec3) -> CGPoint? {
        camera.project(p, width: width, height: height).map { CGPoint(x: $0.x, y: $0.y) }
    }

    /// Direction of a world axis on screen (y down), and how much it faces the viewer.
    package func axis(_ v: Vec3) -> (dx: Double, dy: Double) {
        (v.dot(camera.right), -v.dot(camera.up))
    }
}

/// Icon for a command name in lists (palette, history).
package enum CommandIcons {
    package static func icon(for name: String) -> ForgeIcon {
        let table: [String: ForgeIcon] = [
            "body.extrude": .extrude, "body.revolve": .revolve, "body.fillet_edges": .fillet, "body.boolean": .combine,
            "body.create_box": .box, "body.create_cylinder": .cylinder, "body.create_sphere": .sphere, "body.create_cone": .cylinder,
            "body.create_torus": .sphere, "body.delete": .trash, "body.transform": .move, "query.mass_properties": .massProps,
            "query.measure": .measure, "sketch.create": .sketch, "sketch.exit": .exitSketch, "sketch.add_line": .line,
            "sketch.add_circle": .circle, "sketch.add_arc": .arc, "sketch.add_rectangle": .rectangle, "sketch.add_slot": .slot,
            "sketch.add_polygon": .polygon, "sketch.add_spline": .spline, "sketch.add_ellipse": .ellipse, "sketch.add_point": .point,
            "sketch.fillet": .sketchFillet, "sketch.chamfer": .sketchChamfer, "sketch.trim": .trim, "sketch.extend": .extend,
            "sketch.offset": .offset, "sketch.mirror": .mirror, "sketch.pattern_linear": .linearPattern,
            "sketch.pattern_circular": .circularPattern, "sketch.move": .move, "sketch.add_dimension": .smartDimension,
            "sketch.add_relation": .addRelation, "document.save": .save, "document.open": .open, "document.new": .newDoc,
            "edit.undo": .undo, "edit.redo": .redo,
        ]
        if let i = table[name] { return i }
        if name.hasPrefix("sketch.") { return .sketch }
        if name.hasPrefix("query.") { return .measure }
        if name.hasPrefix("view.") { return .viewOrient }
        return .command
    }
}

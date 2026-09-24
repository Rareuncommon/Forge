// Forge macOS application (SwiftUI). The UI is a client of the command bus: every action goes
// through Engine.execute — there is no UI-only functionality (SPEC §1.2, §3).
//
// Layout follows the design in docs/design (SolidWorks-style, native macOS chrome): window
// toolbar with the document, context tabs and command search; CommandManager ribbon; feature
// tree on the left; viewport with heads-up view toolbar and overlays in the middle;
// PropertyManager on the right; status bar at the bottom.

import AppKit
import ForgeCommands
import ForgeCore
import ForgeKernel
import ForgeRender
import ForgeSketch
import SwiftUI

@main
struct ForgeApp: App {
    @State private var model = AppModel()

    init() {
        // `swift run` launches a bare executable, not an .app bundle: without this it gets no
        // Dock icon or menu bar and does not come to the front.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Forge") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 680)
                .task {
                    NSApplication.shared.activate()
                    await model.bootstrap()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Part") { Task { await model.run("document.new", ["name": "Part1"]) } }.keyboardShortcut("n")
                Button("Open…") { model.openDocument() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveDocument(as: false) }.keyboardShortcut("s")
                Button("Save As…") { model.saveDocument(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Export STEP…") { model.export("step") }
                Button("Export STL…") { model.export("stl") }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { Task { await model.run("edit.undo") } }.keyboardShortcut("z")
                Button("Redo") { Task { await model.run("edit.redo") } }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("View") {
                // SolidWorks keys: Ctrl+1…7 standard views, Ctrl+8 Normal To.
                Button("Front") { model.setOrientation(.front) }.keyboardShortcut("1", modifiers: .control)
                Button("Back") { model.setOrientation(.back) }.keyboardShortcut("2", modifiers: .control)
                Button("Left") { model.setOrientation(.left) }.keyboardShortcut("3", modifiers: .control)
                Button("Right") { model.setOrientation(.right) }.keyboardShortcut("4", modifiers: .control)
                Button("Top") { model.setOrientation(.top) }.keyboardShortcut("5", modifiers: .control)
                Button("Bottom") { model.setOrientation(.bottom) }.keyboardShortcut("6", modifiers: .control)
                Button("Isometric") { model.setOrientation(.isometric) }.keyboardShortcut("7", modifiers: .control)
                Button("Dimetric") { model.setOrientation(.dimetric) }
                Button("Trimetric") { model.setOrientation(.trimetric) }
                Button("Normal To") { model.normalToSketch() }.keyboardShortcut("8", modifiers: .control).disabled(model.activeSketch == nil)
                Divider()
                Button("Zoom to Fit (F)") { model.zoomToFit() }
                Button("Previous View") { model.previousView() }
                Divider()
                Toggle("Perspective", isOn: Binding(get: { model.display.perspective }, set: { model.setPerspective($0) }))
                Toggle("Planes", isOn: Binding(get: { model.display.planes }, set: { model.display.planes = $0; Task { await model.refresh() } }))
                Toggle("Sketch Relations", isOn: Binding(get: { model.display.relations }, set: { model.display.relations = $0 }))
                Toggle("Sketch Dimensions", isOn: Binding(get: { model.display.dimensions }, set: { model.display.dimensions = $0 }))
            }
            CommandGroup(after: .textEditing) {
                Button("Search Commands…") { model.showPalette = true }.keyboardShortcut("k")
            }
        }
    }
}

enum RibbonTab: String, CaseIterable, Identifiable {
    case features = "Features", sketch = "Sketch", evaluate = "Evaluate"
    var id: String { rawValue }
}

/// The operation whose options are shown in the PropertyManager (with OK / Cancel).
enum Operation: Hashable {
    case extrude, cutExtrude, revolve, cutRevolve, hole, fillet, chamfer, shell, draft, plane, linearPattern, circularPattern, mirror, combine
    case massProperties, measure, check
    case primitive(Primitive)
    // Sketch operations on the selected sketch entities.
    case addRelation, displayRelations, sketchOffset, sketchMirror, sketchLinearPattern, sketchCircularPattern
    case sketchMove, sketchRotate, sketchScale

    var title: String {
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

    var icon: ForgeIcon {
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
    var isReport: Bool { self == .massProperties || self == .measure || self == .check || self == .displayRelations }
}

enum Primitive: String, CaseIterable, Identifiable {
    case box, cylinder, sphere, cone, torus
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: ForgeIcon {
        switch self {
        case .box: .box
        case .cylinder, .cone: .cylinder
        case .sphere, .torus: .sphere
        }
    }
}

/// A feature of the tree, as the app shows it.
struct FeatureRow: Identifiable, Equatable {
    var id: String
    var name: String
    var command: String
    var params: JSONValue
    var suppressed: Bool
    var state: FeatureStatus.State
    var error: String?
    var createdBodies: [String]

    var isSketch: Bool { command == "sketch.create" }
    var sketchID: String? { params["sketch"]?.stringValue }

    var icon: ForgeIcon {
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
    var operation: Operation? {
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

struct SketchRow: Identifiable, Equatable {
    var id: String
    var name: String
    var plane: String
    var status: SolveStatus?
    var dof: Int
    var unknowns: Int
}

/// What the viewport shows besides the model.
struct DisplayOptions {
    var planes = true
    var relations = true
    var dimensions = true
    var perspective = false
}

/// App state. Main-actor bound; talks to the Engine actor asynchronously so the UI never blocks.
@MainActor @Observable
final class AppModel {
    let engine = Engine()
    var documentName = "Part1"
    var documentPath: String?
    var bodies: [BodySummary] = []
    var sketches: [SketchRow] = []
    var features: [FeatureRow] = []
    /// Reference planes (Plane features).
    var refPlanes: [RefPlane] = []
    /// Number of active features (rollback bar position); nil = all.
    var rollback: Int?
    /// The feature whose page is open for editing (OK runs feature.edit instead of creating).
    var editingFeature: String?
    var selection: [String] = []
    var inspector: JSONValue?
    var lastError: ForgeError?
    var log: [String] = []
    var showPalette = false
    var paletteQuery = ""
    var ribbonTab: RibbonTab = .features
    var operation: Operation?
    /// The sketch an extrude/revolve uses, and the values being edited in the PropertyManager.
    var operationSketch: String?
    var form = OperationForm()
    /// Bumped whenever the scene must be re-uploaded to the GPU.
    var sceneVersion = 0
    var scene = DocumentSceneBox()
    var viewportCommands = ViewportCommandQueue()
    /// The sketch being edited (mirrors document.state's active_sketch).
    var activeSketch: String?
    var sketchState = SketchUIState()
    /// Shown next to the cursor while sketching (length, angle, radius…), at `hoverViewPoint`
    /// (viewport coordinates, origin top-left).
    var hoverLines: [String] = []
    var hoverViewPoint = CGPoint.zero
    /// Cursor position on the sketch plane, for the status bar.
    var cursorSketchPoint: Point2?
    /// Bumped when the sketch preview changes (re-upload of the viewport overlay).
    var overlayVersion = 0
    /// Camera and viewport size, published by the viewport so overlays can place labels.
    var projection: ViewProjection?
    /// Dimensions and relation glyphs of the sketch being edited, anchored in world space.
    var annotations: [SketchAnnotation] = []
    var display = DisplayOptions()
    var isDark = false
    var treeFilter = ""
    /// Undoable changes since the sketch was opened (Cancel Sketch undoes them).
    var sketchEditCount = 0
    /// For Enter = repeat last command.
    var lastSketchTool: SketchTool?
    var lastOperation: Operation?
    /// Smart Dimension's Modify box, while open.
    var dimensionEdit: DimensionEdit?
    /// Live preview of the operation being set up (bodies it would create).
    var preview = PreviewBox()
    var previewVersion = 0
    var previewError: String?
    /// Context toolbar and shortcut bar (S key) positions in the viewport, when shown.
    var contextToolbarAt: CGPoint?
    var shortcutBarAt: CGPoint?
    var orientationPaletteShown = false

    func bootstrap() async {
        await run("document.new", ["name": "Part1"])
    }

    @discardableResult
    func run(_ command: String, _ params: JSONValue = [:]) async -> CommandOutcome? {
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

    func refresh() async {
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
        let light = Theme.sketchRGBA(dark: false), dark = Theme.sketchRGBA(dark: true)
        var out = item
        out.edgeColors = item.edgeColors.mapValues { c in
            c == .sketchFully || c == light.fully ? dark.fully : c == .sketchUnder ? dark.under : c == .sketchOver ? dark.over : c
        }
        return out
    }

    /// Operations whose PropertyManager collects picks: a click adds to (or, on an item
    /// already picked, removes from) the selection instead of replacing it, as in SolidWorks.
    var collectsPicks: Bool {
        guard let op = operation else { return false }
        return [Operation.fillet, .chamfer, .shell, .draft, .measure, .massProperties, .check, .combine].contains(op) || op.isSketchOperation
    }

    /// A viewport or tree pick. `extend` (⇧, ⌘ or ⌃ held) toggles the item in the selection;
    /// so does any pick while an operation collecting picks is open.
    func select(_ ref: String?, extend: Bool) async {
        let additive = extend || collectsPicks
        if let ref {
            let mode = !additive ? "replace" : selection.contains(ref) ? "remove" : "add"
            await run("selection.set", ["entities": [.string(ref)], "mode": .string(mode)])
        } else if !additive {
            await run("selection.clear")
        }
    }

    func setOrientation(_ o: ViewOrientation) { viewportCommands.send(.orient(o)) }
    func zoomToFit() { viewportCommands.send(.fit) }
    func previousView() { viewportCommands.send(.previous) }
    func setStyle(_ s: RenderStyle) { viewportCommands.send(.style(s)) }
    func setPerspective(_ on: Bool) {
        display.perspective = on
        viewportCommands.send(.projection(on ? .perspective : .orthographic))
    }

    /// SolidWorks keys in the graphics area (docs/research §1.8): F fit, Z / ⇧Z zoom,
    /// S shortcut bar, Space view orientation, Return repeats the last command, Delete deletes
    /// the selected sketch entities.
    func viewportKey(_ key: String, at p: CGPoint) -> Bool {
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

    func normalToSketch() {
        if let p = sketchState.plane { viewportCommands.send(.normalTo(p)) }
    }

    /// Bodies in the selection (a face/edge selection counts for its body).
    var selectedBodies: [String] {
        var out: [String] = []
        for ref in selection {
            let b = String(ref.split(separator: "/").first ?? "")
            if b.hasPrefix("body-"), !out.contains(b) { out.append(b) }
        }
        return out
    }

    var selectedEdges: [String] { selection.filter { $0.contains("/edge-") } }

    /// Fillet / chamfer items: selected edges, and faces (all of a face's edges).
    var filletItems: [String] { selection.filter { $0.contains("/edge-") || $0.contains("/face-") } }

    /// One-line guidance for the status bar.
    var hint: String {
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

    func saveDocument(as saveAs: Bool) {
        if !saveAs, let path = documentPath {
            Task { await run("document.save", ["path": .string(path), "overwrite": true]) }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(documentName).forgepart"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var path = url.path
        if !path.hasSuffix(".forgepart") { path += ".forgepart" }
        Task {
            if await run("document.save", ["path": .string(path), "overwrite": true]) != nil { documentPath = path }
        }
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true  // a .forgepart is a package directory
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if await run("document.open", ["path": .string(url.path)]) != nil {
                documentPath = url.path
                zoomToFit()
            }
        }
    }

    /// Export the selected body (or the first) as STEP or STL.
    func export(_ format: String) {
        guard let body = selectedBodies.first ?? bodies.first?.id else {
            lastError = ForgeError(.invalidParams, "there is no body to export")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(documentName).\(format)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await run("export.\(format)", ["path": .string(url.path), "body": .string(body), "overwrite": true]) }
    }
}

/// The live preview's render items (not observed item by item).
struct PreviewBox {
    var items: [RenderItem] = []
    /// Bodies (ids) the preview replaces on screen.
    var hidden: [String] = []
}

/// Non-observable wrapper so large scene data doesn't participate in SwiftUI diffing.
struct DocumentSceneBox {
    var value: DocumentScene?
}

/// Commands from menus to the viewport, consumed in order by the viewport coordinator
/// (which remembers how many it has applied, so SwiftUI updates never mutate model state).
struct ViewportCommandQueue {
    enum Command { case orient(ViewOrientation), fit, previous, style(RenderStyle), projection(ProjectionKind), zoom(Double), normalTo(SketchPlane) }
    private(set) var log: [Command] = []
    mutating func send(_ c: Command) { log.append(c) }
}

/// A camera snapshot with the viewport size: maps world points to viewport points.
struct ViewProjection: Equatable {
    var camera: Camera
    var width: Double
    var height: Double

    func point(_ p: Vec3) -> CGPoint? {
        camera.project(p, width: width, height: height).map { CGPoint(x: $0.x, y: $0.y) }
    }

    /// Direction of a world axis on screen (y down), and how much it faces the viewer.
    func axis(_ v: Vec3) -> (dx: Double, dy: Double) {
        (v.dot(camera.right), -v.dot(camera.up))
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            RibbonView()
            HSplitView {
                FeatureTreeView()
                    .frame(minWidth: 220, idealWidth: 272, maxWidth: 400)
                ViewportArea()
                    .frame(minWidth: 480, minHeight: 360)
                PropertyManagerView()
                    .frame(minWidth: 280, idealWidth: 312, maxWidth: 420)
            }
            StatusBar()
        }
        .background(Theme.chrome)
        .navigationTitle(model.documentName)
        .navigationSubtitle(model.activeSketch != nil ? "Part · Editing sketch" : "Part")
        .toolbar { WindowToolbar(model: model) }
        .overlay {
            if model.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12).ignoresSafeArea()
                        .onTapGesture { model.showPalette = false }
                    CommandPaletteView()
                        .padding(.top, 90)
                }
            }
        }
        .onAppear { model.isDark = scheme == .dark }
        .onChange(of: scheme) { _, now in
            model.isDark = now == .dark
            Task { await model.refresh() }
        }
    }
}

/// Document actions, context tabs and command search in the window toolbar.
struct WindowToolbar: ToolbarContent {
    @Bindable var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { Task { await model.run("edit.undo") } } label: { IconView(icon: .undo, size: 18) }
                .help("Undo (⌘Z)")
            Button { Task { await model.run("edit.redo") } } label: { IconView(icon: .redo, size: 18) }
                .help("Redo (⇧⌘Z)")
            Button { model.saveDocument(as: false) } label: { IconView(icon: .save, size: 18, accent: Theme.accent) }
                .help("Save (⌘S)")
        }
        ToolbarItem(placement: .principal) {
            Picker("Tab", selection: $model.ribbonTab) {
                ForEach(RibbonTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.showPalette = true } label: {
                HStack(spacing: 8) {
                    IconView(icon: .search, size: 15).foregroundStyle(Theme.text2)
                    Text("Search commands").foregroundStyle(Theme.text2)
                    Spacer(minLength: 24)
                    Text("⌘K").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
                }
                .font(.system(size: 12.5))
                .frame(width: 220)
            }
            .help("Search commands (⌘K)")
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if let e = model.lastError {
                    IconView(icon: .warning, size: 14, accent: Theme.overDefined).foregroundStyle(Theme.overDefined)
                    Text(e.message).lineLimit(1).truncationMode(.tail).foregroundStyle(Theme.text)
                        .help(([e.message] + e.suggestions.map { "Suggestion: \($0.description)" }).joined(separator: "\n"))
                    // Executable fixes from the error (e.g. "make the dimension driven").
                    ForEach(Array(e.suggestions.filter { !$0.command.hasPrefix("help.") && !$0.command.hasPrefix("query.") && $0.command != "sketch.get" }.prefix(2).enumerated()), id: \.offset) { _, fix in
                        Button(fix.description) { Task { await model.run(fix.command, fix.params) } }
                            .buttonStyle(PanelButtonStyle())
                            .controlSize(.small)
                    }
                    Button("Dismiss") { model.lastError = nil }.buttonStyle(.link).font(.system(size: 11.5))
                } else {
                    if let icon = model.operation?.icon ?? model.sketchState.tool?.icon {
                        IconView(icon: icon, size: 14, accent: Theme.accent)
                    }
                    Text(model.hint).lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let p = model.cursorSketchPoint, model.activeSketch != nil {
                StatusCell { Text(String(format: "X %.2f  Y %.2f mm", p.u, p.v)).font(.system(size: 11.5, design: .monospaced)) }
            }
            if let row = model.sketches.first(where: { $0.id == model.activeSketch }) {
                StatusCell { SketchStatusBadge(row: row) }
                StatusCell { StatusDotLabel(text: "Editing \(row.name)", color: Theme.text2) }
            } else {
                StatusCell { StatusDotLabel(text: "Editing Part", color: Theme.text2) }
            }
            StatusCell { Text("MMGS").help("Units: millimetre, gram, second") }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.text2)
        .frame(height: 28)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

private struct StatusCell<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
    }
}

struct StatusDotLabel: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(color).fontWeight(.medium)
        }
    }
}

struct SketchStatusBadge: View {
    let row: SketchRow

    var body: some View {
        StatusDotLabel(text: Self.text(row), color: Self.color(row.status))
    }

    static func text(_ row: SketchRow) -> String {
        switch row.status {
        case .fullyDefined: "Fully defined"
        case .underDefined: "Under defined · \(row.dof) DOF"
        case .redundant, .conflicting: "Over defined"
        case .failed: "Cannot solve"
        case nil: "Empty"
        }
    }

    static func color(_ status: SolveStatus?) -> Color {
        switch status {
        case .fullyDefined: Theme.fullyDefined
        case .underDefined: Theme.underDefined
        case .redundant, .conflicting, .failed: Theme.overDefined
        case nil: Theme.text2
        }
    }
}

/// ⌘K palette: searches every command by name or description. A command without required
/// parameters runs directly; otherwise its parameters are entered as JSON.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var paramsText = "{}"
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        let results = model.engine.registry.search(model.paletteQuery, limit: 8)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconView(icon: .search, size: 18).foregroundStyle(Theme.text2)
                TextField("Search commands", text: $model.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { if let first = selected ?? results.first?.name { choose(first) } }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Rectangle().fill(Theme.line2).frame(height: 1)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(results, id: \.name) { d in
                        let on = d.name == (selected ?? results.first?.name)
                        Button { choose(d.name) } label: {
                            HStack(spacing: 12) {
                                IconView(icon: CommandIcons.icon(for: d.name), size: 20, accent: Theme.accent)
                                    .foregroundStyle(on ? Theme.accentText : Theme.text2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(d.summary).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                    Text(d.name).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text2)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .background(on ? Theme.accentSoft : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if results.isEmpty {
                        Text("No command matches “\(model.paletteQuery)”.").foregroundStyle(Theme.text2).padding(20)
                    }
                }
            }
            .frame(maxHeight: 352)
            if let name = selected {
                Rectangle().fill(Theme.line2).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Parameters for \(name) (JSON)").font(Theme.groupTitle).foregroundStyle(Theme.text2)
                    TextEditor(text: $paramsText)
                        .font(Theme.mono)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.fieldLine))
                        .frame(height: 80)
                    HStack {
                        Spacer()
                        Button("Cancel") { selected = nil }.buttonStyle(PanelButtonStyle())
                        Button("Run") { runSelected() }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .shadow(color: Theme.shadowColor, radius: 24, y: 8)
        .onAppear { focused = true }
        .onExitCommand { model.showPalette = false }
    }

    private func choose(_ name: String) {
        let d = try? model.engine.registry.descriptor(name)
        let required = d?.paramsSchema["required"]?.arrayValue ?? []
        selected = name
        if required.isEmpty {
            paramsText = "{}"
            runSelected()
        } else {
            paramsText = d?.examples.first.map { JSONCoding.string($0, pretty: true) } ?? "{}"
        }
    }

    private func runSelected() {
        guard let name = selected else { return }
        let params = (try? JSONCoding.parse(paramsText)) ?? [:]
        Task {
            await model.run(name, params)
            selected = nil
            model.showPalette = false
        }
    }
}

/// Icon for a command name in lists (palette, history).
enum CommandIcons {
    static func icon(for name: String) -> ForgeIcon {
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

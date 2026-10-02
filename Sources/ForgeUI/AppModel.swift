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
    case sweep, cutSweep, loft, cutLoft, rib
    case massProperties, measure, check, interference, moveBody
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
        case .sweep: "Sweep"
        case .cutSweep: "Cut-Sweep"
        case .loft: "Loft"
        case .cutLoft: "Cut-Loft"
        case .rib: "Rib"
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
        case .moveBody: "Move/Copy Bodies"
        case .massProperties: "Mass Properties"
        case .measure: "Measure"
        case .check: "Check"
        case .interference: "Interference Detection"
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
        case .sweep, .cutSweep: .sweep
        case .loft, .cutLoft: .loft
        case .rib: .rib
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
        case .moveBody: .move
        case .massProperties: .massProps
        case .measure: .measure
        case .check: .check
        case .interference: .combine
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
    package var isReport: Bool { self == .massProperties || self == .measure || self == .check || self == .interference || self == .displayRelations }
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
        case "body.sweep": .sweep
        case "body.loft": .loft
        case "body.rib": .rib
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
        case "body.sweep": params["operation"]?.stringValue == "cut" ? .cutSweep : .sweep
        case "body.loft": params["operation"]?.stringValue == "cut" ? .cutLoft : .loft
        case "body.rib": .rib
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
        case "body.transform": .moveBody
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
    @ObservationIgnored package var selectionZoomRequest = 0
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
    /// While a feature is edited the model is rolled back to just before it (as in SolidWorks),
    /// inside a transaction: the rollback position to return to (nil = the end).
    package var editReturnRollback: String??
    /// The rollback and re-selection that start an edit (awaited by tests).
    package var editTask: Task<Void, Never>?
    package var selection: [String] = []
    package var selectionFilter: SelectionFilter = .all
    package var viewportPickContext: ViewportPickContext?
    private var pickDocumentID: String?
    package var inspector: JSONValue?
    package var lastError: ForgeError?
    package var log: [String] = []
    package var showPalette = false
    package var paletteQuery = ""
    package var ribbonTab: RibbonTab = .features
    package var operation: Operation?
    /// The sketch an extrude/revolve uses, and the values being edited in the PropertyManager.
    package var operationSketch: String? {
        didSet {
            guard oldValue != operationSketch else { return }
            form.contours = nil
            contourChoices = []
            Task { await refreshContourChoices() }
        }
    }
    package var contourChoices: [ExtrudeContourChoice] = []
    package var contourQueryError: String?
    @ObservationIgnored package var contourRequest = 0
    @ObservationIgnored package var contourQueryTask: Task<Void, Never>?
    @ObservationIgnored package var contourQueryKey: String?
    package var form = OperationForm()
    /// Bumped whenever the scene must be re-uploaded to the GPU.
    package var sceneVersion = 0
    package var scene = DocumentSceneBox()
    package var hiddenBodyIDs: Set<String> = []
    package var isIsolatingBodies = false
    /// The document's scene before reference geometry (planes, axes, the sketch grid).
    @ObservationIgnored private var baseScene: DocumentScene?
    @ObservationIgnored private var referenceInputs: ReferenceInputs?
    /// The sketch grid shown (it follows the view: see `gridForView`).
    @ObservationIgnored package private(set) var grid: SketchGrid?
    @ObservationIgnored private var gridPending = false
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
    package var projection: ViewProjection? {
        didSet {
            // Zooming or panning far enough re-spaces or re-centres the sketch grid. Deferred:
            // viewports publish the projection while they update.
            guard activeSketch != nil, !gridPending, gridForView() != grid else { return }
            gridPending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                gridPending = false
                if gridForView() != grid { composeScene() }
            }
        }
    }
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
    package var previewRequest = 0
    package var interferenceRequest = 0
    package var previewError: String?
    /// Context toolbar and shortcut bar (S key) positions in the viewport, when shown.
    package var contextToolbarAt: CGPoint?
    package var shortcutBarAt: CGPoint?
    package var orientationPaletteShown = false

    /// Lines of each sketch, construction lines first (revolve axis choices).
    package var sketchLineIDs: [String: [String]] = [:]
    /// Point coordinates being typed in an entity page (by "point.x" / "point.y").
    package var pointEdits: [String: String] = [:]

    package init() {}

    /// Axis choices of a revolve: the lines of its sketch.
    package var revolveAxisOptions: [String] { operationSketch.flatMap { sketchLineIDs[$0] } ?? [] }

    package func bootstrap() async {
        await run("document.new", ["name": "Part1"])
    }

    @discardableResult
    package func run(_ command: String, _ params: JSONValue = [:]) async -> CommandOutcome? {
        selectionZoomRequest += 1
        do {
            let o = try await engine.execute(command, params)
            interferenceRequest += 1
            if operation == .interference && !command.hasPrefix("selection.") { form.result = nil }
            if command == "document.new" || command == "document.open" {
                documentPath = command == "document.open" ? params["path"]?.stringValue : nil
                operation = nil
                operationSketch = nil
                editingFeature = nil
                editReturnRollback = nil
                sketchEditCount = 0
                sketchState = SketchUIState()
                dimensionEdit = nil
                contextToolbarAt = nil
                shortcutBarAt = nil
                clearOperationPreview()
            }
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

    struct ReferenceInputs {
        var size: Double
        var editing: Sketch?
        var sketches: [Sketch]
        var refPlanes: [RefPlane]
    }

    /// The scene: the document's items plus reference geometry for the current view.
    private func composeScene() {
        guard var ds = baseScene, let r = referenceInputs else { return }
        grid = gridForView()
        ds.scene.items += ReferenceGeometry.items(
            size: r.size, sketch: r.editing, allSketches: r.sketches, planes: display.planes, refPlanes: r.refPlanes, dark: isDark, grid: grid)
        scene = DocumentSceneBox(value: ds)
        sceneVersion += 1
    }

    /// The sketch grid for the current view, as SolidWorks does it: about a dozen cells across
    /// the view's height, spaced 1–2–5 × 10ⁿ, centred near the view. It depends only on the
    /// camera, so drawing never rescales it; zooming refines or coarsens it.
    package func gridForView() -> SketchGrid? {
        guard let sk = referenceInputs?.editing else { return nil }
        let cam = projection?.camera
        let height = cam.map { $0.projection == .orthographic ? 2 * $0.orthoHalfHeight : 2 * $0.distance * tan($0.fovY / 2) } ?? 100
        let aspect = projection.map { $0.width / max($0.height, 1) } ?? 1.5
        let step = ReferenceGeometry.niceStep(height / 12)
        let span = height * max(aspect, 1)
        // Re-centred in blocks of ten cells, covering 1.5 views each way so panning within
        // the view does not rebuild it.
        let block = step * 10
        // Centred where the view's centre ray meets the sketch plane (after orbiting and
        // panning the target can be off the plane); edge-on, the target's projection.
        var centre = cam?.target ?? sk.plane.origin
        if let cam {
            let n = sk.plane.normal, dir = cam.back * -1
            let den = dir.dot(n)
            if abs(den) > 1e-3 { centre = centre + dir * ((sk.plane.origin - centre).dot(n) / den) }
        }
        let t = centre - sk.plane.origin
        let cu = (t.dot(sk.plane.xAxis) / block).rounded() * block, cv = (t.dot(sk.plane.yAxis) / block).rounded() * block
        let cells = Int((span * 1.5 / block).rounded(.up)) * 10
        return SketchGrid(step: step, centerU: cu, centerV: cv, halfCells: min(max(cells, 10), 400))
    }

    package func refresh() async {
        guard let doc = await engine.activeDocument else { return }
        documentName = doc.name
        hiddenBodyIDs = Set(doc.bodyOrder.filter { !doc.isBodyVisible($0) })
        isIsolatingBodies = doc.isolatedBodyIDs != nil
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
        if pickDocumentID != doc.id || selectionFilter != doc.selectionFilter { viewportPickContext = nil }
        pickDocumentID = doc.id
        selectionFilter = doc.selectionFilter
        sketchLineIDs = Dictionary(uniqueKeysWithValues: doc.orderedSketches.map { sk in
            let lines = sk.orderedEntities.filter { $0.kind == .line }
            return (sk.id, (lines.filter(\.construction) + lines.filter { !$0.construction }).map(\.id))
        })
        if var ds = try? DocumentScene(document: doc, highlight: doc.selection) {
            // Planes and origin axes follow the model's size; the sketch grid follows the view.
            let size = max(100, (ds.scene.bounds?.diagonal ?? 0) * 1.2)
            ds.fitBounds = ds.scene.bounds
            let editing = doc.activeSketch.flatMap { doc.sketches[$0] }
            // The sketch being edited: its dimensions (values and lines) are part of what to frame.
            if let sk = editing {
                for c in sk.userConstraints {
                    guard let l = sk.dimensionLayout(c) else { continue }
                    for q in [l.text] + l.segments.flatMap({ [$0.0, $0.1] }) {
                        let p = sk.plane.point(q.u, q.v)
                        let b = BoundingBox(min: p, max: p)
                        ds.fitBounds = ds.fitBounds.map { $0.union(b) } ?? b
                    }
                }
            }
            // Nothing to frame yet: Zoom to Fit shows 100 mm around the origin (not the grid,
            // which follows the view and would zoom out on every fit).
            if ds.fitBounds == nil { ds.fitBounds = BoundingBox(min: Vec3(-50, -50, -50), max: Vec3(50, 50, 50)) }
            if isDark { ds.scene.items = ds.scene.items.map(Self.darkened) }
            baseScene = ds
            referenceInputs = ReferenceInputs(size: size, editing: editing, sketches: doc.orderedSketches, refPlanes: doc.orderedRefPlanes)
            composeScene()
        }
        await refreshSketchState()
        if operation == .extrude || operation == .cutExtrude { await refreshContourChoices() }
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
        return [Operation.fillet, .chamfer, .shell, .draft, .measure, .massProperties, .check, .interference, .combine].contains(op) || op.isSketchOperation
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

    package func setOrientation(_ o: ViewOrientation) { selectionZoomRequest += 1; viewportCommands.send(.orient(o)) }
    package func zoomToFit() { selectionZoomRequest += 1; viewportCommands.send(.fit) }
    package func zoomToSelection() async {
        selectionZoomRequest += 1
        let request = selectionZoomRequest, selected = selection, version = sceneVersion, view = projection
        guard !selected.isEmpty else { return }
        do {
            let aspect = view.map { max($0.width, 1) / max($0.height, 1) } ?? 1
            var params: [String: JSONValue] = ["entities": .array(selected.map(JSONValue.string)), "aspect": .number(aspect)]
            if let view { params["camera"] = try JSONCoding.toJSON(view.camera) }
            let result = try await engine.execute("view.zoom_to_selection", .object(params)).result
            guard request == selectionZoomRequest, selected == selection, version == sceneVersion, view == projection else { return }
            let output = try JSONCoding.fromJSON(ViewZoomToSelection.Output.self, result)
            if let bounds = output.bounds { viewportCommands.send(.fitSelection(bounds)) }
            lastError = nil
        } catch let error as ForgeError {
            guard request == selectionZoomRequest, selected == selection, version == sceneVersion, view == projection else { return }
            lastError = error
        } catch {
            guard request == selectionZoomRequest, selected == selection, version == sceneVersion, view == projection else { return }
            lastError = ForgeError(.internalError, error.localizedDescription)
        }
    }

    package func previousView() { selectionZoomRequest += 1; viewportCommands.send(.previous) }
    package func setStyle(_ s: RenderStyle) { viewportPickContext = nil; viewportCommands.send(.style(s)) }
    package func setPerspective(_ on: Bool) {
        selectionZoomRequest += 1
        display.perspective = on
        viewportCommands.send(.projection(on ? .perspective : .orthographic))
    }

    /// SolidWorks keys in the graphics area (docs/research §1.8): F fit, Z / ⇧Z zoom,
    /// S shortcut bar, Space view orientation, Return repeats the last command, Delete deletes
    /// the selected sketch entities.
    package func viewportKey(_ key: String, at p: CGPoint) -> Bool {
        switch key {
        case "f": zoomToFit()
        case "z": selectionZoomRequest += 1; viewportCommands.send(.zoom(1 / 1.25))
        case "Z": selectionZoomRequest += 1; viewportCommands.send(.zoom(1.25))
        case "s", "S": shortcutBarAt = p
        case "space": orientationPaletteShown.toggle()
        case "tab", "\t":
            guard canSelectOther else { return false }
            Task { await selectOther() }
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

    package var canNormalTo: Bool { sketchState.plane != nil || selectedFace != nil || selection.contains { $0.hasPrefix("plane-") } }

    package func normalToSketch() {
        selectionZoomRequest += 1
        if let plane = sketchState.plane { viewportCommands.send(.normalTo(plane)) }
        else { Task { await normalToSelection() } }
    }

    package func normalToSelection() async {
        selectionZoomRequest += 1
        let request = selectionZoomRequest
        if let plane = sketchState.plane { viewportCommands.send(.normalTo(plane)); return }
        guard let ref = selectedFace ?? selection.last(where: { $0.hasPrefix("plane-") }) else { return }
        do {
            guard let doc = await engine.activeDocument else { return }
            let placement = ref.hasPrefix("plane-") && StandardPlane(rawValue: String(ref.dropFirst(6))) != nil ? String(ref.dropFirst(6)) : ref
            guard request == selectionZoomRequest else { return }
            viewportCommands.send(.normalTo(try doc.resolvePlacement(placement)))
            lastError = nil
        } catch { lastError = ForgeError.wrap(error) }
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

    package var selectedEdges: [String] { selection.filter { entityKind($0) == .edge } }

    /// Fillet / chamfer items: selected edges, and faces (all of a face's edges).
    package var filletItems: [String] { selection.filter { entityKind($0) == .edge || entityKind($0) == .face } }

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
    package enum Command { case orient(ViewOrientation), fit, fitSelection(BoundingBox), previous, style(RenderStyle), projection(ProjectionKind), zoom(Double), normalTo(SketchPlane) }
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

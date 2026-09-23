// Forge macOS application (SwiftUI). The UI is a client of the command bus: every action goes
// through Engine.execute — there is no UI-only functionality (SPEC §1.2, §3).
//
// Layout (SolidWorks-style): command ribbon on top, feature tree on the left, viewport with a
// heads-up view toolbar in the middle, property panel on the right, status bar at the bottom.

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
                .frame(minWidth: 1000, minHeight: 640)
                .task {
                    NSApplication.shared.activate()
                    await model.bootstrap()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Part") { Task { await model.run("document.new", ["name": "Part1"]) } }.keyboardShortcut("n")
                Button("Open…") { model.openDocument() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveDocument(as: false) }.keyboardShortcut("s")
                Button("Save As…") { model.saveDocument(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { Task { await model.run("edit.undo") } }.keyboardShortcut("z")
                Button("Redo") { Task { await model.run("edit.redo") } }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("View") {
                ForEach(ViewOrientation.allCases, id: \.self) { o in
                    Button(o.rawValue.capitalized) { model.setOrientation(o) }
                }
                Divider()
                Button("Zoom to Fit") { model.zoomToFit() }.keyboardShortcut("f", modifiers: [])
                Button("Normal To Sketch") { model.normalToSketch() }.disabled(model.activeSketch == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Command Palette…") { model.showPalette = true }.keyboardShortcut("k")
            }
        }
    }
}

enum RibbonTab: String, CaseIterable, Identifiable {
    case features = "Features", sketch = "Sketch", evaluate = "Evaluate"
    var id: String { rawValue }
}

/// The operation whose options are shown in the property panel (with OK / Cancel).
enum Operation: Equatable {
    case extrude, revolve, fillet, combine, massProperties
    case primitive(Primitive)

    var title: String {
        switch self {
        case .extrude: "Extruded Boss/Base"
        case .revolve: "Revolved Boss/Base"
        case .fillet: "Fillet"
        case .combine: "Combine"
        case .massProperties: "Mass Properties"
        case .primitive(let p): p.title
        }
    }
}

enum Primitive: String, CaseIterable, Identifiable {
    case box, cylinder, sphere
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .box: "cube"
        case .cylinder: "cylinder"
        case .sphere: "circle.circle"
        }
    }
}

struct SketchRow: Identifiable, Equatable {
    var id: String
    var name: String
    var plane: String
    var status: SolveStatus?
    var dof: Int
}

/// App state. Main-actor bound; talks to the Engine actor asynchronously so the UI never blocks.
@MainActor @Observable
final class AppModel {
    let engine = Engine()
    var documentName = "Part1"
    var documentPath: String?
    var bodies: [BodySummary] = []
    var sketches: [SketchRow] = []
    var selection: [String] = []
    var inspector: JSONValue?
    var lastError: ForgeError?
    var log: [String] = []
    var showPalette = false
    var paletteQuery = ""
    var ribbonTab: RibbonTab = .features
    var operation: Operation?
    /// The sketch an extrude/revolve uses, and the values being edited in the property panel.
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
    var hoverLabel: String?
    var hoverViewPoint = CGPoint.zero
    /// Bumped when the sketch preview changes (re-upload of the viewport overlay).
    var overlayVersion = 0

    func bootstrap() async {
        await run("document.new", ["name": "Part1"])
    }

    @discardableResult
    func run(_ command: String, _ params: JSONValue = [:]) async -> CommandOutcome? {
        do {
            let o = try await engine.execute(command, params)
            log.append("\(command) ✓")
            lastError = nil
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
            SketchRow(id: $0.id, name: $0.name, plane: $0.plane.name, status: $0.report?.status, dof: $0.report?.dof ?? 0)
        }
        selection = doc.selection
        if var ds = try? DocumentScene(document: doc, highlight: doc.selection) {
            let size = max(100, (ds.scene.bounds?.diagonal ?? 0) * 1.2)
            let editing = doc.activeSketch.flatMap { doc.sketches[$0] }
            ds.scene.items += ReferenceGeometry.items(size: size, sketch: editing, allSketches: doc.orderedSketches)
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

    func select(_ ref: String?, extend: Bool) async {
        if let ref {
            await run("selection.set", ["entities": [.string(ref)], "mode": extend ? "add" : "replace"])
        } else if !extend {
            await run("selection.clear")
        }
    }

    func setOrientation(_ o: ViewOrientation) { viewportCommands.send(.orient(o)) }
    func zoomToFit() { viewportCommands.send(.fit) }
    func setStyle(_ s: RenderStyle) { viewportCommands.send(.style(s)) }

    func normalToSketch() {
        switch sketchState.plane?.name {
        case "Front": setOrientation(.front)
        case "Top": setOrientation(.top)
        case "Right": setOrientation(.right)
        default: break
        }
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

    /// One-line guidance for the status bar.
    var hint: String {
        if let op = operation { return "\(op.title): set the options on the right, then press OK." }
        if activeSketch != nil {
            if let t = sketchState.tool { return t.hint }
            return "Pick a sketch tool, or select curves and use Smart Dimension. Esc cancels."
        }
        if bodies.isEmpty && sketches.isEmpty {
            return "Start a sketch on a plane (Sketch tab or right-click a plane), or add a primitive."
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
}

/// Non-observable wrapper so large scene data doesn't participate in SwiftUI diffing.
struct DocumentSceneBox {
    var value: DocumentScene?
}

/// Commands from menus to the viewport, consumed in order by the viewport coordinator
/// (which remembers how many it has applied, so SwiftUI updates never mutate model state).
struct ViewportCommandQueue {
    enum Command { case orient(ViewOrientation), fit, style(RenderStyle) }
    private(set) var log: [Command] = []
    mutating func send(_ c: Command) { log.append(c) }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            RibbonView()
            Divider()
            HSplitView {
                FeatureTreeView()
                    .frame(minWidth: 190, idealWidth: 230, maxWidth: 360)
                ZStack(alignment: .top) {
                    ViewportView()
                    HeadsUpToolbar()
                        .padding(.top, 8)
                    if let label = model.hoverLabel {
                        GeometryReader { _ in
                            Text(label)
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .fixedSize()
                                .position(x: model.hoverViewPoint.x + 60, y: model.hoverViewPoint.y + 22)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .frame(minWidth: 420, minHeight: 320)
                PropertyManagerView()
                    .frame(minWidth: 230, idealWidth: 270, maxWidth: 380)
            }
            Divider()
            StatusBar()
        }
        .navigationTitle(model.documentName)
        .sheet(isPresented: $model.showPalette) { CommandPaletteView() }
    }
}

/// Floating view controls over the viewport (SolidWorks' heads-up view toolbar).
struct HeadsUpToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            Button { model.zoomToFit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Zoom to fit (F)")
            Menu {
                ForEach(ViewOrientation.allCases, id: \.self) { o in
                    Button(o.rawValue.capitalized) { model.setOrientation(o) }
                }
            } label: { Image(systemName: "cube.transparent") }
                .help("View orientation")
            if model.activeSketch != nil {
                Button { model.normalToSketch() } label: { Image(systemName: "square.dashed") }
                    .help("Normal to the sketch plane")
            }
            Menu {
                Button("Shaded with Edges") { model.setStyle(.shadedWithEdges) }
                Button("Shaded") { model.setStyle(.shaded) }
                Button("Hidden Lines Removed") { model.setStyle(.hiddenLinesRemoved) }
                Button("Wireframe") { model.setStyle(.wireframe) }
            } label: { Image(systemName: "circle.lefthalf.filled") }
                .help("Display style")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let e = model.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(e.message).lineLimit(1).truncationMode(.tail)
                    .help(([e.message] + e.suggestions.map { "Suggestion: \($0.description)" }).joined(separator: "\n"))
                Button("Dismiss") { model.lastError = nil }.buttonStyle(.link)
            } else {
                Text(model.hint).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let row = model.sketches.first(where: { $0.id == model.activeSketch }) {
                SketchStatusBadge(row: row)
            }
            Text("MMGS").foregroundStyle(.secondary).help("Units: millimetre, gram, second")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }
}

struct SketchStatusBadge: View {
    let row: SketchRow

    var body: some View {
        let (text, color): (String, Color) = switch row.status {
        case .fullyDefined: ("Fully Defined", .primary)
        case .underDefined: ("Under Defined · \(row.dof) DOF", .blue)
        case .redundant, .conflicting: ("Over Defined", .red)
        case .failed: ("Cannot Solve", .red)
        case nil: ("—", .secondary)
        }
        return Text("\(row.name): \(text)").foregroundStyle(color)
    }
}

/// ⌘K palette: searches every command; parameters are entered as JSON and executed through
/// the bus.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var paramsText = "{}"

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading) {
            TextField("Search commands", text: $model.paletteQuery)
                .textFieldStyle(.roundedBorder)
            List(model.engine.registry.search(model.paletteQuery, limit: 30), id: \.name, selection: $selected) { d in
                VStack(alignment: .leading) {
                    Text(d.name).font(.system(.body, design: .monospaced))
                    Text(d.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 240)
            TextEditor(text: $paramsText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 90)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Run") {
                    guard let name = selected else { return }
                    let params = (try? JSONCoding.parse(paramsText)) ?? [:]
                    Task {
                        await model.run(name, params)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding()
        .frame(width: 560, height: 480)
    }
}

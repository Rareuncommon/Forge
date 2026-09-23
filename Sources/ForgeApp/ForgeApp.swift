// Forge macOS application shell (SwiftUI). The UI is a client of the command bus: every action
// below goes through Engine.execute — there is no UI-only functionality (SPEC §1.2, §3).
//
// STATUS: M0 skeleton. Written for macOS 27 / Xcode 27 but NOT yet compiled or run — the M0
// session ran on Linux. See PROGRESS.md.

import ForgeCommands
import ForgeCore
import ForgeKernel
import ForgeRender
import SwiftUI

@main
struct ForgeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Forge") {
            ContentView()
                .environment(model)
                .task { await model.bootstrap() }
        }
        .commands {
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
            }
            CommandGroup(after: .textEditing) {
                Button("Command Palette…") { model.showPalette = true }.keyboardShortcut("k")
            }
        }
    }
}

/// App state. Main-actor bound; talks to the Engine actor asynchronously so the UI never blocks.
@MainActor @Observable
final class AppModel {
    let engine = Engine()
    var bodies: [BodySummary] = []
    var selection: [String] = []
    var inspector: JSONValue?
    var lastError: ForgeError?
    var log: [String] = []
    var showPalette = false
    var paletteQuery = ""
    /// Bumped whenever the scene must be re-uploaded to the GPU.
    var sceneVersion = 0
    var scene = DocumentSceneBox()
    var viewportCommands = ViewportCommandQueue()
    /// The sketch being edited (mirrors document.state's active_sketch).
    var activeSketch: String?
    var sketchState = SketchUIState()

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
        bodies = (try? doc.orderedBodies.map(BodySummary.init)) ?? []
        selection = doc.selection
        if let ds = try? DocumentScene(document: doc, highlight: doc.selection) {
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
}

/// Non-observable wrapper so large scene data doesn't participate in SwiftUI diffing.
struct DocumentSceneBox {
    var value: DocumentScene?
}

/// Commands from menus to the viewport, consumed in order by the viewport coordinator
/// (which remembers how many it has applied, so SwiftUI updates never mutate model state).
struct ViewportCommandQueue {
    enum Command { case orient(ViewOrientation), fit }
    private(set) var log: [Command] = []
    mutating func send(_ c: Command) { log.append(c) }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            FeatureTreeView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            HSplitView {
                VStack(spacing: 0) {
                    SketchToolbar()
                    Divider()
                    ViewportView()
                }
                .frame(minWidth: 400, minHeight: 300)
                InspectorView()
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Box", systemImage: "cube") {
                    Task { await model.run("body.create_box", ["width": 50, "height": 30, "depth": 20]) }
                }
                Button("Cylinder", systemImage: "cylinder") {
                    Task { await model.run("body.create_cylinder", ["radius": 10, "height": 40]) }
                }
                Button("Commands", systemImage: "command") { model.showPalette = true }
            }
        }
        .sheet(isPresented: $model.showPalette) { CommandPaletteView() }
        .overlay(alignment: .bottom) {
            if let e = model.lastError {
                ErrorBanner(error: e)
                    .padding()
            }
        }
    }
}

struct FeatureTreeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.bodies, id: \.id) { b in
            Button {
                Task { await model.select(b.id, extend: NSEvent.modifierFlags.contains(.shift)) }
            } label: {
                VStack(alignment: .leading) {
                    Text(b.name).font(.body)
                    Text("\(b.id) · \(b.topology.faces) faces · \(String(format: "%.1f", b.volumeMM3)) mm³")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(model.selection.contains(b.id) ? Color.accentColor.opacity(0.2) : Color.clear)
            .accessibilityLabel("\(b.name), \(b.topology.faces) faces")
        }
        .navigationTitle("Bodies")
    }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Selection").font(.headline)
                if model.selection.isEmpty {
                    Text("Nothing selected").foregroundStyle(.secondary)
                } else {
                    ForEach(model.selection, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
                }
                if let info = model.inspector {
                    Divider()
                    Text(JSONCoding.string(info, pretty: true))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Divider()
                Text("Log").font(.headline)
                ForEach(Array(model.log.suffix(20).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }
}

struct ErrorBanner: View {
    let error: ForgeError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(error.message).font(.callout.bold())
            ForEach(error.suggestions, id: \.self) { s in
                Text("Suggestion: \(s.description) (\(s.command))").font(.caption)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// ⌘K palette: searches every command; parameters are entered as JSON and executed through
/// the bus. (Inline typed parameter entry replaces the JSON field in M1.)
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

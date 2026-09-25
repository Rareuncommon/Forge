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
import ForgeUI
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
                    model.platform = MacPlatform.shared
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

/// Native macOS dialogs for the shared model.
@MainActor
final class MacPlatform: PlatformServices {
    static let shared = MacPlatform()

    func confirm(_ title: String, _ message: String, confirm: String, cancel: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func chooseSavePath(suggestedName name: String) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func chooseOpenPath() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true  // a .forgepart is a package directory
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

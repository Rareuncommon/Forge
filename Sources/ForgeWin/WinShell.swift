// The Windows front end: shows ForgeUI's shared model through the native shell in CForgeWin.
// The ribbon, tree and PropertyManager are pushed from their specs (RibbonSpec, TreeSpec,
// PanelSpec) whenever what they read changes (Observation); native events call the specs'
// actions. Everything the user does goes through the model and the command bus, exactly as on
// macOS.

import CForgeWin
import ForgeCommands
import ForgeCore
import ForgeRender
import ForgeSketch
import ForgeUI
import Foundation
import Observation

@MainActor
final class WinShell {
    let model = AppModel()
    private(set) var app: OpaquePointer?
    private(set) var viewport: WinViewport!

    // What the native controls were built from (events index into these).
    private var ribbonButtons: [RibbonButton] = []
    private var treeNodes: [TreeNode] = []
    private var panelControls: [PanelControl] = []
    private var panelSections: [PanelSection] = []
    private var panelSignature = ""

    // Set by Observation when what an area shows changed.
    private var dirtyRibbon = true, dirtyTree = true, dirtyPanel = true, dirtyStatus = true, dirtyMenus = true
    private var sketching = false

    init() {}

    /// Create the window; false if Windows refused (no window station, no device).
    func start() -> Bool {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let app = fw_app_create("Forge", { ctx, event in
            guard let ctx, let event else { return }
            let shell = Unmanaged<WinShell>.fromOpaque(ctx).takeUnretainedValue()
            let e = event.pointee
            let text = e.text.map { String(cString: $0) } ?? ""
            MainActor.assumeIsolated { shell.handle(e, text: text) }
        }, ctx) else { return false }
        self.app = app
        viewport = WinViewport(shell: self, app: app)
        model.platform = WinPlatform(app: app)
        fw_app_show(app)
        Task {
            await model.bootstrap()
            sync()
        }
        return true
    }

    /// Run until the window closes. Foundation's run loop (main-actor tasks, timers) is served
    /// between batches of window messages.
    func run() {
        guard let app else { return }
        while fw_app_pump(app, 8) != 0 {
            _ = RunLoop.main.limitDate(forMode: .default)
            sync()
        }
        fw_app_destroy(app)
        self.app = nil
    }

    // MARK: pushing the model to the native controls

    private func observe<T>(_ read: () -> T, _ mark: @escaping @MainActor (WinShell) -> Void) -> T {
        withObservationTracking(read) { [weak self] in
            MainActor.assumeIsolated {
                if let self { mark(self) }
            }
        }
    }

    func sync() {
        guard app != nil else { return }
        // Entering a sketch shows the sketch tools; leaving it goes back to features (as on macOS).
        let nowSketching = model.activeSketch != nil
        if nowSketching != sketching {
            sketching = nowSketching
            model.ribbonTab = nowSketching ? .sketch : .features
        }
        if dirtyRibbon {
            dirtyRibbon = false
            pushRibbon()
        }
        if dirtyTree {
            dirtyTree = false
            pushTree()
        }
        if dirtyPanel {
            dirtyPanel = false
            pushPanel()
        }
        if dirtyStatus {
            dirtyStatus = false
            pushStatus()
        }
        if dirtyMenus {
            dirtyMenus = false
            pushMenus()
        }
        viewport.sync()
    }

    private func pushRibbon() {
        guard let app else { return }
        let (tab, groups) = observe({ (model.ribbonTab, model.ribbonGroups) }) { $0.dirtyRibbon = true }
        fw_set_tab(app, Int32(RibbonTab.allCases.firstIndex(of: tab) ?? 0))
        ribbonButtons = []
        fw_ribbon_begin(app)
        for g in groups {
            fw_ribbon_group(app, g.title)
            for b in g.buttons {
                ribbonButtons.append(b)
                fw_ribbon_button(app, b.title, b.help, b.large ? 1 : 0, b.active ? 1 : 0, b.enabled ? 1 : 0, b.variants.map(\.title).joined(separator: "\n"))
            }
        }
        fw_ribbon_end(app)
    }

    private func pushTree() {
        guard let app else { return }
        let (name, nodes) = observe({ (model.documentName, model.treeNodes) }) { $0.dirtyTree = true }
        treeNodes = []
        fw_tree_begin(app)
        treeNodes.append(TreeNode(id: "part", icon: .part, title: name))
        fw_tree_node(app, 0, name, "", Int32(FW_NODE_NORMAL), 0, "")
        func add(_ n: TreeNode, depth: Int) {
            treeNodes.append(n)
            let state: Int32 =
                switch n.state {
                case _ where n.isRollbackBar: Int32(FW_NODE_ROLLBACK_BAR)
                case .normal: Int32(FW_NODE_NORMAL)
                case .suppressed: Int32(FW_NODE_SUPPRESSED)
                case .rolledBack: Int32(FW_NODE_ROLLED_BACK)
                case .warning: Int32(FW_NODE_WARNING)
                case .error: Int32(FW_NODE_ERROR)
                }
            fw_tree_node(app, Int32(depth), n.title, n.tooltip, state, n.selected ? 1 : 0, n.menu.map(\.title).joined(separator: "\n"))
            for c in n.children { add(c, depth: depth + 1) }
        }
        for n in nodes { add(n, depth: 1) }
        fw_tree_end(app)
    }

    private func pushPanel() {
        guard let app else { return }
        let page = observe({ () -> PanelPage in
            let p = model.panelPage
            // Read the values too, so typing elsewhere (feature edit, undo) refreshes them.
            for s in p.sections {
                _ = s.toggle?.get()
                for c in s.controls { _ = Self.value(c) }
            }
            return p
        }) { $0.dirtyPanel = true }
        let signature = page.signature
        if signature != panelSignature {
            panelSignature = signature
            panelSections = page.sections
            panelControls = page.sections.flatMap(\.controls)
            fw_panel_begin(app, page.title, page.subtitle, page.message ?? "", page.ok != nil ? 1 : 0, page.cancel != nil ? 1 : 0)
            for s in page.sections {
                fw_panel_section(app, s.title, s.toggle.map { $0.get() ? 1 : 0 } ?? -1)
                for c in s.controls { addControl(c) }
            }
            fw_panel_end(app)
        } else {
            panelSections = page.sections
            panelControls = page.sections.flatMap(\.controls)
            for (i, c) in panelControls.enumerated() {
                switch c.kind {
                case .field(_, _, let get, _, _): fw_panel_set_text(app, Int32(i), get())
                case .check(_, let get, _): fw_panel_set_check(app, Int32(i), get() ? 1 : 0)
                case .choice(_, let options, let get, _):
                    let tag = get()
                    fw_panel_set_choice(app, Int32(i), Int32(options.firstIndex { $0.tag == tag } ?? -1))
                default: break
                }
            }
        }
    }

    private static func value(_ c: PanelControl) -> String {
        switch c.kind {
        case .field(_, _, let get, _, _): get()
        case .check(_, let get, _): String(get())
        case .choice(_, _, let get, _): get()
        default: ""
        }
    }

    private func addControl(_ c: PanelControl) {
        guard let app else { return }
        switch c.kind {
        case .field(let label, let unit, let get, _, _): fw_panel_field(app, label, unit, get())
        case .check(let label, let get, _): fw_panel_check(app, label, get() ? 1 : 0)
        case .choice(let label, let options, let get, _):
            let tag = get()
            fw_panel_choice(app, label, options.map(\.title).joined(separator: "\n"), Int32(options.firstIndex { $0.tag == tag } ?? -1))
        case .list(let items, let placeholder, let active, _): fw_panel_list(app, items.joined(separator: "\n"), placeholder, active ? 1 : 0)
        case .note(let text, let warning): fw_panel_note(app, text, warning ? 1 : 0)
        case .value(let label, let value): fw_panel_value(app, label, value)
        case .buttons(let buttons): fw_panel_buttons(app, buttons.map(\.title).joined(separator: "\n"))
        case .rows(let rows):
            fw_panel_rows(
                app, rows.map(\.text).joined(separator: "\n"), rows.map(\.detail).joined(separator: "\n"), rows.map { $0.problem ? "1" : "0" }.joined(separator: "\n"),
                rows.contains { $0.delete != nil } ? 1 : 0)
        }
    }

    private func pushStatus() {
        guard let app else { return }
        let (title, hint, error, cursor, row, dirtySketch) = observe({ () -> (String, String, ForgeError?, Point2?, SketchRow?, Int) in
            let row = model.sketches.first { $0.id == model.activeSketch }
            return (model.documentName, model.hint, model.lastError, model.cursorSketchPoint, row, model.sketchEditCount)
        }) { $0.dirtyStatus = true }
        _ = dirtySketch
        fw_set_title(app, "\(title) - Forge")
        let middle: String
        if let error {
            middle = "\u{26A0} " + error.message
        } else if let p = cursor {
            middle = String(format: "%.2f mm, %.2f mm", p.u, p.v)
        } else {
            middle = ""
        }
        let right = row.map { "\($0.name): " + AppModel.statusText($0) } ?? "MMGS"
        fw_set_status(app, hint, middle, right)
    }

    private func pushMenus() {
        guard let app else { return }
        let (display, style, canNormal) = observe({ (model.display, viewport.style, model.activeSketch != nil) }) { $0.dirtyMenus = true }
        fw_set_menu_check(app, Int32(FW_MENU_PERSPECTIVE), display.perspective ? 1 : 0)
        fw_set_menu_check(app, Int32(FW_MENU_PLANES), display.planes ? 1 : 0)
        fw_set_menu_check(app, Int32(FW_MENU_RELATIONS), display.relations ? 1 : 0)
        fw_set_menu_check(app, Int32(FW_MENU_DIMENSIONS), display.dimensions ? 1 : 0)
        let styles: [(Int, RenderStyle)] = [(FW_MENU_SHADED_EDGES, .shadedWithEdges), (FW_MENU_SHADED, .shaded), (FW_MENU_WIREFRAME, .wireframe), (FW_MENU_HIDDEN_LINES, .hiddenLinesRemoved)]
        for (id, s) in styles { fw_set_menu_check(app, Int32(id), s == style ? 1 : 0) }
        fw_set_menu_enabled(app, Int32(FW_MENU_NORMAL_TO), canNormal ? 1 : 0)
    }

    func markMenus() { dirtyMenus = true }

    // MARK: events

    private func handle(_ e: fw_event, text: String) {
        let extend = Int(e.mods) & (FW_MOD_SHIFT | FW_MOD_CTRL) != 0
        switch Int(e.kind) {
        case FW_EV_MENU: menu(Int(e.id))
        case FW_EV_TAB:
            let tabs = RibbonTab.allCases
            if Int(e.id) < tabs.count { model.ribbonTab = tabs[Int(e.id)] }
        case FW_EV_RIBBON:
            guard Int(e.id) < ribbonButtons.count else { break }
            let b = ribbonButtons[Int(e.id)]
            if e.sub < 0 { b.action() } else if Int(e.sub) < b.variants.count { b.variants[Int(e.sub)].action() }
        case FW_EV_TREE_SELECT:
            if Int(e.id) < treeNodes.count { treeNodes[Int(e.id)].select?(extend) }
        case FW_EV_TREE_ACTIVATE:
            if Int(e.id) < treeNodes.count { treeNodes[Int(e.id)].activate?() }
        case FW_EV_TREE_MENU:
            if Int(e.id) < treeNodes.count, Int(e.sub) < treeNodes[Int(e.id)].menu.count { treeNodes[Int(e.id)].menu[Int(e.sub)].action() }
        case FW_EV_FILTER: model.treeFilter = text
        case FW_EV_PANEL_TEXT, FW_EV_PANEL_SUBMIT, FW_EV_PANEL_CHECK, FW_EV_PANEL_CHOICE, FW_EV_PANEL_BUTTON, FW_EV_PANEL_ROW_DELETE, FW_EV_PANEL_LIST:
            panelEvent(e, text: text)
        case FW_EV_PANEL_SECTION:
            if Int(e.id) < panelSections.count { panelSections[Int(e.id)].toggle?.set(e.sub == 1) }
        case FW_EV_PANEL_OK:
            model.panelPage.ok?()
        case FW_EV_PANEL_CANCEL:
            model.panelPage.cancel?()
        case FW_EV_TICK:
            _ = RunLoop.main.limitDate(forMode: .default)
        case FW_EV_CLOSE:
            break
        default:
            viewport.handle(e, text: text)
        }
        sync()
    }

    private func panelEvent(_ e: fw_event, text: String) {
        guard Int(e.id) < panelControls.count else { return }
        let c = panelControls[Int(e.id)]
        switch (Int(e.kind), c.kind) {
        case (FW_EV_PANEL_TEXT, .field(_, _, _, let set, _)): set(text)
        case (FW_EV_PANEL_SUBMIT, .field(_, _, _, _, let submit)): submit?()
        case (FW_EV_PANEL_CHECK, .check(_, _, let set)): set(e.sub == 1)
        case (FW_EV_PANEL_CHOICE, .choice(_, let options, _, let set)):
            if e.sub >= 0 && Int(e.sub) < options.count { set(options[Int(e.sub)].tag) }
        case (FW_EV_PANEL_BUTTON, .buttons(let buttons)):
            if Int(e.sub) < buttons.count { buttons[Int(e.sub)].action() }
        case (FW_EV_PANEL_ROW_DELETE, .rows(let rows)):
            if Int(e.sub) < rows.count { rows[Int(e.sub)].delete?() }
        case (FW_EV_PANEL_LIST, .list(_, _, _, let activate)): activate?()
        default: break
        }
    }

    private func menu(_ id: Int) {
        switch id {
        case FW_MENU_NEW: Task { await model.run("document.new", ["name": "Part1"]) }
        case FW_MENU_OPEN: model.openDocument()
        case FW_MENU_SAVE: model.saveDocument(as: false)
        case FW_MENU_SAVE_AS: model.saveDocument(as: true)
        case FW_MENU_EXPORT_STEP: model.export("step")
        case FW_MENU_EXPORT_STL: model.export("stl")
        case FW_MENU_UNDO: Task { await model.run("edit.undo") }
        case FW_MENU_REDO: Task { await model.run("edit.redo") }
        case FW_MENU_FRONT: model.setOrientation(.front)
        case FW_MENU_BACK: model.setOrientation(.back)
        case FW_MENU_LEFT: model.setOrientation(.left)
        case FW_MENU_RIGHT: model.setOrientation(.right)
        case FW_MENU_TOP: model.setOrientation(.top)
        case FW_MENU_BOTTOM: model.setOrientation(.bottom)
        case FW_MENU_ISOMETRIC: model.setOrientation(.isometric)
        case FW_MENU_DIMETRIC: model.setOrientation(.dimetric)
        case FW_MENU_TRIMETRIC: model.setOrientation(.trimetric)
        case FW_MENU_NORMAL_TO: model.normalToSketch()
        case FW_MENU_FIT: model.zoomToFit()
        case FW_MENU_PREVIOUS: model.previousView()
        case FW_MENU_PERSPECTIVE: model.setPerspective(!model.display.perspective)
        case FW_MENU_PLANES:
            model.display.planes.toggle()
            Task { await model.refresh() }
        case FW_MENU_RELATIONS: model.display.relations.toggle()
        case FW_MENU_DIMENSIONS: model.display.dimensions.toggle()
        case FW_MENU_SHADED_EDGES: model.setStyle(.shadedWithEdges)
        case FW_MENU_SHADED: model.setStyle(.shaded)
        case FW_MENU_WIREFRAME: model.setStyle(.wireframe)
        case FW_MENU_HIDDEN_LINES: model.setStyle(.hiddenLinesRemoved)
        case FW_MENU_ABOUT:
            if let app {
                fw_message(app, "About Forge", "Forge — parametric CAD, AI-first.\nEvery action is a command on the bus (MCP, CLI and scripts share it).", 0)
            }
        default: break
        }
    }
}

/// Native dialogs for the shared model.
@MainActor
final class WinPlatform: PlatformServices {
    let app: OpaquePointer

    init(app: OpaquePointer) { self.app = app }

    func confirm(_ title: String, _ message: String, confirm: String, cancel: String) -> Bool {
        fw_confirm(app, title, message, confirm, cancel) != 0
    }

    func chooseSavePath(suggestedName name: String) -> String? {
        guard let p = fw_save_dialog(app, name) else { return nil }
        defer { fw_free(p) }
        return String(cString: p)
    }

    func chooseOpenPath() -> String? {
        guard let p = fw_open_dialog(app) else { return nil }
        defer { fw_free(p) }
        return String(cString: p)
    }
}

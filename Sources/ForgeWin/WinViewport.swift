// The Windows viewport: camera navigation (SolidWorks mouse: middle / left drag rotates, right
// drag or Ctrl+middle pans, wheel zooms at the cursor), sketch input, GPU picking, and drawing
// through the shared draw plan (ForgeRender.ViewportPlan) with the Direct3D 11 back end in
// CForgeWin. Labels (dimensions, relations, the cursor readout, the axis triad and the
// confirmation corner) are drawn with Direct2D on top. Mirrors Sources/ForgeApp/ViewportView.swift.

import CForgeWin
import ForgeCommands
import ForgeCore
import ForgeRender
import ForgeSketch
import ForgeUI
import Foundation
import Observation

/// A vertex buffer owned by the Direct3D back end.
final class WinBuffer {
    let pointer: OpaquePointer

    init?(app: OpaquePointer, bytes: [UInt8]) {
        guard let p = bytes.withUnsafeBytes({ fw_buffer_create(app, $0.baseAddress, Int32($0.count)) }) else { return nil }
        pointer = p
    }

    deinit { fw_buffer_release(pointer) }
}

@MainActor
final class WinViewport {
    unowned let shell: WinShell
    let app: OpaquePointer
    var model: AppModel { shell.model }

    private(set) var camera = Camera()
    private(set) var style: RenderStyle = .shadedWithEdges
    private var width = 1, height = 1
    private var scene: [ViewportBatch<WinBuffer>] = []
    private var preview: [ViewportBatch<WinBuffer>] = []
    private var overlay: [ViewportBatch<WinBuffer>] = []
    private var documentScene: DocumentScene?
    private var sceneBounds: BoundingBox?, previewBounds: BoundingBox?
    private var hidden: Set<UInt32> = []
    private var sceneVersion = -1, previewVersion = -1, overlayVersion = -1, hiddenVersion = -1, appliedCommands = 0
    private var history: [Camera] = []
    private var dirty = true

    // Mouse state (pixels, origin top-left).
    private var last = (x: 0, y: 0)
    private var pressAt: (x: Int, y: Int)?
    private var dragged = false
    private var toolPress: (x: Int, y: Int)?
    /// An existing dimension being changed (double-click on its label).
    private var editingDimension: String?
    /// Hit areas drawn this frame: dimension labels and the confirmation corner.
    private var dimensionRects: [(id: String, rect: (x: Float, y: Float, w: Float, h: Float), text: String, driven: Bool)] = []
    private var cornerRects: [(rect: (x: Float, y: Float, w: Float, h: Float), action: () -> Void)] = []

    init(shell: WinShell, app: OpaquePointer) {
        self.shell = shell
        self.app = app
        var w: Int32 = 1, h: Int32 = 1
        fw_view_size(app, &w, &h)
        width = max(1, Int(w))
        height = max(1, Int(h))
        camera.setOrientation(.isometric)
    }

    private var scale: Float { fw_dpi_scale(app) }

    /// Sketch plane while a sketch tool is active (clicks become sketch coordinates).
    private var sketchPlane: SketchPlane? { model.sketchState.tool == nil ? nil : model.sketchState.plane }

    /// Model units per pixel at the camera target.
    private var pixelSize: Double { 2 * camera.visibleHalfHeight / Double(max(height, 1)) }

    // MARK: model → GPU

    private func observe<T>(_ read: () -> T) -> T {
        withObservationTracking(read) { [weak self] in
            MainActor.assumeIsolated { self?.dirty = true }
        }
    }

    func sync() {
        guard dirty else { return }
        dirty = false
        let (sv, pv, ov, commands, _) = observe {
            (model.sceneVersion, model.previewVersion, model.overlayVersion, model.viewportCommands.log.count,
             (model.annotations.count, model.hoverLines, model.dimensionEdit, model.display, model.activeSketch, model.sketchState.tool))
        }
        if sv != sceneVersion, let ds = model.scene.value {
            let first = sceneVersion < 0
            sceneVersion = sv
            documentScene = ds
            scene = ds.scene.items.map { batch($0) }
            sceneBounds = ds.scene.bounds
            if first { fit() }
        }
        if pv != previewVersion || hiddenVersion != sceneVersion {
            previewVersion = pv
            hiddenVersion = sceneVersion
            let items = model.preview.items
            preview = items.map { batch($0) }
            previewBounds = RenderScene(items: items).bounds
            let bodies = documentScene?.bodies ?? []
            hidden = Set(model.preview.hidden.compactMap { id in bodies.firstIndex(of: id).map { UInt32($0) } })
        }
        if ov != overlayVersion {
            overlayVersion = ov
            overlay = SketchOverlay.items(
                model.sketchState.preview, operation: model.sketchState.opPreview, plane: model.sketchState.plane, markerSize: pixelSize * 5, dark: model.isDark
            ).map { batch($0) }
        }
        if commands > appliedCommands {
            for c in model.viewportCommands.log[appliedCommands...] { apply(c) }
            appliedCommands = commands
        }
        editBox()
        publishProjection()
        fw_view_invalidate(app)
    }

    private func batch(_ item: RenderItem) -> ViewportBatch<WinBuffer> {
        ViewportBatch(item) { [app] bytes in WinBuffer(app: app, bytes: bytes) }
    }

    private func apply(_ c: ViewportCommandQueue.Command) {
        switch c {
        case .orient(let o):
            remember()
            camera.setOrientation(o)
            fit()
        case .fit: fit()
        case .previous:
            if let prev = history.popLast() { camera = prev }
        case .style(let s):
            style = s
            shell.markMenus()
        case .projection(let kind):
            if camera.projection != kind {
                camera.projection = kind
                fit()
            }
        case .zoom(let factor): camera.zoom(factor: factor, anchor: camera.target)
        case .normalTo(let plane):
            remember()
            camera.setBasis(back: plane.normal, up: plane.yAxis)
            fit()
        }
        cameraChanged()
    }

    private func fit() {
        guard let b = documentScene?.scene.bounds else { return }
        remember()
        camera.fit(b, aspect: Double(width) / Double(max(height, 1)))
        cameraChanged()
    }

    private func remember() {
        guard history.last != camera else { return }
        history.append(camera)
        if history.count > 20 { history.removeFirst() }
    }

    private func cameraChanged() {
        publishProjection()
        fw_view_invalidate(app)
    }

    /// The camera and size for overlays and the Modify box placement (pixels).
    private func publishProjection() {
        let p = ViewProjection(camera: camera, width: Double(width), height: Double(height))
        if model.projection != p { model.projection = p }
    }

    // MARK: the Modify box

    private func editBox() {
        if let edit = model.dimensionEdit {
            let label = edit.measurement == nil ? "Select a second entity" : "Modify (\(edit.measurement.map { "\($0.kind.rawValue.replacingOccurrences(of: "_", with: " "))" } ?? ""))"
            fw_edit_show(app, Int32(edit.position.x), Int32(edit.position.y), label, edit.text)
        } else if editingDimension == nil {
            fw_edit_hide(app)
        }
    }

    /// Return in the Modify box.
    func commitEdit(_ text: String) {
        if let id = editingDimension {
            editingDimension = nil
            fw_edit_hide(app)
            let angle = dimensionRects.first { $0.id == id }?.text.hasSuffix("°") == true
            let value = angle && Double(text) != nil ? text + " deg" : text
            Task { await model.setDimension(id, to: value) }
        } else {
            model.dimensionEdit?.text = text
            Task { await model.commitDimension() }
        }
    }

    func cancelEdit() {
        editingDimension = nil
        model.dimensionEdit = nil
        fw_edit_hide(app)
        fw_view_focus(app)
    }

    // MARK: drawing

    /// sRGB colour (the design's hex) to the linear values the sRGB target expects.
    private static func linear(_ hex: UInt32) -> [Float] {
        func c(_ v: UInt32) -> Float {
            let s = Float(v & 255) / 255
            return s <= 0.04045 ? s / 12.92 : powf((s + 0.055) / 1.055, 2.4)
        }
        return [c(hex >> 16), c(hex >> 8), c(hex), 1]
    }

    private var frame: ViewportFrame {
        ViewportFrame(camera: camera, style: style, hiddenObjects: hidden, sceneBounds: sceneBounds, previewBounds: previewBounds,
                      aspect: Double(width) / Double(max(height, 1)))
    }

    private func draw(_ d: ViewportDraw<WinBuffer>) {
        d.uniforms.withUnsafeBufferPointer { u in
            fw_draw(app, d.pipeline.rawValue, d.depth.rawValue, d.buffer.pointer, Int32(d.vertexCount), u.baseAddress)
        }
    }

    func render() {
        let top = model.isDark ? Self.linear(0x2E323A) : Self.linear(0xF6F7F9)
        let bottom = model.isDark ? Self.linear(0x17191D) : Self.linear(0xD8DDE5)
        guard fw_frame_begin(app, top, bottom) != 0 else { return }
        for d in frame.draws(scene: scene, preview: preview, overlay: overlay, pick: false) { draw(d) }
        drawAnnotations()
        drawCursorReadout()
        drawTriad()
        drawCorner()
        fw_frame_end(app)
    }

    private func text(_ s: String, _ x: Float, _ y: Float, size: Float = 12, rgba: UInt32 = 0x1D1D_1FFF, centred: Bool = false, boxed: Bool = false) {
        fw_text(app, s, x, y, size * scale, rgba, centred ? 1 : 0, boxed ? 1 : 0)
    }

    private func drawAnnotations() {
        dimensionRects = []
        guard let proj = model.projection, model.activeSketch != nil else { return }
        let s = scale
        for a in model.annotations {
            guard let p = proj.point(a.anchor) else { continue }
            switch a.kind {
            case .dimension where model.display.dimensions:
                let color: UInt32 = a.problem ? 0xC62F_20FF : a.driven ? 0x5E5E_66FF : 0x1D1D_1FFF
                let x = Float(p.x), y = Float(p.y) - 14 * s
                text(a.text, x, y, size: 12.5, rgba: color, centred: true, boxed: true)
                let w = Float(a.text.count) * 8 * s + 14 * s
                dimensionRects.append((a.id, (x - w / 2, y - 11 * s, w, 22 * s), a.text, a.driven))
            case .relation where model.display.relations:
                let color: UInt32 = a.problem ? 0xC62F_20FF : 0x2F9E_55FF
                text(a.text, Float(p.x) + (14 + Float(a.slot) * 20) * s, Float(p.y) + 14 * s, size: 10.5, rgba: color, centred: true, boxed: true)
            default:
                break
            }
        }
    }

    private func drawCursorReadout() {
        guard !model.hoverLines.isEmpty else { return }
        let s = scale
        for (i, line) in model.hoverLines.enumerated() {
            text(line, Float(model.hoverViewPoint.x) + 18 * s, Float(model.hoverViewPoint.y) + (20 + Float(i) * 18) * s, size: 11.5, rgba: 0x1D1D_1FFF, boxed: true)
        }
    }

    /// The axis triad in the lower left corner (X red, Y green, Z blue).
    private func drawTriad() {
        let s = scale
        let ox = 46 * s, oy = Float(height) - 46 * s, len = 30 * s
        let axes: [(Vec3, String, UInt32)] = [(.unitX, "X", 0xD645_3AFF), (.unitY, "Y", 0x2E9E_55FF), (.unitZ, "Z", 0x2E6B_E0FF)]
        for (v, name, color) in axes {
            let dx = Float(v.dot(camera.right)), dy = Float(-v.dot(camera.up))
            fw_line2d(app, ox, oy, ox + dx * len, oy + dy * len, 2 * s, color)
            text(name, ox + dx * (len + 9 * s), oy + dy * (len + 9 * s), size: 10.5, rgba: color, centred: true)
        }
    }

    /// SolidWorks' confirmation corner while a sketch is open: Exit Sketch / Cancel Sketch.
    private func drawCorner() {
        cornerRects = []
        guard model.activeSketch != nil else { return }
        let s = scale
        let y = 24 * s, right = Float(width) - 16 * s
        let items: [(String, UInt32, () -> Void)] = [
            ("\u{2716} Cancel Sketch", 0xC62F_20FF, { [unowned self] in Task { await model.cancelSketch() } }),
            ("\u{2714} Exit Sketch", 0x1F5F_D6FF, { [unowned self] in Task { await model.exitSketch() } }),
        ]
        var x = right
        for (label, color, action) in items {
            let w = Float(label.count) * 7.2 * s + 16 * s
            x -= w
            text(label, x + w / 2, y, size: 12, rgba: color, centred: true, boxed: true)
            cornerRects.append(((x, y - 12 * s, w, 24 * s), action))
            x -= 10 * s
        }
    }

    private static func inside(_ r: (x: Float, y: Float, w: Float, h: Float), _ x: Int, _ y: Int) -> Bool {
        Float(x) >= r.x && Float(x) <= r.x + r.w && Float(y) >= r.y && Float(y) <= r.y + r.h
    }

    // MARK: picking and sketch coordinates

    func pick(x: Int, y: Int, radius: Int = 4) -> PickHit? {
        let x0 = max(0, x - radius), y0 = max(0, y - radius)
        let w = min(width - x0, 2 * radius + 1), h = min(height - y0, 2 * radius + 1)
        guard w > 0, h > 0, fw_pick_begin(app) != 0 else { return nil }
        for d in frame.draws(scene: scene, preview: [], overlay: [], pick: true) { draw(d) }
        var objects = [UInt32](repeating: 0, count: w * h), elements = [UInt32](repeating: 0, count: w * h)
        let ok = objects.withUnsafeMutableBufferPointer { o in
            elements.withUnsafeMutableBufferPointer { e in fw_pick_end(app, Int32(x0), Int32(y0), Int32(w), Int32(h), o.baseAddress, e.baseAddress) }
        }
        guard ok != 0 else { return nil }
        return RenderImage.pick(regionWidth: w, height: h, objects: objects, elements: elements, x: x - x0, y: y - y0, radius: radius)
    }

    private func reference(at x: Int, _ y: Int) -> String? {
        pick(x: x, y: y).flatMap { documentScene?.reference(for: $0) }
    }

    private func sketchPoint(_ x: Int, _ y: Int, plane: SketchPlane) -> (Point2, Double)? {
        let (o, d) = camera.ray(pixelX: Double(x), pixelY: Double(y), width: Double(width), height: Double(height))
        let n = plane.normal
        let denom = d.dot(n)
        guard abs(denom) > 1e-9 else { return nil }
        let hit = o + d * ((plane.origin - o).dot(n) / denom)
        let rel = hit - plane.origin
        return (Point2(rel.dot(plane.xAxis), rel.dot(plane.yAxis)), 8 * pixelSize)
    }

    /// World point under the cursor on the plane through the camera target (zoom anchor).
    private func anchor(_ x: Int, _ y: Int) -> Vec3? {
        let (o, d) = camera.ray(pixelX: Double(x), pixelY: Double(y), width: Double(width), height: Double(height))
        let denom = d.dot(camera.back)
        guard abs(denom) > 1e-9 else { return nil }
        return o + d * ((camera.target - o).dot(camera.back) / denom)
    }

    // MARK: input

    func handle(_ e: fw_event, text: String) {
        let x = Int(e.x), y = Int(e.y)
        let mods = Int(e.mods)
        switch Int(e.kind) {
        case FW_EV_PAINT:
            render()
        case FW_EV_RESIZE:
            width = max(1, x)
            height = max(1, y)
            cameraChanged()
        case FW_EV_MOUSE_DOWN:
            mouseDown(x, y, button: Int(e.button), clicks: Int(e.clicks), mods: mods)
        case FW_EV_MOUSE_MOVE:
            mouseMove(x, y, button: Int(e.button), mods: mods)
        case FW_EV_MOUSE_UP:
            mouseUp(x, y, button: Int(e.button), mods: mods)
        case FW_EV_MOUSE_WHEEL:
            camera.zoom(factor: pow(1.1, Double(e.wheel)), anchor: anchor(x, y))
            cameraChanged()
        case FW_EV_MOUSE_LEAVE:
            model.sketchHover(nil, tolerance: 0, viewPoint: .zero)
        case FW_EV_KEY:
            if text == "escape" {
                if model.dimensionEdit != nil || editingDimension != nil { cancelEdit() } else { model.cancelSketchOperation() }
            } else {
                _ = model.viewportKey(text, at: CGPoint(x: last.x, y: last.y))
            }
        case FW_EV_EDIT_COMMIT:
            commitEdit(text)
        case FW_EV_EDIT_CANCEL:
            cancelEdit()
        default:
            break
        }
    }

    private func mouseDown(_ x: Int, _ y: Int, button: Int, clicks: Int, mods: Int) {
        last = (x, y)
        dragged = false
        pressAt = (x, y)
        if button == 2 && clicks == 2 {
            fit()
            return
        }
        guard button == 0 else { return }
        if let c = cornerRects.first(where: { Self.inside($0.rect, x, y) }) {
            pressAt = nil
            c.action()
            return
        }
        if clicks == 2, let d = dimensionRects.first(where: { Self.inside($0.rect, x, y) }), !d.driven {
            // Double-click a dimension: change its value in the Modify box.
            pressAt = nil
            editingDimension = d.id
            fw_edit_show(app, Int32(x), Int32(y), "Modify", d.text.trimmingCharacters(in: CharacterSet(charactersIn: "R⌀°()")))
            return
        }
        if let plane = sketchPlane, let (q, tol) = sketchPoint(x, y, plane: plane) {
            // Sketch tools act on press; releasing away from the press point is the second click.
            toolPress = (x, y)
            let under = reference(at: x, y)
            Task { await model.sketchClick(q, tolerance: tol, curve: under, clickCount: clicks, viewPoint: CGPoint(x: x, y: y)) }
        }
    }

    private func mouseMove(_ x: Int, _ y: Int, button: Int, mods: Int) {
        let dx = Double(x - last.x), dy = Double(y - last.y)
        last = (x, y)
        if let p = pressAt, abs(x - p.x) + abs(y - p.y) > 3 { dragged = true }
        switch button {
        case 0:
            if let plane = sketchPlane {
                hover(x, y)
                if dragged, let (q, _) = sketchPoint(x, y, plane: plane), let under = reference(at: x, y) {
                    Task { await model.sketchDrag(q, curve: under) }
                }
            } else if mods & FW_MOD_ALT != 0 {
                camera.pan(dxPixels: dx, dyPixels: dy, viewportHeight: Double(height))
                cameraChanged()
            } else if dragged {
                camera.orbit(dx: dx * 0.01, dy: dy * 0.01)
                cameraChanged()
            }
        case 1:
            camera.pan(dxPixels: dx, dyPixels: dy, viewportHeight: Double(height))
            cameraChanged()
        case 2:
            if mods & FW_MOD_CTRL != 0 {
                camera.pan(dxPixels: dx, dyPixels: dy, viewportHeight: Double(height))
            } else if mods & FW_MOD_SHIFT != 0 {
                camera.zoom(factor: pow(1.01, -dy), anchor: camera.target)
            } else {
                camera.orbit(dx: dx * 0.01, dy: dy * 0.01)
            }
            cameraChanged()
        default:
            hover(x, y)
        }
    }

    private func hover(_ x: Int, _ y: Int) {
        guard let plane = sketchPlane, let (q, tol) = sketchPoint(x, y, plane: plane) else { return }
        model.sketchHover(q, tolerance: tol, viewPoint: CGPoint(x: x, y: y))
    }

    private func mouseUp(_ x: Int, _ y: Int, button: Int, mods: Int) {
        defer { pressAt = nil }
        guard button == 0 else { return }
        if let plane = sketchPlane {
            if let start = toolPress, hypot(Double(x - start.x), Double(y - start.y)) > 5, let (q, tol) = sketchPoint(x, y, plane: plane) {
                let under = reference(at: x, y)
                Task { await model.sketchClick(q, tolerance: tol, curve: under, clickCount: 1, viewPoint: CGPoint(x: x, y: y)) }
            }
            toolPress = nil
            return
        }
        guard pressAt != nil, !dragged else { return }
        let ref = reference(at: x, y)
        let extend = mods & (FW_MOD_SHIFT | FW_MOD_CTRL) != 0
        Task { await model.select(ref, extend: extend) }
    }
}

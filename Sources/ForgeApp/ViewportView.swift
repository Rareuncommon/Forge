// Metal viewport host with CAD navigation:
//   left-drag: orbit · right-drag or ⌥-drag: pan · scroll wheel: zoom at cursor
//   trackpad: two-finger scroll pans, pinch zooms at cursor, rotate rolls
//   click: pick (⇧ adds to selection) — picks go through selection.set on the command bus.
//
// With a sketch tool active, clicks become sketch-plane coordinates (plus the sketch curve
// under the cursor, for trim) instead of selections.

import ForgeCommands
import ForgeCore
import ForgeRender
import ForgeSketch
import MetalKit
import ForgeUI
import SwiftUI

struct ViewportView: NSViewRepresentable {
    @Environment(AppModel.self) private var model

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ForgeMTKView {
        let view = ForgeMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 1
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = true
        if let renderer = MetalViewportRenderer(device: view.device) {
            // Transparent clear: the SwiftUI gradient behind the view is the background.
            renderer.transparentBackground = true
            view.renderer = renderer
            view.delegate = renderer
        }
        view.layer?.isOpaque = false
        view.onCamera = { camera, width, height in
            let p = ViewProjection(camera: camera, width: width, height: height)
            if model.projection != p { model.projection = p }
        }
        view.onPick = { ref, extend, at in
            Task {
                await model.select(ref, extend: extend)
                model.contextToolbarAt = ref == nil ? nil : at
            }
        }
        view.onSketchClick = { point, tolerance, curve, count, at in
            Task { await model.sketchClick(point, tolerance: tolerance, curve: curve, clickCount: count, viewPoint: at) }
        }
        view.onSketchDrag = { point, curve in Task { await model.sketchDrag(point, curve: curve) } }
        view.onKey = { key, at in model.viewportKey(key, at: at) }
        view.onSketchHover = { point, tolerance, at in model.sketchHover(point, tolerance: tolerance, viewPoint: at) }
        view.onCancel = { model.cancelSketchOperation() }
        view.setAccessibilityLabel("3D viewport")
        view.setAccessibilityRole(.group)
        return view
    }

    func updateNSView(_ view: ForgeMTKView, context: Context) {
        if context.coordinator.sceneVersion != model.sceneVersion, let ds = model.scene.value {
            let first = context.coordinator.sceneVersion == 0
            context.coordinator.sceneVersion = model.sceneVersion
            view.documentScene = ds
            view.renderer?.setScene(ds.scene)
            view.sketchPlane = model.sketchState.tool == nil ? nil : model.sketchState.plane
            if first { view.fit() } else { view.cameraChanged() }
            view.needsDisplay = true
        }
        if context.coordinator.previewVersion != model.previewVersion || context.coordinator.hiddenSceneVersion != model.sceneVersion {
            context.coordinator.previewVersion = model.previewVersion
            context.coordinator.hiddenSceneVersion = model.sceneVersion
            view.renderer?.setPreview(model.preview.items)
            // Bodies an opaque preview replaces (fillet, cut, combine…) are not drawn meanwhile.
            let bodies = view.documentScene?.bodies ?? []
            view.renderer?.hiddenObjects = Set(model.preview.hidden.compactMap { id in bodies.firstIndex(of: id).map { UInt32($0) } })
            view.needsDisplay = true
        }
        if context.coordinator.overlayVersion != model.overlayVersion {
            context.coordinator.overlayVersion = model.overlayVersion
            view.renderer?.setOverlay(
                SketchOverlay.items(model.sketchState.preview, operation: model.sketchState.opPreview, plane: model.sketchState.plane,
                             markerSize: view.pixelSize * 5, dark: model.isDark))
            view.needsDisplay = true
        }
        let commands = model.viewportCommands.log
        view.sketchPlane = model.sketchState.tool == nil ? nil : model.sketchState.plane
        if context.coordinator.appliedCommands < commands.count {
            for c in commands[context.coordinator.appliedCommands...] {
                switch c {
                case .orient(let o): view.orient(o)
                case .fit: view.fit()
                case .previous: view.previousView()
                case .style(let st):
                    view.renderer?.style = st
                    view.needsDisplay = true
                case .projection(let kind): view.setProjection(kind)
                case .zoom(let factor): view.zoom(factor)
                case .normalTo(let plane): view.normalTo(plane)
                }
            }
            context.coordinator.appliedCommands = commands.count
        }
    }

    final class Coordinator {
        var sceneVersion = 0
        var appliedCommands = 0
        var overlayVersion = 0
        var previewVersion = 0
        var hiddenSceneVersion = 0
    }
}

final class ForgeMTKView: MTKView {
    var renderer: MetalViewportRenderer?
    var documentScene: DocumentScene?
    var onPick: ((String?, Bool, CGPoint) -> Void)?
    /// Set while a sketch tool is active: clicks become sketch coordinates instead of picks.
    var sketchPlane: SketchPlane?
    var onSketchClick: ((Point2, Double, String?, Int, CGPoint) -> Void)?
    var onSketchDrag: ((Point2, String?) -> Void)?
    /// Keys the viewport handles (SolidWorks shortcuts); returns false to pass it on.
    var onKey: ((String, CGPoint) -> Bool)?
    private var lastMouse = CGPoint.zero
    var onSketchHover: ((Point2?, Double, CGPoint) -> Void)?
    /// A sketch tool press in progress (for click-drag drawing).
    private var toolPress: NSPoint?
    var onCancel: (() -> Void)?
    /// Called (asynchronously) whenever the camera or the view size changes.
    var onCamera: ((Camera, Double, Double) -> Void)?
    private var history: [Camera] = []
    private var dragStart: NSPoint?
    private var dragged = false

    override var acceptsFirstResponder: Bool { true }

    private var scale: Double { Double(window?.backingScaleFactor ?? 2) }

    func fit() {
        guard let r = renderer, let b = documentScene?.scene.bounds else { return }
        remember()
        r.camera.fit(b, aspect: Double(bounds.width / max(bounds.height, 1)))
        cameraChanged()
    }

    func orient(_ o: ViewOrientation) {
        remember()
        renderer?.camera.setOrientation(o)
        fit()
    }

    /// View normal to a plane (its normal toward the viewer, its y axis up).
    func normalTo(_ plane: SketchPlane) {
        remember()
        renderer?.camera.setBasis(back: plane.normal, up: plane.yAxis)
        fit()
    }

    /// Zoom about the view centre (Z / ⇧Z).
    func zoom(_ factor: Double) {
        guard let r = renderer else { return }
        r.camera.zoom(factor: factor, anchor: r.camera.target)
        cameraChanged()
    }

    func previousView() {
        guard let r = renderer, let last = history.popLast() else { return }
        r.camera = last
        cameraChanged()
    }

    func setProjection(_ kind: ProjectionKind) {
        guard let r = renderer, r.camera.projection != kind else { return }
        r.camera.projection = kind
        fit()
    }

    /// Keeps views for "Previous View" (the last 20).
    private func remember() {
        guard let cam = renderer?.camera, history.last != cam else { return }
        history.append(cam)
        if history.count > 20 { history.removeFirst() }
    }

    func cameraChanged() {
        needsDisplay = true
        guard let cam = renderer?.camera else { return }
        let (w, h) = (Double(bounds.width), Double(bounds.height))
        DispatchQueue.main.async { [weak self] in self?.onCamera?(cam, w, h) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cameraChanged()
    }

    /// Model units per view point at the camera target (for marker sizes and snap tolerance).
    var pixelSize: Double {
        guard let cam = renderer?.camera else { return 0.1 }
        return 2 * cam.visibleHalfHeight / max(Double(bounds.height), 1)
    }

    /// Sketch-plane coordinates under a view point, and the snap tolerance there.
    private func sketchPoint(at p: NSPoint, plane: SketchPlane) -> (Point2, Double)? {
        guard let cam = renderer?.camera else { return nil }
        let (o, d) = cam.ray(pixelX: Double(p.x), pixelY: Double(bounds.height - p.y), width: Double(bounds.width), height: Double(bounds.height))
        let n = plane.normal
        let denom = d.dot(n)
        guard abs(denom) > 1e-9 else { return nil }
        let hit = o + d * ((plane.origin - o).dot(n) / denom)
        let rel = hit - plane.origin
        return (Point2(rel.dot(plane.xAxis), rel.dot(plane.yAxis)), 8 * pixelSize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hover(event)
    }

    override func mouseExited(with event: NSEvent) {
        onSketchHover?(nil, 0, .zero)
    }

    private func hover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        lastMouse = CGPoint(x: p.x, y: bounds.height - p.y)
        guard let plane = sketchPlane else { return }
        guard let sp = sketchPoint(at: p, plane: plane) else { return }
        onSketchHover?(sp.0, sp.1, CGPoint(x: p.x, y: bounds.height - p.y))
    }

    private func sketchClick(at p: NSPoint, count: Int) {
        guard let plane = sketchPlane, let r = renderer, let sp = sketchPoint(at: p, plane: plane) else { return }
        let (q, tol) = sp
        let px = Int(Double(p.x) * scale), py = Int(Double(bounds.height - p.y) * scale)
        let under = r.pick(x: px, y: py, drawableWidth: Int(drawableSize.width), drawableHeight: Int(drawableSize.height))
            .flatMap { documentScene?.reference(for: $0) }
        onSketchClick?(q, tol, under, count, CGPoint(x: p.x, y: bounds.height - p.y))
    }

    private func sketchDrag(at p: NSPoint) {
        guard let plane = sketchPlane, let r = renderer, let sp = sketchPoint(at: p, plane: plane) else { return }
        let px = Int(Double(p.x) * scale), py = Int(Double(bounds.height - p.y) * scale)
        let under = r.pick(x: px, y: py, drawableWidth: Int(drawableSize.width), drawableHeight: Int(drawableSize.height))
            .flatMap { documentScene?.reference(for: $0) }
        if under != nil { onSketchDrag?(sp.0, under) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil)
        dragged = false
        if sketchPlane != nil {
            // Sketch tools act on press; a drag then ends the entity where the mouse is released.
            toolPress = dragStart
            sketchClick(at: dragStart!, count: event.clickCount)
        }
    }

    /// SolidWorks middle button: drag rotates, Ctrl+drag pans, Shift+drag zooms; a double
    /// click zooms to fit. Works while a sketch tool is active.
    override func otherMouseDown(with event: NSEvent) {
        if event.clickCount == 2 { fit() }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            pan(event)
        } else if event.modifierFlags.contains(.shift) {
            renderer?.camera.zoom(factor: pow(1.01, -Double(event.deltaY)), anchor: renderer?.camera.target)
        } else {
            renderer?.camera.orbit(dx: Double(event.deltaX) * 0.01, dy: Double(event.deltaY) * 0.01)
        }
        cameraChanged()
    }

    override func mouseDragged(with event: NSEvent) {
        if sketchPlane != nil {
            dragged = true
            hover(event)
            sketchDrag(at: convert(event.locationInWindow, from: nil))
            return
        }
        dragged = true
        if event.modifierFlags.contains(.option) {
            pan(event)
        } else {
            renderer?.camera.orbit(dx: Double(event.deltaX) * 0.01, dy: Double(event.deltaY) * 0.01)
        }
        cameraChanged()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        let p = convert(event.locationInWindow, from: nil)
        if sketchPlane != nil {
            // Click-drag drawing: releasing away from the press point is the second click.
            if let start = toolPress, hypot(p.x - start.x, p.y - start.y) > 5 { sketchClick(at: p, count: 1) }
            toolPress = nil
            return
        }
        guard !dragged, let r = renderer else { return }
        guard let ds = documentScene else { return }
        let px = Int(Double(p.x) * scale), py = Int(Double(bounds.height - p.y) * scale)
        let hit = r.pick(x: px, y: py, drawableWidth: Int(drawableSize.width), drawableHeight: Int(drawableSize.height))
        onPick?(hit.flatMap { ds.reference(for: $0) }, !event.modifierFlags.intersection([.shift, .command, .control]).isEmpty, CGPoint(x: p.x, y: bounds.height - p.y))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            onCancel?()
            return
        }
        let key: String
        switch event.keyCode {
        case 36, 76: key = "return"
        case 51, 117: key = "delete"
        case 49: key = "space"
        default: key = event.characters ?? ""
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, onKey?(key, lastMouse) == true { return }
        super.keyDown(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        pan(event)
        cameraChanged()
    }

    private func pan(_ event: NSEvent) {
        renderer?.camera.pan(dxPixels: Double(event.deltaX), dyPixels: Double(event.deltaY), viewportHeight: Double(bounds.height))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let r = renderer else { return }
        if event.hasPreciseScrollingDeltas && event.phase != [] {
            // Trackpad two-finger scroll: pan.
            r.camera.pan(dxPixels: -Double(event.scrollingDeltaX), dyPixels: -Double(event.scrollingDeltaY), viewportHeight: Double(bounds.height))
        } else {
            // Mouse wheel: zoom toward the cursor.
            let factor = pow(1.1, Double(event.scrollingDeltaY) / (event.hasPreciseScrollingDeltas ? 10 : 1))
            r.camera.zoom(factor: factor, anchor: anchor(for: event))
        }
        cameraChanged()
    }

    override func magnify(with event: NSEvent) {
        renderer?.camera.zoom(factor: 1 + Double(event.magnification), anchor: anchor(for: event))
        cameraChanged()
    }

    override func rotate(with event: NSEvent) {
        guard let r = renderer else { return }
        let q = Quat(axis: r.camera.back, angle: Double(event.rotation) * .pi / 180)
        r.camera.orientation = (q * r.camera.orientation).normalized
        cameraChanged()
    }

    /// World point under the cursor on the plane through the camera target.
    private func anchor(for event: NSEvent) -> Vec3? {
        guard let cam = renderer?.camera else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let (o, d) = cam.ray(pixelX: Double(p.x), pixelY: Double(bounds.height - p.y), width: Double(bounds.width), height: Double(bounds.height))
        let denom = d.dot(cam.back)
        guard abs(denom) > 1e-9 else { return nil }
        let t = (cam.target - o).dot(cam.back) / denom
        return o + d * t
    }
}

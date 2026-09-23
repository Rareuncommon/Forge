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
            view.renderer = renderer
            view.delegate = renderer
        }
        view.onPick = { ref, extend in Task { await model.select(ref, extend: extend) } }
        view.onSketchClick = { point, tolerance, curve in Task { await model.sketchClick(point, tolerance: tolerance, curve: curve) } }
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
            if first { view.fit() }
            view.needsDisplay = true
        }
        let commands = model.viewportCommands.log
        view.sketchPlane = model.sketchState.tool == nil ? nil : model.sketchState.plane
        if context.coordinator.appliedCommands < commands.count {
            for c in commands[context.coordinator.appliedCommands...] {
                switch c {
                case .orient(let o): view.orient(o)
                case .fit: view.fit()
                case .style(let st):
                    view.renderer?.style = st
                    view.needsDisplay = true
                }
            }
            context.coordinator.appliedCommands = commands.count
        }
    }

    final class Coordinator {
        var sceneVersion = 0
        var appliedCommands = 0
    }
}

final class ForgeMTKView: MTKView {
    var renderer: MetalViewportRenderer?
    var documentScene: DocumentScene?
    var onPick: ((String?, Bool) -> Void)?
    /// Set while a sketch tool is active: clicks become sketch coordinates instead of picks.
    var sketchPlane: SketchPlane?
    var onSketchClick: ((Point2, Double, String?) -> Void)?
    var onCancel: (() -> Void)?
    private var dragStart: NSPoint?
    private var dragged = false

    override var acceptsFirstResponder: Bool { true }

    private var scale: Double { Double(window?.backingScaleFactor ?? 2) }

    func fit() {
        guard let r = renderer, let b = documentScene?.scene.bounds else { return }
        r.camera.fit(b, aspect: Double(bounds.width / max(bounds.height, 1)))
        needsDisplay = true
    }

    func orient(_ o: ViewOrientation) {
        renderer?.camera.setOrientation(o)
        fit()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        if event.modifierFlags.contains(.option) {
            pan(event)
        } else {
            renderer?.camera.orbit(dx: Double(event.deltaX) * 0.01, dy: Double(event.deltaY) * 0.01)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard !dragged, let r = renderer else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let plane = sketchPlane {
            // Ray through the cursor intersected with the sketch plane.
            let cam = r.camera
            let (o, d) = cam.ray(pixelX: Double(p.x), pixelY: Double(bounds.height - p.y), width: Double(bounds.width), height: Double(bounds.height))
            let n = plane.normal
            let denom = d.dot(n)
            guard abs(denom) > 1e-9 else { return }
            let hit = o + d * ((plane.origin - o).dot(n) / denom)
            let rel = hit - plane.origin
            // Snap tolerance: 8 pixels in model units at the target plane.
            let tolerance = 8 * 2 * cam.visibleHalfHeight / max(Double(bounds.height), 1)
            let px = Int(Double(p.x) * scale), py = Int(Double(bounds.height - p.y) * scale)
            let under = r.pick(x: px, y: py, drawableWidth: Int(drawableSize.width), drawableHeight: Int(drawableSize.height))
                .flatMap { documentScene?.reference(for: $0) }
            onSketchClick?(Point2(rel.dot(plane.xAxis), rel.dot(plane.yAxis)), tolerance, under)
            return
        }
        guard let ds = documentScene else { return }
        let px = Int(Double(p.x) * scale), py = Int(Double(bounds.height - p.y) * scale)
        let hit = r.pick(x: px, y: py, drawableWidth: Int(drawableSize.width), drawableHeight: Int(drawableSize.height))
        onPick?(hit.flatMap { ds.reference(for: $0) }, event.modifierFlags.contains(.shift))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        pan(event)
        needsDisplay = true
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
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        renderer?.camera.zoom(factor: 1 + Double(event.magnification), anchor: anchor(for: event))
        needsDisplay = true
    }

    override func rotate(with event: NSEvent) {
        guard let r = renderer else { return }
        let q = Quat(axis: r.camera.back, angle: Double(event.rotation) * .pi / 180)
        r.camera.orientation = (q * r.camera.orientation).normalized
        needsDisplay = true
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

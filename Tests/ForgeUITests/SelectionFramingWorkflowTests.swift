import ForgeCommands
import ForgeCore
import ForgeRender
import Foundation
import Testing
@testable import ForgeUI

@MainActor
@Suite("Desktop selection framing")
struct SelectionFramingWorkflowTests {
    @Test func selectedGeometryQueuesExplicitBoundsAndEmptyOrHiddenSelectionIsANoOp() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_box", ["width": 10, "height": 20, "depth": 30])
        await m.run("body.create_box", ["width": 10, "height": 20, "depth": 30, "origin": [1000, 0, 0]])
        await m.select("body-1/face@feature-1:+z", extend: false)
        await m.zoomToSelection()
        guard case .fitSelection(let bounds, _)? = m.viewportCommands.log.last else { Issue.record("selection fit missing"); return }
        #expect(abs(bounds.center.z - 30) < 1e-6)
        #expect(bounds.max.x < 11)
        let count = m.viewportCommands.log.count
        await m.select(nil, extend: false)
        await m.zoomToSelection()
        #expect(m.viewportCommands.log.count == count)
        await m.setBodiesVisible(["body-1"], false)
        await m.select("body-1", extend: false)
        await m.zoomToSelection()
        #expect(m.viewportCommands.log.count == count)
        #expect(m.lastError == nil)
        m.previousView()
        guard case .previous? = m.viewportCommands.log.last else { Issue.record("previous view missing"); return }
    }

    @Test func newerNavigationIsNeverOverwrittenByPendingSelectionFraming() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_box", ["width": 10, "height": 20, "depth": 30])
        await m.select("body-1", extend: false)
        m.sketchState.plane = .front
        for action in ["fit", "zoom", "normal"] {
            let initial = m.selectionZoomRequest
            let pending = Task { await m.zoomToSelection() }
            // Wait until the request has started; completion before navigation is also valid.
            while m.selectionZoomRequest == initial { await Task.yield() }
            switch action {
            case "fit": m.zoomToFit()
            case "zoom": _ = m.viewportKey("z", at: .zero)
            default: m.normalToSketch()
            }
            await pending.value
            switch (action, m.viewportCommands.log.last) {
            case ("fit", .fit?), ("zoom", .zoom?), ("normal", .normalTo?): break
            default: Issue.record("older selection framing overwrote newer navigation")
            }
        }
    }
    @Test func nativeCameraIntentDiscardsFramingAlreadyQueuedForViewportConsumption() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_box", ["width": 10, "height": 20, "depth": 30])
        await m.select("body-1", extend: false)
        await m.zoomToSelection()
        let queued = try #require(m.viewportCommands.log.last)
        #expect(m.acceptsViewportCommand(queued))
        // SwiftUI/desktop timer has not consumed the fit yet when native input occurs.
        m.viewportCameraInput()
        #expect(!m.acceptsViewportCommand(queued))
        #expect(m.acceptsViewportCommand(.zoom(1.25)))
        await m.zoomToSelection()
        let fresh = try #require(m.viewportCommands.log.last)
        #expect(m.acceptsViewportCommand(fresh))
        #expect(!m.acceptsViewportCommand(queued))
    }

    @Test func nativeCameraIntentCancelsFramingBeforeDeferredProjectionPublication() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_box", ["width": 10, "height": 20, "depth": 30])
        await m.select("body-1", extend: false)
        let oldView = ViewProjection(camera: Camera(), width: 800, height: 600)
        m.projection = oldView
        let engine = m.engine, gate = FramingEngineGate()
        // Hold the engine so the test cannot accidentally complete framing before input.
        let blocker = Task.detached { await engine.holdForCameraRace(gate) }
        defer { gate.release.signal() }
        while !gate.didStart() { await Task.yield() }
        let initial = m.selectionZoomRequest, commandCount = m.viewportCommands.log.count
        let framing = Task { await m.zoomToSelection() }
        while m.selectionZoomRequest == initial { await Task.yield() }
        // Native input has changed the renderer camera, but its async onCamera callback
        // has not published yet. The stale cached projection must not admit the result.
        m.viewportCameraInput()
        var gestureCamera = oldView.camera
        gestureCamera.orbit(dx: 0.2, dy: 0.1)
        #expect(m.projection == oldView)
        gate.release.signal()
        await blocker.value
        await framing.value
        #expect(m.viewportCommands.log.count == commandCount)
        #expect(m.lastError == nil)
        // Deliver the deferred publication only after the framing result returned.
        m.projection = ViewProjection(camera: gestureCamera, width: 800, height: 600)
        #expect(m.projection?.camera == gestureCamera)
        // A new request after publication still frames normally.
        await m.zoomToSelection()
        guard case .fitSelection? = m.viewportCommands.log.last else {
            Issue.record("fresh selection framing missing after gesture publication"); return
        }
    }

}


private final class FramingEngineGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func didStart() -> Bool { started.wait(timeout: .now()) == .success }
}

private extension Engine {
    func holdForCameraRace(_ gate: FramingEngineGate) {
        gate.started.signal()
        gate.release.wait()
    }
}

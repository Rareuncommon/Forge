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
        guard case .fitSelection(let bounds)? = m.viewportCommands.log.last else { Issue.record("selection fit missing"); return }
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
}

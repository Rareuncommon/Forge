import ForgeCommands
import ForgeCore
import ForgeRender
import Foundation
import Testing
@testable import ForgeUI

@MainActor
@Suite("Desktop filtered selection and Select Other")
struct SelectionWorkflowTests {
    private func model() async -> AppModel {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_box", ["width": 10, "height": 10, "depth": 10])
        await m.run("body.create_box", ["width": 10, "height": 10, "depth": 10, "origin": [0, 0, -20]])
        return m
    }
    private func camera() -> Camera {
        var camera = Camera(target: Vec3(5, 5, 0), distance: 100, orthoHalfHeight: 20)
        camera.setOrientation(.front)
        return camera
    }
    private func click(_ m: AppModel, at point: CGPoint = CGPoint(x: 200, y: 200), extend: Bool = false) async {
        m.projection = ViewProjection(camera: camera(), width: 400, height: 400)
        await m.viewportPick(at: point, camera: camera(), width: 400, height: 400, extend: extend)
    }

    @Test func bodyFilterCyclesThroughOccludedBodyAndWraps() async throws {
        let m = await model()
        await m.setSelectionFilter(.bodies)
        await click(m)
        #expect(m.selection == ["body-1"])
        #expect(m.canSelectOther)
        await m.selectOther()
        #expect(m.selection == ["body-2"])
        await m.selectOther()
        #expect(m.selection == ["body-1"])
        // Recompute against the current scene, never resurrect a hidden candidate.
        await m.setBodiesVisible(["body-2"], false)
        await m.selectOther()
        #expect(m.selection == ["body-1"])
        await m.setBodiesVisible(["body-1"], false)
        await m.selectOther()
        #expect(!m.canSelectOther)
    }

    @Test func filtersSelectFacesEdgesAndBodiesAtSameBoundary() async throws {
        let m = await model()
        let boundary = CGPoint(x: 150, y: 200)
        await m.setSelectionFilter(.faces)
        await click(m, at: boundary)
        #expect(m.selection.first?.contains("/face-") == true)
        await m.setSelectionFilter(.edges)
        #expect(!m.canSelectOther)
        await click(m, at: boundary)
        #expect(m.selection.first?.contains("/edge-") == true)
        await m.setSelectionFilter(.bodies)
        await click(m, at: boundary)
        #expect(m.selection == ["body-1"])
        // Empty interior has no edge hit, so normal replacement clears selection.
        await m.setSelectionFilter(.edges)
        await click(m)
        #expect(m.selection.isEmpty)
    }

    @Test func cyclingPreservesOtherSelectionsAndCameraChangeDisablesIt() async throws {
        let m = await model()
        await m.setSelectionFilter(.faces)
        await m.select("plane-front", extend: false)
        await click(m, extend: true)
        let first = try #require(m.selection.last)
        #expect(m.selection.count == 2)
        await m.selectOther()
        #expect(m.selection.count == 2)
        #expect(m.selection.first == "plane-front")
        #expect(m.selection.last != first)
        var changed = camera()
        changed.orbit(dx: 0.2, dy: 0)
        m.projection = ViewProjection(camera: changed, width: 400, height: 400)
        #expect(!m.canSelectOther)
        let prior = m.selection
        await m.selectOther()
        #expect(m.selection == prior)
    }

    @Test func activeDrawingToolYieldsToExtrusionContourPickingOnAllDesktops() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.newSketch(on: .front)
        await m.run("sketch.add_rectangle", ["points": [[0, 0], [10, 10]]])
        m.chooseTool(.circle)
        #expect(m.viewportSketchPlane != nil)
        m.begin(.extrude)
        await m.refreshContourChoices()
        m.form.activeBox = "contours"
        #expect(m.activeSketch != nil)
        #expect(m.viewportSketchPlane == nil)
        let count = m.sketchState.sketch?.orderedEntities.count
        await click(m)
        #expect(m.form.contours?.count == 1)
        #expect(m.sketchState.sketch?.orderedEntities.count == count)
        #expect(!m.canSelectOther)
        await click(m)
        #expect(m.form.contours?.isEmpty == true)
    }

    @Test func allGeometryPickingRespectsWireframeAndShadedDisplay() async throws {
        let m = await model()
        await m.viewportPick(at: CGPoint(x: 200, y: 200), camera: camera(), width: 400, height: 400, extend: false, style: .wireframe)
        #expect(m.selection.isEmpty)
        await m.viewportPick(at: CGPoint(x: 150, y: 200), camera: camera(), width: 400, height: 400, extend: false, style: .shaded)
        #expect(m.selection.first?.contains("/face-") == true)
        await m.viewportPick(at: CGPoint(x: 150, y: 200), camera: camera(), width: 400, height: 400, extend: false, style: .wireframe)
        #expect(m.selection.first?.contains("/edge-") == true)
    }

    @Test func selectionControlsExistOnEveryDesktopRibbonTab() async throws {
        let m = await model()
        for tab in [RibbonTab.features, .sketch, .evaluate] {
            m.ribbonTab = tab
            let group = try #require(m.ribbonGroups.first { $0.title == "Selection" })
            #expect(group.buttons.filter { $0.id.hasPrefix("filter-") }.count == 4)
            #expect(group.buttons.contains { $0.id == "selectOther" })
        }
    }
}

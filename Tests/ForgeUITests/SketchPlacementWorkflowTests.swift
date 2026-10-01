import ForgeCore
import ForgeRender
import ForgeSketch
import Foundation
import Testing
@testable import ForgeUI

@MainActor
@Suite("Desktop face sketch workflows")
struct SketchPlacementWorkflowTests {
    private func box() async -> AppModel {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_box", ["width": 20, "height": 20, "depth": 20])
        return m
    }

    private func pickTopFace(_ m: AppModel) throws -> String {
        let scene = try #require(m.scene.value)
        let bodies = RenderScene(items: scene.scene.items.filter { $0.objectID < 1_000_000 })
        let hit = try #require(RayPicker.pick(bodies, origin: Vec3(10, 10, 100), direction: Vec3(0, 0, -1)))
        #expect(hit.element == .face)
        return try #require(scene.reference(for: hit))
    }

    @Test func featureRibbonStartsPickedFaceSketchAndCutsThePart() async throws {
        let m = await box()
        let face = try pickTopFace(m)
        await m.select(face, extend: false)
        m.ribbonTab = .features
        let button = try #require(m.ribbonGroups.flatMap(\.buttons).first { $0.id == "startSketch" })
        #expect(button.enabled && button.title == "Sketch on Face")
        button.action()
        for _ in 0..<100 where m.sketchState.tool != .line && m.lastError == nil { try await Task.sleep(for: .milliseconds(10)) }
        let id = try #require(m.activeSketch)
        let plane = try #require(m.sketchState.plane)
        #expect(abs(plane.origin.z - 20) < 1e-7)
        #expect(plane.normal.z > 0.99)
        for _ in 0..<100 {
            if case .normalTo? = m.viewportCommands.log.last { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .normalTo(let cameraPlane)? = m.viewportCommands.log.last else { Issue.record("face sketch did not orient its camera"); return }
        #expect(cameraPlane == plane)
        // Translate known world-space corners into the face's local coordinates, then use
        // the same two-click rectangle workflow as the desktop viewport.
        func local(_ p: Vec3) -> Point2 {
            let d = p - plane.origin
            return Point2(d.dot(plane.xAxis), d.dot(plane.yAxis))
        }
        m.chooseTool(.rectangle)
        await m.sketchClick(local(Vec3(5, 5, 20)), tolerance: 0.001, curve: nil)
        await m.sketchClick(local(Vec3(10, 10, 20)), tolerance: 0.001, curve: nil)
        #expect(m.lastError == nil)
        let document = try #require(await m.engine.activeDocument)
        #expect(document.sketches[id]?.placement?.contains("/face@") == true)
        await m.exitSketch()
        m.begin(.cutExtrude)
        m.form.depth = "5"
        await m.commitOperation()
        #expect(m.lastError == nil)
        let result = try await m.engine.execute("query.mass_properties", ["body": "body-1"])
        let volume = try #require(result.result["volume_mm3"]?.doubleValue)
        #expect(abs(volume - (8000 - 5 * 5 * 5)) < 1e-6)
    }

    @Test func invalidBodySelectionDoesNotFallBackToFrontPlane() async {
        let m = await box()
        for ref in ["body-1", "body-1/edge-0"] {
            await m.select(ref, extend: false)
            await m.startSketchFromSelection()
            #expect(m.activeSketch == nil && m.sketches.isEmpty)
            #expect(m.lastError?.code == .invalidParams)
        }
    }

    @Test func curvedFaceIsRejectedWithoutCreatingAFrontSketch() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_sphere", ["radius": 10])
        await m.select("body-1/face-0", extend: false)
        await m.startSketchFromSelection()
        #expect(m.activeSketch == nil && m.sketches.isEmpty)
        #expect(m.lastError != nil)
    }

    @Test func modelSelectionModeConvertsFaceBoundaryThroughCommandBus() async throws {
        let m = await box()
        let face = try pickTopFace(m)
        await m.select(face, extend: false)
        await m.startSketchFromSelection()
        let id = try #require(m.activeSketch)
        #expect(m.sketchState.tool == .line)
        m.selectModelGeometry()
        #expect(m.sketchState.tool == nil && m.activeSketch == id)
        await m.select(face, extend: false)
        m.ribbonTab = .sketch
        let convert = try #require(m.ribbonGroups.flatMap(\.buttons).first { $0.id == "convertEntities" })
        #expect(convert.enabled)
        await m.convertSelectedModelGeometry()
        #expect(m.lastError == nil)
        let doc = try #require(await m.engine.activeDocument)
        let sketch = try #require(doc.sketches[id])
        #expect(sketch.orderedEntities.filter { $0.kind == .line }.count == 4)
        await m.run("edit.undo")
        #expect(m.sketchState.sketch?.orderedEntities.filter { $0.kind == .line }.isEmpty == true)
        await m.run("edit.redo")
        #expect(m.sketchState.sketch?.orderedEntities.filter { $0.kind == .line }.count == 4)
    }
}

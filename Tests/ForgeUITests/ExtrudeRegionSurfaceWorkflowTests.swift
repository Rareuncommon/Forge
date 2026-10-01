import ForgeCore
import Foundation
import Testing
@testable import ForgeUI

@MainActor
@Suite("Desktop selected contours and surface limits")
struct ExtrudeRegionSurfaceWorkflowTests {
    private func model() async -> AppModel {
        let m = AppModel()
        await m.bootstrap()
        return m
    }
    private func twoRegions(_ m: AppModel) async {
        await m.run("sketch.create", ["plane": "front"])
        await m.run("sketch.add_rectangle", ["points": [[0, 0], [10, 10]]])
        await m.run("sketch.add_circle", ["center": [5, 5], "radius": 2])
        await m.run("sketch.add_rectangle", ["points": [[20, 0], [25, 5]]])
        await m.run("sketch.exit")
    }

    @Test func panelChecklistSelectsOneRegionKeepsHoleAndSurvivesFeatureEditing() async throws {
        let m = await model()
        await twoRegions(m)
        m.begin(.extrude)
        await m.refreshContourChoices()
        #expect(m.contourChoices.count == 2)
        let region = try #require(m.contourChoices.first { $0.area > 50 })
        let all = try #require(m.panelPage.sections.flatMap(\.controls).first { $0.id == "allContours" })
        guard case .check(_, _, let setAll) = all.kind else { Issue.record("Expected all-region checkbox"); return }
        setAll(false)
        let check = try #require(m.panelPage.sections.flatMap(\.controls).first { $0.id == "contour-" + region.id })
        guard case .check(_, _, let setRegion) = check.kind else { Issue.record("Expected region checkbox"); return }
        setRegion(true)
        m.form.depth = "3"
        let key = m.previewKey
        m.form.contours = nil
        #expect(m.previewKey != key)
        m.form.contours = [region.selector]
        await m.updatePreview()
        #expect(m.preview.items.count == 1)
        await m.commitOperation()
        #expect(m.lastError == nil)
        let before = try #require(await m.engine.activeDocument?.body("body-1"))
        #expect(abs(try before.shape.massProperties().volume - (100 - 4 * .pi) * 3) < 1e-6)
        let feature = try #require(m.features.last)
        m.editFeature(feature)
        await m.editTask?.value
        #expect(m.form.contours == [region.selector])
        await m.commitOperation()
        let after = try #require(await m.engine.activeDocument?.body("body-1"))
        #expect(abs(try after.shape.massProperties().volume - (100 - 4 * .pi) * 3) < 1e-6)
    }

    @Test func viewportRegionPickingIgnoresHolesAndTogglesSelectedRegion() async throws {
        let m = await model()
        await twoRegions(m)
        m.begin(.extrude)
        await m.refreshContourChoices()
        m.form.activeBox = "contours"
        #expect(await m.pickExtrusionContour(origin: Vec3(2, 2, 100), direction: Vec3(0, 0, -1)))
        #expect(m.form.contours?.count == 1)
        let selected = m.form.contours
        #expect(await m.pickExtrusionContour(origin: Vec3(5, 5, 100), direction: Vec3(0, 0, -1)))
        #expect(m.lastError?.code == .invalidParams)
        #expect(m.form.contours == selected)
        #expect(await m.pickExtrusionContour(origin: Vec3(2, 2, 100), direction: Vec3(0, 0, -1)))
        #expect(m.form.contours?.isEmpty == true)
        m.form.activeBox = ""
        #expect(await m.pickExtrusionContour(origin: Vec3(2, 2, 100), direction: Vec3(0, 0, -1)) == false)
    }

    @Test func surfaceAndOffsetBothDirectionsPreviewAndEditorRoundtrip() async throws {
        let m = await model()
        await m.run("plane.create", ["reference": "front", "offset": 10])
        await m.run("plane.create", ["reference": "front", "offset": -5])
        await m.run("sketch.create", ["plane": "front"])
        await m.run("sketch.add_rectangle", ["points": [[0, 0], [4, 3]]])
        await m.run("sketch.exit")
        m.begin(.extrude)
        m.form.endCondition = .offsetFromSurface
        await m.select(["plane-1"])
        m.useSelectedExtrudeSurface()
        #expect(m.form.surface == "plane-1")
        m.form.surfaceOffset = "0.2 cm"
        m.form.direction2 = true
        m.form.endCondition2 = .upToSurface
        await m.select(["plane-2"])
        m.useSelectedExtrudeSurface(direction2: true)
        #expect(m.form.surface2 == "plane-2")
        await m.updatePreview()
        let bounds = try #require(m.preview.items.first?.mesh.bounds)
        #expect(abs(bounds.min.z + 5) < 1e-5 && abs(bounds.max.z - 8) < 1e-5)
        await m.commitOperation()
        #expect(m.lastError == nil)
        let feature = try #require(m.features.last)
        m.editFeature(feature)
        await m.editTask?.value
        #expect(m.form.endCondition == .offsetFromSurface && m.form.endCondition2 == .upToSurface)
        #expect(m.form.surface == "plane-1" && m.form.surface2 == "plane-2")
        #expect(m.form.surfaceOffset == "0.2 cm")
        await m.commitOperation()
        let body = try #require(await m.engine.activeDocument?.body("body-1"))
        #expect(abs(try body.shape.massProperties().volume - 156) < 1e-6)
    }

    @Test func surfaceFieldsInvalidatePreviewAndChangingSketchClearsContourIntent() async throws {
        let m = await model()
        await twoRegions(m)
        m.begin(.extrude)
        await m.refreshContourChoices()
        m.form.contours = [try #require(m.contourChoices.first).selector]
        for path in [\OperationForm.surface, \.surfaceOffset, \.surface2, \.surfaceOffset2] {
            let old = m.previewKey
            m.form[keyPath: path] += "1"
            #expect(m.previewKey != old)
        }
        var old = m.previewKey
        m.form.reverseSurfaceOffset.toggle()
        #expect(m.previewKey != old)
        old = m.previewKey
        m.form.reverseSurfaceOffset2.toggle()
        #expect(m.previewKey != old)
        m.operationSketch = nil
        #expect(m.form.contours == nil && m.contourChoices.isEmpty)
    }

    @Test func qualifiedContourSelectorsRoundTripThroughChecklistWithoutDuplicates() async throws {
        let m = await model()
        await twoRegions(m)
        m.begin(.extrude)
        await m.refreshContourChoices()
        let choice = try #require(m.contourChoices.first)
        let sketch = try #require(m.operationSketch)
        m.form.contours = [choice.selector.map { sketch + "/" + $0 }]
        #expect(m.contourIsSelected(choice))
        m.setContourSelected(choice, true)
        #expect(m.form.contours == [choice.selector])
        await m.updatePreview()
        #expect(m.previewError == nil)
        m.setContourSelected(choice, false)
        #expect(m.form.contours?.isEmpty == true)
    }


    @Test func concurrentContourRefreshesAllAwaitPopulatedChoices() async throws {
        let m = await model()
        await twoRegions(m)
        m.begin(.extrude)
        let requests = (0..<5).map { _ in Task { @MainActor in
            await m.refreshContourChoices()
            return m.contourChoices.count
        } }
        for request in requests { #expect(await request.value == 2) }
        #expect(m.contourQueryError == nil)
    }

}

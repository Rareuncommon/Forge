import ForgeCore
import Foundation
import Testing
@testable import ForgeUI

@MainActor
@Suite("Body placement workflows")
struct BodyPlacementWorkflowTests {
    @Test func placementInputsInvalidatePreviewAndUnitsReachGeometry() async throws {
        let model = AppModel()
        await model.bootstrap()
        await model.run("body.create_box", ["width": 10, "height": 20, "depth": 30])
        model.begin(.moveBody)
        let original = model.previewKey
        model.form.bodyDX = "1 in"
        #expect(model.previewKey != original)
        await model.updatePreview()
        let bounds = try #require(model.preview.items.first?.mesh.bounds)
        #expect(abs(bounds.min.x - 25.4) < 1e-5)
        #expect(abs(bounds.max.x - 35.4) < 1e-5)
        // Every placement field is observed by the native and SwiftUI preview schedulers.
        for key in [\OperationForm.bodyDY, \.bodyDZ, \.bodyAngle, \.bodyAxis, \.bodyOriginX, \.bodyOriginY, \.bodyOriginZ,
                    \.vertexX, \.vertexY, \.vertexZ, \.vertex2X, \.vertex2Y, \.vertex2Z] {
            let before = model.previewKey
            model.form[keyPath: key] += "1"
            #expect(model.previewKey != before)
        }
        var before = model.previewKey
        model.form.bodyCopy.toggle()
        #expect(model.previewKey != before)
        before = model.previewKey
        model.form.bodyRotation.toggle()
        #expect(model.previewKey != before)
        before = model.previewKey
        model.form.bodyCustomAxis = [1, 1, 0]
        #expect(model.previewKey != before)
    }

    @Test func editingTranslationResetsUnstoredRotationDefaults() async throws {
        let model = AppModel()
        await model.bootstrap()
        await model.run("body.create_box", ["width": 10, "height": 20, "depth": 30])
        await model.run("body.transform", ["body": "body-1", "translate": [10, 0, 0]])
        model.form.bodyAxis = "custom"
        model.form.bodyCustomAxis = [1, 1, 0]
        model.form.bodyOriginX = "100"
        model.form.bodyAngle = "123"
        model.editFeature(try #require(model.features.last))
        await model.editTask?.value
        #expect(!model.form.bodyRotation)
        #expect(model.form.bodyAxis == "z" && model.form.bodyAngle == "90")
        #expect(model.form.bodyOriginX == "0" && model.form.bodyCustomAxis == [0, 0, 1])
        model.cancelOperation()
    }

    @Test func copyRotateMoveThenEditAndUndo() async throws {
        let model = AppModel()
        await model.bootstrap()
        await model.run("body.create_box", ["width": 10, "height": 20, "depth": 30])
        await model.select(["body-1"])
        model.begin(.moveBody)
        #expect(model.panelPage.title == "Move/Copy Bodies")
        model.form.bodyCopy = true
        model.form.bodyDX = "100"
        model.form.bodyRotation = true
        model.form.bodyAngle = "90"
        model.form.bodyAxis = "z"
        await model.commitOperation()
        #expect(model.bodies.count == 2)
        let moved = try #require(await model.engine.activeDocument?.body("body-2"))
        #expect((try moved.shape.massProperties().centroid - Vec3(90, 5, 15)).length < 1e-6)
        let feature = try #require(model.features.last)
        #expect(feature.operation == .moveBody)
        model.editFeature(feature)
        await model.editTask?.value
        #expect(model.form.bodyCopy)
        #expect(model.form.bodyRotation)
        model.form.bodyDX = "120"
        await model.commitOperation()
        let edited = try #require(await model.engine.activeDocument?.body("body-2"))
        #expect(abs(try edited.shape.massProperties().centroid.x - 110) < 1e-6)
        await model.run("edit.undo")
        let restored = try #require(await model.engine.activeDocument?.body("body-2"))
        #expect(abs(try restored.shape.massProperties().centroid.x - 90) < 1e-6)
    }

    @Test func customRotationAxisSurvivesInspectorRoundtrip() async throws {
        let model = AppModel()
        await model.bootstrap()
        await model.run("body.create_box", ["width": 10, "height": 20, "depth": 30])
        await model.run("body.transform", ["body": "body-1", "rotate": ["axis": [1, 1, 0], "angle": "30 deg", "origin": [2, 3, 4]]])
        let before = try #require(await model.engine.activeDocument?.body("body-1")).shape
        let mass = try before.massProperties()
        let feature = try #require(model.features.last)
        model.editFeature(feature)
        await model.editTask?.value
        #expect(model.form.bodyAxis == "custom")
        await model.commitOperation()
        let after = try #require(await model.engine.activeDocument?.body("body-1")).shape
        #expect((try after.massProperties().centroid - mass.centroid).length < 1e-6)
    }

    @Test func upToVertexBothDirectionsSurvivesFeatureEditor() async throws {
        let model = AppModel()
        await model.bootstrap()
        await model.run("sketch.create", ["plane": "front"])
        await model.run("sketch.add_rectangle", ["points": [[0, 0], [10, 10]]])
        await model.run("sketch.exit")
        await model.run("body.extrude", ["sketch": "sketch-1", "end_condition": "up_to_vertex", "vertex": [0, 0, 15], "direction2": ["end_condition": "up_to_vertex", "vertex": [0, 0, -5]]])
        let feature = try #require(model.features.last)
        model.editFeature(feature)
        await model.editTask?.value
        #expect(model.form.endCondition == .upToVertex)
        #expect(model.form.endCondition2 == .upToVertex)
        await model.commitOperation()
        let body = try #require(await model.engine.activeDocument?.body("body-1"))
        #expect(abs(try body.shape.massProperties().volume - 2000) < 1e-6)
        #expect(model.features.last?.params["end_condition"] == "up_to_vertex")
        #expect(model.features.last?.params["direction2"]?["end_condition"] == "up_to_vertex")
    }

    @Test func normalToSelectedFaceAndPlaneWithoutOpeningSketch() async throws {
        let model = AppModel()
        await model.bootstrap()
        await model.run("body.create_box", ["width": 10, "height": 20, "depth": 30])
        await model.select(["body-1/face-0"])
        #expect(model.canNormalTo)
        await model.normalToSelection()
        #expect(model.activeSketch == nil)
        #expect(model.lastError == nil)
        guard case .normalTo(let facePlane)? = model.viewportCommands.log.last else { Issue.record("No face camera command"); return }
        #expect(abs(facePlane.normal.x) > 0.99)
        await model.select(["plane-top"])
        await model.normalToSelection()
        #expect(model.lastError == nil)
        guard case .normalTo(let plane)? = model.viewportCommands.log.last else { Issue.record("No plane camera command"); return }
        #expect(abs(plane.normal.y) > 0.99)
    }
}

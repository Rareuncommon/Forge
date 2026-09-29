import ForgeCore
import Foundation
import Testing
@testable import ForgeUI

@MainActor
@Suite("Modeling workflows")
struct ModelWorkflowTests {
    @Test func interferencePanelReportsVolumeAndInvalidatesAfterEdits() async throws {
        let model = AppModel()
        await model.bootstrap()
        await model.run("body.create_box", ["width": 10, "height": 10, "depth": 10])
        await model.run("body.create_box", ["width": 10, "height": 10, "depth": 10, "origin": [5, 0, 0]])
        model.ribbonTab = .evaluate
        #expect(model.ribbonGroups.flatMap(\.buttons).contains { $0.id == "interference" && $0.enabled })
        model.operation = .interference
        #expect(model.collectsPicks)
        await model.computeInterference()
        #expect(model.form.result?["interference_count"] == 1)
        let pair = try #require(model.interferencePairs.first)
        #expect(abs(try #require(pair["volume_mm3"]?.doubleValue) - 500) < 1e-8)
        #expect(model.interferenceLabel(pair).contains("500"))
        #expect(model.panelPage.title == "Interference Detection")
        #expect(model.panelPage.ok == nil)
        await model.selectInterference(pair)
        #expect(Set(model.selection) == Set(["body-1", "body-2"]))
        #expect(model.interferencePairs.count == 1)
        await model.computeInterference()
        await model.run("body.transform", ["body": "body-2", "translate": [100, 0, 0]])
        #expect(model.form.result == nil)
        await model.computeInterference()
        #expect(model.form.result?["interference_count"] == 0)
        model.cancelOperation()
        await model.computeInterference()
        #expect(model.form.result == nil)
    }

    @Test func treeMovesIndependentFeaturesAndExposesDependencyActions() async throws {
        let model = AppModel()
        await model.bootstrap()
        await model.run("body.create_box", ["width": 2, "height": 3, "depth": 4])
        await model.run("body.create_sphere", ["radius": 2, "center": [20, 0, 0]])
        #expect(model.features.count == 2)
        let node = try #require(model.treeNodes.first { $0.id == "feature-2" })
        #expect(node.menu.contains { $0.title == "Parent/Child…" })
        #expect(node.menu.contains { $0.title == "Move Up" })
        await model.moveFeature("feature-2", by: -1)
        #expect(model.features.map(\.id) == ["feature-2", "feature-1"])
        await model.run("edit.undo")
        #expect(model.features.map(\.id) == ["feature-1", "feature-2"])
        await model.moveFeature("feature-1", by: 1)
        #expect(model.features.map(\.id) == ["feature-2", "feature-1"])
    }

    @Test func desktopImportUsesCommandBusAndPreservesSaveDestination() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("forge-ui-step-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("Part.step").path
        let model = AppModel()
        await model.bootstrap()
        await model.run("body.create_box", ["width": 2, "height": 3, "depth": 4])
        try #require(await model.run("export.step", ["path": .string(path)]) != nil)
        await model.run("document.new")
        #expect(await model.importSTEP(path: path))
        #expect(model.documentPath == nil)
        #expect(model.bodies.count == 1)
        #expect(abs(model.bodies[0].volumeMM3 - 24) < 1e-9)
        await model.run("edit.undo")
        #expect(model.bodies.isEmpty)
        await model.run("edit.redo")
        #expect(model.bodies.count == 1)
    }
}

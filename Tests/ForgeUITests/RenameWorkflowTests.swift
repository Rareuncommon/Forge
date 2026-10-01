import ForgeCore
import Foundation
import Testing
@testable import ForgeUI

@MainActor
private final class NamePromptPlatform: PlatformServices {
    var answer: String?
    var prompts: [(String, String)] = []
    func requestName(_ title: String, currentName: String) -> String? {
        prompts.append((title, currentName))
        return answer
    }
    func confirm(_ title: String, _ message: String, confirm: String, cancel: String) -> Bool { true }
    func chooseSavePath(suggestedName name: String) -> String? { nil }
    func chooseOpenPath() -> String? { nil }
}

@MainActor
@Suite("Tree rename workflows")
struct RenameWorkflowTests {
    @Test func unicodeNamesPreserveIdentityAndUndoRedo() async throws {
        let model = AppModel(), prompt = NamePromptPlatform()
        model.platform = prompt
        await model.bootstrap()
        await model.run("body.create_box", ["width": 2, "height": 3, "depth": 4])
        let oldBody = try #require(model.bodies.first).name
        let oldFeature = try #require(model.features.first).name
        prompt.answer = "机架 — café"
        await model.renameBody("body-1")
        #expect(model.bodies.first?.name == prompt.answer)
        #expect(model.bodies.first?.id == "body-1")
        #expect(prompt.prompts.last?.1 == oldBody)
        await model.run("edit.undo")
        #expect(model.bodies.first?.name == oldBody)
        await model.run("edit.redo")
        #expect(model.bodies.first?.name == "机架 — café")
        prompt.answer = "底座 — Base"
        await model.renameFeature("feature-1")
        #expect(model.features.first?.name == prompt.answer)
        #expect(model.features.first?.id == "feature-1")
        #expect(prompt.prompts.last?.1 == oldFeature)
        await model.run("edit.undo")
        #expect(model.features.first?.name == oldFeature)
        await model.run("edit.redo")
        #expect(model.features.first?.name == "底座 — Base")
        let volume = try #require(model.bodies.first?.volumeMM3)
        #expect(abs(volume - 24) < 1e-12)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("forge-rename-\(UUID().uuidString).forgepart")
        defer { try? FileManager.default.removeItem(at: folder) }
        try #require(await model.run("document.save", ["path": .string(folder.path)]) != nil)
        await model.run("document.new")
        try #require(await model.run("document.open", ["path": .string(folder.path)]) != nil)
        #expect(model.features.first?.name == "底座 — Base")
        #expect(model.bodies.first?.name == "机架 — café")
    }

    @Test func cancelAndUnchangedNamesDoNotAddUndoSteps() async throws {
        let model = AppModel(), prompt = NamePromptPlatform()
        model.platform = prompt
        await model.bootstrap()
        await model.run("body.create_box", ["width": 2, "height": 3, "depth": 4])
        prompt.answer = nil
        await model.renameBody("body-1")
        await model.renameFeature("feature-1")
        prompt.answer = try #require(model.bodies.first).name
        await model.renameBody("body-1")
        prompt.answer = try #require(model.features.first).name
        await model.renameFeature("feature-1")
        await model.run("edit.undo")
        #expect(model.bodies.isEmpty)
        #expect(model.features.isEmpty)
    }

    @Test func emptyNamesShowCommandErrorAndPreserveNames() async throws {
        let model = AppModel(), prompt = NamePromptPlatform()
        model.platform = prompt
        await model.bootstrap()
        await model.run("body.create_box", ["width": 2, "height": 3, "depth": 4])
        let oldBody = try #require(model.bodies.first).name
        let oldFeature = try #require(model.features.first).name
        prompt.answer = "   "
        await model.renameBody("body-1")
        #expect(model.lastError?.code == .invalidParams)
        #expect(model.bodies.first?.name == oldBody)
        await model.renameFeature("feature-1")
        #expect(model.lastError?.code == .invalidParams)
        #expect(model.features.first?.name == oldFeature)
        await model.run("edit.undo")
        #expect(model.bodies.isEmpty)
    }

    @Test func sharedTreeExposesRenameForBodiesFeaturesAndAbsorbedSketches() async throws {
        let model = AppModel()
        await model.bootstrap()
        await model.run("sketch.create", ["plane": "front"])
        await model.run("sketch.add_circle", ["center": [0, 0], "radius": 2])
        await model.run("sketch.exit")
        await model.run("body.extrude", ["sketch": "sketch-1", "depth": 3])
        let bodyFolder = try #require(model.treeNodes.first { $0.id == "bodies" })
        #expect(bodyFolder.children.first?.menu.contains { $0.title == "Rename…" } == true)
        let extrude = try #require(model.treeNodes.first { $0.id == "feature-2" })
        #expect(extrude.menu.contains { $0.title == "Rename…" })
        #expect(extrude.children.first?.menu.contains { $0.title == "Rename…" } == true)
    }
}

import ForgeCore
import ForgeRender
import Foundation
import Testing
@testable import ForgeUI

@MainActor
@Suite("Desktop body visibility")
struct BodyVisibilityWorkflowTests {
    private func model() async -> AppModel {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_box", ["width": 10, "height": 10, "depth": 10])
        await m.run("body.create_box", ["width": 10, "height": 10, "depth": 10, "origin": [30, 0, 0]])
        return m
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 where !predicate() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }

    @Test func bodyTreeHideAndShowActionsUpdateSceneAndRemainAccessible() async throws {
        let m = await model()
        let body = try #require(m.treeNodes.first { $0.id == "bodies" }?.children.first { $0.id == "body-1" })
        let hide = try #require(body.menu.first { $0.title == "Hide Body" })
        hide.action()
        try await wait { m.scene.value?.bodies == ["body-2"] }
        #expect(m.bodies.count == 2 && m.hiddenBodyIDs == ["body-1"])
        let hidden = try #require(m.treeNodes.first { $0.id == "bodies" }?.children.first { $0.id == "body-1" })
        #expect(hidden.title.contains("Hidden"))
        let show = try #require(hidden.menu.first { $0.title == "Show Body" })
        show.action()
        try await wait { m.scene.value?.bodies == ["body-1", "body-2"] }
        #expect(m.lastError == nil)
    }

    @Test func faceSelectionRibbonIsolationRestoresOriginalVisibility() async throws {
        let m = await model()
        await m.setBodiesVisible(["body-2"], false)
        await m.select("body-1/face-0", extend: false)
        m.ribbonTab = .features
        let isolate = try #require(m.ribbonGroups.flatMap(\.buttons).first { $0.id == "isolateBodies" })
        #expect(isolate.enabled)
        isolate.action()
        try await wait { m.isIsolatingBodies }
        await m.setBodiesVisible(["body-2"], true)
        #expect(m.scene.value?.bodies == ["body-1", "body-2"])
        let exit = try #require(m.ribbonGroups.flatMap(\.buttons).first { $0.id == "exitIsolation" })
        #expect(exit.enabled)
        exit.action()
        try await wait { !m.isIsolatingBodies && m.scene.value?.bodies == ["body-1"] }
        let showAll = try #require(m.ribbonGroups.flatMap(\.buttons).first { $0.id == "showAllBodies" })
        showAll.action()
        try await wait { m.hiddenBodyIDs.isEmpty && m.scene.value?.bodies.count == 2 }
        #expect(m.lastError == nil)
    }

    @Test func hidingEveryBodyProducesUnpickableEmptyModelSceneAndUndoRestoresIt() async throws {
        let m = await model()
        await m.setBodiesVisible(["body-1", "body-2"], false)
        let ds = try #require(m.scene.value)
        #expect(ds.bodies.isEmpty)
        let modelItems = ds.scene.items.filter { $0.objectID < 1_000_000 }
        #expect(modelItems.isEmpty)
        #expect(RayPicker.pick(RenderScene(items: modelItems), origin: Vec3(5, 5, 100), direction: Vec3(0, 0, -1)) == nil)
        await m.run("edit.undo")
        #expect(m.scene.value?.bodies == ["body-1", "body-2"])
        await m.run("document.new")
        #expect(m.hiddenBodyIDs.isEmpty && !m.isIsolatingBodies)
    }
}

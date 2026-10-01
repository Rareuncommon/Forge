import ForgeCore
import ForgeData
import ForgeRender
import Foundation
import Testing
@testable import ForgeCommands

@Suite("Body visibility commands")
struct VisibilityTests {
    private func engine() async throws -> Engine {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10, "origin": [30, 0, 0]])
        return e
    }

    @Test func hiddenBodiesAreNotRenderedPickedOrFramedButRemainInModel() async throws {
        let e = try await engine()
        let result = try await e.execute("view.set_visibility", ["bodies": ["body-1"], "visible": false])
        #expect(result.changes.modified == ["doc-1"])
        let doc = try #require(await e.activeDocument)
        #expect(doc.bodies.count == 2 && doc.features.count == 2)
        let scene = try DocumentScene(document: doc)
        #expect(scene.bodies == ["body-2"])
        #expect(scene.scene.bounds?.min.x == 30)
        #expect(RayPicker.pick(scene.scene, origin: Vec3(5, 5, 100), direction: Vec3(0, 0, -1)) == nil)
        let hit = try #require(RayPicker.pick(scene.scene, origin: Vec3(35, 5, 100), direction: Vec3(0, 0, -1)))
        #expect(scene.reference(for: hit)?.hasPrefix("body-2/face-") == true)
        let state = try await e.execute("document.state").result
        #expect(state["visibility"]?["hidden_bodies"] == ["body-1"])
        #expect(state["visibility"]?["visible_bodies"] == ["body-2"])
        let properties = try await e.execute("query.mass_properties", ["body": "body-1"]).result
        #expect(abs((properties["volume_mm3"]?.doubleValue ?? 0) - 1000) < 1e-8)
    }

    @Test func visibilityTransactionUndoDryRunAndInvalidInputsAreAtomic() async throws {
        let e = try await engine()
        let dry = try await e.execute("view.set_visibility", ["bodies": ["body-1"], "visible": false], dryRun: true)
        #expect(dry.changes.modified == ["doc-1"])
        #expect(await e.activeDocument?.hiddenBodyIDs.isEmpty == true)
        await #expect(throws: ForgeError.self) {
            try await e.execute("view.set_visibility", ["bodies": ["body-1", "missing"], "visible": false])
        }
        #expect(await e.activeDocument?.hiddenBodyIDs.isEmpty == true)
        try await e.execute("transaction.begin", ["label": "Hide first body"])
        try await e.execute("view.set_visibility", ["bodies": ["body-1"], "visible": false])
        try await e.execute("transaction.commit")
        try await e.execute("edit.undo")
        #expect(await e.activeDocument?.hiddenBodyIDs.isEmpty == true)
        try await e.execute("edit.redo")
        #expect(await e.activeDocument?.hiddenBodyIDs == ["body-1"])
    }

    @Test func isolationRestoresPriorVisibilityAndNewBodiesStayOutsideIt() async throws {
        let e = try await engine()
        try await e.execute("view.set_visibility", ["bodies": ["body-1"], "visible": false])
        try await e.execute("view.isolate", ["bodies": ["body-1"]])
        #expect(try DocumentScene(document: #require(await e.activeDocument)).bodies == ["body-1"])
        try await e.execute("body.create_sphere", ["radius": 1])
        #expect(try DocumentScene(document: #require(await e.activeDocument)).bodies == ["body-1"])
        try await e.execute("view.set_visibility", ["bodies": ["body-2"], "visible": true])
        try await e.execute("view.exit_isolation")
        #expect(try DocumentScene(document: #require(await e.activeDocument)).bodies == ["body-2", "body-3"])
        try await e.execute("edit.undo")
        #expect(await e.activeDocument?.isolatedBodyIDs == ["body-1", "body-2"])
        try await e.execute("view.show_all")
        #expect(try DocumentScene(document: #require(await e.activeDocument)).bodies.count == 3)
        #expect(await e.activeDocument?.isolatedBodyIDs == nil)
    }

    @Test func saveDuringIsolationPersistsOrdinaryVisibilityOnlyAndOldFilesDefaultVisible() async throws {
        let e = try await engine()
        try await e.execute("view.set_visibility", ["bodies": ["body-1"], "visible": false])
        try await e.execute("view.isolate", ["bodies": ["body-1"]])
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("forge-visibility-\(UUID().uuidString).forgepart")
        defer { try? FileManager.default.removeItem(at: path) }
        try await e.execute("document.save", ["path": .string(path.path)])
        let loaded = Engine()
        try await loaded.execute("document.open", ["path": .string(path.path)])
        #expect(await loaded.activeDocument?.isolatedBodyIDs == nil)
        #expect(try DocumentScene(document: #require(await loaded.activeDocument)).bodies == ["body-2"])
        try await loaded.execute("document.regenerate")
        #expect(try DocumentScene(document: #require(await loaded.activeDocument)).bodies == ["body-2"])
        let modelPath = path.appendingPathComponent("model.json")
        var json = try JSONCoding.parse(String(contentsOf: modelPath, encoding: .utf8)).objectValue!
        json.removeValue(forKey: "hidden_bodies")
        try JSONCoding.string(.object(json)).write(to: modelPath, atomically: true, encoding: .utf8)
        let legacy = Engine()
        try await legacy.execute("document.open", ["path": .string(path.path)])
        #expect(try DocumentScene(document: #require(await legacy.activeDocument)).bodies.count == 2)
    }

    @Test func packageVisibilityRetainsSuppressedBodiesButIgnoresUnknownFutureIDs() async throws {
        let e = try await engine()
        try await e.execute("view.set_visibility", ["bodies": ["body-2"], "visible": false])
        try await e.execute("feature.suppress", ["feature": "feature-2"])
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("forge-hidden-ids-\(UUID().uuidString).forgepart")
        defer { try? FileManager.default.removeItem(at: path) }
        try await e.execute("document.save", ["path": .string(path.path)])
        let modelPath = path.appendingPathComponent("model.json")
        var json = try JSONCoding.parse(String(contentsOf: modelPath, encoding: .utf8)).objectValue!
        json["hidden_bodies"] = ["body-2", "body-3", "missing"]
        try JSONCoding.string(.object(json)).write(to: modelPath, atomically: true, encoding: .utf8)
        let loaded = Engine()
        try await loaded.execute("document.open", ["path": .string(path.path)])
        #expect(await loaded.activeDocument?.hiddenBodyIDs == ["body-2"])
        try await loaded.execute("feature.suppress", ["feature": "feature-2", "suppressed": false])
        #expect(await loaded.activeDocument?.isBodyVisible("body-2") == false)
        try await loaded.execute("body.create_sphere", ["radius": 1])
        #expect(await loaded.activeDocument?.isBodyVisible("body-3") == true)
    }

}

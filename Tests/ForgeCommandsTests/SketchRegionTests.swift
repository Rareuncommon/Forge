import ForgeCore
import Foundation
import Testing
@testable import ForgeCommands

@Suite("Selected sketch regions")
struct SketchRegionTests {
    func engine() async throws -> Engine {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("sketch.create", ["plane": "front"])
        return e
    }

    func regions(_ e: Engine, at: JSONValue? = nil) async throws -> [JSONValue] {
        var params: [String: JSONValue] = [:]
        params["at"] = at
        return try #require(try await e.execute("sketch.regions", .object(params)).result["regions"]?.arrayValue)
    }

    @Test func selectedContourSurvivesLoopOrderingChangesAndRoundTrips() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [10, 20]]])
        try await e.execute("sketch.add_rectangle", ["points": [[30, 0], [35, 5]]])
        let choices = try await regions(e)
        let selected = try #require(choices.first { $0["area_mm2"] == 200 }?["selector"])
        let preview = try await e.execute("body.extrude", ["depth": 3, "contours": .array([selected])], dryRun: true)
        #expect(abs((volume(preview) ?? 0) - 600) < 1e-6)
        #expect(await e.activeDocument!.bodies.isEmpty)
        try await e.execute("body.extrude", ["depth": 3, "contours": .array([selected])])
        // Profile discovery places closed circles before chained lines; this changes old ordinals.
        try await e.execute("sketch.add_circle", ["center": [50, 0], "radius": 2])
        try await e.execute("document.regenerate")
        #expect(abs(try await e.activeDocument!.body("body-1").shape.massProperties().volume - 600) < 1e-6)
        #expect(try await regions(e).contains { $0["selector"] == selected })
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("forge-region-\(UUID().uuidString).forgepart")
        defer { try? FileManager.default.removeItem(at: path) }
        try await e.execute("document.save", ["path": .string(path.path)])
        let loaded = Engine()
        try await loaded.execute("document.open", ["path": .string(path.path)])
        try await loaded.execute("document.regenerate")
        #expect(abs(try await loaded.activeDocument!.body("body-1").shape.massProperties().volume - 600) < 1e-6)
        #expect(await loaded.activeDocument!.features.last!.params["contours"] == .array([selected]))
    }

    @Test func holesAndNestedIslandsRemainSeparateSelectableRegions() async throws {
        let e = try await engine()
        for radius in [10, 6, 2] { try await e.execute("sketch.add_circle", ["center": [0, 0], "radius": .number(Double(radius))]) }
        let choices = try await regions(e)
        #expect(choices.count == 2)
        let ring = try #require(choices.first { ($0["holes"]?.arrayValue?.count ?? 0) == 1 })
        let island = try #require(choices.first { ($0["holes"]?.arrayValue?.count ?? 0) == 0 })
        #expect(abs(ring["area_mm2"]!.doubleValue! - 64 * .pi) < 1e-8)
        #expect(abs(island["area_mm2"]!.doubleValue! - 4 * .pi) < 1e-8)
        let onlyRing = try await e.execute("body.extrude", ["depth": 2, "contours": .array([ring["selector"]!])])
        #expect(abs((volume(onlyRing) ?? 0) - 128 * .pi) < 1e-6)
        try await e.execute("edit.undo")
        #expect(await e.activeDocument!.bodies.isEmpty)
        try await e.execute("edit.redo")
        #expect(abs(try await e.activeDocument!.body("body-1").shape.massProperties().volume - 128 * .pi) < 1e-6)
        try await e.execute("feature.edit", ["feature": "feature-2", "params": ["contours": .array([ring["selector"]!, island["selector"]!])]])
        #expect(abs(try await e.activeDocument!.body("body-1").shape.massProperties().volume - 136 * .pi) < 1e-6)
        #expect(try await regions(e, at: [8, 0]).first?["selector"] == ring["selector"])
        #expect(try await regions(e, at: [4, 0]).isEmpty)
        #expect(try await regions(e, at: [0, 0]).first?["selector"] == island["selector"])
        #expect(try await regions(e, at: [20, 20]).isEmpty)
    }

    @Test func explicitClosedContourCanIgnoreUnrelatedOpenGeometry() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [10, 5]]])
        let selector = try #require(try await regions(e).first?["selector"])
        try await e.execute("sketch.add_line", ["start": [30, 0], "end": [40, 0]])
        let query = try await e.execute("sketch.regions").result
        #expect(query["profile_valid"] == false)
        #expect(query["regions"]?.arrayValue?.count == 1)
        await #expect(throws: ForgeError.self) { try await e.execute("body.extrude", ["depth": 2]) }
        let result = try await e.execute("body.extrude", ["depth": 2, "contours": .array([selector])])
        #expect(abs((volume(result) ?? 0) - 100) < 1e-6)
    }

    @Test func changedContourFailsExplicitlyInsteadOfSelectingAnotherRegion() async throws {
        let e = try await engine()
        try await e.execute("sketch.add_circle", ["center": [0, 0], "radius": 5])
        try await e.execute("sketch.add_circle", ["center": [20, 0], "radius": 2])
        let selected = try #require(try await regions(e).first { ($0["area_mm2"]?.doubleValue ?? 0) > 50 }?["selector"])
        let entity = try #require(selected.arrayValue?.first?.stringValue)
        try await e.execute("body.extrude", ["depth": 2, "contours": .array([selected])])
        try await e.execute("sketch.split", ["entity": .string(entity), "at": [[5, 0], [-5, 0]]])
        #expect(await e.activeDocument!.bodies.isEmpty)
        #expect(await e.activeDocument!.features.last?.status.error?.code == .referenceLost)
        try await e.execute("edit.undo")
        #expect(abs(try await e.activeDocument!.body("body-1").shape.massProperties().volume - 50 * .pi) < 1e-6)
    }

    @Test func invalidDuplicateHoleAndCrossSketchSelectorsAreRejected() async throws {
        let e = try await engine()
        let outer = try await e.execute("sketch.add_circle", ["center": [0, 0], "radius": 10]).result["created"]!.arrayValue!.first!
        let hole = try await e.execute("sketch.add_circle", ["center": [0, 0], "radius": 5]).result["created"]!.arrayValue!.first!
        for contours in [JSONValue.array([]), .array([.array([])]), .array([.array([hole])]), .array([.array([outer, outer])]),
                                    .array([.array([outer]), .array([outer])]), [["missing"]], [["sketch-99/circle-1"]]] {
            await #expect(throws: ForgeError.self) { try await e.execute("body.extrude", ["depth": 1, "contours": contours]) }
        }
        #expect(await e.activeDocument!.bodies.isEmpty)
        let qualified: JSONValue = .array([.array([.string("sketch-1/" + outer.stringValue!)])])
        let result = try await e.execute("body.extrude", ["depth": 1, "contours": qualified])
        #expect(abs((volume(result) ?? 0) - 75 * .pi) < 1e-6)
    }

    @Test func cutUsesOnlyTheSelectedRegionAndTracksItsDimension() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 30, "height": 10, "depth": 5])
        try await e.execute("sketch.create", ["plane": "front"])
        let circle = try await e.execute("sketch.add_circle", ["center": [5, 5], "radius": 2]).result["created"]!.arrayValue!.first!
        try await e.execute("sketch.add_circle", ["center": [25, 5], "radius": 2])
        let selector = try #require(try await regions(e, at: [5, 5]).first?["selector"])
        let dimension = try await e.execute("sketch.add_dimension", ["type": "radius", "entities": .array([circle]), "value": 2]).result["constraints"]!.arrayValue!.first!
        let cut = try await e.execute("body.extrude", ["operation": "cut", "depth": 5, "contours": .array([selector])])
        #expect(abs((volume(cut) ?? 0) - (1500 - 20 * .pi)) < 1e-6)
        try await e.execute("sketch.set_dimension", ["constraint": dimension, "value": 3])
        #expect(abs(try await e.activeDocument!.body("body-1").shape.massProperties().volume - (1500 - 45 * .pi)) < 1e-6)
    }


    @Test func nestingUsesLoopTraversalWhenIndividualEdgesAreReversed() async throws {
        let e = try await engine()
        for endpoints in [JSONValue.array([[0, 0], [10, 0]]), [[10, 10], [10, 0]], [[10, 10], [0, 10]], [[0, 0], [0, 10]]] {
            try await e.execute("sketch.add_line", ["start": endpoints.arrayValue![0], "end": endpoints.arrayValue![1]])
        }
        try await e.execute("sketch.add_circle", ["center": [5, 5], "radius": 1])
        let choices = try await regions(e)
        #expect(choices.count == 1)
        let region = try #require(choices.first)
        #expect(region["holes"]?.arrayValue?.count == 1)
        #expect(abs(region["area_mm2"]!.doubleValue! - (100 - .pi)) < 1e-8)
        let result = try await e.execute("body.extrude", ["depth": 1, "contours": .array([region["selector"]!])])
        #expect(abs((volume(result) ?? 0) - (100 - .pi)) < 1e-6)
    }

}

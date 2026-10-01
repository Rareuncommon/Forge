import ForgeCore
import Foundation
import Testing
@testable import ForgeCommands

@Suite("Planar extrusion end conditions")
struct SurfaceExtrudeTests {
    private func engine() async throws -> Engine {
        let e = Engine()
        try await e.execute("document.new")
        return e
    }
    private func profile(_ e: Engine) async throws {
        try await e.execute("sketch.create", ["plane": "front"])
        try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [4, 3]]])
        try await e.execute("sketch.exit")
    }
    private func volume(_ e: Engine, _ body: String = "body-1") async throws -> Double {
        try #require(try await e.execute("query.mass_properties", ["body": .string(body)]).result["volume_mm3"]?.doubleValue)
    }

    @Test func parallelPlaneBothDirectionsOffsetsAndUndo() async throws {
        let e = try await engine()
        try await e.execute("plane.create", ["reference": "front", "offset": 10, "name": "Ceiling"])
        try await e.execute("plane.create", ["reference": "front", "offset": -5])
        try await profile(e)
        try await e.execute("body.extrude", ["sketch": "sketch-1", "end_condition": "offset_from_surface", "surface": "Ceiling", "offset": "0.2 cm", "direction2": ["end_condition": "up_to_surface", "surface": "plane-2"]])
        #expect(abs(try await volume(e) - 12 * 13) < 1e-6)
        let doc = try #require(await e.activeDocument)
        let feature = try #require(doc.features.last)
        #expect(feature.params["surface"] == "plane-1")
        let parents = try await e.execute("feature.dependencies", ["feature": .string(feature.id)]).result["parents"]
        #expect(parents?.arrayValue?.contains("feature-1") == true)
        #expect(parents?.arrayValue?.contains("feature-2") == true)
        try await e.execute("feature.edit", ["feature": .string(feature.id), "params": ["reverse_offset": true]])
        #expect(abs(try await volume(e) - 12 * 17) < 1e-6)
        try await e.execute("edit.undo")
        #expect(abs(try await volume(e) - 12 * 13) < 1e-6)
        try await e.execute("edit.redo")
        #expect(abs(try await volume(e) - 12 * 17) < 1e-6)
    }

    @Test func reverseDirectionAndSecondDirectionOffset() async throws {
        let e = try await engine()
        try await e.execute("plane.create", ["reference": "front", "offset": 10])
        try await e.execute("plane.create", ["reference": "front", "offset": -5, "flip": true])
        try await profile(e)
        try await e.execute("body.extrude", ["sketch": "sketch-1", "end_condition": "up_to_surface", "surface": "plane-2", "reverse": true,
                                            "direction2": ["end_condition": "offset_from_surface", "surface": "plane-1", "offset": 2]])
        #expect(abs(try await volume(e) - 12 * 13) < 1e-6)
        let box = try await e.activeDocument!.body("body-1").shape.boundingBox()
        #expect(abs(box.min.z + 5) < 1e-6 && abs(box.max.z - 8) < 1e-6)
    }

    @Test func obliqueFaceUsesPerpendicularOffsetAndPersistentNames() async throws {
        let e = try await engine()
        try await e.execute("body.create_box", ["origin": [-50, -50, -2], "width": 100, "height": 100, "depth": 2])
        try await e.execute("body.transform", ["body": "body-1", "rotate": ["axis": [0, 1, 0], "angle": "30 deg"], "translate": [0, 0, 10]])
        let faces = try #require(try await e.execute("query.faces", ["body": "body-1"]).result["faces"]?.arrayValue)
        let top = try #require(faces.first { $0["persistent_id"]?.stringValue?.contains("feature-1:+z") == true })
        let transient = try #require(top["id"])
        try await profile(e)
        try await e.execute("body.extrude", ["sketch": "sketch-1", "end_condition": "up_to_surface", "surface": transient])
        let height = 10 - 2 * tan(Double.pi / 6)
        #expect(abs(try await volume(e, "body-2") - 12 * height) < 1e-6)
        let feature = try #require(await e.activeDocument?.features.last)
        #expect(feature.params["surface"]?.stringValue?.contains("/face@") == true)
        #expect(feature.references?.count == 1)
        try await e.execute("feature.edit", ["feature": .string(feature.id), "params": ["end_condition": "offset_from_surface", "offset": 2]])
        #expect(abs(try await volume(e, "body-2") - 12 * (height - 2 / cos(Double.pi / 6))) < 1e-6)
        try await e.execute("feature.edit", ["feature": "feature-2", "params": ["translate": [0, 0, 14]]])
        #expect(abs(try await volume(e, "body-2") - 12 * (height + 4 - 2 / cos(Double.pi / 6))) < 1e-6)
        let newFaces = try #require(try await e.execute("query.faces", ["body": "body-2"]).result["faces"]?.arrayValue)
        #expect(newFaces.contains { $0["persistent_id"]?.stringValue?.contains("\(feature.id):end_cap") == true })
    }

    @Test func planeRegenerationSuppressionSaveAndReopen() async throws {
        let e = try await engine()
        try await e.execute("plane.create", ["reference": "front", "offset": 10])
        try await profile(e)
        try await e.execute("body.extrude", ["sketch": "sketch-1", "end_condition": "up_to_surface", "surface": "plane-1"])
        try await e.execute("feature.edit", ["feature": "feature-1", "params": ["offset": 15]])
        #expect(abs(try await volume(e) - 180) < 1e-6)
        try await e.execute("feature.suppress", ["feature": "feature-1"])
        #expect(await e.activeDocument?.features.last?.status.state == .error)
        #expect(await e.activeDocument?.bodies.isEmpty == true)
        try await e.execute("feature.suppress", ["feature": "feature-1", "suppressed": false])
        #expect(abs(try await volume(e) - 180) < 1e-6)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("forge-surface-\(UUID().uuidString).forgepart")
        defer { try? FileManager.default.removeItem(at: path) }
        try await e.execute("document.save", ["path": .string(path.path)])
        try await e.execute("document.new")
        try await e.execute("document.open", ["path": .string(path.path)])
        try await e.execute("document.regenerate")
        #expect(abs(try await volume(e) - 180) < 1e-6)
    }

    @Test func surfaceCutDryRunAndDependencyReorder() async throws {
        let e = try await engine()
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        try await e.execute("plane.create", ["reference": "front", "offset": 6])
        try await profile(e)
        let params: JSONValue = ["sketch": "sketch-1", "end_condition": "up_to_surface", "surface": "plane-1", "operation": "cut", "scope": ["body-1"]]
        try await e.execute("body.extrude", params, dryRun: true)
        #expect(abs(try await volume(e) - 1000) < 1e-6)
        try await e.execute("body.extrude", params)
        #expect(abs(try await volume(e) - (1000 - 4 * 3 * 6)) < 1e-6)
        await #expect(throws: ForgeError.self) {
            try await e.execute("feature.reorder", ["feature": "feature-4", "before": "feature-2"])
        }
        #expect(abs(try await volume(e) - 928) < 1e-6)
    }

    @Test func invalidLimitsAreAtomic() async throws {
        let e = try await engine()
        try await e.execute("plane.create", ["reference": "front", "offset": 10])
        try await e.execute("body.create_sphere", ["radius": 2, "center": [0, 0, 20]])
        try await profile(e)
        let before = try #require(await e.activeDocument)
        let bad: [JSONValue] = [
            ["sketch": "sketch-1", "end_condition": "up_to_surface"],
            ["sketch": "sketch-1", "end_condition": "up_to_surface", "surface": "plane-top"],
            ["sketch": "sketch-1", "end_condition": "up_to_surface", "surface": "plane-front"],
            ["sketch": "sketch-1", "end_condition": "up_to_surface", "surface": "body-1/face-0"],
            ["sketch": "sketch-1", "end_condition": "up_to_surface", "surface": "plane-1", "reverse": true],
            ["sketch": "sketch-1", "end_condition": "offset_from_surface", "surface": "plane-1"],
            ["sketch": "sketch-1", "end_condition": "offset_from_surface", "surface": "plane-1", "offset": -1],
            ["sketch": "sketch-1", "end_condition": "offset_from_surface", "surface": "plane-1", "offset": 12],
            ["sketch": "sketch-1", "end_condition": "up_to_surface", "surface": "plane-1", "draft": ["angle": "2 deg"]],
            ["sketch": "sketch-1", "depth": 3, "surface": "plane-1"],
        ]
        for params in bad {
            await #expect(throws: ForgeError.self) { try await e.execute("body.extrude", params) }
            #expect(await e.activeDocument?.features.count == before.features.count)
            #expect(await e.activeDocument?.bodyOrder == before.bodyOrder)
        }
    }
}

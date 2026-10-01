import ForgeCore
import ForgeKernel
import Foundation
import Testing

@testable import ForgeCommands

@Suite("Convert model entities")
struct SketchConvertTests {
    func boxEngine() async throws -> Engine {
        let engine = Engine()
        try await engine.execute("document.new")
        try await engine.execute("body.create_box", ["width": 10, "height": 20, "depth": 30])
        return engine
    }

    func planarFace(_ engine: Engine, normal: Vec3) async throws -> String {
        let body = try #require(await engine.activeDocument?.bodies["body-1"])
        for index in 0..<(try body.shape.topology().faces) {
            if (try body.shape.face(index).normal - normal).length < 1e-6 { return "body-1/face-\(index)" }
        }
        throw ForgeError(.internalError, "test face not found")
    }

    func circularEdge(_ engine: Engine) async throws -> String {
        let body = try #require(await engine.activeDocument?.bodies["body-1"])
        for index in 0..<(try body.shape.topology().edges) {
            if try body.shape.edge(index).curveType == .circle { return "body-1/edge-\(index)" }
        }
        throw ForgeError(.internalError, "test edge not found")
    }

    @Test func faceBoundaryMakesClosedProfileWithUndoDryRunAndRoundTrip() async throws {
        let engine = try await boxEngine()
        let face = try await planarFace(engine, normal: .unitZ)
        try await engine.execute("sketch.create", ["face": .string(face)])
        let params: JSONValue = ["entities": [.string(face), .string(face)]]
        let dry = try await engine.execute("sketch.convert_entities", params, dryRun: true)
        #expect(dry.result["created"]?.arrayValue?.count == 4)
        #expect(await engine.activeDocument?.orderedSketches[0].orderedEntities.count == 1)
        let result = try await engine.execute("sketch.convert_entities", params)
        #expect(result.result["created"]?.arrayValue?.count == 4)
        let converted = try #require(await engine.activeDocument?.orderedSketches.first)
        #expect(converted.report?.dof == 0)
        try await engine.execute("edit.undo")
        #expect(await engine.activeDocument?.orderedSketches[0].orderedEntities.count == 1)
        try await engine.execute("edit.redo")
        #expect(await engine.activeDocument?.orderedSketches[0] == converted)
        let extrusion = try await engine.execute("body.extrude", ["depth": 2])
        #expect(abs((volume(extrusion) ?? 0) - 400) < 1e-6)
        try await engine.execute("document.regenerate")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forge-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Part.forgepart").path
        try await engine.execute("document.save", ["path": .string(path)])
        let reopened = Engine()
        try await reopened.execute("document.open", ["path": .string(path)])
        try await reopened.execute("document.regenerate")
        #expect(await reopened.activeDocument?.orderedSketches[0].orderedEntities.count == converted.orderedEntities.count)
        let mass = try await reopened.execute("query.mass_properties", ["body": "body-2"])
        #expect(abs((mass.result["volume_mm3"]?.doubleValue ?? 0) - 400) < 1e-6)
    }

    @Test func parallelCircleProjectsExactlyAndRemainsDetached() async throws {
        let engine = Engine()
        try await engine.execute("document.new")
        try await engine.execute("body.create_cylinder", ["radius": 4, "height": 12])
        let edge = try await circularEdge(engine)
        try await engine.execute("sketch.create", ["plane": "front", "offset": 20])
        let result = try await engine.execute("sketch.convert_entities", ["entities": [.string(edge)], "fixed": false])
        let id = try #require(result.result["created"]?.arrayValue?.first?.stringValue)
        var sketch = try #require(await engine.activeDocument?.orderedSketches.first)
        #expect(try sketch.entity(id).kind == .circle)
        #expect(sketch.report?.dof == 3)
        let circle = try sketch.entity(id)
        #expect(abs(sketch.params[circle.params[0]] - 4) < 1e-9)
        try await engine.execute("feature.edit", ["feature": "feature-1", "params": ["radius": 6]])
        sketch = try #require(await engine.activeDocument?.orderedSketches.first)
        #expect(abs(sketch.params[circle.params[0]] - 4) < 1e-9)
    }

    @Test func convertsCircularArcsWithoutChangingTheirSweep() async throws {
        let engine = Engine()
        try await engine.execute("document.new")
        try await engine.execute("body.create_cylinder", ["radius": 4, "height": 12])
        try await engine.execute("body.create_box", ["width": 10, "height": 20, "depth": 14, "origin": [0, -10, -1]])
        try await engine.execute("body.boolean", ["operation": "cut", "target": "body-1", "tool": "body-2"])
        let edge = try await circularEdge(engine)
        try await engine.execute("sketch.create", ["plane": "front"])
        let result = try await engine.execute("sketch.convert_entities", ["entities": [.string(edge)]])
        let id = try #require(result.result["created"]?.arrayValue?.first?.stringValue)
        let sketch = try #require(await engine.activeDocument?.orderedSketches.first)
        let arc = try sketch.entity(id)
        #expect(arc.kind == .arc)
        #expect(sketch.report?.dof == 0)
        let points = try arc.points.map { try sketch.entity($0) }.map { Vec3(sketch.params[$0.params[0]], sketch.params[$0.params[1]], 0) }
        #expect(abs((points[1] - points[0]).length - 4) < 1e-8)
        #expect(abs((points[2] - points[1]).length - 8) < 1e-8)
        // CCW from +Y to -Y sweeps the retained negative-X half, not the removed half.
        #expect(abs(points[1].y - 4) < 1e-8)
        #expect(abs(points[2].y + 4) < 1e-8)
    }

    @Test func unsupportedProjectionRejectsWholeCommand() async throws {
        let engine = Engine()
        try await engine.execute("document.new")
        try await engine.execute("body.create_cylinder", ["radius": 4, "height": 12])
        let edge = try await circularEdge(engine)
        try await engine.execute("sketch.create", ["plane": "right"])
        let before = await engine.activeDocument?.orderedSketches.first
        await #expect(throws: ForgeError.self) {
            try await engine.execute("sketch.convert_entities", ["entities": [.string(edge)]])
        }
        #expect(await engine.activeDocument?.orderedSketches.first == before)
        let body = try #require(await engine.activeDocument?.bodies["body-1"])
        let line = try #require((0..<(try body.shape.topology().edges)).first { (try? body.shape.edge($0).curveType) == .line })
        try await engine.execute("sketch.create", ["plane": "front"])
        await #expect(throws: ForgeError.self) {
            try await engine.execute("sketch.convert_entities", ["entities": [.string(edge), .string("body-1/edge-\(line)")]])
        }
        #expect(await engine.activeDocument?.orderedSketches[1].orderedEntities.count == 1)
    }
}

@Suite("Sketch attachment repair")
struct SketchAttachmentRepairTests {
    @Test func lostPlaneBlocksDownstreamGeometryAndCanBeRepairedWithUndo() async throws {
        let engine = Engine()
        try await engine.execute("document.new")
        try await engine.execute("plane.create", ["reference": "top", "offset": 30])
        try await engine.execute("sketch.create", ["plane": "Plane1"])
        try await engine.execute("sketch.add_rectangle", ["points": [[0, 0], [10, 10]]])
        try await engine.execute("body.extrude", ["depth": 2])
        try await engine.execute("feature.delete", ["feature": "Plane1"])
        #expect(await engine.activeDocument!.bodies.isEmpty)
        #expect(await engine.activeDocument!.features.map(\.status.state) == [.error, .error])
        await #expect(throws: ForgeError.self) { try await engine.execute("body.extrude", ["depth": 4]) }
        try await engine.execute("feature.repair_reference", ["feature": "Sketch1", "old": "plane-1", "new": "front"])
        #expect(await engine.activeDocument!.features.map(\.status.state) == [.ok, .ok])
        #expect(abs(try await engine.activeDocument!.body("body-1").shape.boundingBox().max.z - 2) < 1e-6)
        try await engine.execute("edit.undo")
        #expect(await engine.activeDocument!.bodies.isEmpty)
        try await engine.execute("edit.redo")
        #expect(await engine.activeDocument!.features.map(\.status.state) == [.ok, .ok])
    }

    @Test func faceAttachmentRepairChangesPersistedPlacement() async throws {
        let helper = SketchConvertTests()
        let engine = try await helper.boxEngine()
        let front = try await helper.planarFace(engine, normal: .unitZ)
        let side = try await helper.planarFace(engine, normal: .unitY)
        try await engine.execute("sketch.create", ["face": .string(front)])
        try await engine.execute("sketch.add_circle", ["center": [5, 5], "radius": 2])
        try await engine.execute("body.extrude", ["depth": 3])
        let old = try #require(await engine.activeDocument!.orderedSketches[0].placement)
        try await engine.execute("feature.repair_reference", ["feature": "Sketch1", "old": .string(old), "new": .string(side)])
        let sketch = try #require(await engine.activeDocument?.orderedSketches.first)
        #expect((sketch.plane.normal - .unitY).length < 1e-8)
        #expect(sketch.placement?.contains("face@") == true)
        #expect(sketch.placement != old)
        try await engine.execute("feature.edit", ["feature": "Box1", "params": ["height": 25]])
        #expect(abs(try await engine.activeDocument!.body("body-2").shape.boundingBox().min.y - 25) < 1e-6)
    }
}

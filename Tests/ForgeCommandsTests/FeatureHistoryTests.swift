import ForgeCore
import Foundation
import Testing
@testable import ForgeCommands

@Suite("Feature history inspection and reorder")
struct FeatureHistoryTests {
    func boxes() async throws -> Engine {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 10, "height": 20, "depth": 30])
        try await e.execute("body.create_box", ["width": 5, "height": 5, "depth": 5, "origin": [50, 0, 0]])
        return e
    }
    func ids(_ e: Engine) async -> [String] { await e.activeDocument!.features.map(\.id) }

    @Test func independentReorderPreservesIDsGeometryAndRoundTrips() async throws {
        let e = try await boxes()
        let get = try await e.execute("feature.get", ["feature": "Box1"]).result
        #expect(get["id"] == "feature-1")
        try await e.execute("feature.reorder", ["feature": "Box2", "before": "Box1"], dryRun: true)
        #expect(await ids(e) == ["feature-1", "feature-2"])
        try await e.execute("feature.reorder", ["feature": "Box2", "before": "Box1"])
        #expect(await ids(e) == ["feature-2", "feature-1"])
        #expect(abs(try await e.execute("query.mass_properties", ["body": "body-1"]).result["volume_mm3"]!.doubleValue! - 6000) < 1e-6)
        try await e.execute("edit.undo")
        #expect(await ids(e) == ["feature-1", "feature-2"])
        try await e.execute("edit.redo")
        #expect(await ids(e) == ["feature-2", "feature-1"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reordered.forgepart").path
        try await e.execute("document.save", ["path": .string(path)])
        let opened = Engine()
        try await opened.execute("document.open", ["path": .string(path)])
        try await opened.execute("document.regenerate")
        #expect(await ids(opened) == ["feature-2", "feature-1"])
        #expect(await opened.activeDocument!.features.allSatisfy { $0.status.state == .ok })
    }

    @Test func modificationDependenciesAndRejectedMoveAreAtomic() async throws {
        let e = try await boxes()
        try await e.execute("body.transform", ["body": "body-1", "translate": [2, 0, 0]])
        try await e.execute("body.transform", ["body": "body-1", "translate": [3, 0, 0]])
        let deps = try await e.execute("feature.dependencies", ["feature": "feature-4"]).result
        #expect(deps["parents"] == ["feature-3"])
        #expect(deps["ancestors"] == ["feature-1", "feature-3"])
        let reverse = try await e.execute("feature.dependencies", ["feature": "feature-1"]).result
        #expect(reverse["descendants"] == ["feature-3", "feature-4"])
        await #expect(throws: ForgeError.self) {
            try await e.execute("feature.reorder", ["feature": "feature-4", "before": "feature-3"])
        }
        #expect(await ids(e) == ["feature-1", "feature-2", "feature-3", "feature-4"])
        let bounds = try await e.activeDocument!.body("body-1").shape.boundingBox()
        #expect(abs(bounds.min.x - 5) < 1e-6)
        try await e.execute("edit.undo")
        #expect(await ids(e) == ["feature-1", "feature-2", "feature-3"])
    }

    @Test func sketchPlaneAndPatternParentsAreTracked() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("plane.create", ["reference": "front", "offset": 3])
        try await e.execute("sketch.create", ["plane": "Plane1"])
        try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [10, 10]]])
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 4])
        try await e.execute("pattern.linear", ["features": ["Boss-Extrude1"], "direction": "x", "spacing": 20, "count": 2])
        let deps = try await e.execute("feature.dependencies", ["feature": "LPattern1"]).result
        #expect(deps["ancestors"] == ["feature-1", "feature-2", "feature-3"])
        await #expect(throws: ForgeError.self) {
            try await e.execute("feature.reorder", ["feature": "Sketch1", "before": "Plane1"])
        }
        await #expect(throws: ForgeError.self) {
            try await e.execute("feature.reorder", ["feature": "Boss-Extrude1", "before": "Sketch1"])
        }
        try await e.execute("feature.rollback", ["before": "LPattern1"])
        await #expect(throws: ForgeError.self) {
            try await e.execute("feature.reorder", ["feature": "Sketch1"])
        }
        #expect(await e.activeDocument!.rollback == 3)
    }

    @Test func implicitScopeCannotGainNewBodiesByReordering() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("sketch.create", ["plane": "front"])
        try await e.execute("sketch.add_rectangle", ["points": [[0, 0], [10, 10]]])
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 10, "merge": true])
        try await e.execute("body.create_box", ["width": 5, "height": 5, "depth": 5, "origin": [50, 0, 0]])
        await #expect(throws: ForgeError.self) {
            try await e.execute("feature.reorder", ["feature": "Box1", "before": "Boss-Extrude1"])
        }
        #expect(await ids(e) == ["feature-1", "feature-2", "feature-3"])
        #expect(await e.activeDocument!.bodies.count == 2)
    }
}

@Suite("Explicit empty feature scope")
struct EmptyFeatureScopeHistoryTests {
    @Test func emptyScopeDoesNotDependOnOtherBodies() async throws {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 5, "height": 5, "depth": 5])
        try await e.execute("sketch.create", ["plane": "front"])
        try await e.execute("sketch.add_rectangle", ["points": [[20, 0], [30, 10]]])
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 10, "merge": true, "scope": []])
        let deps = try await e.execute("feature.dependencies", ["feature": "Boss-Extrude1"]).result
        #expect(deps["parents"] == ["feature-2"])
        try await e.execute("feature.reorder", ["feature": "Box1"])
        #expect(await e.activeDocument!.features.map(\.id) == ["feature-2", "feature-3", "feature-1"])
        #expect(await e.activeDocument!.bodyOrder.count == 2)
    }
}

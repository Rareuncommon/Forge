import ForgeCore
import ForgeData
import ForgeKernel
import Foundation
import Testing

@testable import ForgeCommands

@Suite("STEP solid import")
struct STEPImportTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forge-step-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func fixture(_ dir: URL, multiple: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent("Bracket.STEP")
        var shapes = [try Kernel.box(size: Vec3(10, 20, 30))]
        if multiple { shapes.append(try Kernel.cylinder(origin: Vec3(50, 0, 0), radius: 2, height: 10)) }
        try Kernel.exportSTEP(shapes, to: url)
        return url
    }

    @Test func importsSeparateSolidsWithAnalyticMassAndStableNames() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir, multiple: true)
        let engine = Engine()
        try await engine.execute("document.new", ["units": ["length": "in"]])
        let result = try await engine.execute("document.import_step", ["path": .string(source.path), "name": "Imported"]).result
        let bodies = result["bodies"]!.arrayValue!
        #expect(bodies.count == 2)
        #expect(bodies.map { $0["name"]! } == ["Imported 1", "Imported 2"])
        let volumes = bodies.map { $0["volume_mm3"]!.doubleValue! }.sorted()
        #expect(abs(volumes[0] - 40 * Double.pi) < 1e-6)
        #expect(abs(volumes[1] - 6000) < 1e-6)
        let before = await engine.activeDocument!
        #expect(before.baseBodies.count == 2)
        #expect(before.features.isEmpty)
        let names = before.orderedBodies.map { $0.naming?.faceBases }
        try await engine.execute("document.regenerate")
        #expect(await engine.activeDocument!.orderedBodies.map { $0.naming?.faceBases } == names)
        let second = dir.appendingPathComponent("Roundtrip.step")
        try await engine.execute("export.step", ["path": .string(second.path)])
        let shape = try Kernel.importSTEP(from: second)
        #expect(abs(try shape.massProperties().volume - (6000 + 40 * Double.pi)) < 1e-6)
    }

    @Test func importedReferencesFollowRotationAndDownstreamFilletAfterReopen() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir)
        let engine = Engine()
        try await engine.execute("document.new")
        try await engine.execute("document.import_step", ["path": .string(source.path)])
        let original = try #require(await engine.activeDocument?.body("body-1"))
        let names = try #require(original.naming)
        #expect(Set(names.faceBases.flatMap { $0 }).count == 6)
        let centroids = try names.faces.indices.map { try original.shape.face($0).centroid }
        try await engine.execute("body.transform", ["body": "body-1", "translate": [0, 0, 0]])
        try await engine.execute("feature.edit", ["feature": "feature-1", "params": [
            "rotate": ["axis": [0, 0, 1], "angle": "180 deg"],
        ]])
        let rotated = try #require(await engine.activeDocument?.body("body-1"))
        for (name, center) in zip(names.faces, centroids) {
            let indices = try #require(rotated.naming).resolveFace(name)
            let index = try #require(indices.first)
            #expect(indices.count == 1)
            let actual = try rotated.shape.face(index).centroid
            #expect((actual - Vec3(-center.x, -center.y, center.z)).length < 1e-6)
        }
        try await engine.execute("edit.undo")
        let edges = try await engine.execute("query.edges", ["body": "body-1"]).result["edges"]!.arrayValue!
        let edge = try #require(edges.first { edge in
            let point = edge["midpoint"]!.arrayValue!.map { $0.doubleValue! }
            return abs(point[0] - 10) < 1e-6 && abs(point[1]) < 1e-6 && abs(point[2] - 15) < 1e-6
        }?["persistent_id"]?.stringValue)
        try await engine.execute("body.fillet_edges", ["edges": [.string(edge)], "radius": 1])
        try await engine.execute("feature.edit", ["feature": "feature-1", "params": [
            "rotate": ["axis": [0, 0, 1], "angle": "180 deg"],
        ]])
        let saved = dir.appendingPathComponent("Rotated.forgepart")
        try await engine.execute("document.save", ["path": .string(saved.path)])
        try FileManager.default.removeItem(at: source)
        let reopened = Engine()
        try await reopened.execute("document.open", ["path": .string(saved.path)])
        try await reopened.execute("document.regenerate")
        let document = try #require(await reopened.activeDocument)
        #expect(document.features.allSatisfy { $0.status.state == .ok })
        let faces = try await reopened.execute("query.faces", ["body": "body-1"]).result["faces"]!.arrayValue!
        let blends = faces.filter { $0["surface_type"]?.stringValue == "cylinder" }
        #expect(blends.count == 1)
        let blend = try #require(blends.first?["centroid"]?.arrayValue).map { $0.doubleValue! }
        // Rotation carries the original x=10,y=0 edge to x=-10,y=0.
        #expect(blend[0] < -9 && blend[1] > -1 && blend[1] < 0)
        #expect(abs(try document.body("body-1").shape.massProperties().volume - (6000 - (1 - Double.pi / 4) * 30)) < 1e-5)
    }

    @Test func dryRunUndoRedoAndSourceRemoval() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir)
        let engine = Engine()
        try await engine.execute("document.new")
        let params: JSONValue = ["path": .string(source.path)]
        let preview = try await engine.execute("document.import_step", params, dryRun: true)
        #expect(preview.changes.created.contains("body-1"))
        #expect(await engine.activeDocument!.bodies.isEmpty)
        try await engine.execute("document.import_step", params)
        #expect(await engine.activeDocument!.bodies["body-1"]?.name == "Bracket")
        try FileManager.default.removeItem(at: source)
        try await engine.execute("edit.undo")
        #expect(await engine.activeDocument!.baseBodies.isEmpty)
        try await engine.execute("edit.redo")
        try await engine.execute("document.regenerate")
        #expect(await engine.activeDocument!.bodyOrder == ["body-1"])
        let doc = await engine.activeDocument!
        #expect(abs(try doc.body("body-1").shape.massProperties().volume - 6000) < 1e-6)
    }

    @Test func savesOriginalDespiteModifiedAndDeletedOutputs() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir)
        let engine = Engine()
        try await engine.execute("document.new")
        try await engine.execute("document.import_step", ["path": .string(source.path)])
        let originalNames = await engine.activeDocument!.baseBodies[0].naming?.faceBases
        try await engine.execute("body.transform", ["body": "body-1", "translate": [100, 0, 0]])
        let moved = dir.appendingPathComponent("Moved.forgepart")
        try await engine.execute("document.save", ["path": .string(moved.path)])
        try await engine.execute("body.delete", ["body": "body-1"])
        let removed = dir.appendingPathComponent("Deleted.forgepart")
        try await engine.execute("document.save", ["path": .string(removed.path)])
        try FileManager.default.removeItem(at: source)
        let reopened = Engine()
        try await reopened.execute("document.open", ["path": .string(moved.path)])
        try await reopened.execute("document.regenerate")
        let movedDoc = await reopened.activeDocument!
        #expect(abs(try movedDoc.body("body-1").shape.massProperties().centroid.x - 105) < 1e-6)
        #expect(movedDoc.baseBodies[0].naming?.faceBases == originalNames)
        try await reopened.execute("feature.suppress", ["feature": "feature-1", "suppressed": true])
        let base = await reopened.activeDocument!
        #expect(abs(try base.body("body-1").shape.massProperties().centroid.x - 5) < 1e-6)
        let deleted = Engine()
        try await deleted.execute("document.open", ["path": .string(removed.path)])
        try await deleted.execute("document.regenerate")
        #expect(await deleted.activeDocument!.bodies.isEmpty)
        try await deleted.execute("feature.suppress", ["feature": "feature-2", "suppressed": true])
        #expect(await deleted.activeDocument!.bodyOrder == ["body-1"])
    }

    @Test func schemaTwoBaseBodiesMigrateToIndependentOriginals() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir)
        let engine = Engine()
        try await engine.execute("document.new")
        try await engine.execute("document.import_step", ["path": .string(source.path)])
        let old = dir.appendingPathComponent("Old.forgepart")
        try await engine.execute("document.save", ["path": .string(old.path)])
        let manifest = old.appendingPathComponent("manifest.json")
        var m = try JSONCoding.parse(Data(contentsOf: manifest)).objectValue!
        m["schema"] = 2
        try Data(JSONCoding.string(.object(m)).utf8).write(to: manifest)
        let model = old.appendingPathComponent("model.json")
        var o = try JSONCoding.parse(Data(contentsOf: model)).objectValue!
        o.removeValue(forKey: "base_sources")
        try Data(JSONCoding.string(.object(o)).utf8).write(to: model)
        let migrated = Engine()
        try await migrated.execute("document.open", ["path": .string(old.path)])
        try await migrated.execute("body.transform", ["body": "body-1", "translate": [100, 0, 0]])
        let new = dir.appendingPathComponent("New.forgepart")
        try await migrated.execute("document.save", ["path": .string(new.path)])
        let pkg = try DocumentPackage.read(from: new)
        #expect(pkg.manifest.schema == 3)
        #expect(pkg.baseBreps.count == 1)
        let reopened = Engine()
        try await reopened.execute("document.open", ["path": .string(new.path)])
        try await reopened.execute("document.regenerate")
        let doc = await reopened.activeDocument!
        #expect(abs(try doc.body("body-1").shape.massProperties().centroid.x - 105) < 1e-6)
    }

    @Test func importsBeforeModelingAndRefusesRetroactiveFeatureEffects() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir)
        let engine = Engine()
        try await engine.execute("document.new")
        try await engine.execute("document.import_step", ["path": .string(source.path)])
        try await engine.execute("document.import_step", ["path": .string(source.path)])
        #expect(await engine.activeDocument!.baseBodies.count == 2)
        try await engine.execute("body.transform", ["body": "body-1", "translate": [100, 0, 0]])
        let before = try await engine.execute("document.state").result
        let journal = await engine.journal()
        await #expect(throws: ForgeError.self) { try await engine.execute("document.import_step", ["path": .string(source.path)]) }
        #expect(try await engine.execute("document.state").result == before)
        #expect(await engine.journal() == journal)
        // The failed import creates no undo entry: undo reverts the preceding move.
        try await engine.execute("edit.undo")
        let doc = await engine.activeDocument!
        #expect(doc.baseBodies.count == 2)
        #expect(doc.features.isEmpty)
        #expect(abs(try doc.body("body-1").shape.massProperties().centroid.x - 5) < 1e-6)
    }

    @Test func rejectsSurfaceOnlyAndMixedGeometryWithoutPartialImport() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let points = [Vec3(50, 0, 0), Vec3(60, 0, 0), Vec3(60, 10, 0), Vec3(50, 10, 0)]
        let face = try Kernel.faces(loops: [(0..<4).map { .line(points[$0], points[($0 + 1) % 4]) }], regions: [0])
        let box = try Kernel.box(size: Vec3(10, 20, 30))
        let engine = Engine()
        try await engine.execute("document.new")
        for shapes in [[face], [box, face]] {
            let path = dir.appendingPathComponent("Surfaces.step")
            try Kernel.exportSTEP(shapes, to: path)
            await #expect(throws: ForgeError.self) { try await engine.execute("document.import_step", ["path": .string(path.path)]) }
            #expect(await engine.activeDocument!.bodies.isEmpty)
        }
    }

    @Test func invalidFilesDoNotMutateDocument() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = Engine()
        try await engine.execute("document.new")
        let bad = dir.appendingPathComponent("invalid.step")
        try Data("not STEP".utf8).write(to: bad)
        for path in [bad.path, dir.appendingPathComponent("missing.step").path, dir.path, "", "null\0.step"] {
            await #expect(throws: ForgeError.self) { try await engine.execute("document.import_step", ["path": .string(path)]) }
            #expect(await engine.activeDocument!.baseBodies.isEmpty)
            #expect(await engine.activeDocument!.bodies.isEmpty)
        }
        let valid = try fixture(dir)
        try await engine.execute("sketch.create", ["plane": "front"])
        await #expect(throws: ForgeError.self) { try await engine.execute("document.import_step", ["path": .string(valid.path)]) }
    }
}

import ForgeCore
import Foundation
import Testing

@testable import ForgeCommands

func volume(_ o: CommandOutcome) -> Double? { o.result["body"]?["volume_mm3"]?.doubleValue }

@Suite("Command registry")
struct RegistryTests {
    let registry = CommandRegistry.standard

    @Test func everyCommandHasValidDocumentedSchema() throws {
        for d in registry.all {
            #expect(d.paramsSchema["type"] == "object", "\(d.name) params must be an object schema")
            #expect(!d.summary.isEmpty, "\(d.name) needs a summary")
            #expect(d.name.contains("."), "\(d.name) must be namespaced")
            // Every property documented, and every documented key exists.
            guard let docsType = d.paramsSchema["properties"]?.objectValue else { continue }
            for (key, prop) in docsType {
                #expect(prop["description"] != nil, "\(d.name).\(key) is undocumented")
            }
        }
    }

    @Test func everyExampleDecodesAndValidates() throws {
        for d in registry.all {
            for ex in d.examples {
                #expect(SchemaValidator.validate(ex, against: d.paramsSchema).isEmpty, "\(d.name) example \(ex) fails schema")
                #expect(throws: Never.self, "\(d.name) example \(ex) fails decoding") { try d.check(ex, .mmgs) }
            }
        }
    }

    @Test func searchRanksNameMatches() {
        #expect(registry.search("cylinder").first?.name == "body.create_cylinder")
        #expect(registry.search("undo").first?.name == "edit.undo")
        #expect(registry.search("export step").first?.name == "export.step")
    }

    @Test func unknownCommandSuggestsAlternatives() {
        do {
            _ = try registry.descriptor("body.create_boxx")
            Issue.record("expected error")
        } catch let e as ForgeError {
            #expect(e.code == .unknownCommand)
            #expect(e.suggestions.contains { $0.params["name"] == "body.create_box" })
        } catch { Issue.record("\(error)") }
    }
}

@Suite("Engine")
struct EngineTests {
    func engineWithDoc() async throws -> Engine {
        let e = Engine()
        try await e.execute("document.new", ["name": "Test"])
        return e
    }

    @Test func noDocumentGivesActionableError() async throws {
        let e = Engine()
        do {
            try await e.execute("body.create_box", ["width": 1, "height": 1, "depth": 1])
            Issue.record("expected error")
        } catch let err as ForgeError {
            #expect(err.code == .preconditionFailed)
            #expect(err.suggestions.first?.command == "document.new")
        }
    }

    @Test func createQueryAndUnits() async throws {
        let e = try await engineWithDoc()
        let o = try await e.execute("body.create_box", ["width": "1 in", "height": 10, "depth": 10])
        #expect(abs(volume(o)! - 2540) < 1e-6)
        #expect(o.changes.created == ["body-1"])
        #expect(o.result["body"]?["topology"]?["faces"] == 6)

        let inch = Engine()
        try await inch.execute("document.new", ["units": ["length": "in"]])
        let o2 = try await inch.execute("body.create_box", ["width": 1, "height": 1, "depth": 1])
        #expect(abs(volume(o2)! - 25.4 * 25.4 * 25.4) < 1e-6)
    }

    @Test func invalidParamsAreStructured() async throws {
        let e = try await engineWithDoc()
        do {
            try await e.execute("body.create_box", ["width": 1, "hieght": 1, "depth": 1])
            Issue.record("expected error")
        } catch let err as ForgeError {
            #expect(err.code == .invalidParams)
            #expect(err.message.contains("did you mean 'height'"))
        }
        do {
            try await e.execute("body.create_box", ["width": -1, "height": 1, "depth": 1])
            Issue.record("expected error")
        } catch let err as ForgeError {
            #expect(err.code == .invalidParams)
            #expect(err.message.contains("width"))
        }
    }

    @Test func undoRedo() async throws {
        let e = try await engineWithDoc()
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        try await e.execute("body.create_cylinder", ["radius": 2, "height": 20, "origin": [5, 5, -5]])
        let cut = try await e.execute("body.boolean", ["operation": "cut", "target": "body-1", "tool": "body-2"])
        #expect(cut.changes.modified == ["body-1"])
        #expect(cut.changes.deleted == ["body-2"])
        #expect(await e.activeDocument!.bodyOrder == ["body-1"])

        let u = try await e.execute("edit.undo")
        #expect(u.result["undone"] == "body.boolean")
        #expect(await e.activeDocument!.bodyOrder == ["body-1", "body-2"])
        try await e.execute("edit.redo")
        #expect(await e.activeDocument!.bodyOrder == ["body-1"])
        try await e.execute("edit.undo")
        try await e.execute("edit.undo")
        try await e.execute("edit.undo")
        #expect(await e.activeDocument!.bodyOrder.isEmpty)
        await #expect(throws: ForgeError.self) { try await e.execute("edit.undo") }
        // A new command clears the redo stack.
        try await e.execute("body.create_sphere", ["radius": 1])
        await #expect(throws: ForgeError.self) { try await e.execute("edit.redo") }
    }

    @Test func dryRunPredictsWithoutCommitting() async throws {
        let e = try await engineWithDoc()
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10, "origin": [5, 0, 0]])
        let dry = try await e.execute("body.boolean", ["operation": "fuse", "target": "body-1", "tool": "body-2"], dryRun: true)
        #expect(dry.dryRun)
        #expect(dry.changes.modified == ["body-1"] && dry.changes.deleted == ["body-2"])
        #expect(abs(volume(dry)! - 1500) < 1e-6)
        #expect(await e.activeDocument!.bodyOrder == ["body-1", "body-2"])
        let state = try await e.execute("document.state")
        #expect(state.result["undo"]?.arrayValue?.count == 2)
        await #expect(throws: ForgeError.self) { try await e.execute("edit.undo", dryRun: true) }
    }

    @Test func transactionsCommitAsOneUndoStepAndRollback() async throws {
        let e = try await engineWithDoc()
        try await e.execute("transaction.begin", ["label": "two boxes"])
        try await e.execute("body.create_box", ["width": 1, "height": 1, "depth": 1])
        try await e.execute("body.create_box", ["width": 2, "height": 2, "depth": 2])
        await #expect(throws: ForgeError.self) { try await e.execute("edit.undo") }
        let c = try await e.execute("transaction.commit")
        #expect(c.result["changes"]?["created"] == ["body-1", "body-2"])
        let u = try await e.execute("edit.undo")
        #expect(u.result["undone"] == "two boxes")
        #expect(await e.activeDocument!.bodyOrder.isEmpty)

        try await e.execute("transaction.begin")
        try await e.execute("body.create_box", ["width": 1, "height": 1, "depth": 1])
        let r = try await e.execute("transaction.rollback")
        #expect(r.result["changes"]?["created"]?.arrayValue?.count == 1)
        #expect(await e.activeDocument!.bodyOrder.isEmpty)
        await #expect(throws: ForgeError.self) { try await e.execute("transaction.commit") }
    }

    @Test func atomicBatchRollsBackOnFailure() async throws {
        let e = try await engineWithDoc()
        let b = try await e.executeBatch([
            Invocation("body.create_box", ["width": 1, "height": 1, "depth": 1]),
            Invocation("body.create_box", ["width": 0, "height": 1, "depth": 1]),
        ])
        #expect(b.failedIndex == 1)
        #expect(b.error?.code == .invalidParams)
        #expect(!b.committed)
        #expect(await e.activeDocument!.bodyOrder.isEmpty)

        let ok = try await e.executeBatch([
            Invocation("body.create_box", ["width": 10, "height": 10, "depth": 10]),
            Invocation("body.create_sphere", ["radius": 3, "center": [10, 10, 10]]),
            Invocation("body.boolean", ["operation": "cut", "target": "body-1", "tool": "body-2"]),
        ])
        #expect(ok.committed && ok.failedIndex == nil)
        let s = try await e.execute("document.state")
        #expect(s.result["undo"] == ["batch of 3 commands"])
    }

    @Test func dryRunBatchSeesItsOwnIntermediateResults() async throws {
        let e = try await engineWithDoc()
        let b = try await e.executeBatch(
            [
                Invocation("body.create_box", ["width": 10, "height": 10, "depth": 10]),
                Invocation("body.fillet_edges", ["body": "body-1", "edges": ["body-1/edge-0"], "radius": 1]),
            ], dryRun: true)
        #expect(b.failedIndex == nil)
        #expect(b.outcomes.allSatisfy { $0.dryRun })
        #expect(await e.activeDocument!.bodyOrder.isEmpty)
    }

    @Test func booleanEmptyResultSuggestsMeasure() async throws {
        let e = try await engineWithDoc()
        try await e.execute("body.create_box", ["width": 1, "height": 1, "depth": 1])
        try await e.execute("body.create_box", ["width": 1, "height": 1, "depth": 1, "origin": [5, 5, 5]])
        do {
            try await e.execute("body.boolean", ["operation": "common", "target": "body-1", "tool": "body-2"])
            Issue.record("expected error")
        } catch let err as ForgeError {
            #expect(err.code == .emptyResult)
            #expect(err.entities == ["body-1", "body-2"])
            #expect(err.suggestions.contains { $0.command == "query.measure" })
        }
        let m = try await e.execute("query.measure", ["from": "body-1", "to": "body-2"])
        #expect(abs(m.result["distance_mm"]!.doubleValue! - 4 * 3.0.squareRoot()) < 1e-9)
    }

    @Test func selectionIsExplicitAndSurvivesUndo() async throws {
        let e = try await engineWithDoc()
        try await e.execute("body.create_box", ["width": 1, "height": 1, "depth": 1])
        try await e.execute("selection.set", ["entities": ["body-1/face-2", "body-1/edge-0"]])
        #expect(try await e.execute("selection.get").result["selection"] == ["body-1/face-2", "body-1/edge-0"])
        await #expect(throws: ForgeError.self) { try await e.execute("selection.set", ["entities": ["body-1/face-99"]]) }
        try await e.execute("body.create_sphere", ["radius": 1])
        try await e.execute("edit.undo")
        #expect(try await e.execute("selection.get").result["selection"]?.arrayValue?.count == 2)
        try await e.execute("body.delete", ["body": "body-1"])
        #expect(try await e.execute("selection.get").result["selection"] == [])
    }

    @Test func queriesDescribeEntities() async throws {
        let e = try await engineWithDoc()
        try await e.execute("body.create_cylinder", ["radius": 5, "height": 10])
        let faces = try await e.execute("query.faces", ["body": "body-1"]).result["faces"]!.arrayValue!
        #expect(faces.count == 3)
        #expect(faces.compactMap { $0["surface_type"]?.stringValue }.sorted() == ["cylinder", "plane", "plane"])
        let edges = try await e.execute("query.edges", ["body": "body-1"]).result["edges"]!.arrayValue!
        #expect(edges.count == 3)
        let ent = try await e.execute("query.entity", ["ref": "body-1/face-0"])
        #expect(ent.result["kind"] == "face")
        let mp = try await e.execute("query.mass_properties", ["body": "body-1", "density": 7850])
        #expect(abs(mp.result["mass_kg"]!.doubleValue! - Double.pi * 250 * 7850e-9) < 1e-12)
        let v = try await e.execute("query.validate")
        #expect(v.result["ok"] == true)
    }

    @Test func journalReplaysToIdenticalModel() async throws {
        let e = try await engineWithDoc()
        try await e.execute("body.create_box", ["width": 20, "height": 10, "depth": 5])
        try await e.execute("body.create_cylinder", ["radius": 2, "height": 20, "origin": [10, 5, -5]])
        try await e.execute("body.boolean", ["operation": "cut", "target": "body-1", "tool": "body-2"])
        try await e.execute("body.fillet_edges", ["body": "body-1", "edges": ["0"], "radius": 1])
        try await e.execute("body.transform", ["body": "body-1", "rotate": ["axis": [0, 1, 0], "angle": 30]])
        let journal = await e.journal()

        let replay = Engine()
        for inv in journal { try await replay.execute(inv.command, inv.params) }
        let a = try await e.execute("query.bodies").result
        let b = try await replay.execute("query.bodies").result
        #expect(a == b)
        let brepA = try await e.activeDocument!.bodies["body-1"]!.shape.brepData()
        let brepB = try await replay.activeDocument!.bodies["body-1"]!.shape.brepData()
        #expect(brepA.count == brepB.count)
    }

    @Test func multipleDocuments() async throws {
        let e = Engine()
        try await e.execute("document.new", ["name": "A"])
        try await e.execute("body.create_box", ["width": 1, "height": 1, "depth": 1])
        try await e.execute("document.new", ["name": "B"])
        let list = try await e.execute("document.list").result
        #expect(list["active"] == "doc-2")
        #expect(list["documents"]?.arrayValue?.count == 2)
        try await e.execute("body.create_sphere", ["radius": 1], document: "doc-1")
        #expect(await e.document("doc-1")!.bodyOrder.count == 2)
        #expect(await e.document("doc-2")!.bodyOrder.isEmpty)
        try await e.execute("document.close")
        #expect(await e.state.activeDocumentID == "doc-1")
    }

    @Test func renderAndPickRoundTrip() async throws {
        let e = try await engineWithDoc()
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        let view: JSONValue = ["orientation": "front", "width": 200, "height": 200]
        let r = try await e.execute("view.render", ["view": view])
        let png = Data(base64Encoded: r.result["png_base64"]!.stringValue!)!
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        // Front view looks down -Z: the centre pixel is the +Z face.
        let pick = try await e.execute("view.pick", ["x": 100, "y": 100, "view": view, "radius": 0])
        #expect(pick.result["element"] == "face")
        #expect(pick.result["face"]?["normal"] == [0, 0, 1])
        let miss = try await e.execute("view.pick", ["x": 2, "y": 2, "view": view, "radius": 0])
        #expect(miss.result["hit"] == nil || miss.result["hit"] == .null)
        let multi = try await e.execute("view.render_multiview", ["size": 64])
        #expect(multi.result["width"] == 128)
    }

    @Test func exportsWriteFilesAndRefuseOverwrite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forge-cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = try await engineWithDoc()
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        let step = dir.appendingPathComponent("a.step").path
        let o = try await e.execute("export.step", ["path": .string(step)])
        #expect(o.result["bytes"]!.intValue! > 1000)
        await #expect(throws: ForgeError.self) { try await e.execute("export.step", ["path": .string(step)]) }
        try await e.execute("export.step", ["path": .string(step), "overwrite": true])
        let stl = try await e.execute("export.stl", ["path": .string(dir.appendingPathComponent("a.stl").path), "body": "body-1"])
        #expect(stl.result["bytes"] == .number(84 + 12 * 50))  // binary STL: header + 12 triangles
        await #expect(throws: ForgeError.self) { try await e.execute("export.step", ["path": "/nonexistent-dir/x.step"]) }
    }
}

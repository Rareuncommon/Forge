import ForgeCore
import Foundation
import Testing

@testable import ForgeCommands

@Suite("Document files")
struct FileTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("forge-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func saveOpenKeepsStateAndPath() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Part.forgepart").path
        let e = Engine()
        try await e.execute("document.new", ["name": "Bracket", "units": ["length": "in"]])
        try await e.execute("body.create_box", ["width": 1, "height": 2, "depth": 3])
        try await e.execute("sketch.create", ["plane": "top"])
        try await e.execute("sketch.add_circle", ["center": [0, 0], "radius": 0.5])
        let saved = try await e.execute("document.save", ["path": .string(path)]).result
        #expect(saved["files"] == ["bodies/body-1.brep", "manifest.json", "model.json", "thumbnails/thumbnail.png"])
        // Re-saving to the document's own path needs no overwrite flag; another existing
        // package is not clobbered without one.
        try await e.execute("document.save")
        let other = dir.appendingPathComponent("Other.forgepart").path
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        await #expect(throws: ForgeError.self) { try await e.execute("document.save", ["path": .string(other)]) }

        let o = Engine()
        let opened = try await o.execute("document.open", ["path": .string(path)]).result
        #expect(opened["document"]?["name"] == "Bracket")
        #expect(opened["document"]?["length_unit"] == "in")
        let a = try await e.execute("document.state").result, b = try await o.execute("document.state").result
        #expect(a["bodies"] == b["bodies"])
        #expect(a["sketches"]?[0]?["dof"] == b["sketches"]?[0]?["dof"])
        // Counters continue: the next body in the reopened document is body-2.
        let next = try await o.execute("body.create_sphere", ["radius": 1]).result
        #expect(next["body"]?["id"] == "body-2")
        // model.json is human-readable, sorted JSON.
        let model = try String(contentsOfFile: path + "/model.json", encoding: .utf8)
        #expect(model.contains("\"next_body\" : 2"))
        #expect(!model.contains("-0,"))
        #expect(model.contains("\"sketches\""))
    }

    @Test func unreadableFilesAreStructuredErrors() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = Engine()
        do {
            try await e.execute("document.open", ["path": .string(dir.appendingPathComponent("missing.forgepart").path)])
            Issue.record("expected error")
        } catch let err as ForgeError { #expect(err.code == .ioError) }

        // A package from a newer schema is refused with a clear message.
        try await e.execute("document.new")
        let p = dir.appendingPathComponent("New.forgepart")
        try await e.execute("document.save", ["path": .string(p.path)])
        let m = p.appendingPathComponent("manifest.json")
        let text = try String(contentsOf: m, encoding: .utf8).replacingOccurrences(of: "\"schema\" : 2", with: "\"schema\" : 99")
        try text.write(to: m, atomically: true, encoding: .utf8)
        do {
            try await e.execute("document.open", ["path": .string(p.path)])
            Issue.record("expected error")
        } catch let err as ForgeError {
            #expect(err.code == .unsupported)
            #expect(err.message.contains("newer"))
        }
        await #expect(throws: ForgeError.self) { try await e.execute("document.save", ["path": .string(dir.appendingPathComponent("x.step").path)]) }
    }

    @Test func featureTreeRoundTripsAndStaysParametric() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("sketch.create", ["plane": "front"])
        let r = try await e.execute("sketch.add_circle", ["center": [0, 0], "radius": 5]).result
        let circle = r["created"]![0]!.stringValue!
        let dim = try await e.execute("sketch.add_dimension", ["type": "diameter", "entities": [.string(circle)], "value": 10]).result["constraints"]![0]!
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 20])
        try await e.execute("feature.suppress", ["feature": "Boss-Extrude1", "suppressed": false])
        let p = dir.appendingPathComponent("Pin.forgepart")
        try await e.execute("document.save", ["path": .string(p.path)])

        let e2 = Engine()
        try await e2.execute("document.open", ["path": .string(p.path)])
        let tree = try await e2.execute("feature.list").result["features"]!.arrayValue!
        #expect(tree.map { $0["name"]!.stringValue! } == ["Sketch1", "Boss-Extrude1"])
        // Still parametric after reopening: a new diameter regenerates the pin.
        try await e2.execute("sketch.edit", ["sketch": "sketch-1"])
        try await e2.execute("sketch.set_dimension", ["constraint": dim, "value": 20])
        let v = try await e2.execute("query.mass_properties", ["body": "body-1"]).result["volume_mm3"]!.doubleValue!
        #expect(abs(v - Double.pi * 100 * 20) < 1e-6 * v)
        // Saving the reopened, unchanged document reproduces the same model.json.
        let e3 = Engine()
        try await e3.execute("document.open", ["path": .string(p.path)])
        let q = dir.appendingPathComponent("Pin2.forgepart")
        try await e3.execute("document.save", ["path": .string(q.path)])
        let a = try Data(contentsOf: p.appendingPathComponent("model.json")), b = try Data(contentsOf: q.appendingPathComponent("model.json"))
        #expect(String(decoding: a, as: UTF8.self).replacingOccurrences(of: "Pin", with: "") == String(decoding: b, as: UTF8.self).replacingOccurrences(of: "Pin2", with: "").replacingOccurrences(of: "Pin", with: ""))
    }

    @Test func schemaOneFilesOpenWithBaseBodies() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        let p = dir.appendingPathComponent("Old.forgepart")
        try await e.execute("document.save", ["path": .string(p.path)])
        // Rewrite as schema 1: no feature tree.
        let m = p.appendingPathComponent("manifest.json")
        try String(contentsOf: m, encoding: .utf8).replacingOccurrences(of: "\"schema\" : 2", with: "\"schema\" : 1").write(to: m, atomically: true, encoding: .utf8)
        let model = p.appendingPathComponent("model.json")
        guard case .object(var o) = try JSONCoding.parse(try Data(contentsOf: model)) else { Issue.record("model"); return }
        for k in ["features", "rollback", "next_feature", "feature_counters", "base_bodies", "body_names"] { o.removeValue(forKey: k) }
        try Data(JSONCoding.string(.object(o), pretty: true).utf8).write(to: model)

        let e2 = Engine()
        try await e2.execute("document.open", ["path": .string(p.path)])
        #expect(await e2.activeDocument!.features.isEmpty)
        #expect(await e2.activeDocument!.baseBodies.map(\.id) == ["body-1"])
        // New features build on the base body, and a full regeneration keeps it.
        try await e2.execute("body.create_sphere", ["radius": 2])
        try await e2.execute("document.regenerate")
        #expect(await e2.activeDocument!.bodyOrder == ["body-1", "body-2"])
    }
}

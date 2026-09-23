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
        let text = try String(contentsOf: m, encoding: .utf8).replacingOccurrences(of: "\"schema\" : 1", with: "\"schema\" : 99")
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
}

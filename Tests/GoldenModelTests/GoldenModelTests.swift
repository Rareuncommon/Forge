import ForgeCommands
import ForgeCore
import Foundation
import Testing

/// Golden models (SPEC §9): command scripts with analytically derived expectations for
/// volume, surface area, centroid, bounding box and topology. Each is also regenerated twice
/// to check bit-for-bit deterministic geometry.
@Suite("Golden models")
struct GoldenModelTests {
    static let modelURLs: [URL] = {
        guard let dir = Bundle.module.url(forResource: "Models", withExtension: nil) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    @Test func suiteIsNotEmpty() {
        #expect(Self.modelURLs.count >= 10)
    }

    @Test(arguments: modelURLs)
    func modelMatchesSpec(_ url: URL) async throws {
        let script = try ForgeScript.load(url)
        #expect(script.expect != nil, "\(url.lastPathComponent) has no expectations")
        let result = try await Engine().run(script)
        let report = try #require(result.report)
        for c in report.checks where !c.passed {
            Issue.record("\(url.lastPathComponent): \(c.subject).\(c.property) expected \(c.expected) got \(c.actual)")
        }
        #expect(report.passed)
        #expect(report.checks.count >= 3)
    }

    @Test(arguments: modelURLs)
    func regenerationIsDeterministic(_ url: URL) async throws {
        let script = try ForgeScript.load(url)
        func build() async throws -> [String: Data] {
            let e = Engine()
            _ = try await e.run(script)
            let doc = try #require(await e.activeDocument)
            var out: [String: Data] = [:]
            for b in doc.orderedBodies { out[b.id] = try b.shape.brepData() }
            for sk in doc.orderedSketches {
                out[sk.id] = sk.params.withUnsafeBufferPointer { Data(buffer: $0) }
            }
            return out
        }
        let a = try await build(), b = try await build()
        #expect(a.keys.sorted() == b.keys.sorted())
        for k in a.keys { #expect(a[k] == b[k], "\(url.lastPathComponent) \(k) differs between regenerations") }
    }

    /// Save → open in a fresh engine → spec still passes → save again gives identical bytes.
    @Test(arguments: modelURLs)
    func saveOpenRoundTrip(_ url: URL) async throws {
        let script = try ForgeScript.load(url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forge-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("a.forgepart"), second = dir.appendingPathComponent("b.forgepart")

        let e = Engine()
        _ = try await e.run(script)
        try await e.execute("document.save", ["path": .string(first.path)])

        let reopened = Engine()
        try await reopened.execute("document.open", ["path": .string(first.path)])
        if let spec = script.expect {
            let report = try QueryCompareToSpec.evaluate(spec, document: try #require(await reopened.activeDocument))
            for c in report.checks where !c.passed {
                Issue.record("\(url.lastPathComponent) after reopen: \(c.subject).\(c.property) expected \(c.expected) got \(c.actual)")
            }
        }
        try await reopened.execute("document.save", ["path": .string(second.path)])
        func files(_ root: URL) throws -> [String: Data] {
            var out: [String: Data] = [:]
            let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            for case let f as URL in en where !f.hasDirectoryPath {
                out[String(f.path.dropFirst(root.path.count))] = try Data(contentsOf: f)
            }
            return out
        }
        let a = try files(first), b = try files(second)
        #expect(a.keys.sorted() == b.keys.sorted())
        for k in a.keys where a[k] != b[k] { Issue.record("\(url.lastPathComponent): \(k) differs after save → open → save") }
    }
}

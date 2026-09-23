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
}

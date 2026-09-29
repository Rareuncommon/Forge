import ForgeCore
import ForgeData
import Foundation
import Testing

@Suite("Document package validation")
struct PackageValidationTests {
    func package() -> DocumentPackage {
        DocumentPackage(
            manifest: .init(app: "test", kernel: "test"),
            model: .init(name: "Test", units: .mmgs,
                         bodies: [.init(id: "body-1", name: "Body", producedBy: "test", brep: "bodies/body-1.brep")],
                         sketches: [], nextBody: 2, nextSketch: 1),
            breps: ["body-1": Data("fixture".utf8)], thumbnailPNG: nil)
    }

    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forge-package-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func replaceJSON(_ value: JSONValue, at url: URL) throws {
        try Data(JSONCoding.string(value).utf8).write(to: url)
    }

    @Test func rejectsUnsafePayloadPathsOnReadAndWrite() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Test.forgepart")
        try package().write(to: url, overwrite: false)
        for path in ["../outside.brep", "/tmp/outside.brep", "bodies/../../outside.brep", "bodies/../outside.brep",
                     "bodies//body.brep", "bodies/./body.brep", "bodies\\outside.brep", "bodies/C:outside.brep",
                     "bodies/body\0.brep", "manifest.json"] {
            var pkg = package()
            pkg.model.bodies[0].brep = path
            #expect(throws: ForgeError.self) { try pkg.files() }
            try replaceJSON(JSONCoding.toJSON(pkg.model), at: url.appendingPathComponent("model.json"))
            #expect(throws: ForgeError.self) { try DocumentPackage.read(from: url) }
        }
    }

    @Test func validatesOriginalBasePayloads() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Base.forgepart")
        var pkg = package()
        pkg.model.baseBodies = ["body-1"]
        pkg.model.baseSources = [.init(id: "body-1", name: "Base", producedBy: "document.import_step", brep: "bodies/base/body-1.brep")]
        pkg.baseBreps = ["body-1": Data("original".utf8)]
        try pkg.write(to: url, overwrite: false)
        #expect(try DocumentPackage.read(from: url) == pkg)
        var invalid = pkg
        invalid.model.baseSources![0].brep = "bodies/../../outside.brep"
        #expect(throws: ForgeError.self) { try invalid.files() }
        try replaceJSON(JSONCoding.toJSON(invalid.model), at: url.appendingPathComponent("model.json"))
        #expect(throws: ForgeError.self) { try DocumentPackage.read(from: url) }
        invalid = pkg
        invalid.model.baseSources!.append(invalid.model.baseSources![0])
        #expect(throws: ForgeError.self) { try invalid.files() }
        try replaceJSON(JSONCoding.toJSON(invalid.model), at: url.appendingPathComponent("model.json"))
        #expect(throws: ForgeError.self) { try DocumentPackage.read(from: url) }
        try replaceJSON(JSONCoding.toJSON(pkg.model), at: url.appendingPathComponent("model.json"))
        try FileManager.default.removeItem(at: url.appendingPathComponent("bodies/base/body-1.brep"))
        #expect(throws: ForgeError.self) { try DocumentPackage.read(from: url) }
    }

    @Test func rejectsInvalidSchemaVersionsWithoutCrashing() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Test.forgepart")
        try package().write(to: url, overwrite: false)
        let manifest = try JSONCoding.toJSON(package().manifest).objectValue!
        for version in [JSONValue.number(0), -1, 1.5, 1e100, .number(Double(DocumentPackage.currentSchema + 1))] {
            var modified = manifest
            modified["schema"] = version
            try replaceJSON(.object(modified), at: url.appendingPathComponent("manifest.json"))
            #expect(throws: ForgeError.self) { try DocumentPackage.read(from: url) }
        }
    }

    @Test func rejectsDuplicateBodyIDsAndPaths() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Test.forgepart")
        try package().write(to: url, overwrite: false)
        for duplicateID in [true, false] {
            var pkg = package()
            var record = pkg.model.bodies[0]
            if duplicateID { record.brep = "bodies/other.brep" } else { record.id = "body-2" }
            pkg.model.bodies.append(record)
            pkg.breps[record.id] = Data("fixture".utf8)
            #expect(throws: ForgeError.self) { try pkg.files() }
            try replaceJSON(JSONCoding.toJSON(pkg.model), at: url.appendingPathComponent("model.json"))
            #expect(throws: ForgeError.self) { try DocumentPackage.read(from: url) }
        }
    }

    #if !os(Windows)
    @Test func doesNotReadSymlinksOutsidePackage() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Test.forgepart")
        let external = dir.appendingPathComponent("external")
        try Data("outside".utf8).write(to: external)
        try package().write(to: url, overwrite: false)
        let thumbnail = url.appendingPathComponent("thumbnails/thumbnail.png")
        try FileManager.default.createDirectory(at: thumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: thumbnail, withDestinationURL: external)
        #expect(try DocumentPackage.read(from: url).thumbnailPNG == nil)
        let body = url.appendingPathComponent("bodies/body-1.brep")
        try FileManager.default.removeItem(at: body)
        try FileManager.default.createSymbolicLink(at: body, withDestinationURL: external)
        #expect(throws: ForgeError.self) { try DocumentPackage.read(from: url) }
    }
    #endif
}

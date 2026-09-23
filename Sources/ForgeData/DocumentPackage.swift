import ForgeCore
import ForgeSketch
import Foundation

/// On-disk document package (docs/adr/0004-file-format.md):
///
///     Name.forgepart/
///       manifest.json          format, schema version, kind, app/kernel versions, units
///       model.json             authoritative, human-diffable document content
///       bodies/<id>.brep       canonical binary BREP of direct (non-feature) bodies
///       thumbnails/thumbnail.png
///
/// JSON is written with sorted keys and 2-space indentation, and BREP is canonical, so saving
/// an unchanged document reproduces identical bytes (git- and PDM-friendly).
public struct DocumentPackage: Sendable, Equatable {
    public static let currentSchema = 1
    public static let formatName = "forge-document"

    public var manifest: Manifest
    public var model: Model
    /// BREP bytes by body id.
    public var breps: [String: Data]
    public var thumbnailPNG: Data?

    public init(manifest: Manifest, model: Model, breps: [String: Data], thumbnailPNG: Data?) {
        self.manifest = manifest
        self.model = model
        self.breps = breps
        self.thumbnailPNG = thumbnailPNG
    }

    public struct Manifest: Codable, Sendable, Equatable {
        public var format: String
        public var schema: Int
        public var kind: String
        public var app: String
        public var kernel: String

        public init(kind: String = "part", app: String, kernel: String) {
            format = DocumentPackage.formatName
            schema = DocumentPackage.currentSchema
            self.kind = kind
            self.app = app
            self.kernel = kernel
        }
    }

    public struct BodyRecord: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var producedBy: String
        public var brep: String

        public init(id: String, name: String, producedBy: String, brep: String) {
            self.id = id
            self.name = name
            self.producedBy = producedBy
            self.brep = brep
        }

        enum CodingKeys: String, CodingKey {
            case id, name, brep
            case producedBy = "produced_by"
        }
    }

    public struct Model: Codable, Sendable, Equatable {
        public var name: String
        public var units: UnitSystem
        public var bodies: [BodyRecord]
        public var sketches: [Sketch]
        public var nextBody: Int
        public var nextSketch: Int

        public init(name: String, units: UnitSystem, bodies: [BodyRecord], sketches: [Sketch], nextBody: Int, nextSketch: Int) {
            self.name = name
            self.units = units
            self.bodies = bodies
            self.sketches = sketches
            self.nextBody = nextBody
            self.nextSketch = nextSketch
        }

        enum CodingKeys: String, CodingKey {
            case name, units, bodies, sketches
            case nextBody = "next_body"
            case nextSketch = "next_sketch"
        }
    }

    // MARK: writing

    /// Canonical JSON: via JSONValue so integral numbers (including -0) are written as
    /// integers, keys sorted, 2-space indentation, trailing newline.
    static func json<T: Encodable>(_ value: T) throws -> Data {
        var d = Data(JSONCoding.string(try JSONCoding.toJSON(value), pretty: true).utf8)
        d.append(0x0A)
        return d
    }

    /// The files of the package, by relative path (deterministic content).
    public func files() throws -> [String: Data] {
        var out: [String: Data] = [
            "manifest.json": try Self.json(manifest),
            "model.json": try Self.json(model),
        ]
        for b in model.bodies {
            guard let data = breps[b.id] else { throw ForgeError(.internalError, "missing BREP for \(b.id)") }
            out[b.brep] = data
        }
        if let t = thumbnailPNG { out["thumbnails/thumbnail.png"] = t }
        return out
    }

    /// Write atomically: build a sibling temporary package, then swap it into place.
    public func write(to url: URL, overwrite: Bool) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) && !overwrite {
            throw ForgeError(.ioError, "'\(url.path)' exists; pass overwrite: true to replace it", entities: [url.path])
        }
        let parent = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            throw ForgeError(.ioError, "directory '\(parent.path)' does not exist")
        }
        let tmp = parent.appendingPathComponent(".\(url.lastPathComponent).saving-\(UUID().uuidString)")
        do {
            for (path, data) in try files() {
                let f = tmp.appendingPathComponent(path)
                try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: f)
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch let e as ForgeError {
            try? fm.removeItem(at: tmp)
            throw e
        } catch {
            try? fm.removeItem(at: tmp)
            throw ForgeError(.ioError, "could not write \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: reading

    public static func read(from url: URL) throws -> DocumentPackage {
        func load(_ rel: String) throws -> Data {
            let f = url.appendingPathComponent(rel)
            do { return try Data(contentsOf: f) } catch {
                throw ForgeError(.ioError, "\(url.lastPathComponent) is missing \(rel)", entities: [url.path])
            }
        }
        let manifestJSON = try JSONCoding.parse(try load("manifest.json"))
        guard manifestJSON["format"]?.stringValue == formatName else {
            throw ForgeError(.ioError, "\(url.path) is not a Forge document")
        }
        guard let schema = manifestJSON["schema"]?.intValue else { throw ForgeError(.ioError, "manifest has no schema version") }
        guard schema <= currentSchema else {
            throw ForgeError(
                .unsupported, "\(url.lastPathComponent) was written by a newer Forge (schema \(schema); this build reads up to \(currentSchema))")
        }
        var modelJSON = try JSONCoding.parse(try load("model.json"))
        // Forward migration, one schema step at a time (docs/adr/0004).
        var version = schema
        while version < currentSchema {
            modelJSON = try Migrations.steps[version]!(modelJSON)
            version += 1
        }
        let manifest = try JSONCoding.fromJSON(Manifest.self, manifestJSON)
        let model = try JSONCoding.fromJSON(Model.self, modelJSON)
        var breps: [String: Data] = [:]
        for b in model.bodies { breps[b.id] = try load(b.brep) }
        let thumb = try? Data(contentsOf: url.appendingPathComponent("thumbnails/thumbnail.png"))
        var m = manifest
        m.schema = currentSchema
        return DocumentPackage(manifest: m, model: model, breps: breps, thumbnailPNG: thumb)
    }
}

/// Schema migrations: `steps[n]` converts model.json from schema n to n + 1.
public enum Migrations {
    public static let steps: [Int: @Sendable (JSONValue) throws -> JSONValue] = [:]
}

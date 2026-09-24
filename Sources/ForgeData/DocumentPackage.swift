import ForgeCore
import ForgeSketch
import Foundation

/// On-disk document package (docs/adr/0004-file-format.md):
///
///     Name.forgepart/
///       manifest.json          format, schema version, kind, app/kernel versions, units
///       model.json             authoritative, human-diffable document content
///       bodies/<id>.brep       canonical binary BREP of every body (base bodies, and the
///                              regeneration result of the feature tree)
///       thumbnails/thumbnail.png
///
/// JSON is written with sorted keys and 2-space indentation, and BREP is canonical, so saving
/// an unchanged document reproduces identical bytes (git- and PDM-friendly).
public struct DocumentPackage: Sendable, Equatable {
    public static let currentSchema = 2
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

    /// A feature of the tree (schema 2): the command it replays and its parameters.
    public struct FeatureRecord: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var command: String
        public var params: JSONValue
        public var suppressed: Bool
        public var createdBodies: [String]
        public var edgeCount: Int?
        /// Status at save time (ok, warning, error, suppressed, rolled_back) and its message.
        public var state: String
        public var error: ForgeError?

        public init(
            id: String, name: String, command: String, params: JSONValue, suppressed: Bool, createdBodies: [String], edgeCount: Int?,
            state: String, error: ForgeError?
        ) {
            self.id = id
            self.name = name
            self.command = command
            self.params = params
            self.suppressed = suppressed
            self.createdBodies = createdBodies
            self.edgeCount = edgeCount
            self.state = state
            self.error = error
        }

        enum CodingKeys: String, CodingKey {
            case id, name, command, params, suppressed, state, error
            case createdBodies = "created_bodies"
            case edgeCount = "edge_count"
        }
    }

    public struct Model: Codable, Sendable, Equatable {
        public var name: String
        public var units: UnitSystem
        public var bodies: [BodyRecord]
        public var sketches: [Sketch]
        public var nextBody: Int
        public var nextSketch: Int
        /// Schema 2: the feature tree, the rollback position, bodies that exist without a
        /// feature (from schema 1 files), display names given with body.rename.
        public var features: [FeatureRecord]
        public var rollback: Int?
        public var nextFeature: Int
        public var featureCounters: [String: Int]
        public var baseBodies: [String]
        public var bodyNames: [String: String]
        /// Reference planes (outputs of Plane features), as JSON records.
        public var refPlanes: [JSONValue]?
        public var nextPlane: Int?

        public init(
            name: String, units: UnitSystem, bodies: [BodyRecord], sketches: [Sketch], nextBody: Int, nextSketch: Int,
            features: [FeatureRecord] = [], rollback: Int? = nil, nextFeature: Int = 1, featureCounters: [String: Int] = [:],
            baseBodies: [String] = [], bodyNames: [String: String] = [:], refPlanes: [JSONValue]? = nil, nextPlane: Int? = nil
        ) {
            self.name = name
            self.units = units
            self.bodies = bodies
            self.sketches = sketches
            self.nextBody = nextBody
            self.nextSketch = nextSketch
            self.features = features
            self.rollback = rollback
            self.nextFeature = nextFeature
            self.featureCounters = featureCounters
            self.baseBodies = baseBodies
            self.bodyNames = bodyNames
            self.refPlanes = refPlanes
            self.nextPlane = nextPlane
        }

        enum CodingKeys: String, CodingKey {
            case name, units, bodies, sketches, features, rollback
            case nextBody = "next_body"
            case nextSketch = "next_sketch"
            case nextFeature = "next_feature"
            case featureCounters = "feature_counters"
            case baseBodies = "base_bodies"
            case bodyNames = "body_names"
            case refPlanes = "ref_planes"
            case nextPlane = "next_plane"
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
    public static let steps: [Int: @Sendable (JSONValue) throws -> JSONValue] = [
        // 1 → 2: the feature tree. Schema 1 bodies had no features: they become base bodies.
        1: { model in
            guard case .object(var o) = model else { throw ForgeError(.ioError, "model.json is not an object") }
            let ids = (o["bodies"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
            o["features"] = .array([])
            o["next_feature"] = .number(1)
            o["feature_counters"] = .object([:])
            o["base_bodies"] = .array(ids.map { .string($0) })
            o["body_names"] = .object([:])
            return .object(o)
        }
    ]
}

import ForgeCore
import ForgeKernel
import Foundation

public enum QueryBodies: Command {
    public typealias Params = NoParams
    public struct Output: Codable, Sendable { public var bodies: [BodySummary] }

    public static let name = "query.bodies"
    public static let summary = "List bodies in creation order with volume, bounding box, topology counts and validity"
    public static let category = CommandCategory.query
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.preconditionFailed]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        Output(bodies: try ctx.requireDocument().orderedBodies.map(BodySummary.init))
    }
}

public struct BodyParam: Codable, Sendable, SchemaDocumented {
    public var body: String
    public static let fieldDocs: [String: FieldDoc] = ["body": "Body id (\"body-1\") or unique name"]
}

public enum QueryFaces: Command {
    public typealias Params = BodyParam
    public struct Output: Codable, Sendable { public var faces: [FaceDescriptor] }

    public static let name = "query.faces"
    public static let summary = "Faces of a body with surface type, area, centroid and outward normal"
    public static let discussion = "Face ids are transient in M0 (they index the current geometry). Use the descriptors to confirm you picked the right face."
    public static let category = CommandCategory.query
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity]
    public static let examples: [JSONValue] = [["body": "body-1"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let b = try ctx.requireDocument().body(p.body)
        let n = try b.shape.topology().faces
        return Output(faces: try (0..<n).map { FaceDescriptor(body: b.id, try b.shape.face($0)) })
    }
}

public enum QueryEdges: Command {
    public typealias Params = BodyParam
    public struct Output: Codable, Sendable { public var edges: [EdgeDescriptor] }

    public static let name = "query.edges"
    public static let summary = "Edges of a body with curve type, length, end points and adjacent faces"
    public static let category = CommandCategory.query
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity]
    public static let examples: [JSONValue] = [["body": "body-1"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let b = try ctx.requireDocument().body(p.body)
        let n = try b.shape.topology().edges
        return Output(edges: try (0..<n).map { EdgeDescriptor(body: b.id, try b.shape.edge($0)) })
    }
}

public enum QueryEntity: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var ref: String
        public static let fieldDocs: [String: FieldDoc] = ["ref": "Entity reference: \"body-1\", \"body-1/face-2\" or \"body-1/edge-5\""]
    }
    public struct Output: Codable, Sendable {
        public var kind: String
        public var body: BodySummary?
        public var face: FaceDescriptor?
        public var edge: EdgeDescriptor?
    }

    public static let name = "query.entity"
    public static let summary = "Describe any entity (body, face or edge) by reference"
    public static let category = CommandCategory.query
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity]
    public static let examples: [JSONValue] = [["ref": "body-1/face-0"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let ref = try EntityRef.parse(p.ref)
        let b = try ctx.requireDocument().body(ref.body)
        switch ref.kind {
        case .body:
            return Output(kind: "body", body: try BodySummary(b))
        case .face:
            return Output(kind: "face", face: FaceDescriptor(body: b.id, try b.shape.face(ref.index!)))
        case .edge:
            return Output(kind: "edge", edge: EdgeDescriptor(body: b.id, try b.shape.edge(ref.index!)))
        case .vertex:
            throw ForgeError(.notImplemented, "vertex queries arrive with persistent naming (M2)", entities: [p.ref])
        }
    }
}

public enum QueryMassProperties: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var body: String
        public var density: Double?
        public static let fieldDocs: [String: FieldDoc] = [
            "body": "Body id or unique name",
            "density": FieldDoc("Density in kg/m³ (materials arrive in M2)", default: 1000),
        ]
        public func validate() throws {
            if let d = density, !(d > 0 && d.isFinite) { throw ForgeError(.invalidParams, "density must be positive") }
        }
    }
    public struct Output: Codable, Sendable {
        public var body: String
        public var volumeMM3: Double
        public var surfaceAreaMM2: Double
        public var massKG: Double
        public var densityKGPerM3: Double
        public var centroidMM: [Double]
        /// About the centroid, aligned with the model axes.
        public var inertiaKGMM2: [Double]
        public var principalMomentsKGMM2: [Double]

        enum CodingKeys: String, CodingKey {
            case body
            case volumeMM3 = "volume_mm3"
            case surfaceAreaMM2 = "surface_area_mm2"
            case massKG = "mass_kg"
            case densityKGPerM3 = "density_kg_per_m3"
            case centroidMM = "centroid_mm"
            case inertiaKGMM2 = "inertia_kg_mm2"
            case principalMomentsKGMM2 = "principal_moments_kg_mm2"
        }
    }

    public static let name = "query.mass_properties"
    public static let summary = "Volume, surface area, mass, centre of mass and inertia tensor of a body"
    public static let category = CommandCategory.query
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity]
    public static let examples: [JSONValue] = [["body": "body-1", "density": 7850]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let b = try ctx.requireDocument().body(p.body)
        let mp = try b.shape.massProperties()
        let rho = p.density ?? 1000
        let k = rho * 1e-9  // kg per mm³
        return Output(
            body: b.id, volumeMM3: mp.volume, surfaceAreaMM2: mp.surfaceArea, massKG: mp.volume * k, densityKGPerM3: rho,
            centroidMM: mp.centroid.array, inertiaKGMM2: mp.inertia.map { $0 * k }, principalMomentsKGMM2: mp.principalMoments.map { $0 * k })
    }
}

public enum QueryMeasure: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var from: String
        public var to: String
        public static let fieldDocs: [String: FieldDoc] = ["from": "First body", "to": "Second body"]
    }
    public struct Output: Codable, Sendable {
        public var distanceMM: Double
        public var pointFrom: [Double]
        public var pointTo: [Double]

        enum CodingKeys: String, CodingKey {
            case distanceMM = "distance_mm"
            case pointFrom = "point_from"
            case pointTo = "point_to"
        }
    }

    public static let name = "query.measure"
    public static let summary = "Minimum distance between two bodies, with the closest points"
    public static let discussion = "M0 measures body to body. Face/edge/vertex measurement and angles arrive with persistent naming (M2)."
    public static let category = CommandCategory.query
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity, .notImplemented]
    public static let examples: [JSONValue] = [["from": "body-1", "to": "body-2"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let a = try EntityRef.parse(p.from), b = try EntityRef.parse(p.to)
        guard a.kind == .body, b.kind == .body else {
            throw ForgeError(.notImplemented, "M0 measures between bodies only", entities: [p.from, p.to])
        }
        let d = try Kernel.distance(try doc.body(a.body).shape, try doc.body(b.body).shape)
        return Output(distanceMM: d.distance, pointFrom: d.pointA.array, pointTo: d.pointB.array)
    }
}

public enum QueryValidate: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var body: String?
        public static let fieldDocs: [String: FieldDoc] = ["body": FieldDoc("Body to check", default: "all bodies")]
    }
    public struct BodyCheck: Codable, Sendable {
        public var body: String
        public var valid: Bool
        public var closed: Bool
        public var freeEdges: Int
        public var issues: [String]

        enum CodingKeys: String, CodingKey {
            case body, valid, closed, issues
            case freeEdges = "free_edges"
        }
    }
    public struct Output: Codable, Sendable {
        public var ok: Bool
        public var bodies: [BodyCheck]
    }

    public static let name = "query.validate"
    public static let summary = "Geometry check: B-rep validity, open (free) edges, empty bodies"
    public static let category = CommandCategory.query
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let bodies = try p.body.map { [try doc.body($0)] } ?? doc.orderedBodies
        let checks: [BodyCheck] = try bodies.map { b in
            let v = try b.shape.check()
            var issues: [String] = []
            if v.isEmpty { issues.append("body is empty") }
            if !v.isValid { issues.append("B-rep is invalid (self-intersection, bad tolerances or broken topology)") }
            if !v.isClosed { issues.append("\(v.freeEdges) free edge(s): the body is not watertight") }
            return BodyCheck(body: b.id, valid: v.isValid, closed: v.isClosed, freeEdges: v.freeEdges, issues: issues)
        }
        return Output(ok: checks.allSatisfy { $0.issues.isEmpty }, bodies: checks)
    }
}

// MARK: - Selection (explicit, queryable state)

public enum SelectionMode: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case replace, add, remove
}

public enum SelectionSet: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var entities: [String]
        public var mode: SelectionMode?
        public static let fieldDocs: [String: FieldDoc] = [
            "entities": "Entity references to select",
            "mode": FieldDoc("replace, add or remove", default: "replace"),
        ]
    }
    public struct Output: Codable, Sendable { public var selection: [String] }

    public static let name = "selection.set"
    public static let summary = "Set, extend or reduce the selection"
    public static let category = CommandCategory.selection
    public static let undo = UndoBehavior.session
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams]
    public static let examples: [JSONValue] = [["entities": ["body-1/face-0"]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        var refs: [String] = []
        for s in p.entities {
            let r = try EntityRef.parse(s)
            let b = try doc.body(r.body)
            let t = try b.shape.topology()
            if let i = r.index {
                let count = r.kind == .face ? t.faces : r.kind == .edge ? t.edges : t.vertices
                guard i < count else { throw ForgeError(.unknownEntity, "\(b.id) has no \(r.kind.rawValue) \(i)", entities: [s]) }
            }
            refs.append(EntityRef(body: b.id, kind: r.kind, index: r.index).description)
        }
        switch p.mode ?? .replace {
        case .replace: doc.selection = refs
        case .add: doc.selection += refs.filter { !doc.selection.contains($0) }
        case .remove: doc.selection.removeAll { refs.contains($0) }
        }
        ctx.document = doc
        return Output(selection: doc.selection)
    }
}

public enum SelectionGet: Command {
    public typealias Params = NoParams
    public struct Output: Codable, Sendable { public var selection: [String] }

    public static let name = "selection.get"
    public static let summary = "Current selection"
    public static let category = CommandCategory.selection
    public static let undo = UndoBehavior.none

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        Output(selection: try ctx.requireDocument().selection)
    }
}

public enum SelectionClear: Command {
    public typealias Params = NoParams
    public struct Output: Codable, Sendable { public var selection: [String] }

    public static let name = "selection.clear"
    public static let summary = "Clear the selection"
    public static let category = CommandCategory.selection
    public static let undo = UndoBehavior.session

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        doc.selection = []
        ctx.document = doc
        return Output(selection: [])
    }
}

// MARK: - Export

func checkWritable(_ path: String, overwrite: Bool?) throws -> URL {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    if FileManager.default.fileExists(atPath: url.path), overwrite != true {
        throw ForgeError(.ioError, "'\(url.path)' exists; pass overwrite: true to replace it", entities: [url.path])
    }
    let dir = url.deletingLastPathComponent()
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
        throw ForgeError(.ioError, "directory '\(dir.path)' does not exist")
    }
    return url
}

public enum ExportSTEP: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var path: String
        public var bodies: [String]?
        public var overwrite: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "path": "Output .step/.stp file path",
            "bodies": FieldDoc("Bodies to export", default: "all bodies"),
            "overwrite": FieldDoc("Replace an existing file", default: false),
        ]
    }
    public struct Output: Codable, Sendable {
        public var path: String
        public var bodies: [String]
        public var bytes: Int
    }

    public static let name = "export.step"
    public static let summary = "Export bodies to STEP (AP214, millimetres)"
    public static let category = CommandCategory.export
    public static let undo = UndoBehavior.none
    public static let supportsDryRun = false
    public static let errors: [ErrorCode] = [.ioError, .unknownEntity, .preconditionFailed]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let bodies = try p.bodies.map { try $0.map { try doc.body($0) } } ?? doc.orderedBodies
        guard !bodies.isEmpty else { throw ForgeError(.preconditionFailed, "no bodies to export") }
        let url = try checkWritable(p.path, overwrite: p.overwrite)
        try Kernel.exportSTEP(bodies.map(\.shape), to: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Output(path: url.path, bodies: bodies.map(\.id), bytes: size)
    }
}

public enum ExportSTL: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var path: String
        public var body: String
        public var ascii: Bool?
        public var tolerance: Length?
        public var overwrite: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "path": "Output .stl file path",
            "body": "Body to export",
            "ascii": FieldDoc("Write ASCII instead of binary STL", default: false),
            "tolerance": FieldDoc("Maximum chordal deviation", default: "automatic (0.1% of the body diagonal)"),
            "overwrite": FieldDoc("Replace an existing file", default: false),
        ]
        public func validate() throws { if let t = tolerance { try requirePositive(t, "tolerance") } }
    }
    public struct Output: Codable, Sendable {
        public var path: String
        public var bytes: Int
    }

    public static let name = "export.stl"
    public static let summary = "Export a body as an STL triangle mesh"
    public static let category = CommandCategory.export
    public static let undo = UndoBehavior.none
    public static let supportsDryRun = false
    public static let errors: [ErrorCode] = [.ioError, .unknownEntity]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let b = try ctx.requireDocument().body(p.body)
        let url = try checkWritable(p.path, overwrite: p.overwrite)
        try Kernel.exportSTL(b.shape, to: url, ascii: p.ascii ?? false, linearDeflection: p.tolerance?.millimeters ?? 0)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Output(path: url.path, bytes: size)
    }
}

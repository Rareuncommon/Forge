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
    public static let discussion = "id indexes the current geometry; persistent_id (docs/adr/0002) stays valid when the model regenerates. Either can be passed to commands; features store persistent ids."
    public static let category = CommandCategory.query
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity]
    public static let examples: [JSONValue] = [["body": "body-1"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let b = try ctx.requireDocument().body(p.body)
        let n = try b.shape.topology().faces
        return Output(faces: try (0..<n).map { FaceDescriptor(b, try b.shape.face($0)) })
    }
}

public enum QueryFindFaces: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var feature: String
        public var role: String?
        public var body: String?
        public static let fieldDocs: [String: FieldDoc] = [
            "feature": "Feature id or name (\"Boss-Extrude1\")",
            "role": FieldDoc(
                "Role of the face in that feature: end_cap, start_cap, side (extrude); swept, start_face, end_face (revolve); blend (fillet, chamfer); wall, rim (shell); +x … -z (box); top, bottom, side (cylinder, cone); a sketch entity (\"line-3\") matches the faces made from it",
                default: "any"),
            "body": FieldDoc("Only this body", default: "all bodies"),
        ]
    }
    public struct Output: Codable, Sendable { public var faces: [FaceDescriptor] }

    public static let name = "query.find_faces"
    public static let summary = "Find faces by the feature that made them and their role (\"the end cap of Boss-Extrude1\")"
    public static let discussion = "Semantic queries resolve to persistent ids (docs/adr/0002): pass persistent_id to a command and the reference keeps its meaning when the model changes."
    public static let category = CommandCategory.query
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity]
    public static let examples: [JSONValue] = [["feature": "Boss-Extrude1", "role": "end_cap"], ["feature": "Fillet1", "role": "blend"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let f = doc.features[try doc.featureIndex(p.feature)]
        let prefix = "\(f.id):"
        func matches(_ base: String) -> Bool {
            guard base.hasPrefix(prefix) else { return false }
            guard let role = p.role else { return true }
            let rest = base.dropFirst(prefix.count)
            return rest == role || rest.hasPrefix(role + "(") || rest.hasPrefix(role + "@") || rest.contains("(\(role))")
        }
        let bodies = try p.body.map { [try doc.body($0)] } ?? doc.orderedBodies
        var out: [FaceDescriptor] = []
        for b in bodies {
            guard let n = b.naming else { continue }
            for i in n.faceBases.indices where n.faceBases[i].contains(where: matches) {
                out.append(FaceDescriptor(b, try b.shape.face(i)))
            }
        }
        return Output(faces: out)
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
        return Output(edges: try (0..<n).map { EdgeDescriptor(b, try b.shape.edge($0)) })
    }
}

public enum QueryEntity: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var ref: String
        public static let fieldDocs: [String: FieldDoc] = ["ref": "Entity reference: \"body-1\", \"body-1/face-2\", \"body-1/edge-5\" or a persistent one (\"body-1/face@feature-1:+z\")"]
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
        let doc = try ctx.requireDocument()
        let b = try doc.body(ref.body)
        switch ref.kind {
        case .body:
            return Output(kind: "body", body: try BodySummary(b))
        case .face:
            return Output(kind: "face", face: FaceDescriptor(b, try b.shape.face(try doc.faceIndices([p.ref], of: b, sets: false)[0])))
        case .edge:
            let e = try doc.edgeIndices([p.ref], of: b)
            guard e.count == 1 else {
                throw ForgeError(.invalidParams, "\(p.ref) designates \(e.count) edges", entities: e.map { "\(b.id)/edge-\($0)" })
            }
            return Output(kind: "edge", edge: EdgeDescriptor(b, try b.shape.edge(e[0])))
        case .vertex:
            throw ForgeError(.notImplemented, "vertex queries are not implemented yet", entities: [p.ref])
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
    public enum Mode: String, Codable, Sendable, CaseIterable, SchemaEnum {
        case distance, angle
    }
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var from: String
        public var to: String?
        public var mode: Mode?
        public static let fieldDocs: [String: FieldDoc] = [
            "from": "Body, face, edge or vertex reference (including persistent face/edge names)",
            "to": "Optional second reference for distance; required for angle",
            "mode": FieldDoc("distance or angle; angle requires two planar faces/straight edges (mixed pairs allowed), returning angle_degrees in [0, 90] between unoriented supporting planes/lines", default: "distance"),
        ]
    }
    public struct EntityMeasurement: Codable, Sendable {
        public var reference: String
        public var kind: String
        public var lengthMM: Double?
        public var areaMM2: Double?
        public var volumeMM3: Double?
        public var radiusMM: Double?
        public var center: [Double]?
        public var normal: [Double]?
        public var position: [Double]?
        enum CodingKeys: String, CodingKey {
            case reference, kind, center, normal, position
            case lengthMM = "length_mm", areaMM2 = "area_mm2", volumeMM3 = "volume_mm3", radiusMM = "radius_mm"
        }
    }
    public struct Output: Codable, Sendable {
        public var angleDegrees: Double?
        public var distanceMM: Double?
        public var pointFrom: [Double]?
        public var pointTo: [Double]?
        public var deltaMM: [Double]?
        public var fromEntity: EntityMeasurement
        public var toEntity: EntityMeasurement?
        enum CodingKeys: String, CodingKey {
            case angleDegrees = "angle_degrees"
            case distanceMM = "distance_mm", pointFrom = "point_from", pointTo = "point_to", deltaMM = "delta_mm"
            case fromEntity = "from_entity", toEntity = "to_entity"
        }
    }

    public static let name = "query.measure"
    public static let summary = "Measure entity sizes, minimum distances, or angles between planar faces and straight edges"
    public static let discussion = "One selection returns its length, area, volume, circular radius or vertex position as applicable. In distance mode, two selections also return exact B-rep minimum distance, closest points and their signed XYZ displacement, all in millimeters. Named references must identify a single face or edge. mode=angle requires two planar faces or straight edges (including mixed pairs), returning angle_degrees in [0, 90] between their unoriented supporting planes/lines. Parallel or antiparallel planes/lines measure 0; a line normal to a plane measures 90. Curved, degenerate and body/vertex angle selections are rejected. Maximum distances and normal-distance modes are not implemented."
    public static let category = CommandCategory.query
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams, .referenceLost, .kernelFailure, .notImplemented]
    public static let examples: [JSONValue] = [
        ["from": "body-1", "to": "body-2"], ["from": "body-1/edge-0"],
        ["from": "body-1/face-0", "to": "body-1/vertex-2"],
        ["from": "body-1/face-0", "to": "body-1/edge-0", "mode": "angle"],
    ]

    static func resolve(_ reference: String, in doc: Document) throws -> (Shape, EntityMeasurement) {
        let ref = try EntityRef.parse(reference)
        let body = try doc.body(ref.body)
        var summary = EntityMeasurement(reference: reference, kind: ref.kind.rawValue)
        switch ref.kind {
        case .body:
            let properties = try body.shape.massProperties()
            summary.areaMM2 = properties.surfaceArea
            summary.volumeMM3 = properties.volume
            summary.center = properties.centroid.array
            return (body.shape, summary)
        case .face:
            let index = try doc.faceIndices([reference], of: body, sets: false)[0]
            let face = try body.shape.face(index)
            summary.areaMM2 = face.area
            summary.center = face.centroid.array
            if face.surfaceType == .plane { summary.normal = face.normal.array }
            return (try body.shape.subshape(.face, index: index), summary)
        case .edge:
            let indices = try doc.edgeIndices([reference], of: body)
            guard indices.count == 1 else { throw ForgeError(.invalidParams, "measurement requires one edge; reference identifies \(indices.count)", entities: [reference]) }
            let edge = try body.shape.edge(indices[0])
            summary.lengthMM = edge.length
            summary.radiusMM = edge.circleRadius
            summary.center = edge.circleCenter?.array
            return (try body.shape.subshape(.edge, index: indices[0]), summary)
        case .vertex:
            guard let index = ref.index, index < (try body.shape.topology().vertices) else {
                throw ForgeError(.unknownEntity, "no vertex '\(reference)'", entities: [reference])
            }
            summary.position = try body.shape.vertex(index).array
            return (try body.shape.subshape(.vertex, index: index), summary)
        }
    }

    /// Resolve through the same single-entity/persistent-name rules used by distance.
    static func angleDirection(_ reference: String, in doc: Document) throws -> (Vec3, Bool) {
        let ref = try EntityRef.parse(reference)
        let body = try doc.body(ref.body)
        let direction: Vec3
        let isPlane: Bool
        switch ref.kind {
        case .face:
            let face = try body.shape.face(doc.faceIndices([reference], of: body, sets: false)[0])
            guard face.surfaceType == .plane else {
                throw ForgeError(.notImplemented, "angle measurement requires a planar face", entities: [reference])
            }
            direction = face.normal
            isPlane = true
        case .edge:
            let indices = try doc.edgeIndices([reference], of: body)
            guard indices.count == 1 else {
                throw ForgeError(.invalidParams, "angle measurement requires one edge", entities: [reference])
            }
            let edge = try body.shape.edge(indices[0])
            guard edge.curveType == .line, !edge.isDegenerate else {
                throw ForgeError(.notImplemented, "angle measurement requires a nondegenerate straight edge", entities: [reference])
            }
            direction = edge.end - edge.start
            isPlane = false
        case .body, .vertex:
            throw ForgeError(.notImplemented, "angle measurement supports planar faces and straight edges", entities: [reference])
        }
        guard direction.length.isFinite, direction.length > 0 else {
            throw ForgeError(.invalidParams, "angle measurement has no defined direction", entities: [reference])
        }
        return (direction.normalized, isPlane)
    }

    static func angleDegrees(_ a: Vec3, _ b: Vec3, mixed: Bool) -> Double {
        // atan2 avoids acos/asin domain errors and cancellation near 0 and 90 degrees.
        let dot = abs(a.dot(b))
        let cross = a.cross(b).length
        return (mixed ? atan2(dot, cross) : atan2(cross, dot)) * 180 / .pi
    }

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        if p.mode == .angle && p.to == nil {
            throw ForgeError(.invalidParams, "angle measurement requires two selections")
        }
        let doc = try ctx.requireDocument()
        let (a, first) = try resolve(p.from, in: doc)
        guard let to = p.to else { return Output(fromEntity: first) }
        let (b, second) = try resolve(to, in: doc)
        if p.mode == .angle {
            let (u, firstPlane) = try angleDirection(p.from, in: doc)
            let (v, secondPlane) = try angleDirection(to, in: doc)
            return Output(angleDegrees: angleDegrees(u, v, mixed: firstPlane != secondPlane),
                          fromEntity: first, toEntity: second)
        }
        let distance = try Kernel.distance(a, b)
        return Output(distanceMM: distance.distance, pointFrom: distance.pointA.array, pointTo: distance.pointB.array,
                      deltaMM: (distance.pointB - distance.pointA).array, fromEntity: first, toEntity: second)
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
            if s.hasPrefix("plane-"), StandardPlane(rawValue: String(s.dropFirst(6))) != nil {
                refs.append(s)
                continue
            }
            if let plane = doc.refPlanes[s] ?? doc.orderedRefPlanes.first(where: { $0.name == s }) {
                refs.append(plane.id)
                continue
            }
            if s.hasPrefix("sketch-") || doc.sketches[String(s.split(separator: "/").first ?? "")] != nil {
                guard doc.referenceExists(s) else {
                    throw ForgeError(.unknownEntity, "no sketch entity '\(s)'", entities: [s],
                                     suggestions: [SuggestedFix(description: "List the sketch", command: "sketch.get", params: ["sketch": .string(String(s.split(separator: "/")[0]))])])
                }
                refs.append(s)
                continue
            }
            var r = try EntityRef.parse(s)
            let b = try doc.body(r.body)
            if r.name != nil {
                // Selection is transient: a persistent reference selects what it designates now.
                let current = doc.transientRefs(s)
                guard !current.isEmpty else {
                    throw ForgeError(.referenceLost, "\(s) does not exist in the current model", entities: [s])
                }
                refs += current.filter { !refs.contains($0) }
                continue
            }
            r.body = b.id
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

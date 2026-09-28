import ForgeCore
import ForgeKernel
import Foundation

// Result payloads shared by several commands. snake_case JSON keys throughout; every
// numeric result states its unit in the key or documentation (SPEC §5.4).

public struct TopologyCounts: Codable, Sendable, Hashable {
    public var solids, shells, faces, wires, edges, vertices: Int

    init(_ t: Shape.Topology) {
        solids = t.solids
        shells = t.shells
        faces = t.faces
        wires = t.wires
        edges = t.edges
        vertices = t.vertices
    }
}

public struct BoxResult: Codable, Sendable, Hashable {
    /// mm
    public var min: [Double]
    public var max: [Double]
    public var size: [Double]

    init(_ b: BoundingBox) {
        min = b.min.array
        max = b.max.array
        size = b.size.array
    }
}

/// Everything an agent needs to confirm it is looking at the right body.
public struct BodySummary: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var kind: Shape.Kind
    public var volumeMM3: Double
    public var surfaceAreaMM2: Double
    public var centroid: [Double]
    public var bbox: BoxResult
    public var topology: TopologyCounts
    public var valid: Bool
    public var producedBy: String

    enum CodingKeys: String, CodingKey {
        case id, name, kind, centroid, bbox, topology, valid
        case volumeMM3 = "volume_mm3"
        case surfaceAreaMM2 = "surface_area_mm2"
        case producedBy = "produced_by"
    }

    public init(_ body: Body) throws {
        let s = body.shape
        let mp = try s.massProperties()
        id = body.id
        name = body.name
        kind = s.kind
        volumeMM3 = mp.volume
        surfaceAreaMM2 = mp.surfaceArea
        centroid = mp.centroid.array
        bbox = BoxResult(try s.boundingBox())
        topology = TopologyCounts(try s.topology())
        valid = try s.check().isValid
        producedBy = body.producedBy
    }
}

public struct BodyResult: Codable, Sendable {
    public var body: BodySummary
    /// Every body a cut or merge changed (the first is `body`).
    public var bodies: [String]?

    public init(body: BodySummary, bodies: [String]? = nil) {
        self.body = body
        self.bodies = bodies
    }
}

public struct FaceDescriptor: Codable, Sendable, Hashable {
    public var id: String
    /// Persistent reference (docs/adr/0002): stays valid when the model regenerates.
    public var persistentID: String?
    public var surfaceType: Shape.SurfaceType
    public var areaMM2: Double
    public var centroid: [Double]
    public var normal: [Double]
    public var edgeCount: Int

    enum CodingKeys: String, CodingKey {
        case id, centroid, normal
        case persistentID = "persistent_id"
        case surfaceType = "surface_type"
        case areaMM2 = "area_mm2"
        case edgeCount = "edge_count"
    }

    init(_ b: Body, _ f: Shape.FaceInfo) {
        let body = b.id
        id = EntityRef(body: body, kind: .face, index: f.index).description
        persistentID = b.naming.flatMap { f.index < $0.faces.count ? EntityRef(body: body, kind: .face, name: $0.faces[f.index]).description : nil }
        surfaceType = f.surfaceType
        areaMM2 = f.area
        centroid = f.centroid.array
        normal = f.normal.array
        edgeCount = f.edgeCount
    }
}

public struct EdgeDescriptor: Codable, Sendable, Hashable {
    public var id: String
    /// Persistent reference (docs/adr/0002): stays valid when the model regenerates.
    public var persistentID: String?
    public var curveType: Shape.CurveType
    public var lengthMM: Double
    public var start: [Double]
    public var end: [Double]
    public var midpoint: [Double]
    public var degenerate: Bool
    public var faces: [String]

    enum CodingKeys: String, CodingKey {
        case id, start, end, midpoint, degenerate, faces
        case persistentID = "persistent_id"
        case curveType = "curve_type"
        case lengthMM = "length_mm"
    }

    init(_ b: Body, _ e: Shape.EdgeInfo) {
        let body = b.id
        id = EntityRef(body: body, kind: .edge, index: e.index).description
        persistentID = b.naming.flatMap { e.index < $0.edges.count ? EntityRef(body: body, kind: .edge, name: $0.edges[e.index]).description : nil }
        curveType = e.curveType
        lengthMM = e.length
        start = e.start.array
        end = e.end.array
        midpoint = e.midpoint.array
        degenerate = e.isDegenerate
        faces = e.faces.map { EntityRef(body: body, kind: .face, index: $0).description }
    }
}

public struct DocumentSummary: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var lengthUnit: LengthUnit
    public var angleUnit: AngleUnit
    public var bodyCount: Int
    public var active: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, active
        case lengthUnit = "length_unit"
        case angleUnit = "angle_unit"
        case bodyCount = "body_count"
    }

    init(_ d: Document, active: Bool) {
        id = d.id
        name = d.name
        lengthUnit = d.units.length
        angleUnit = d.units.angle
        bodyCount = d.bodyOrder.count
        self.active = active
    }
}

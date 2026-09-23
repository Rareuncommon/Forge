import CForgeKernel
import ForgeCore
import Foundation

/// An immutable B-rep shape. Thread-safe to share: the kernel never mutates a shape handle
/// after creation (meshing works on a private copy), hence `@unchecked Sendable`.
public final class Shape: @unchecked Sendable {
    let handle: OpaquePointer

    init(owning handle: OpaquePointer) { self.handle = handle }
    deinit { fk_shape_release(handle) }

    public enum Kind: String, Codable, Sendable, CaseIterable, SchemaEnum {
        case compound, compsolid, solid, shell, face, wire, edge, vertex, empty
    }

    public var kind: Kind {
        switch fk_shape_type(handle) {
        case 0: .compound
        case 1: .compsolid
        case 2: .solid
        case 3: .shell
        case 4: .face
        case 5: .wire
        case 6: .edge
        case 7: .vertex
        default: .empty
        }
    }

    public struct Topology: Codable, Sendable, Hashable {
        public var solids, shells, faces, wires, edges, vertices: Int
    }

    public func topology() throws -> Topology {
        var t = FKTopology()
        var err = FKError()
        if fk_topology(handle, &t, &err) != 0 { throw Kernel.error(err) }
        return Topology(
            solids: Int(t.solids), shells: Int(t.shells), faces: Int(t.faces), wires: Int(t.wires),
            edges: Int(t.edges), vertices: Int(t.vertices))
    }

    public struct MassProperties: Codable, Sendable, Hashable {
        /// mm³
        public var volume: Double
        /// mm²
        public var surfaceArea: Double
        public var centroid: Vec3
        /// Row-major inertia tensor about the centroid for unit density (mm⁵).
        public var inertia: [Double]
        /// Ascending principal moments for unit density (mm⁵).
        public var principalMoments: [Double]
    }

    public func massProperties() throws -> MassProperties {
        var m = FKMassProperties()
        var err = FKError()
        if fk_mass_properties(handle, &m, &err) != 0 { throw Kernel.error(err) }
        let c = m.centroid, i = m.inertia, p = m.principalMoments
        return MassProperties(
            volume: m.volume, surfaceArea: m.surfaceArea, centroid: Vec3(c.0, c.1, c.2),
            inertia: [i.0, i.1, i.2, i.3, i.4, i.5, i.6, i.7, i.8], principalMoments: [p.0, p.1, p.2])
    }

    /// Axis-aligned bounding box. `tight` computes the exact box (slower).
    public func boundingBox(tight: Bool = true) throws -> BoundingBox {
        var b = [Double](repeating: 0, count: 6)
        var err = FKError()
        if fk_bounding_box(handle, tight ? 1 : 0, &b, &err) != 0 { throw Kernel.error(err) }
        return BoundingBox(min: Vec3(b[0], b[1], b[2]), max: Vec3(b[3], b[4], b[5]))
    }

    public struct Validity: Codable, Sendable, Hashable {
        public var isValid: Bool
        public var isClosed: Bool
        public var freeEdges: Int
        public var isEmpty: Bool
    }

    public func check() throws -> Validity {
        var v = FKValidity()
        var err = FKError()
        if fk_check(handle, &v, &err) != 0 { throw Kernel.error(err) }
        return Validity(isValid: v.isValid != 0, isClosed: v.isClosed != 0, freeEdges: Int(v.freeEdges), isEmpty: v.isEmpty != 0)
    }

    public enum SurfaceType: String, Codable, Sendable, CaseIterable, SchemaEnum {
        case plane, cylinder, cone, sphere, torus, bezier, bspline, revolution, extrusion, offset, other
    }

    public enum CurveType: String, Codable, Sendable, CaseIterable, SchemaEnum {
        case line, circle, ellipse, hyperbola, parabola, bezier, bspline, offset, other
    }

    public struct FaceInfo: Codable, Sendable, Hashable {
        public var index: Int
        public var surfaceType: SurfaceType
        public var area: Double
        public var centroid: Vec3
        public var normal: Vec3
        public var edgeCount: Int
    }

    public func face(_ index: Int) throws -> FaceInfo {
        var f = FKFaceInfo()
        var err = FKError()
        if fk_face_info(handle, Int32(index), &f, &err) != 0 { throw Kernel.error(err) }
        let types = SurfaceType.allCases
        return FaceInfo(
            index: index, surfaceType: types[min(Int(f.surfaceType), types.count - 1)], area: f.area,
            centroid: Vec3(f.centroid.0, f.centroid.1, f.centroid.2),
            normal: Vec3(f.normal.0, f.normal.1, f.normal.2), edgeCount: Int(f.edgeCount))
    }

    public struct EdgeInfo: Codable, Sendable, Hashable {
        public var index: Int
        public var curveType: CurveType
        public var length: Double
        public var start: Vec3
        public var end: Vec3
        public var midpoint: Vec3
        public var isDegenerate: Bool
        public var faces: [Int]
    }

    public func edge(_ index: Int) throws -> EdgeInfo {
        var e = FKEdgeInfo()
        var err = FKError()
        if fk_edge_info(handle, Int32(index), &e, &err) != 0 { throw Kernel.error(err) }
        var faces = [Int32](repeating: 0, count: 8)
        let n = fk_edge_faces(handle, Int32(index), &faces, Int32(faces.count), &err)
        if n < 0 { throw Kernel.error(err) }
        let types = CurveType.allCases
        return EdgeInfo(
            index: index, curveType: types[min(Int(e.curveType), types.count - 1)], length: e.length,
            start: Vec3(e.start.0, e.start.1, e.start.2), end: Vec3(e.end.0, e.end.1, e.end.2),
            midpoint: Vec3(e.midpoint.0, e.midpoint.1, e.midpoint.2), isDegenerate: e.isDegenerate != 0,
            faces: faces.prefix(Int(min(n, 8))).map { Int($0) })
    }

    /// Tessellate for display/picking. `linearDeflection` ≤ 0 picks an automatic value.
    public func tessellate(linearDeflection: Double = 0, angularDeflection: Double = 0.35) throws -> Mesh {
        var err = FKError()
        guard let m = fk_tessellate(handle, linearDeflection, angularDeflection, &err) else { throw Kernel.error(err) }
        defer { fk_mesh_release(m) }
        return Mesh(copying: m)
    }

    /// Binary B-rep serialization (geometry only).
    public func brepData() throws -> Data {
        var ptr: UnsafeMutablePointer<UInt8>?
        var size = 0
        var err = FKError()
        if fk_write_brep(handle, &ptr, &size, &err) != 0 { throw Kernel.error(err) }
        defer { fk_free_buffer(ptr) }
        return Data(bytes: ptr!, count: size)
    }

    public static func fromBREP(_ data: Data) throws -> Shape {
        try data.withUnsafeBytes { raw in
            try Kernel.call { err in
                fk_read_brep(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, err)
            }
        }
    }
}

/// A display/picking tessellation. Triangles carry the index of the B-rep face they came
/// from; edge polylines carry the B-rep edge index.
public struct Mesh: Sendable {
    public var positions: [Float]
    public var normals: [Float]
    public var indices: [UInt32]
    public var triangleFaces: [UInt32]
    public var edgeOffsets: [UInt32]
    public var edgeIDs: [UInt32]
    public var edgePoints: [Float]

    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }
    public var edgeCount: Int { edgeIDs.count }

    public init(
        positions: [Float], normals: [Float], indices: [UInt32], triangleFaces: [UInt32],
        edgeOffsets: [UInt32] = [0], edgeIDs: [UInt32] = [], edgePoints: [Float] = []
    ) {
        self.positions = positions
        self.normals = normals
        self.indices = indices
        self.triangleFaces = triangleFaces
        self.edgeOffsets = edgeOffsets
        self.edgeIDs = edgeIDs
        self.edgePoints = edgePoints
    }

    init(copying m: OpaquePointer) {
        func copy<T>(_ p: UnsafePointer<T>?, _ n: Int) -> [T] {
            guard let p, n > 0 else { return [] }
            return Array(UnsafeBufferPointer(start: p, count: n))
        }
        let nv = fk_mesh_vertex_count(m), nt = fk_mesh_triangle_count(m), ne = fk_mesh_edge_count(m)
        positions = copy(fk_mesh_positions(m), nv * 3)
        normals = copy(fk_mesh_normals(m), nv * 3)
        indices = copy(fk_mesh_indices(m), nt * 3)
        triangleFaces = copy(fk_mesh_triangle_faces(m), nt)
        edgeOffsets = copy(fk_mesh_edge_offsets(m), ne + 1)
        edgeIDs = copy(fk_mesh_edge_ids(m), ne)
        let npts = edgeOffsets.last.map(Int.init) ?? 0
        edgePoints = copy(fk_mesh_edge_points(m), npts * 3)
    }

    public func position(_ i: Int) -> Vec3 {
        Vec3(Double(positions[3 * i]), Double(positions[3 * i + 1]), Double(positions[3 * i + 2]))
    }

    /// Axis-aligned bounds of the tessellation.
    public var bounds: BoundingBox? {
        let all = positions + edgePoints
        guard all.count >= 3 else { return nil }
        func at(_ i: Int) -> Vec3 { Vec3(Double(all[3 * i]), Double(all[3 * i + 1]), Double(all[3 * i + 2])) }
        var lo = at(0), hi = lo
        for i in 1..<(all.count / 3) {
            let p = at(i)
            lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        return BoundingBox(min: lo, max: hi)
    }

    /// Enclosed volume by the divergence theorem (sanity check against the B-rep).
    public var signedVolume: Double {
        var v = 0.0
        for t in 0..<triangleCount {
            let a = position(Int(indices[3 * t])), b = position(Int(indices[3 * t + 1])), c = position(Int(indices[3 * t + 2]))
            v += a.dot(b.cross(c))
        }
        return v / 6
    }
}

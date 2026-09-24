import CForgeKernel
import ForgeCore
import Foundation

/// Swift face of the geometry kernel. No OCCT or C types escape this module's public API
/// other than through these wrappers (docs/adr/0001-kernel-wrapping.md).
public enum Kernel {
    public static var version: String { String(cString: fk_kernel_version()) }

    // MARK: primitives

    public static func box(origin: Vec3 = .zero, size: Vec3) throws -> Shape {
        try call { err in withUnsafePointer3(origin) { fk_make_box($0, size.x, size.y, size.z, err) } }
    }

    public static func cylinder(origin: Vec3 = .zero, axis: Vec3 = .unitZ, radius: Double, height: Double) throws -> Shape {
        try call { err in
            withUnsafePointer3(origin) { o in withUnsafePointer3(axis) { a in fk_make_cylinder(o, a, radius, height, err) } }
        }
    }

    public static func cone(origin: Vec3 = .zero, axis: Vec3 = .unitZ, radius1: Double, radius2: Double, height: Double) throws -> Shape {
        try call { err in
            withUnsafePointer3(origin) { o in withUnsafePointer3(axis) { a in fk_make_cone(o, a, radius1, radius2, height, err) } }
        }
    }

    public static func sphere(center: Vec3 = .zero, radius: Double) throws -> Shape {
        try call { err in withUnsafePointer3(center) { fk_make_sphere($0, radius, err) } }
    }

    public static func torus(origin: Vec3 = .zero, axis: Vec3 = .unitZ, majorRadius: Double, minorRadius: Double) throws -> Shape {
        try call { err in
            withUnsafePointer3(origin) { o in
                withUnsafePointer3(axis) { a in fk_make_torus(o, a, majorRadius, minorRadius, err) }
            }
        }
    }

    // MARK: operations

    public enum BooleanOp: String, Codable, Sendable, CaseIterable, SchemaEnum {
        case fuse, cut, common
        var c: FKBooleanOp {
            switch self {
            case .fuse: FK_BOOL_FUSE
            case .cut: FK_BOOL_CUT
            case .common: FK_BOOL_COMMON
            }
        }
    }

    public static func boolean(_ op: BooleanOp, _ a: Shape, _ b: Shape) throws -> Shape {
        try call { err in fk_boolean(a.handle, b.handle, op.c, err) }
    }

    public static func transform(_ shape: Shape, _ t: Transform3) throws -> Shape {
        try call { err in t.m.withUnsafeBufferPointer { fk_transform(shape.handle, $0.baseAddress, err) } }
    }

    public static func fillet(_ shape: Shape, edges: [Int], radius: Double) throws -> Shape {
        let idx = edges.map { Int32($0) }
        return try call { err in idx.withUnsafeBufferPointer { fk_fillet_edges(shape.handle, $0.baseAddress, $0.count, radius, err) } }
    }

    /// Chamfer edges: equal distance; or `distance2` (two distances, the first on the first
    /// face of each edge); or `angle` (radians) with the distance.
    public static func chamfer(_ shape: Shape, edges: [Int], distance: Double, distance2: Double? = nil, angle: Double? = nil) throws -> Shape {
        let idx = edges.map { Int32($0) }
        return try call { err in
            idx.withUnsafeBufferPointer { fk_chamfer_edges(shape.handle, $0.baseAddress, $0.count, distance, distance2 ?? 0, angle ?? 0, err) }
        }
    }

    /// Hollow a solid (walls inward, or outward), opening the given faces.
    public static func shell(_ shape: Shape, openFaces: [Int], thickness: Double, outward: Bool = false) throws -> Shape {
        let idx = openFaces.map { Int32($0) }
        return try call { err in idx.withUnsafeBufferPointer { fk_shell(shape.handle, $0.baseAddress, $0.count, thickness, outward ? 1 : 0, err) } }
    }

    /// Draft faces about a neutral plane (origin, pull direction), tapering inward or outward.
    public static func draft(_ shape: Shape, faces: [Int], neutralOrigin: Vec3, pull: Vec3, angle: Double, outward: Bool = false) throws -> Shape {
        let idx = faces.map { Int32($0) }
        return try call { err in
            idx.withUnsafeBufferPointer { f in
                withUnsafePointer3(neutralOrigin) { o in withUnsafePointer3(pull) { d in fk_draft_faces(shape.handle, f.baseAddress, f.count, o, d, angle, outward ? 1 : 0, err) } }
            }
        }
    }

    /// Extrusion with drafted sides (taper inward along v, or outward).
    public static func extrudeDrafted(_ profile: Shape, by v: Vec3, angle: Double, outward: Bool = false) throws -> Shape {
        try call { err in withUnsafePointer3(v) { fk_extrude_draft(profile.handle, $0, angle, outward ? 1 : 0, err) } }
    }

    /// Grow (> 0) or shrink (< 0) a planar face's boundary, rounding corners.
    public static func offsetFace(_ face: Shape, by distance: Double) throws -> Shape {
        try call { err in fk_offset_face(face.handle, distance, err) }
    }

    /// Minimum distance between two shapes and the closest points.
    public static func distance(_ a: Shape, _ b: Shape) throws -> (distance: Double, pointA: Vec3, pointB: Vec3) {
        var d = 0.0
        var pa = [0.0, 0, 0], pb = [0.0, 0, 0]
        var err = FKError()
        let rc = fk_distance(a.handle, b.handle, &d, &pa, &pb, &err)
        if rc != 0 { throw Kernel.error(err) }
        return (d, Vec3(pa[0], pa[1], pa[2]), Vec3(pb[0], pb[1], pb[2]))
    }

    // MARK: exchange

    public static func exportSTEP(_ shapes: [Shape], to url: URL) throws {
        let handles: [OpaquePointer?] = shapes.map { $0.handle }
        var err = FKError()
        let rc = handles.withUnsafeBufferPointer { fk_export_step($0.baseAddress, $0.count, url.path, &err) }
        if rc != 0 { throw Kernel.error(err) }
    }

    public static func importSTEP(from url: URL) throws -> Shape {
        try call { err in fk_import_step(url.path, err) }
    }

    public static func exportSTL(_ shape: Shape, to url: URL, ascii: Bool = false, linearDeflection: Double = 0) throws {
        var err = FKError()
        if fk_export_stl(shape.handle, url.path, ascii ? 1 : 0, linearDeflection, &err) != 0 { throw Kernel.error(err) }
    }

    // MARK: helpers

    static func call(_ body: (UnsafeMutablePointer<FKError>) -> OpaquePointer?) throws -> Shape {
        var err = FKError()
        guard let h = body(&err) else { throw error(err) }
        return Shape(owning: h)
    }

    static func error(_ err: FKError) -> ForgeError {
        let message = withUnsafeBytes(of: err.message) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let code: ErrorCode =
            switch Int(err.code) {
            case Int(FK_ERR_INVALID_ARGUMENT): .invalidParams
            case Int(FK_ERR_BOOLEAN_FAILED): .booleanFailed
            case Int(FK_ERR_EMPTY_RESULT): .emptyResult
            case Int(FK_ERR_IO): .ioError
            case Int(FK_ERR_OUT_OF_RANGE): .unknownEntity
            default: .kernelFailure
            }
        return ForgeError(code, message.isEmpty ? "kernel operation failed" : message)
    }
}

func withUnsafePointer3<R>(_ v: Vec3, _ body: (UnsafePointer<Double>) -> R) -> R {
    let a = [v.x, v.y, v.z]
    return a.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// A segment of a planar profile loop, in model coordinates (mm).
public enum ProfileSegment: Sendable, Hashable {
    case line(Vec3, Vec3)
    /// start, a point on the arc, end
    case arc(Vec3, Vec3, Vec3)
    case circle(center: Vec3, normal: Vec3, radius: Double)
    case ellipse(center: Vec3, normal: Vec3, majorDirection: Vec3, majorRadius: Double, minorRadius: Double)
    /// Elliptical arc from parameter `from` to `to`, counter-clockwise about `normal`.
    case ellipseArc(center: Vec3, normal: Vec3, majorDirection: Vec3, majorRadius: Double, minorRadius: Double, from: Double, to: Double)
    /// Clamped uniform B-spline through its end poles.
    case bspline(poles: [Vec3], degree: Int)

    var c: FKSegment {
        var s = FKSegment()
        var p = [Double](repeating: 0, count: 13)
        func put(_ v: Vec3, _ at: Int) {
            p[at] = v.x
            p[at + 1] = v.y
            p[at + 2] = v.z
        }
        switch self {
        case .line(let a, let b):
            s.kind = Int32(FK_SEG_LINE.rawValue)
            put(a, 0)
            put(b, 3)
        case .arc(let a, let m, let b):
            s.kind = Int32(FK_SEG_ARC.rawValue)
            put(a, 0)
            put(m, 3)
            put(b, 6)
        case .circle(let c, let n, let r):
            s.kind = Int32(FK_SEG_CIRCLE.rawValue)
            put(c, 0)
            put(n, 3)
            p[9] = r
        case .ellipse(let c, let n, let d, let a, let b):
            s.kind = Int32(FK_SEG_ELLIPSE.rawValue)
            put(c, 0)
            put(n, 3)
            put(d, 6)
            p[9] = a
            p[10] = b
        case .ellipseArc(let c, let n, let d, let a, let b, let from, let to):
            s.kind = Int32(FK_SEG_ELLIPSE_ARC.rawValue)
            put(c, 0)
            put(n, 3)
            put(d, 6)
            p[9] = a
            p[10] = b
            p[11] = from
            p[12] = to
        case .bspline:
            s.kind = Int32(FK_SEG_BSPLINE.rawValue)  // pole block filled in by Kernel.faces
        }
        withUnsafeMutableBytes(of: &s.p) { raw in
            p.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        return s
    }
}

extension Kernel {
    /// Planar faces from profile loops. `regions[i]` groups loops; the first loop of each
    /// region is its outer boundary, the rest are holes.
    public static func faces(loops: [[ProfileSegment]], regions: [Int]) throws -> Shape {
        precondition(loops.count == regions.count)
        guard !loops.isEmpty else { throw ForgeError(.invalidParams, "no profile loops") }
        var segs: [FKSegment] = []
        var starts: [Int32] = []
        var poles: [Double] = []
        for l in loops {
            starts.append(Int32(segs.count))
            for seg in l {
                var c = seg.c
                if case .bspline(let ps, let degree) = seg {
                    c.p.0 = Double(poles.count / 3)
                    c.p.1 = Double(ps.count)
                    c.p.2 = Double(degree)
                    for q in ps { poles += [q.x, q.y, q.z] }
                }
                segs.append(c)
            }
        }
        starts.append(Int32(segs.count))
        let reg = regions.map { Int32($0) }
        let poleCount = poles.count / 3
        return try call { err in
            segs.withUnsafeBufferPointer { sp in
                starts.withUnsafeBufferPointer { st in
                    reg.withUnsafeBufferPointer { rg in
                        poles.withUnsafeBufferPointer { pp in
                            fk_make_faces(sp.baseAddress, st.baseAddress, rg.baseAddress, loops.count, pp.baseAddress, poleCount, err)
                        }
                    }
                }
            }
        }
    }

    public static func extrude(_ profile: Shape, by v: Vec3) throws -> Shape {
        try call { err in withUnsafePointer3(v) { fk_extrude(profile.handle, $0, err) } }
    }

    public static func revolve(_ profile: Shape, origin: Vec3, axis: Vec3, angle: Double) throws -> Shape {
        try call { err in
            withUnsafePointer3(origin) { o in withUnsafePointer3(axis) { a in fk_revolve(profile.handle, o, a, angle, err) } }
        }
    }
}

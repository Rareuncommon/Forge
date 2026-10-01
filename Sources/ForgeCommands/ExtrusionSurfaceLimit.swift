import ForgeCore
import ForgeKernel
import Foundation

/// An oriented supporting plane: the kept material is its negative half-space.
/// A finite clipping box surrounds the actual extrusion bounds; only its z=0 face
/// can intersect the extrusion, so this is an exact planar cut independent of model size.
struct ExtrusionSurfaceLimit {
    var origin: Vec3
    var normal: Vec3
    var x: Vec3
    var y: Vec3
    var reference: String
    var role: String

    var toLocal: Transform3 {
        Transform3(m: [x.x, x.y, x.z, -origin.dot(x), y.x, y.y, y.z, -origin.dot(y), normal.x, normal.y, normal.z, -origin.dot(normal)])
    }
    var toWorld: Transform3 {
        Transform3(m: [x.x, y.x, normal.x, origin.x, x.y, y.y, normal.y, origin.y, x.z, y.z, normal.z, origin.z])
    }

    init(document: Document, reference: String, offset: Double, reverseOffset: Bool, travel: Vec3, role: String) throws {
        let ref = reference.hasPrefix("plane-") && StandardPlane(rawValue: String(reference.dropFirst(6))) != nil ? String(reference.dropFirst(6)) : reference
        let plane = try document.resolvePlacement(ref)
        let dot = plane.normal.dot(travel)
        guard abs(dot) > 1e-9 else { throw ForgeError(.invalidParams, "the limiting plane is parallel to the extrusion direction", entities: [reference]) }
        normal = dot > 0 ? plane.normal : -plane.normal
        x = plane.xAxis
        y = normal.cross(x).normalized
        origin = plane.origin + normal * (reverseOffset ? offset : -offset)
        self.reference = reference
        self.role = role
    }

    func reach(profile: Shape, travel: Vec3) throws -> Double {
        let bounds = try Kernel.transform(profile, toLocal).boundingBox()
        let denominator = normal.dot(travel)
        let minimum = -bounds.max.z / denominator
        let maximum = -bounds.min.z / denominator
        guard minimum > 1e-7, maximum.isFinite else {
            throw ForgeError(.invalidParams, "the limiting plane must lie ahead of the entire profile; it crosses, touches or lies behind the sketch", entities: [reference])
        }
        // Overshoot so the provisional prism's end cap cannot survive the clipping operation.
        return maximum + max(1, maximum * 1e-6)
    }

    func clip(_ input: NamedShape, feature: String) throws -> NamedShape {
        let bounds = try Kernel.transform(input.shape, toLocal).boundingBox()
        let pad = max(1, bounds.diagonal * 0.01)
        let local = try Kernel.box(origin: Vec3(bounds.min.x - pad, bounds.min.y - pad, bounds.min.z - pad),
                                   size: Vec3(bounds.size.x + 2 * pad, bounds.size.y + 2 * pad, -bounds.min.z + pad))
        let mask = try Kernel.transform(local, toWorld)
        let names = Array(repeating: ["\(feature):\(role)"], count: try mask.topology().faces)
        let result = try Kernel.boolean(.common, input.shape, mask)
        return try Naming.named(result, [input, NamedShape(mask, faces: names)], feature: feature)
    }
}

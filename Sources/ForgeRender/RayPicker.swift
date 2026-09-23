import ForgeCore
import ForgeKernel
import Foundation

/// CPU ray picking against tessellations (Möller–Trumbore) with edge proximity. Used by the
/// interactive viewport for hover/click where reading back a GPU ID buffer is unnecessary.
public enum RayPicker {
    /// Pick along a ray. Edges within `edgeTolerance` (world units) of the ray win over
    /// faces if they are not behind the nearest face hit.
    public static func pick(_ scene: RenderScene, origin: Vec3, direction: Vec3, edgeTolerance: Double = 0) -> PickHit? {
        let d = direction.normalized
        var bestFace: (PickHit, Double)?
        for item in scene.items {
            let m = item.mesh
            for t in 0..<m.triangleCount {
                let a = m.position(Int(m.indices[3 * t])), b = m.position(Int(m.indices[3 * t + 1])), c = m.position(Int(m.indices[3 * t + 2]))
                guard let dist = intersect(origin: origin, dir: d, a, b, c) else { continue }
                if bestFace == nil || dist < bestFace!.1 {
                    bestFace = (PickHit(objectID: item.objectID, element: .face, index: m.triangleFaces[t], point: origin + d * dist), dist)
                }
            }
        }
        if edgeTolerance > 0 {
            var bestEdge: (PickHit, Double, Double)?  // hit, perpendicular distance, ray parameter
            for item in scene.items {
                let m = item.mesh
                for e in 0..<m.edgeCount {
                    let s = Int(m.edgeOffsets[e]), en = Int(m.edgeOffsets[e + 1])
                    guard en - s >= 2 else { continue }
                    for k in s..<(en - 1) {
                        let p = Vec3(Double(m.edgePoints[3 * k]), Double(m.edgePoints[3 * k + 1]), Double(m.edgePoints[3 * k + 2]))
                        let q = Vec3(Double(m.edgePoints[3 * k + 3]), Double(m.edgePoints[3 * k + 4]), Double(m.edgePoints[3 * k + 5]))
                        let (perp, tRay, point) = raySegmentDistance(origin: origin, dir: d, p, q)
                        guard perp <= edgeTolerance, tRay >= 0 else { continue }
                        if let f = bestFace, tRay > f.1 + edgeTolerance * 2 { continue }  // hidden behind a face
                        if bestEdge == nil || perp < bestEdge!.1 {
                            bestEdge = (PickHit(objectID: item.objectID, element: .edge, index: m.edgeIDs[e], point: point), perp, tRay)
                        }
                    }
                }
            }
            if let e = bestEdge { return e.0 }
        }
        return bestFace?.0
    }

    static func intersect(origin: Vec3, dir: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double? {
        let e1 = b - a, e2 = c - a
        let p = dir.cross(e2)
        let det = e1.dot(p)
        guard abs(det) > 1e-14 else { return nil }
        let inv = 1 / det
        let s = origin - a
        let u = s.dot(p) * inv
        guard u >= -1e-9, u <= 1 + 1e-9 else { return nil }
        let q = s.cross(e1)
        let v = dir.dot(q) * inv
        guard v >= -1e-9, u + v <= 1 + 1e-9 else { return nil }
        let t = e2.dot(q) * inv
        return t >= 0 ? t : nil
    }

    /// Distance between a ray and a segment; returns (distance, ray parameter, closest point on segment).
    static func raySegmentDistance(origin: Vec3, dir: Vec3, _ p: Vec3, _ q: Vec3) -> (Double, Double, Vec3) {
        let u = dir, v = q - p, w = origin - p
        let a = u.dot(u), b = u.dot(v), c = v.dot(v), d = u.dot(w), e = v.dot(w)
        let denom = a * c - b * b
        var sc: Double, tc: Double
        if denom < 1e-14 {
            sc = 0
            tc = c > 0 ? e / c : 0
        } else {
            sc = (b * e - c * d) / denom
            tc = (a * e - b * d) / denom
        }
        tc = max(0, min(1, tc))
        // Recompute ray parameter for the clamped segment point.
        let segPoint = p + v * tc
        sc = max(0, (segPoint - origin).dot(u) / a)
        let rayPoint = origin + u * sc
        return ((rayPoint - segPoint).length, sc, segPoint)
    }
}

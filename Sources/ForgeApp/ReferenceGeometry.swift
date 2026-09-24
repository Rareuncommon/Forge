// Reference geometry drawn in the viewport: the three origin planes, the origin axes, a grid
// on the sketch being edited, and markers for sketch points (which have no curve to draw).
// Display only — these items have object IDs outside the document's, so picks ignore them.

import ForgeCommands
import ForgeCore
import Foundation
import ForgeKernel
import ForgeRender
import ForgeSketch

enum ReferenceGeometry {
    static let firstObjectID: UInt32 = 1_000_000

    static func planeColor(_ dark: Bool) -> RGBA { dark ? RGBA(0.40, 0.52, 0.72) : RGBA(0.42, 0.55, 0.78) }
    static func gridColor(_ dark: Bool) -> RGBA { dark ? RGBA(0.17, 0.19, 0.22) : RGBA(0.80, 0.83, 0.88) }
    static func gridAxisColor(_ dark: Bool) -> RGBA { dark ? RGBA(0.25, 0.28, 0.33) : RGBA(0.60, 0.65, 0.75) }

    /// Items for the current state. `size` is the model's extent (mm) used to scale planes,
    /// axes and the grid; `sketch` is the sketch being edited, if any.
    static func items(size: Double, sketch: Sketch?, allSketches: [Sketch], planes: Bool = true, refPlanes: [RefPlane] = [], dark: Bool = false) -> [RenderItem] {
        var out: [RenderItem] = []
        var lines = LineBuilder()
        let s = size
        if let sk = sketch {
            // Grid on the sketch plane, spacing 1–2–5 × 10ⁿ for ~20 cells across.
            let step = niceStep(s / 10)
            let n = Int((s / step).rounded(.up))
            for i in -n...n {
                let t = Double(i) * step
                let c = i == 0 ? gridAxisColor(dark) : gridColor(dark)
                lines.add([sk.plane.point(t, -Double(n) * step), sk.plane.point(t, Double(n) * step)], c)
                lines.add([sk.plane.point(-Double(n) * step, t), sk.plane.point(Double(n) * step, t)], c)
            }
        } else if planes {
            // Front (XY), Top (XZ) and Right (YZ) plane outlines.
            let h = s / 2
            lines.add([Vec3(-h, -h, 0), Vec3(h, -h, 0), Vec3(h, h, 0), Vec3(-h, h, 0), Vec3(-h, -h, 0)], planeColor(dark))
            lines.add([Vec3(-h, 0, -h), Vec3(h, 0, -h), Vec3(h, 0, h), Vec3(-h, 0, h), Vec3(-h, 0, -h)], planeColor(dark))
            lines.add([Vec3(0, -h, -h), Vec3(0, h, -h), Vec3(0, h, h), Vec3(0, -h, h), Vec3(0, -h, -h)], planeColor(dark))
        }
        // Reference planes (Plane features): a square outline centred on the plane origin.
        if planes && sketch == nil {
            let h = s / 3
            for r in refPlanes {
                let p = r.plane
                lines.add([p.point(-h, -h), p.point(h, -h), p.point(h, h), p.point(-h, h), p.point(-h, -h)], planeColor(dark))
            }
        }
        // Origin axes: X red, Y green, Z blue.
        let a = s * 0.25
        lines.add([.zero, Vec3(a, 0, 0)], RGBA(0.85, 0.20, 0.20))
        lines.add([.zero, Vec3(0, a, 0)], RGBA(0.20, 0.65, 0.25))
        lines.add([.zero, Vec3(0, 0, a)], RGBA(0.20, 0.35, 0.90))
        // Sketch points (endpoints, centres, free points) as small crosses in their plane.
        let m = s * 0.006
        for sk in allSketches {
            for e in sk.orderedEntities where e.kind == .point && e.id != Sketch.originID {
                let (u, v) = sk.point(e.id)
                let color = e.construction ? RGBA.sketchConstruction : Theme.sketchRGBA(dark: dark).point
                lines.add([sk.plane.point(u - m, v - m), sk.plane.point(u + m, v + m)], color)
                lines.add([sk.plane.point(u - m, v + m), sk.plane.point(u + m, v - m)], color)
            }
        }
        out.append(lines.item(objectID: firstObjectID))
        return out
    }

    static func niceStep(_ x: Double) -> Double {
        guard x > 0, x.isFinite else { return 10 }
        let p = pow(10, floor(log10(x)))
        let f = x / p
        return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * p
    }

    /// Accumulates polylines into one line-only mesh with per-polyline colours.
    struct LineBuilder {
        var points: [Float] = []
        var offsets: [UInt32] = [0]
        var ids: [UInt32] = []
        var colors: [UInt32: RGBA] = [:]

        mutating func add(_ polyline: [Vec3], _ color: RGBA) {
            for p in polyline { points += [Float(p.x), Float(p.y), Float(p.z)] }
            offsets.append(UInt32(points.count / 3))
            let id = UInt32(ids.count)
            ids.append(id)
            colors[id] = color
        }

        func item(objectID: UInt32) -> RenderItem {
            let mesh = Mesh(positions: [], normals: [], indices: [], triangleFaces: [], edgeOffsets: offsets, edgeIDs: ids, edgePoints: points)
            return RenderItem(objectID: objectID, mesh: mesh, color: .edge, edgeColors: colors)
        }
    }
}

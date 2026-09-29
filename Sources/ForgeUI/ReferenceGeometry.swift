// Reference geometry drawn in the viewport: the three origin planes, the origin axes, a grid
// on the sketch being edited, and markers for sketch points (which have no curve to draw).
// Display only — these items have object IDs outside the document's, so picks ignore them.

import ForgeCommands
import ForgeCore
import Foundation
import ForgeKernel
import ForgeRender
import ForgeSketch

/// The sketch grid: `step` apart, centred at (centerU, centerV) on the sketch plane,
/// `halfCells` cells each way.
package struct SketchGrid: Equatable {
    package var step: Double
    package var centerU: Double
    package var centerV: Double
    package var halfCells: Int
}

package enum ReferenceGeometry {
    package static let firstObjectID: UInt32 = 1_000_000

    package static func planeColor(_ dark: Bool) -> RGBA { dark ? RGBA(0.40, 0.52, 0.72) : RGBA(0.42, 0.55, 0.78) }
    // Linear values (the viewports render to sRGB targets) of the design's greys: light grid
    // #CCD1DE / axes #A3ADC4, dark grid #33363D / axes #4A4F59.
    package static func gridColor(_ dark: Bool) -> RGBA { dark ? RGBA(0.033, 0.037, 0.047) : RGBA(0.60, 0.64, 0.73) }
    package static func gridAxisColor(_ dark: Bool) -> RGBA { dark ? RGBA(0.068, 0.078, 0.10) : RGBA(0.37, 0.42, 0.55) }

    /// Items for the current state. `size` is the model's extent (mm) used to scale planes,
    /// axes and the grid; `sketch` is the sketch being edited, if any.
    /// `grid`: the sketch grid for the view (nil: sized from `size`, ~20 cells across).
    package static func items(
        size: Double, sketch: Sketch?, allSketches: [Sketch], planes: Bool = true, refPlanes: [RefPlane] = [], dark: Bool = false, grid: SketchGrid? = nil
    ) -> [RenderItem] {
        var out: [RenderItem] = []
        var lines = LineBuilder()
        let s = size
        // In a sketch the origin axes and point markers are sized with the grid (the view).
        var axisLength = s * 0.25, marker = s * 0.006
        if let sk = sketch {
            let g = grid ?? SketchGrid(step: niceStep(s / 10), centerU: 0, centerV: 0, halfCells: Int((s / niceStep(s / 10)).rounded(.up)))
            let step = g.step, n = g.halfCells
            axisLength = step * 2.5
            marker = step * 0.06
            // Just behind the plane (as seen normal to the sketch), so sketch lines lying on a
            // grid line are drawn over it, not hidden by it.
            let back = sk.plane.normal * (-step * 1e-2)
            let (u0, u1) = (g.centerU - Double(n) * step, g.centerU + Double(n) * step)
            let (v0, v1) = (g.centerV - Double(n) * step, g.centerV + Double(n) * step)
            for i in -n...n {
                let u = g.centerU + Double(i) * step, v = g.centerV + Double(i) * step
                lines.add([sk.plane.point(u, v0) + back, sk.plane.point(u, v1) + back], abs(u) < step * 1e-6 ? gridAxisColor(dark) : gridColor(dark))
                lines.add([sk.plane.point(u0, v) + back, sk.plane.point(u1, v) + back], abs(v) < step * 1e-6 ? gridAxisColor(dark) : gridColor(dark))
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
        let a = axisLength
        lines.add([.zero, Vec3(a, 0, 0)], RGBA(0.85, 0.20, 0.20))
        lines.add([.zero, Vec3(0, a, 0)], RGBA(0.20, 0.65, 0.25))
        lines.add([.zero, Vec3(0, 0, a)], RGBA(0.20, 0.35, 0.90))
        // Sketch points (endpoints, centres, free points) as small crosses in their plane.
        let m = marker
        for sk in allSketches {
            for e in sk.orderedEntities where e.kind == .point && e.id != Sketch.originID {
                let (u, v) = sk.point(e.id)
                let color = e.construction ? RGBA.sketchConstruction : Palette.sketch(dark: dark).point
                lines.add([sk.plane.point(u - m, v - m), sk.plane.point(u + m, v + m)], color)
                lines.add([sk.plane.point(u - m, v + m), sk.plane.point(u + m, v - m)], color)
            }
        }
        out.append(lines.item(objectID: firstObjectID))
        return out
    }

    package static func niceStep(_ x: Double) -> Double {
        guard x > 0, x.isFinite else { return 10 }
        let p = pow(10, floor(log10(x)))
        let f = x / p
        return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * p
    }

    /// Accumulates polylines into one line-only mesh with per-polyline colours.
    package struct LineBuilder {
        package var points: [Float] = []
        package var offsets: [UInt32] = [0]
        package var ids: [UInt32] = []
        package var colors: [UInt32: RGBA] = [:]

        package mutating func add(_ polyline: [Vec3], _ color: RGBA) {
            for p in polyline { points += [Float(p.x), Float(p.y), Float(p.z)] }
            offsets.append(UInt32(points.count / 3))
            let id = UInt32(ids.count)
            ids.append(id)
            colors[id] = color
        }

        package func item(objectID: UInt32) -> RenderItem {
            let mesh = Mesh(positions: [], normals: [], indices: [], triangleFaces: [], edgeOffsets: offsets, edgeIDs: ids, edgePoints: points)
            return RenderItem(objectID: objectID, mesh: mesh, color: .edge, edgeColors: colors)
        }
    }
}

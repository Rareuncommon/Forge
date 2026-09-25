import ForgeCore
import ForgeRender
import ForgeSketch
import Foundation

package enum SketchOverlay {
    /// Overlay items for the sketch preview: rubber-band geometry and the snap marker (a ring,
    /// as in the design).
    package static func items(_ preview: SketchPreview?, operation: [[Point2]] = [], plane: SketchPlane?, markerSize: Double, dark: Bool) -> [RenderItem] {
        guard let plane, preview != nil || !operation.isEmpty else { return [] }
        let pv = preview ?? SketchPreview()
        let color = Palette.sketch(dark: dark).preview
        var lines = ReferenceGeometry.LineBuilder()
        for pl in operation {
            lines.add(pl.map { plane.point($0.u, $0.v) }, color)
        }
        for pl in pv.polylines {
            lines.add(pl.map { plane.point($0.u, $0.v) }, color)
        }
        if let m = pv.marker {
            let r = markerSize * 1.4
            lines.add((0...24).map { i in
                let t = 2 * Double.pi * Double(i) / 24
                return plane.point(m.u + r * cos(t), m.v + r * sin(t))
            }, color)
        }
        // Inference lines, dotted (SolidWorks: blue = guide only, yellow = adds a relation).
        let guideColor = dark ? RGBA(0.40, 0.62, 1.0) : RGBA(0.20, 0.45, 0.90)
        func dotted(_ a: Point2, _ b: Point2, _ c: RGBA) {
            let len = hypot(b.u - a.u, b.v - a.v)
            let dash = markerSize * 0.9, gap = markerSize * 0.9
            guard len > 0, dash > 0 else { return }
            var t = 0.0
            while t < len {
                let t1 = min(len, t + dash)
                lines.add([plane.point(a.u + (b.u - a.u) * t / len, a.v + (b.v - a.v) * t / len),
                           plane.point(a.u + (b.u - a.u) * t1 / len, a.v + (b.v - a.v) * t1 / len)], c)
                t = t1 + gap
            }
        }
        for g in pv.guides { dotted(g.from, g.to, guideColor) }
        if let g = pv.relationGuide {
            // Extend the relation line past the cursor, as SolidWorks does.
            let d = hypot(g.to.u - g.from.u, g.to.v - g.from.v)
            if d > 0 {
                let k = markerSize * 8 / d
                dotted(g.to, Point2(g.to.u + (g.to.u - g.from.u) * k, g.to.v + (g.to.v - g.from.v) * k), color)
            }
        }
        return [lines.item(objectID: ReferenceGeometry.firstObjectID + 1)]
    }
}

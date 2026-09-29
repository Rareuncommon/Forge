// How a dimension is drawn, as SolidWorks draws it: extension (witness) lines from the measured
// geometry to a dimension line through the value, arrows where the dimension line meets them;
// radius and diameter leaders through the circle; an arc with arrows between two lines for an
// angle. Everything is in sketch coordinates (mm). The value's position is stored on the
// constraint (`SketchConstraint.label`) relative to the dimension's reference point, so it
// follows the geometry when that moves or scales.

import ForgeCore
import Foundation

// Vector arithmetic on sketch points (this file's layouts).
extension Point2 {
    static func + (a: Point2, b: Point2) -> Point2 { Point2(a.u + b.u, a.v + b.v) }
    static func - (a: Point2, b: Point2) -> Point2 { Point2(a.u - b.u, a.v - b.v) }
    static func * (a: Point2, k: Double) -> Point2 { Point2(a.u * k, a.v * k) }
    func dot(_ b: Point2) -> Double { u * b.u + v * b.v }
    func cross(_ b: Point2) -> Double { u * b.v - v * b.u }
    var length: Double { hypot(u, v) }
    var normalized: Point2 { let l = length; return l > 0 ? self * (1 / l) : self }
}

public struct DimensionArrow: Sendable, Equatable {
    /// Where the arrowhead's point is.
    public var tip: Point2
    /// Unit direction the arrowhead points (from its base to its tip).
    public var direction: Point2
}

public struct DimensionLayout: Sendable, Equatable {
    /// Extension lines, from the geometry to the dimension line (drawn a little past it).
    public var extensions: [(Point2, Point2)]
    /// The dimension line, leaders and angle arcs (as short chords).
    public var segments: [(Point2, Point2)]
    public var arrows: [DimensionArrow]
    /// Centre of the value's text.
    public var text: Point2

    public static func == (a: Self, b: Self) -> Bool {
        func same(_ x: [(Point2, Point2)], _ y: [(Point2, Point2)]) -> Bool {
            x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
        return a.arrows == b.arrows && a.text == b.text && same(a.extensions, b.extensions) && same(a.segments, b.segments)
    }
}

extension Sketch {
    private func pt(_ id: String) -> Point2 {
        let (u, v) = point(id)
        return Point2(u, v)
    }

    /// A point entity's position, or a circle's / arc's / ellipse's centre.
    private func centre(_ e: SketchEntity) -> Point2? {
        switch e.kind {
        case .point: pt(e.id)
        case .circle, .arc, .ellipse, .ellipseArc: pt(e.points[0])
        default: nil
        }
    }

    /// The two points a linear dimension measures between (the second may be the foot on a line).
    private func linearEnds(_ ids: [String]) -> (Point2, Point2)? {
        let es = ids.compactMap { entities[$0] }
        guard es.count == ids.count else { return nil }
        func foot(_ p: Point2, on line: SketchEntity) -> Point2 {
            let a = pt(line.points[0]), b = pt(line.points[1])
            let d = b - a, l2 = d.dot(d)
            return l2 > 0 ? a + d * ((p - a).dot(d) / l2) : a
        }
        switch es.count {
        case 1 where es[0].kind == .line:
            return (pt(es[0].points[0]), pt(es[0].points[1]))
        case 2:
            let (e0, e1) = (es[0], es[1])
            if e0.kind == .line && e1.kind == .line {
                let m = (pt(e0.points[0]) + pt(e0.points[1])) * 0.5
                return (m, foot(m, on: e1))
            }
            if e0.kind == .line, let c = centre(e1) { return (c, foot(c, on: e0)) }
            if e1.kind == .line, let c = centre(e0) { return (c, foot(c, on: e1)) }
            guard let c0 = centre(e0), let c1 = centre(e1) else { return nil }
            return (c0, c1)
        default:
            return nil
        }
    }

    /// Centre and radius of the circle or arc a radius / diameter dimension measures.
    private func circle(_ ids: [String]) -> (Point2, Double)? {
        guard ids.count == 1, let e = entities[ids[0]] else { return nil }
        switch e.kind {
        case .circle: return (pt(e.points[0]), params[e.params[0]])
        case .arc: return (pt(e.points[0]), (pt(e.points[1]) - pt(e.points[0])).length)
        default: return nil
        }
    }

    /// The vertex and the two lines' directions (as drawn, start → end) of an angle.
    private func angleFrame(_ ids: [String]) -> (vertex: Point2, d1: Point2, d2: Point2, reach: Double)? {
        guard ids.count == 2, let l1 = entities[ids[0]], let l2 = entities[ids[1]], l1.kind == .line, l2.kind == .line else { return nil }
        let a1 = pt(l1.points[0]), b1 = pt(l1.points[1]), a2 = pt(l2.points[0]), b2 = pt(l2.points[1])
        let d1 = b1 - a1, d2 = b2 - a2
        let den = d1.cross(d2)
        guard abs(den) > 1e-12 * max(1, d1.length * d2.length), d1.length > 0, d2.length > 0 else { return nil }
        let t = (a2 - a1).cross(d2) / den
        let v = a1 + d1 * t
        let reach = max((a1 - v).length, (b1 - v).length, (a2 - v).length, (b2 - v).length)
        return (v, d1.normalized, d2.normalized, reach)
    }

    /// The point a dimension's value position is stored relative to: the middle of a linear
    /// dimension's two points, a circle's centre or an angle's vertex.
    public func dimensionReference(_ kind: ConstraintKind, _ ids: [String]) -> Point2? {
        switch kind {
        case .radius, .diameter: return circle(ids)?.0
        case .angle: return angleFrame(ids)?.vertex
        case .distance, .horizontalDistance, .verticalDistance:
            return linearEnds(ids).map { ($0.0 + $0.1) * 0.5 }
        case .offset:
            return ids.first.flatMap { entities[$0] }.flatMap { e in e.kind == .line ? (pt(e.points[0]) + pt(e.points[1])) * 0.5 : centre(e) }
        default: return nil
        }
    }

    /// Where the value goes when the dimension has no stored position: beside a line (on its
    /// left), outside a circle at 45°, inside the angle between two lines.
    public func defaultDimensionLabel(_ kind: ConstraintKind, _ ids: [String]) -> Point2? {
        switch kind {
        case .radius, .diameter:
            guard let (c, r) = circle(ids) else { return nil }
            return c + Point2(0.7071, 0.7071) * (r * 1.35)
        case .angle:
            guard let f = angleFrame(ids) else { return nil }
            let bis = f.d1 + f.d2
            return f.vertex + (bis.length > 1e-9 ? bis.normalized : f.d1) * (f.reach * 0.5)
        case .distance, .horizontalDistance, .verticalDistance:
            guard let (a, b) = linearEnds(ids) else { return nil }
            let d = Self.direction(kind, a, b)
            let len = abs((b - a).dot(d))
            let n = Point2(-d.v, d.u)
            return (a + b) * 0.5 + n * max(len * 0.2, 1)
        default:
            return dimensionReference(kind, ids)
        }
    }

    /// The direction a linear dimension measures along.
    private static func direction(_ kind: ConstraintKind, _ a: Point2, _ b: Point2) -> Point2 {
        switch kind {
        case .horizontalDistance: return Point2(1, 0)
        case .verticalDistance: return Point2(0, 1)
        default:
            let d = b - a
            return d.length > 1e-12 ? d.normalized : Point2(1, 0)
        }
    }

    /// The layout of constraint `c` (a dimension), its value at its stored position.
    public func dimensionLayout(_ c: SketchConstraint) -> DimensionLayout? {
        guard c.kind.isDimension else { return nil }
        let at = c.label.flatMap { l in dimensionReference(c.kind, c.entities).map { $0 + Point2(l[0], l[1]) } }
        return dimensionLayout(c.kind, c.entities, label: at)
    }

    /// The layout of a dimension of `kind` on `ids` with its value at `label` (sketch
    /// coordinates; nil: the default position).
    public func dimensionLayout(_ kind: ConstraintKind, _ ids: [String], label: Point2?) -> DimensionLayout? {
        guard let label = label ?? defaultDimensionLabel(kind, ids) else { return nil }
        switch kind {
        case .distance, .horizontalDistance, .verticalDistance:
            guard let (a, b) = linearEnds(ids) else { return nil }
            let d = Self.direction(kind, a, b)
            let n = Point2(-d.v, d.u)
            // Feet of the extension lines on the dimension line through the value.
            let a2 = a + n * (label - a).dot(n), b2 = b + n * (label - b).dot(n)
            let ext = [(a, a2), (b, b2)].filter { ($0.1 - $0.0).length > 1e-9 }
            var segs: [(Point2, Point2)] = []
            // The dimension line, extended to the value when that sits outside.
            let ta = (a2 - label).dot(d), tb = (b2 - label).dot(d)
            let lo = min(ta, tb, 0), hi = max(ta, tb, 0)
            segs.append((label + d * lo, label + d * hi))
            var arrows: [DimensionArrow] = []
            if (b2 - a2).length > 1e-9 {
                let u = (b2 - a2).normalized
                arrows = [DimensionArrow(tip: a2, direction: u * -1), DimensionArrow(tip: b2, direction: u)]
            }
            return DimensionLayout(extensions: ext, segments: segs, arrows: arrows, text: label)
        case .radius, .diameter:
            guard let (c, r) = circle(ids) else { return nil }
            let off = label - c
            let u = off.length > 1e-9 ? off.normalized : Point2(1, 0)
            let p1 = c + u * r
            let far = max(off.length, r)
            if kind == .radius {
                return DimensionLayout(extensions: [], segments: [(c, c + u * far)], arrows: [DimensionArrow(tip: p1, direction: u)], text: label)
            }
            let p2 = c - u * r
            return DimensionLayout(
                extensions: [], segments: [(p2, c + u * far)], arrows: [DimensionArrow(tip: p1, direction: u), DimensionArrow(tip: p2, direction: u * -1)], text: label)
        case .angle:
            guard let f = angleFrame(ids), let l1 = entities[ids[0]], let l2 = entities[ids[1]] else { return nil }
            // The measured angle is between the directions as drawn; the opposite sector shows
            // the same angle, so the arc goes in whichever of the two holds the value.
            let flip = (label - f.vertex).dot(f.d1 + f.d2) < 0 ? -1.0 : 1.0
            let r1 = f.d1 * flip, r2 = f.d2 * flip
            let radius = max((label - f.vertex).length, 1e-6)
            let t1 = atan2(r1.v, r1.u)
            var sweep = atan2(r1.cross(r2), r1.dot(r2))
            if abs(sweep) < 1e-9 { sweep = 1e-9 }
            let n = max(8, Int(abs(sweep) / (.pi / 48)))
            var segs: [(Point2, Point2)] = []
            func at(_ t: Double) -> Point2 { f.vertex + Point2(cos(t), sin(t)) * radius }
            for k in 0..<n {
                segs.append((at(t1 + sweep * Double(k) / Double(n)), at(t1 + sweep * Double(k + 1) / Double(n))))
            }
            // Extension lines along each ray when the arc is beyond the line.
            var ext: [(Point2, Point2)] = []
            for (ray, line) in [(r1, l1), (r2, l2)] {
                let reach = max(0, (pt(line.points[0]) - f.vertex).dot(ray), (pt(line.points[1]) - f.vertex).dot(ray))
                if reach < radius { ext.append((f.vertex + ray * reach, f.vertex + ray * radius)) }
            }
            let s = sweep > 0 ? 1.0 : -1.0
            // Tangents at the arc's ends, pointing out of the arc.
            let tanStart = Point2(sin(t1), -cos(t1)) * s, tEnd = t1 + sweep
            let tanEnd = Point2(-sin(tEnd), cos(tEnd)) * s
            return DimensionLayout(
                extensions: ext, segments: segs, arrows: [DimensionArrow(tip: at(t1), direction: tanStart), DimensionArrow(tip: at(tEnd), direction: tanEnd)], text: label)
        default:
            // Offsets: the value beside the offset copy, with a leader from its reference point.
            guard let ref = dimensionReference(kind, ids) else { return nil }
            return DimensionLayout(extensions: [], segments: (label - ref).length > 1e-9 ? [(ref, label)] : [], arrows: [], text: label)
        }
    }
}

extension Sketch {
    /// Place dimension `id`'s value at `at` (sketch coordinates); nil: back to the default.
    public mutating func setDimensionLabel(_ id: String, at: Point2?) throws {
        guard let i = constraints.firstIndex(where: { $0.id == id && !$0.isInternal }) else {
            throw ForgeError(.unknownEntity, "sketch \(self.id) has no dimension '\(id)'", entities: ["\(self.id)/\(id)"])
        }
        let c = constraints[i]
        guard c.kind.isDimension else { throw ForgeError(.invalidParams, "\(id) is a \(c.kind.rawValue) relation, not a dimension", entities: [id]) }
        guard let at else {
            constraints[i].label = nil
            return
        }
        guard let ref = dimensionReference(c.kind, c.entities) else { return }
        constraints[i].label = [at.u - ref.u, at.v - ref.v]
    }

    /// SolidWorks' "scale sketch on first dimension": when a length dimension of `kind` on
    /// `ids` with `value` would be the sketch's first, scale everything drawn about the sketch
    /// origin so it already measures `value`. The profile keeps its proportions instead of one
    /// entity shrinking or growing alone. Does nothing (returns nil) when the sketch already
    /// has a length dimension, has fixed geometry, or the dimension is an angle. Returns the
    /// factor applied.
    @discardableResult
    public mutating func scaleForFirstDimension(_ kind: ConstraintKind, _ ids: [String], value: Double) throws -> Double? {
        guard kind.isDimension, !kind.isAngular, kind != .offset, value > 0 else { return nil }
        guard !userConstraints.contains(where: { ($0.kind.isDimension && !$0.kind.isAngular) || $0.kind == .fix }) else { return nil }
        let norm = try normalize(kind, ids)
        let probe = SketchConstraint(id: "", kind: kind, entities: norm, value: nil, driven: false, side: chooseSide(kind, norm), isInternal: false)
        let current = abs(measure(probe) { self.params[$0] })
        guard current > 1e-9 else { return nil }
        let f = value / current
        guard abs(f - 1) > 1e-9 else { return nil }
        let drawn = entityOrder.filter { id in id != Self.originID && entities[id]?.owner == nil }
        guard !drawn.isEmpty else { return nil }
        _ = try scale(drawn, about: (0, 0), by: f, keepRelations: true)
        return f
    }
}

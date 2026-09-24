import ForgeCore
import Foundation

/// Where the cursor snaps while sketching, and why (SolidWorks' inference).
public struct SketchSnap: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// No inference: the raw cursor position.
        case none
        /// An existing point (endpoint, centre, sketch point).
        case point
        /// The midpoint of a line.
        case midpoint
        /// On a curve (nearest point).
        case onCurve
        /// Horizontal / vertical from the point the entity is drawn from (within 3°).
        case horizontal, vertical
        /// Lined up horizontally and/or vertically with other points (dotted guides).
        case aligned
    }

    public var point: Point2
    public var kind: Kind
    /// The point, line (midpoint) or curve snapped to.
    public var target: String?
    /// Inference guides: from the point lined up with, to the snapped position.
    public var guides: [Guide]

    public struct Guide: Sendable, Equatable {
        public var from: Point2
        public var to: Point2

        public init(from: Point2, to: Point2) {
            self.from = from
            self.to = to
        }
    }

    public init(point: Point2, kind: Kind, target: String? = nil, guides: [Guide] = []) {
        self.point = point
        self.kind = kind
        self.target = target
        self.guides = guides
    }
}

extension Sketch {
    /// Snap a cursor position. `tolerance` is the capture distance in sketch units (a few
    /// pixels); `from` is the point the entity is being drawn from (horizontal/vertical
    /// inference); `extra` are pending points not yet in the sketch (they can be lined up with).
    ///
    /// Priority: existing point, line midpoint, horizontal/vertical from `from` (combined with
    /// alignment to other points), on a curve, then alignment alone.
    public func snap(_ raw: Point2, tolerance: Double, from: Point2? = nil, extra: [Point2] = []) -> SketchSnap {
        let pts: [(id: String?, p: Point2)] =
            orderedEntities.filter { $0.kind == .point }.map { e in let (u, v) = point(e.id); return (e.id, Point2(u, v)) }
            + extra.map { (nil, $0) }
        func dist(_ a: Point2, _ b: Point2) -> Double { hypot(a.u - b.u, a.v - b.v) }

        if let best = pts.filter({ $0.id != nil }).min(by: { dist($0.p, raw) < dist($1.p, raw) }), dist(best.p, raw) <= tolerance {
            return SketchSnap(point: best.p, kind: .point, target: best.id)
        }
        if let from, dist(from, raw) <= tolerance {
            return SketchSnap(point: from, kind: .point)
        }
        for e in orderedEntities where e.kind == .line {
            let (a, b) = (point(e.points[0]), point(e.points[1]))
            let m = Point2((a.0 + b.0) / 2, (a.1 + b.1) / 2)
            if dist(m, raw) <= tolerance { return SketchSnap(point: m, kind: .midpoint, target: e.id) }
        }

        var u = raw.u, v = raw.v
        var kind = SketchSnap.Kind.none
        var lockedU = false, lockedV = false
        if let s = from {
            let dx = raw.u - s.u, dy = raw.v - s.v
            let t = tan(3 * Double.pi / 180)
            if dx != 0 || dy != 0 {
                if abs(dy) <= abs(dx) * t {
                    v = s.v; lockedV = true; kind = .horizontal
                } else if abs(dx) <= abs(dy) * t {
                    u = s.u; lockedU = true; kind = .vertical
                }
            }
        }
        // Alignment with other points: the closest one per axis, within the tolerance.
        var guides: [SketchSnap.Guide] = []
        var alignU: Point2?, alignV: Point2?
        let candidates = pts.map(\.p) + (from.map { [$0] } ?? [])
        if !lockedU {
            alignU = candidates.filter { abs($0.u - raw.u) <= tolerance && abs($0.v - raw.v) > tolerance }
                .min { abs($0.u - raw.u) < abs($1.u - raw.u) }
            if let q = alignU { u = q.u }
        }
        if !lockedV {
            alignV = candidates.filter { abs($0.v - raw.v) <= tolerance && abs($0.u - raw.u) > tolerance }
                .min { abs($0.v - raw.v) < abs($1.v - raw.v) }
            if let q = alignV { v = q.v }
        }
        let snapped = Point2(u, v)
        if let q = alignU { guides.append(.init(from: q, to: snapped)) }
        if let q = alignV { guides.append(.init(from: q, to: snapped)) }
        if kind != .none { return SketchSnap(point: snapped, kind: kind, guides: guides) }

        // On a curve (the nearest point of its polyline) beats lining up with other points.
        var best: (Point2, String, Double)?
        for e in orderedEntities where e.kind != .point {
            let pl = polyline(e.id)
            for i in 0..<max(0, pl.count - 1) {
                let q = Self.closest(raw, Point2(pl[i].0, pl[i].1), Point2(pl[i + 1].0, pl[i + 1].1))
                let d = dist(q, raw)
                if d <= tolerance && (best == nil || d < best!.2) { best = (q, e.id, d) }
            }
        }
        if let b = best { return SketchSnap(point: b.0, kind: .onCurve, target: b.1) }
        if !guides.isEmpty { return SketchSnap(point: snapped, kind: .aligned, guides: guides) }
        return SketchSnap(point: raw, kind: .none)
    }

    static func closest(_ p: Point2, _ a: Point2, _ b: Point2) -> Point2 {
        let dx = b.u - a.u, dy = b.v - a.v
        let l2 = dx * dx + dy * dy
        guard l2 > 0 else { return a }
        let t = max(0, min(1, ((p.u - a.u) * dx + (p.v - a.v) * dy) / l2))
        return Point2(a.u + t * dx, a.v + t * dy)
    }
}

/// The dimension Smart Dimension would add for a set of picked entities, and its current value.
public struct SketchMeasurement: Sendable, Equatable {
    /// distance, horizontal_distance, vertical_distance, radius, diameter or angle.
    public var kind: ConstraintKind
    /// mm, or radians for an angle.
    public var value: Double
}

extension Sketch {
    /// What to dimension for the picked entities (in pick order), measured now: one line →
    /// length; circle → diameter; arc → radius; two lines → angle (distance if parallel); two
    /// points, a point and a line, or curves' centres → distance. `mode` chooses horizontal or
    /// vertical instead of aligned distance between two points.
    public func measure(_ ids: [String], mode: ConstraintKind = .distance) -> SketchMeasurement? {
        let es = ids.compactMap { entities[$0] }
        guard es.count == ids.count, !es.isEmpty else { return nil }
        func p(_ id: String) -> Point2 { let (u, v) = point(id); return Point2(u, v) }
        func center(_ e: SketchEntity) -> Point2? {
            switch e.kind {
            case .point: p(e.id)
            case .circle, .arc, .ellipse, .ellipseArc: p(e.points[0])
            default: nil
            }
        }
        switch es.count {
        case 1:
            let e = es[0]
            switch e.kind {
            case .line:
                let a = p(e.points[0]), b = p(e.points[1])
                return SketchMeasurement(kind: .distance, value: hypot(b.u - a.u, b.v - a.v))
            case .circle:
                return SketchMeasurement(kind: .diameter, value: 2 * params[e.params[0]])
            case .arc:
                let c = p(e.points[0]), s = p(e.points[1])
                return SketchMeasurement(kind: .radius, value: hypot(s.u - c.u, s.v - c.v))
            default:
                return nil
            }
        case 2:
            let (e0, e1) = (es[0], es[1])
            if e0.kind == .line && e1.kind == .line {
                let a0 = p(e0.points[0]), a1 = p(e0.points[1]), b0 = p(e1.points[0]), b1 = p(e1.points[1])
                let (ux, uy, vx, vy) = (a1.u - a0.u, a1.v - a0.v, b1.u - b0.u, b1.v - b0.v)
                let angle = abs(atan2(ux * vy - uy * vx, ux * vx + uy * vy))
                if angle > 1e-6 && abs(angle - .pi) > 1e-6 { return SketchMeasurement(kind: .angle, value: angle) }
                let len = hypot(ux, uy)
                guard len > 0 else { return nil }
                return SketchMeasurement(kind: .distance, value: abs((b0.u - a0.u) * uy - (b0.v - a0.v) * ux) / len)
            }
            if let line = es.first(where: { $0.kind == .line }), let other = es.first(where: { $0.kind != .line }), let c = center(other) {
                let a = p(line.points[0]), b = p(line.points[1])
                let len = hypot(b.u - a.u, b.v - a.v)
                guard len > 0 else { return nil }
                return SketchMeasurement(kind: .distance, value: abs((c.u - a.u) * (b.v - a.v) - (c.v - a.v) * (b.u - a.u)) / len)
            }
            guard let c0 = center(e0), let c1 = center(e1) else { return nil }
            switch mode {
            case .horizontalDistance: return SketchMeasurement(kind: .horizontalDistance, value: abs(c1.u - c0.u))
            case .verticalDistance: return SketchMeasurement(kind: .verticalDistance, value: abs(c1.v - c0.v))
            default: return SketchMeasurement(kind: .distance, value: hypot(c1.u - c0.u, c1.v - c0.v))
            }
        default:
            return nil
        }
    }
}

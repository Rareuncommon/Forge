import ForgeCore
import Foundation

/// Characteristic length that turns angular residuals (radians) into length-like residuals
/// so rows are comparably scaled.
let angularScale = 10.0

extension Sketch {
    // MARK: validation and normalisation

    func kinds(_ ids: [String]) throws -> [SketchEntityKind] {
        try ids.map { try entity($0).kind }
    }

    static func isRound(_ k: SketchEntityKind) -> Bool { k == .circle || k == .arc }
    static func isCurve(_ k: SketchEntityKind) -> Bool { k != .point }

    /// Checks entity types for a constraint and returns the entity list in canonical order.
    func normalize(_ kind: ConstraintKind, _ ids: [String]) throws -> [String] {
        func bad(_ expected: String) -> ForgeError {
            ForgeError(
                .invalidParams,
                "\(kind.rawValue) needs \(expected); got \(ids.isEmpty ? "nothing" : ids.joined(separator: ", "))",
                entities: ids.map { "\(id)/\($0)" })
        }
        guard Set(ids).count == ids.count else { throw ForgeError(.invalidParams, "\(kind.rawValue): the same entity is listed twice") }
        let k = try kinds(ids)
        switch kind {
        case .coincident:
            guard k == [.point, .point] else {
                if k.count == 2, k.contains(.point), k.contains(where: Self.isCurve) {
                    throw ForgeError(
                        .invalidParams, "use on_entity to put a point on a curve", entities: ids,
                        suggestions: [SuggestedFix(description: "Point on curve", command: "sketch.add_relation", params: ["type": "on_entity", "entities": .array(ids.map { .string($0) })])])
                }
                throw bad("two points")
            }
            return ids
        case .onEntity:
            guard k.count == 2, k.filter({ $0 == .point }).count >= 1, k.contains(where: Self.isCurve) || k == [.point, .point] else {
                throw bad("a point and a curve")
            }
            guard k.contains(where: Self.isCurve) else { throw bad("a point and a curve (use coincident for two points)") }
            return k[0] == .point ? ids : [ids[1], ids[0]]
        case .horizontal, .vertical:
            if k == [.line] || k == [.point, .point] { return ids }
            throw bad("one line or two points")
        case .parallel, .perpendicular, .collinear:
            guard k == [.line, .line] else { throw bad("two lines") }
            return ids
        case .tangent:
            guard k.count == 2 else { throw bad("a line and a circle/arc, or two circles/arcs") }
            if k.contains(.spline) {
                guard k.allSatisfy({ $0 == .line || $0 == .arc || $0 == .spline }) else {
                    throw bad("a spline and a line, arc or spline that share an endpoint")
                }
                let ordered = k[0] == .spline && k[1] != .spline ? [ids[1], ids[0]] : ids
                guard sharedTangencyPoint(ordered) != nil else {
                    // NOT IMPLEMENTED: tangency to a spline away from its ends.
                    throw ForgeError(
                        .notImplemented, "tangency to a spline is only supported where it meets the other curve at one of its ends",
                        entities: ids.map { "\(id)/\($0)" })
                }
                return ordered
            }
            if k[0] == .line && Self.isRound(k[1]) { return ids }
            if k[1] == .line && Self.isRound(k[0]) { return [ids[1], ids[0]] }
            if Self.isRound(k[0]) && Self.isRound(k[1]) { return ids }
            throw bad("a line and a circle/arc, or two circles/arcs")
        case .equal:
            if k == [.line, .line] { return ids }
            if k.count == 2, Self.isRound(k[0]), Self.isRound(k[1]) { return ids }
            throw bad("two lines or two circles/arcs")
        case .symmetric:
            guard k.count == 3, k[2] == .line, k[0] == k[1], k[0] != .ellipse, k[0] != .ellipseArc else {
                throw bad("two points, lines, circles or arcs and a line (the symmetry axis)")
            }
            return ids
        case .midpoint:
            if k == [.point, .line] { return ids }
            if k == [.line, .point] { return [ids[1], ids[0]] }
            throw bad("a point and a line")
        case .concentric:
            guard k.count == 2, k.allSatisfy({ $0 != .line }), k.contains(where: { $0 != .point }) else {
                throw bad("two circles/arcs/ellipses (or one and a point)")
            }
            return ids
        case .coradial:
            guard k.count == 2, k.allSatisfy(Self.isRound) else { throw bad("two circles/arcs") }
            return ids
        case .fix:
            guard k.count == 1 else { throw bad("one entity") }
            return ids
        case .distance:
            switch k {
            case [.line], [.point, .point], [.line, .line]: return ids
            case [.point, .line]: return ids
            case [.line, .point]: return [ids[1], ids[0]]
            default:
                if k.count == 2, k.allSatisfy({ $0 == .point || Self.isRound($0) || $0 == .ellipse }) { return ids }  // centre distance
                throw bad("a line, or two of point/line/circle")
            }
        case .horizontalDistance, .verticalDistance:
            guard k == [.line] || k == [.point, .point] else { throw bad("one line or two points") }
            return ids
        case .radius, .diameter:
            guard k.count == 1, Self.isRound(k[0]) else { throw bad("one circle or arc") }
            return ids
        case .angle:
            guard k == [.line, .line] else { throw bad("two lines") }
            return ids
        case .offset:
            guard k.count == 2, k[0] == k[1], k[0] == .line || Self.isRound(k[0]) else {
                throw bad("two lines, two arcs or two circles (original, then offset copy)")
            }
            return ids
        case .arcRadius:
            return ids
        }
    }

    // MARK: residuals

    /// Rows a constraint contributes to the system (0 for fix and driven dimensions).
    func rowCount(_ c: SketchConstraint) -> Int {
        if c.driven || c.kind == .fix { return 0 }
        switch c.kind {
        case .coincident, .midpoint, .concentric, .collinear: return 2
        case .symmetric:
            switch entities[c.entities[0]]?.kind {
            case .line: return 4
            case .circle: return 3
            case .arc: return 5  // centre (2) + start↔end (2) + end↔start angle (1); radius is internal
            default: return 2
            }
        case .coradial: return 3
        case .onEntity where entities[c.entities[1]]?.kind == .spline: return 2
        case .offset:
            let tangent = c.tangentEnds?.count ?? 0, aligned = c.alignedEnds?.count ?? 0
            return entities[c.entities[0]]?.kind == .line ? 2 + aligned : 3 - (tangent > 0 ? 1 : 0) + aligned + tangent
        default: return 1
        }
    }

    /// Parameter indices a constraint depends on (sorted, unique).
    func constraintParams(_ c: SketchConstraint) -> [Int] {
        Array(Set(c.entities.flatMap { e -> [Int] in
            guard let ent = entities[e] else { return [] }
            return ent.kind == .point ? ent.params : paramIndices(e)
        } + (c.aux ?? []))).sorted()
    }

    /// Evaluate a constraint's residuals. `p` maps a global parameter index to a scalar.
    func residuals<D: SolverScalar>(_ c: SketchConstraint, _ p: (Int) -> D) -> [D] {
        func pt(_ id: String) -> V2<D> {
            let e = entities[id]!
            return V2(x: p(e.params[0]), y: p(e.params[1]))
        }
        func ends(_ line: String) -> (V2<D>, V2<D>) {
            let e = entities[line]!
            return (pt(e.points[0]), pt(e.points[1]))
        }
        /// Centre of a circle/arc/ellipse, or the point itself.
        func center(_ id: String) -> V2<D> {
            let e = entities[id]!
            return e.kind == .point ? pt(id) : pt(e.points[0])
        }
        func radius(_ id: String) -> D {
            let e = entities[id]!
            if e.kind == .circle { return p(e.params[0]) }
            return (pt(e.points[1]) - pt(e.points[0])).length  // arc: |start - centre|
        }
        /// Signed distance from a point to the infinite line through a line entity.
        func lineDistance(_ q: V2<D>, _ line: String) -> D {
            let (a, b) = ends(line)
            let d = b - a
            return d.cross(q - a) / d.length
        }
        let v = D(constant: c.value ?? 0)
        let s = c.side
        let ids = c.entities
        switch c.kind {
        case .coincident:
            let a = pt(ids[0]), b = pt(ids[1])
            return [a.x - b.x, a.y - b.y]
        case .onEntity:
            let q = pt(ids[0])
            let curve = entities[ids[1]]!
            switch curve.kind {
            case .line: return [lineDistance(q, ids[1])]
            case .circle, .arc: return [(q - center(ids[1])).length - radius(ids[1])]
            case .ellipse, .ellipseArc:
                let c0 = center(ids[1]), a = p(curve.params[0]), b = p(curve.params[1]), rot = p(curve.params[2])
                let d = q - c0
                let cr = D.cos(rot), sr = D.sin(rot)
                let u = d.x * cr + d.y * sr, w = -(d.x * sr) + d.y * cr
                // Approximate distance: (normalised radius - 1) · geometric mean axis.
                return [(D.sqrt((u / a) * (u / a) + (w / b) * (w / b)) - D(constant: 1)) * D.sqrt(a * b)]
            case .spline:
                // q = S(t) with the curve parameter t as an extra unknown (clamped to [0, 1] in
                // evaluation so the solver cannot run off the ends).
                let poles = curve.points.map(pt)
                return BSpline.residual(q, poles, degree: curve.degree ?? 3, t: p(c.aux![0]))
            case .point: return []
            }
        case .horizontal:
            if ids.count == 1 {
                let (a, b) = ends(ids[0])
                return [a.y - b.y]
            }
            return [pt(ids[0]).y - pt(ids[1]).y]
        case .vertical:
            if ids.count == 1 {
                let (a, b) = ends(ids[0])
                return [a.x - b.x]
            }
            return [pt(ids[0]).x - pt(ids[1]).x]
        case .parallel:
            // The angle between the lines folded into (−π/2, π/2]: zero only when parallel (a
            // zero-length line cannot satisfy it, unlike a bare cross product), and slope 1
            // everywhere — even from an exactly perpendicular start, where sin θ is stationary.
            let (a1, b1) = ends(ids[0]), (a2, b2) = ends(ids[1])
            let d1 = b1 - a1, d2 = b2 - a2
            let (cr, dt) = (d1.cross(d2), d1.dot(d2))
            let f = dt.value < 0 ? -1.0 : 1.0
            return [D.atan2(cr * f, dt * f) * angularScale]
        case .perpendicular:
            // Same, for the angle away from perpendicular.
            let (a1, b1) = ends(ids[0]), (a2, b2) = ends(ids[1])
            let d1 = b1 - a1, d2 = b2 - a2
            let (cr, dt) = (d1.cross(d2), d1.dot(d2))
            let f = cr.value < 0 ? -1.0 : 1.0
            return [D.atan2(dt * f, cr * f) * angularScale]
        case .collinear:
            let (a2, b2) = ends(ids[1])
            return [lineDistance(a2, ids[0]), lineDistance(b2, ids[0])]
        case .tangent:
            if entities[ids[1]]!.kind == .spline, let at = c.at {
                // Spline end: its end tangent is the first/last control-point leg.
                let sp = entities[ids[1]]!.points
                let t = at == sp.first! ? pt(sp[1]) - pt(sp[0]) : pt(sp[sp.count - 1]) - pt(sp[sp.count - 2])
                let first = entities[ids[0]]!
                let dir: V2<D>
                switch first.kind {
                case .line:
                    let (a, b) = ends(ids[0])
                    dir = b - a
                case .spline:
                    let op = first.points
                    let shared = pt(at)
                    let atStart = (pt(op[0]) - shared).length.value < (pt(op[op.count - 1]) - shared).length.value
                    dir = atStart ? pt(op[1]) - pt(op[0]) : pt(op[op.count - 1]) - pt(op[op.count - 2])
                default:
                    // Arc: the tangent is perpendicular to the radius at the shared point.
                    let r = pt(at) - center(ids[0])
                    dir = V2(x: -r.y, y: r.x)
                }
                return [dir.cross(t) / (dir.length * t.length) * angularScale]
            }
            if let at = c.at {
                // Endpoint tangency: the tangent direction at the shared point is continuous.
                let q = pt(at)
                if entities[ids[0]]!.kind == .line {
                    let (a, b) = ends(ids[0])
                    let d = b - a
                    return [d.dot(q - center(ids[1])) / d.length]
                }
                let u = q - center(ids[0]), w = q - center(ids[1])
                return [u.cross(w) / w.length]
            }
            if entities[ids[0]]!.kind == .line {
                return [lineDistance(center(ids[1]), ids[0]) * s - radius(ids[1])]
            }
            let dist = (center(ids[0]) - center(ids[1])).length
            // side > 0: external (d = r1 + r2); side < 0: internal (d = |r1 - r2|, sign fixed at creation).
            if s > 0 { return [dist - (radius(ids[0]) + radius(ids[1]))] }
            let inner = (radius(ids[0]) - radius(ids[1])) * (s < -1.5 ? -1.0 : 1.0)
            return [dist - inner]
        case .equal:
            if entities[ids[0]]!.kind == .line {
                let (a1, b1) = ends(ids[0]), (a2, b2) = ends(ids[1])
                return [(b1 - a1).length - (b2 - a2).length]
            }
            return [radius(ids[0]) - radius(ids[1])]
        case .symmetric:
            let (la, lb) = ends(ids[2])
            let d = lb - la
            func sym(_ a: V2<D>, _ b: V2<D>) -> [D] {
                [lineDistance((a + b) * D(constant: 0.5), ids[2]), (b - a).dot(d) / d.length]
            }
            func reflect(_ q: V2<D>) -> V2<D> {
                let n = V2(x: -d.y / d.length, y: d.x / d.length)
                return q - n * (lineDistance(q, ids[2]) * 2.0)
            }
            let e1 = entities[ids[0]]!, e2 = entities[ids[1]]!
            switch e1.kind {
            case .line:
                // side 1: start↔start; side -1: start↔end (chosen at creation).
                let (a1, b1) = ends(ids[0]), (a2, b2) = ends(ids[1])
                return s > 0 ? sym(a1, a2) + sym(b1, b2) : sym(a1, b2) + sym(b1, a2)
            case .circle:
                return sym(pt(e1.points[0]), pt(e2.points[0])) + [radius(ids[0]) - radius(ids[1])]
            case .arc:
                // A reflection reverses orientation: arc 2 runs from mirror(end 1) to mirror(start 1).
                // With the centres mirrored and arc 2's radius internal, the last end only needs its
                // angle; the cross product is regular everywhere on the circle.
                let c2 = pt(e2.points[0]), s2 = pt(e2.points[1])
                let m = reflect(pt(e1.points[2]))
                return sym(pt(e1.points[0]), c2) + sym(pt(e1.points[1]), pt(e2.points[2]))
                    + [(m - c2).cross(s2 - c2) / radius(ids[1])]
            default:
                return sym(pt(ids[0]), pt(ids[1]))
            }
        case .offset:
            // Copy at signed distance side·value from the original (left of a line's direction;
            // outward for circles/arcs), plus aligned free ends.
            let orig = entities[ids[0]]!, copy = entities[ids[1]]!
            let tangent = c.tangentEnds ?? []
            var rows: [D]
            if orig.kind == .line {
                rows = copy.points.filter { !tangent.contains($0) }.map { lineDistance(pt($0), ids[0]) * s - v }
            } else {
                let c1 = center(ids[0]), c2 = center(ids[1])
                rows = [c2.x - c1.x, c2.y - c1.y]
                if tangent.isEmpty { rows.append((radius(ids[1]) - radius(ids[0])) * s - v) }
            }
            for p2 in (c.alignedEnds ?? []) + tangent {
                guard let k = copy.points.firstIndex(of: p2) else { continue }
                let q = pt(p2), o = pt(orig.points[k])
                if orig.kind == .line {
                    let (a, b) = ends(ids[0])
                    let d = b - a
                    rows.append((q - o).dot(d) / d.length)
                } else {
                    let c1 = center(ids[0])
                    rows.append((o - c1).cross(q - c1) / radius(ids[0]))
                }
            }
            return rows
        case .midpoint:
            let q = pt(ids[0])
            let (a, b) = ends(ids[1])
            let m = (a + b) * D(constant: 0.5)
            return [q.x - m.x, q.y - m.y]
        case .concentric:
            let a = center(ids[0]), b = center(ids[1])
            return [a.x - b.x, a.y - b.y]
        case .coradial:
            let a = center(ids[0]), b = center(ids[1])
            return [a.x - b.x, a.y - b.y, radius(ids[0]) - radius(ids[1])]
        case .fix:
            return []
        case .distance:
            return [measure(c, p) - v]
        case .horizontalDistance, .verticalDistance, .radius, .diameter:
            return [measure(c, p) - v]
        case .angle:
            return [(measure(c, p) - v) * angularScale]
        case .arcRadius:
            let e = entities[ids[0]]!
            let c0 = pt(e.points[0])
            return [(pt(e.points[1]) - c0).length - (pt(e.points[2]) - c0).length]
        }
    }

    /// The quantity a dimension measures (mm or radians), in the orientation fixed by `side`.
    func measure<D: SolverScalar>(_ c: SketchConstraint, _ p: (Int) -> D) -> D {
        func pt(_ id: String) -> V2<D> {
            let e = entities[id]!
            return V2(x: p(e.params[0]), y: p(e.params[1]))
        }
        func ends(_ line: String) -> (V2<D>, V2<D>) {
            let e = entities[line]!
            return (pt(e.points[0]), pt(e.points[1]))
        }
        func center(_ id: String) -> V2<D> {
            let e = entities[id]!
            return e.kind == .point ? pt(id) : pt(e.points[0])
        }
        func radius(_ id: String) -> D {
            let e = entities[id]!
            if e.kind == .circle { return p(e.params[0]) }
            return (pt(e.points[1]) - pt(e.points[0])).length
        }
        let ids = c.entities
        let kinds = ids.map { entities[$0]!.kind }
        func pair() -> (V2<D>, V2<D>) {
            if kinds == [.line] { return ends(ids[0]) }
            return (pt(ids[0]), pt(ids[1]))
        }
        switch c.kind {
        case .distance:
            switch kinds {
            case [.line]:
                let (a, b) = ends(ids[0])
                return (b - a).length
            case [.point, .line]:
                let (a, b) = ends(ids[1])
                let d = b - a
                return d.cross(pt(ids[0]) - a) / d.length * c.side
            case [.line, .line]:
                let (a, b) = ends(ids[0])
                let d = b - a
                let (q, _) = ends(ids[1])
                return d.cross(q - a) / d.length * c.side
            default:
                return (center(ids[1]) - center(ids[0])).length
            }
        case .horizontalDistance:
            let (a, b) = pair()
            return (b.x - a.x) * c.side
        case .verticalDistance:
            let (a, b) = pair()
            return (b.y - a.y) * c.side
        case .offset:
            if entities[ids[0]]!.kind == .line {
                let (a2, _) = ends(ids[1]), (a, b) = ends(ids[0])
                let d = b - a
                return d.cross(a2 - a) / d.length * c.side
            }
            return (radius(ids[1]) - radius(ids[0])) * c.side
        case .radius:
            return radius(ids[0])
        case .diameter:
            return radius(ids[0]) * 2.0
        case .angle:
            let (a1, b1) = ends(ids[0]), (a2, b2) = ends(ids[1])
            let d1 = b1 - a1, d2 = b2 - a2
            return D.atan2(d1.cross(d2), d1.dot(d2)) * c.side
        default:
            return D(constant: 0)
        }
    }

    /// For a tangency between two curves that share an endpoint (by position), the endpoint of
    /// the circular curve at which to apply first-order endpoint tangency.
    func sharedTangencyPoint(_ ids: [String]) -> String? {
        guard ids.count == 2, let e0 = entities[ids[0]], let e1 = entities[ids[1]] else { return nil }
        func endpoints(_ e: SketchEntity) -> [String] {
            switch e.kind {
            case .line: return e.points
            case .arc: return [e.points[1], e.points[2]]
            case .spline: return [e.points.first!, e.points.last!]
            default: return []
            }
        }
        let scale = max(1, params.map(abs).max() ?? 1)
        let tol = 1e-7 * scale
        // The anchor is the spline's end (a spline is always second), else the circular
        // curve's endpoint (for arc-arc: the first arc's).
        let round = e1.kind == .spline ? e1 : e0.kind == .line ? e1 : e0
        let other = round.id == e1.id ? e0 : e1
        for p in endpoints(round) {
            let (x, y) = point(p)
            for q in endpoints(other) {
                let (u, v) = point(q)
                if abs(x - u) <= tol && abs(y - v) <= tol { return p }
            }
        }
        return nil
    }

    /// Choose the orientation (`side`) of a new constraint from the current geometry so that
    /// the constraint is satisfied by the nearest configuration.
    func chooseSide(_ kind: ConstraintKind, _ ids: [String]) -> Double {
        let x: (Int) -> Double = { self.params[$0] }
        func sign(_ v: Double) -> Double { v < 0 ? -1 : 1 }
        var probe = SketchConstraint(id: "", kind: kind, entities: ids, value: nil, driven: false, side: 1, isInternal: false)
        switch kind {
        case .tangent:
            if entities[ids[0]]!.kind == .line {
                let e = entities[ids[0]]!
                let (ax, ay) = point(e.points[0]), (bx, by) = point(e.points[1])
                let c = entities[ids[1]]!.points[0]
                let (cx, cy) = point(c)
                return sign((bx - ax) * (cy - ay) - (by - ay) * (cx - ax))
            }
            // external vs internal: whichever is closer to satisfied now.
            let (c1x, c1y) = point(entities[ids[0]]!.points[0]), (c2x, c2y) = point(entities[ids[1]]!.points[0])
            let d = ((c1x - c2x) * (c1x - c2x) + (c1y - c2y) * (c1y - c2y)).squareRoot()
            probe.kind = .radius
            probe.entities = [ids[0]]
            let r1 = measure(probe, x)
            probe.entities = [ids[1]]
            let r2 = measure(probe, x)
            if abs(d - (r1 + r2)) <= abs(d - abs(r1 - r2)) { return 1 }
            return r1 >= r2 ? -1 : -2
        case .distance:
            let k = ids.map { entities[$0]!.kind }
            if k == [.point, .line] || k == [.line, .line] {
                probe.side = 1
                return sign(measure(probe, x))
            }
            return 1
        case .symmetric where entities[ids[0]]!.kind == .line:
            // Pair each endpoint with the nearer mirror image.
            let a = entities[ids[0]]!, b = entities[ids[1]]!, axis = entities[ids[2]]!
            let (ax, ay) = point(axis.points[0]), (bx, by) = point(axis.points[1])
            let dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy
            func reflect(_ q: (Double, Double)) -> (Double, Double) {
                let t = ((q.0 - ax) * dx + (q.1 - ay) * dy) / l2
                let fx = ax + t * dx, fy = ay + t * dy
                return (2 * fx - q.0, 2 * fy - q.1)
            }
            func d2(_ p: (Double, Double), _ q: (Double, Double)) -> Double { (p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1) }
            let m0 = reflect(point(a.points[0])), m1 = reflect(point(a.points[1]))
            let (s0, s1) = (point(b.points[0]), point(b.points[1]))
            return d2(m0, s0) + d2(m1, s1) <= d2(m0, s1) + d2(m1, s0) ? 1 : -1
        case .horizontalDistance, .verticalDistance, .angle, .offset:
            probe.side = 1
            return sign(measure(probe, x))
        default:
            return 1
        }
    }
}

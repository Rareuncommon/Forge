import ForgeCore
import Foundation

/// A rigid 2D map used to copy sketch geometry (mirror, patterns).
struct RigidMap2 {
    /// x' = R·x + t, where R is a rotation or reflection times a uniform scale `k`.
    var r00: Double, r01: Double, r10: Double, r11: Double
    var tx: Double, ty: Double
    var k: Double = 1

    var isReflection: Bool { r00 * r11 - r01 * r10 < 0 }

    func apply(_ p: (Double, Double)) -> (Double, Double) {
        (r00 * p.0 + r01 * p.1 + tx, r10 * p.0 + r11 * p.1 + ty)
    }

    static func scaling(about c: (Double, Double), by f: Double) -> RigidMap2 {
        RigidMap2(r00: f, r01: 0, r10: 0, r11: f, tx: c.0 * (1 - f), ty: c.1 * (1 - f), k: f)
    }

    /// Maps a direction angle (e.g. an ellipse's major-axis rotation).
    func apply(angle a: Double) -> Double {
        atan2(r10 * cos(a) + r11 * sin(a), r00 * cos(a) + r01 * sin(a))
    }

    static func translation(_ dx: Double, _ dy: Double) -> RigidMap2 {
        RigidMap2(r00: 1, r01: 0, r10: 0, r11: 1, tx: dx, ty: dy)
    }

    static func rotation(about c: (Double, Double), by t: Double) -> RigidMap2 {
        let (cs, sn) = (cos(t), sin(t))
        return RigidMap2(r00: cs, r01: -sn, r10: sn, r11: cs, tx: c.0 - cs * c.0 + sn * c.1, ty: c.1 - sn * c.0 - cs * c.1)
    }

    /// Reflection across the line through a and b.
    static func reflection(_ a: (Double, Double), _ b: (Double, Double)) -> RigidMap2 {
        let dx = b.0 - a.0, dy = b.1 - a.1, l2 = dx * dx + dy * dy
        let (c2, s2) = ((dx * dx - dy * dy) / l2, 2 * dx * dy / l2)
        return RigidMap2(r00: c2, r01: s2, r10: s2, r11: -c2, tx: a.0 - c2 * a.0 - s2 * a.1, ty: a.1 - s2 * a.0 + c2 * a.1)
    }
}

extension Sketch {
    /// Curves and standalone points to copy, in sketch order. An endpoint whose curve is also
    /// selected is dropped (the curve brings it); a lone endpoint becomes a free point copy.
    func copySet(_ ids: [String], excluding: Set<String> = []) throws -> [String] {
        guard !ids.isEmpty else { throw ForgeError(.invalidParams, "select at least one entity") }
        var chosen = Set<String>()
        for id in ids {
            let e = try entity(id)
            guard id != Self.originID else { throw ForgeError(.invalidParams, "the sketch origin cannot be copied", entities: [id]) }
            guard !excluding.contains(id) else {
                throw ForgeError(.invalidParams, "\(id) is the mirror axis / pattern reference and cannot also be copied", entities: [id])
            }
            if e.kind == .point, let owner = e.owner, ids.contains(owner) { continue }
            chosen.insert(id)
        }
        return entityOrder.filter(chosen.contains)
    }

    /// Copies entities under `map`. Returns old → new ids for every copied curve and point.
    mutating func copy(_ ids: [String], _ map: RigidMap2) -> [String: String] {
        var m: [String: String] = [:]
        for id in ids {
            let e = entities[id]!
            let pts = e.points.map { point($0) }
            let n: String
            switch e.kind {
            case .point:
                let q = map.apply(point(id))
                n = addPoint(q.0, q.1, construction: e.construction)
            case .line:
                n = addLine(from: map.apply(pts[0]), to: map.apply(pts[1]), construction: e.construction)
            case .circle:
                n = addCircle(center: map.apply(pts[0]), radius: params[e.params[0]] * map.k, construction: e.construction)
            case .arc:
                // A reflection reverses the sense of rotation: the copy runs from image(end) to image(start).
                n = map.isReflection
                    ? addArc(center: map.apply(pts[0]), start: map.apply(pts[2]), end: map.apply(pts[1]), construction: e.construction)
                    : addArc(center: map.apply(pts[0]), start: map.apply(pts[1]), end: map.apply(pts[2]), construction: e.construction)
            case .ellipse:
                n = addEllipse(
                    center: map.apply(pts[0]), major: params[e.params[0]] * map.k, minor: params[e.params[1]] * map.k,
                    rotation: map.apply(angle: params[e.params[2]]), construction: e.construction)
            case .spline:
                n = insertSpline(poles: pts.map(map.apply), degree: e.degree ?? 3, construction: e.construction)
            }
            m[id] = n
            let ne = entities[n]!
            var newPoints = ne.points
            if e.kind == .arc && map.isReflection { newPoints.swapAt(1, 2) }
            for (old, new) in zip(e.points, newPoints) { m[old] = new }
        }
        return m
    }

    /// Adds a relation unless the sketch already implies it; other errors propagate.
    @discardableResult
    mutating func addUnlessImplied(_ kind: ConstraintKind, _ ids: [String]) throws -> String? {
        do {
            return try addConstraint(kind, ids)
        } catch let e as ForgeError where e.code == .sketchRedundant {
            return nil
        }
    }

    /// Re-creates, between the copies, the topological relations that hold between the
    /// originals (coincident, point on curve, tangent). Returns the constraints added.
    mutating func copyTopology(_ m: [String: String], skip: Set<ConstraintKind> = []) throws -> [String] {
        var added: [String] = []
        for c in userConstraints where [.coincident, .onEntity, .tangent].contains(c.kind) {
            guard c.entities.allSatisfy({ m[$0] != nil }), !skip.contains(c.kind) else { continue }
            if let id = try addUnlessImplied(c.kind, c.entities.map { m[$0]! }) { added.append(id) }
        }
        return added
    }

    // MARK: mirror

    /// Mirror entities about a line (SPEC 7.1 "mirror"): copies with symmetric relations, so
    /// the copy follows the original when it is edited. Returns (created entities, constraints).
    public mutating func mirror(_ ids: [String], about axis: String) throws -> (created: [String], constraints: [String]) {
        let ax = try entity(axis)
        guard ax.kind == .line else { throw ForgeError(.invalidParams, "the mirror axis must be a line", entities: [axis]) }
        let set = try copySet(ids, excluding: Set([axis] + ax.points))
        var s = self
        let map = RigidMap2.reflection(s.point(ax.points[0]), s.point(ax.points[1]))
        let m = s.copy(set, map)
        var added: [String] = []
        // Whole circles and arcs first (their rows are independent of their internal radius),
        // then the topology between copies, then the points still free. A round curve whose
        // whole-curve relation is partly implied (two arcs sharing an end) falls back to
        // relating its points.
        var free: [String] = []
        for id in set {
            let e = entities[id]!
            switch e.kind {
            case .circle, .arc:
                if let c = try s.addUnlessImplied(.symmetric, [id, m[id]!, axis]) { added.append(c) } else { free += e.points }
            case .line, .spline: free += e.points
            case .point: free.append(id)
            case .ellipse: break  // copied without a relation (symmetric does not cover ellipses yet)
            }
        }
        added += try s.copyTopology(m, skip: [.tangent])
        for p in free {
            if let c = try s.addUnlessImplied(.symmetric, [p, m[p]!, axis]) { added.append(c) }
        }
        added += try s.copyTopology(m, skip: [.coincident, .onEntity])
        s.resolve()
        self = s
        return (set.map { m[$0]! }, added)
    }

    // MARK: patterns

    /// Linear pattern (SPEC 7.1 "linear pattern"): `count` instances (including the seed) along
    /// `direction` (radians from the sketch x axis) every `spacing`, optionally in a second
    /// direction. Copies keep the seed's size and orientation (equal / parallel relations).
    public mutating func linearPattern(
        _ ids: [String], direction: Double, spacing: Double, count: Int,
        direction2: Double? = nil, spacing2: Double? = nil, count2: Int = 1
    ) throws -> (created: [[String]], constraints: [String]) {
        guard count >= 1, count2 >= 1, count * count2 >= 2 else { throw ForgeError(.invalidParams, "a pattern needs at least 2 instances") }
        guard count * count2 <= 1000 else { throw ForgeError(.invalidParams, "at most 1000 instances") }
        let set = try copySet(ids)
        var s = self
        var created: [[String]] = [], added: [String] = []
        for j in 0..<count2 {
            for i in 0..<count where i > 0 || j > 0 {
                var dx = Double(i) * spacing * cos(direction), dy = Double(i) * spacing * sin(direction)
                if let d2 = direction2, let s2 = spacing2 {
                    dx += Double(j) * s2 * cos(d2)
                    dy += Double(j) * s2 * sin(d2)
                }
                let m = s.copy(set, .translation(dx, dy))
                added += try s.copyTopology(m)
                added += try s.relateToSeed(set, m, parallel: true)
                created.append(set.map { m[$0]! })
            }
        }
        s.resolve()
        self = s
        return (created, added)
    }

    /// Circular pattern (SPEC 7.1 "circular pattern"): `count` instances (including the seed)
    /// about `center`, spread over `angle` (2π: evenly around a full circle).
    public mutating func circularPattern(_ ids: [String], center: (Double, Double), angle: Double, count: Int) throws
        -> (created: [[String]], constraints: [String])
    {
        guard count >= 2, count <= 1000 else { throw ForgeError(.invalidParams, "count must be between 2 and 1000") }
        guard angle != 0, abs(angle) <= 2 * .pi + 1e-12 else { throw ForgeError(.invalidParams, "angle must be non-zero and at most 360 degrees") }
        let set = try copySet(ids)
        let full = abs(abs(angle) - 2 * .pi) < 1e-9
        let step = full ? angle / Double(count) : angle / Double(count - 1)
        var s = self
        var created: [[String]] = [], added: [String] = []
        for i in 1..<count {
            let m = s.copy(set, .rotation(about: center, by: Double(i) * step))
            added += try s.copyTopology(m)
            added += try s.relateToSeed(set, m, parallel: false)
            created.append(set.map { m[$0]! })
        }
        s.resolve()
        self = s
        return (created, added)
    }

    /// Size relations tying a pattern instance to its seed.
    mutating func relateToSeed(_ set: [String], _ m: [String: String], parallel: Bool) throws -> [String] {
        var added: [String] = []
        for id in set {
            switch entities[id]!.kind {
            case .line:
                if parallel, let c = try addUnlessImplied(.parallel, [id, m[id]!]) { added.append(c) }
                if let c = try addUnlessImplied(.equal, [id, m[id]!]) { added.append(c) }
            case .circle, .arc:
                if let c = try addUnlessImplied(.equal, [id, m[id]!]) { added.append(c) }
            default: break
            }
        }
        return added
    }
}

extension Sketch {
    // MARK: move / rotate / scale (SPEC 7.1 "move/copy/rotate/scale")

    /// Applies `map` to entities in place, or to copies when `copy` is set. In place, relations
    /// that tie moved geometry to unmoved geometry are deleted unless `keepRelations` (then the
    /// solver pulls the result back into agreement); relations the map itself breaks
    /// (horizontal/vertical under rotation) are deleted, and dimensions among the moved
    /// geometry scale with it. Returns (moved or created entities, removed constraints,
    /// added constraints).
    mutating func transform(_ ids: [String], _ map: RigidMap2, copy: Bool, keepRelations: Bool) throws
        -> (entities: [String], removed: [String], added: [String])
    {
        let set = try copySet(ids)
        var s = self
        if copy {
            let m = s.copy(set, map)
            let added = try s.copyTopology(m)
            s.resolve()
            self = s
            return (set.map { m[$0]! }, [], added)
        }
        var moved = Set(set)
        for id in set { moved.formUnion(entities[id]!.points) }
        // Rotations other than half turns break horizontal/vertical; a half turn keeps them but
        // flips the sign of horizontal/vertical distances.
        let rotates = abs(map.r01) > 1e-12
        let halfTurn = !rotates && map.r00 < 0
        var removed: [String] = []
        for c in s.userConstraints {
            let inside = c.entities.allSatisfy(moved.contains)
            let touches = c.entities.contains(where: moved.contains)
            guard touches else { continue }
            if !inside {
                if !keepRelations { removed.append(c.id) }
                continue
            }
            switch c.kind {
            case .horizontal, .vertical:
                if rotates { removed.append(c.id) }
            case .horizontalDistance, .verticalDistance:
                if rotates {
                    removed.append(c.id)
                } else if halfTurn, let i = s.constraints.firstIndex(where: { $0.id == c.id }) {
                    s.constraints[i].side = -s.constraints[i].side
                }
            case .distance, .radius, .diameter, .offset:
                if map.k != 1, let v = c.value { s.setValue(c.id, v * map.k) }
            default: break
            }
        }
        removed = s.removeConstraints(removed)
        // Move points, then scale radii / ellipse axes.
        for id in moved where s.entities[id]!.kind == .point {
            s.setPoint(id, map.apply(point(id)))
        }
        for id in set {
            let e = s.entities[id]!
            switch e.kind {
            case .circle: s.params[e.params[0]] *= map.k
            case .ellipse:
                s.params[e.params[0]] *= map.k
                s.params[e.params[1]] *= map.k
                s.params[e.params[2]] = map.apply(angle: s.params[e.params[2]])
            default: break
            }
        }
        s.refreshDriven()
        let r = s.resolve()
        if r.status == .failed || !r.conflicting.isEmpty {
            throw ForgeError(
                .sketchConflict, "the moved geometry conflicts with relations it keeps; move with keep_relations false or delete them",
                entities: set + r.conflicting)
        }
        self = s
        return (set, removed, [])
    }

    public mutating func move(_ ids: [String], by d: (Double, Double), copy: Bool = false, keepRelations: Bool = false) throws
        -> (entities: [String], removed: [String], added: [String])
    {
        try transform(ids, .translation(d.0, d.1), copy: copy, keepRelations: keepRelations)
    }

    public mutating func rotate(_ ids: [String], about c: (Double, Double), by angle: Double, copy: Bool = false, keepRelations: Bool = false)
        throws -> (entities: [String], removed: [String], added: [String])
    {
        try transform(ids, .rotation(about: c, by: angle), copy: copy, keepRelations: keepRelations)
    }

    public mutating func scale(_ ids: [String], about c: (Double, Double), by f: Double, copy: Bool = false, keepRelations: Bool = false)
        throws -> (entities: [String], removed: [String], added: [String])
    {
        guard f > 0, f.isFinite else { throw ForgeError(.invalidParams, "scale factor must be positive") }
        return try transform(ids, .scaling(about: c, by: f), copy: copy, keepRelations: keepRelations)
    }
}

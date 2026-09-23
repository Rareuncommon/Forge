import ForgeCore
import Foundation

/// A relation or dimension added automatically while creating geometry (Instant relations).
public struct InferredRelation: Codable, Sendable, Hashable {
    public var constraint: String
    public var kind: ConstraintKind
    public var entities: [String]
}

extension Sketch {
    /// Tolerance for exact-coordinate inference (coincident points, horizontal/vertical).
    static let inferenceTolerance = 1e-9

    // MARK: constraints

    /// Add a relation or dimension, solve, and commit only if the result is consistent.
    /// Throws `sketch_conflict` / `sketch_redundant` / `solver_failed` with executable fixes.
    @discardableResult
    public mutating func addConstraint(_ kind: ConstraintKind, _ entities: [String], value: Double? = nil, driven: Bool = false)
        throws -> String
    {
        guard kind != .arcRadius else { throw ForgeError(.invalidParams, "arc_radius is internal") }
        let ids = try normalize(kind, entities)
        var value = value
        if kind.isDimension {
            let probe = SketchConstraint(id: "", kind: kind, entities: ids, value: nil, driven: false, side: chooseSide(kind, ids), isInternal: false)
            let current = measure(probe) { self.params[$0] }
            if value == nil || driven { value = current }
            try Self.validateDimension(kind, value!)
        } else if value != nil {
            throw ForgeError(.invalidParams, "\(kind.rawValue) is a relation and takes no value")
        }
        if kind == .fix, ids == [Self.originID] { throw ForgeError(.sketchRedundant, "the sketch origin is always fixed", entities: ids) }
        let before = report
        var trial = self
        var c = SketchConstraint(id: "", kind: kind, entities: ids, value: value, driven: driven, side: chooseSide(kind, ids), isInternal: false)
        if kind == .tangent { c.at = sharedTangencyPoint(ids) }
        let id = trial.appendConstraint(c)
        let r = SketchSolver.solve(&trial)
        try Self.judge(r, new: id, previous: before, kind: kind, entities: ids, value: value, sketchID: self.id)
        trial.refreshDriven()
        self = trial
        return id
    }

    static func validateDimension(_ kind: ConstraintKind, _ v: Double) throws {
        guard v.isFinite else { throw ForgeError(.invalidParams, "dimension value must be finite") }
        switch kind {
        case .angle:
            guard v > 0, v <= .pi + 1e-12 else { throw ForgeError(.invalidParams, "angle must be in (0, 180] degrees") }
        case .radius, .diameter:
            guard v > 0 else { throw ForgeError(.invalidParams, "\(kind.rawValue) must be positive") }
        case .distance:
            guard v >= 0 else { throw ForgeError(.invalidParams, "distance must not be negative") }
        default:
            break
        }
    }

    /// Decide whether a solve after adding/changing `new` is acceptable.
    static func judge(
        _ r: SolveReport, new id: String, previous: SolveReport?, kind: ConstraintKind, entities: [String], value: Double?, sketchID: String
    ) throws {
        let refs = entities.map { "\(sketchID)/\($0)" }
        let wasConflicting = Set(previous?.conflicting ?? [])
        let newConflicts = r.conflicting.filter { !wasConflicting.contains($0) }
        if r.conflicting.contains(id) || !newConflicts.isEmpty {
            var fixes: [SuggestedFix] = []
            if kind.isDimension {
                var p: JSONValue = ["type": .string(kind.rawValue), "entities": .array(entities.map { .string($0) }), "driven": true]
                if case .object(var o) = p { o["sketch"] = .string(sketchID); p = .object(o) }
                fixes.append(SuggestedFix(description: "Add it as a driven (reference) dimension instead", command: "sketch.add_dimension", params: p))
            }
            for other in r.conflicting where other != id {
                fixes.append(SuggestedFix(description: "Delete conflicting \(other)", command: "sketch.delete", params: ["sketch": .string(sketchID), "items": [.string(other)]]))
            }
            throw ForgeError(
                .sketchConflict,
                "\(kind.rawValue) on \(entities.joined(separator: ", ")) conflicts with existing constraints \(r.conflicting.filter { $0 != id }.joined(separator: ", "))",
                entities: refs + r.conflicting.filter { $0 != id }.map { "\(sketchID)/\($0)" }, suggestions: fixes,
                details: ["conflicting": .array(r.conflicting.map { .string($0) })])
        }
        if r.redundant.contains(id) {
            var fixes: [SuggestedFix] = []
            if kind.isDimension {
                fixes.append(SuggestedFix(
                    description: "Add it as a driven (reference) dimension", command: "sketch.add_dimension",
                    params: ["sketch": .string(sketchID), "type": .string(kind.rawValue), "entities": .array(entities.map { .string($0) }), "driven": true]))
            }
            throw ForgeError(
                .sketchRedundant, "\(kind.rawValue) on \(entities.joined(separator: ", ")) is already implied by existing constraints (the sketch would be over-defined)",
                entities: refs, suggestions: fixes)
        }
        if r.status == .failed && previous?.status != .failed {
            throw ForgeError(
                .solverFailed, "the sketch cannot be solved with \(kind.rawValue)\(value.map { " = \($0)" } ?? "") on \(entities.joined(separator: ", ")); the geometry may be impossible (e.g. a triangle violating the triangle inequality)",
                entities: refs,
                suggestions: [SuggestedFix(description: "Inspect the sketch", command: "sketch.get", params: ["sketch": .string(sketchID)])])
        }
    }

    /// Change a driving dimension's value (or make it driven/driving) and re-solve.
    public mutating func setDimension(_ id: String, value: Double?, driven: Bool?) throws {
        let c = try constraint(id)
        guard c.kind.isDimension else { throw ForgeError(.invalidParams, "\(id) is a \(c.kind.rawValue) relation, not a dimension") }
        let before = report
        var trial = self
        if let d = driven { trial.setDriven(id, d) }
        if let v = value {
            try Self.validateDimension(c.kind, v)
            if trial.constraints.first(where: { $0.id == id })!.driven {
                throw ForgeError(.invalidParams, "\(id) is driven; set driven: false to make it drive the geometry")
            }
            trial.setValue(id, v)
        }
        let r = SketchSolver.solve(&trial)
        try Self.judge(r, new: id, previous: before, kind: c.kind, entities: c.entities, value: value, sketchID: self.id)
        if r.status == .failed { throw ForgeError(.solverFailed, "no solution with \(id) = \(value ?? c.value ?? 0)", entities: ["\(self.id)/\(id)"]) }
        trial.refreshDriven()
        self = trial
    }

    /// Update the measured value of every driven dimension.
    mutating func refreshDriven() {
        for i in constraints.indices where constraints[i].driven {
            constraints[i].value = measure(constraints[i]) { self.params[$0] }
        }
    }

    /// Solve and refresh; used after pure geometry edits.
    @discardableResult
    public mutating func resolve() -> SolveReport {
        let r = SketchSolver.solve(&self)
        refreshDriven()
        return r
    }

    // MARK: dragging

    /// Drag a point (or translate a whole curve by moving its first point) toward a target,
    /// keeping all constraints. The dragged point is held at the target when possible;
    /// otherwise the geometry moves as little as possible.
    public mutating func drag(_ id: String, to target: (Double, Double)) throws {
        let e = try entity(id)
        var trial = self
        let before = report
        if e.kind == .point {
            trial.params[e.params[0]] = target.0
            trial.params[e.params[1]] = target.1
            var held = trial
            let r = SketchSolver.solve(&held, extraFixed: Set(e.params))
            if r.status != .failed && r.conflicting.isEmpty {
                trial = held
            } else {
                _ = SketchSolver.solve(&trial)
            }
        } else {
            let anchor = e.points[0]
            let (ax, ay) = point(anchor)
            let dx = target.0 - ax, dy = target.1 - ay
            for p in e.points {
                let pe = entities[p]!
                trial.params[pe.params[0]] += dx
                trial.params[pe.params[1]] += dy
            }
            _ = SketchSolver.solve(&trial)
        }
        guard let r = trial.report, r.status != .failed || before?.status == .failed else {
            throw ForgeError(.solverFailed, "could not solve after dragging \(id)", entities: ["\(self.id)/\(id)"])
        }
        // Re-run the full analysis without the temporary hold.
        trial.resolve()
        self = trial
    }

    // MARK: inference

    /// Existing point at (u, v), preferring non-owned/earlier points; excludes `exclude`.
    func pointAt(_ u: Double, _ v: Double, excluding exclude: Set<String>) -> String? {
        let tol = Self.inferenceTolerance * max(1, abs(u), abs(v))
        for id in entityOrder where !exclude.contains(id) {
            guard let e = entities[id], e.kind == .point else { continue }
            let (x, y) = point(id)
            if abs(x - u) <= tol && abs(y - v) <= tol { return id }
        }
        return nil
    }

    /// Add coincident relations for new points that land exactly on existing points, and
    /// horizontal/vertical relations for exactly axis-aligned new lines.
    public mutating func inferRelations(newEntities: [String]) -> [InferredRelation] {
        var out: [InferredRelation] = []
        let fresh = Set(newEntities.flatMap { [$0] + (entities[$0]?.points ?? []) })
        for id in newEntities {
            guard let e = entities[id] else { continue }
            let pts = e.kind == .point ? [id] : e.points.filter { entities[$0]?.owner == id }
            for p in pts {
                if e.kind == .circle || e.kind == .ellipse { continue }
                let (u, v) = point(p)
                if let other = pointAt(u, v, excluding: fresh), let c = try? addConstraint(.coincident, [other, p]) {
                    out.append(InferredRelation(constraint: c, kind: .coincident, entities: [other, p]))
                }
            }
            if e.kind == .line {
                let (ax, ay) = point(e.points[0]), (bx, by) = point(e.points[1])
                let tol = Self.inferenceTolerance * max(1, abs(ax), abs(bx), abs(ay), abs(by))
                if abs(ay - by) <= tol, let c = try? addConstraint(.horizontal, [id]) {
                    out.append(InferredRelation(constraint: c, kind: .horizontal, entities: [id]))
                } else if abs(ax - bx) <= tol, let c = try? addConstraint(.vertical, [id]) {
                    out.append(InferredRelation(constraint: c, kind: .vertical, entities: [id]))
                }
            }
        }
        return out
    }

    // MARK: compound geometry

    /// Connect lines end-to-start in a closed chain with coincident relations.
    mutating func closeChain(_ lines: [String]) throws {
        for i in lines.indices {
            let a = entities[lines[i]]!.points[1], b = entities[lines[(i + 1) % lines.count]]!.points[0]
            try addConstraint(.coincident, [a, b])
        }
    }

    public enum RectangleMode: String, Codable, Sendable, CaseIterable, SchemaEnum {
        case corner, center, threePoint = "three_point", parallelogram
    }

    /// Rectangles (SPEC 7.1): corner (2 opposite corners), center (centre + corner),
    /// three_point (3 corners, any angle), parallelogram (3 corners).
    public mutating func addRectangle(_ mode: RectangleMode, _ pts: [(Double, Double)], construction: Bool = false) throws -> [String] {
        let need = mode == .corner || mode == .center ? 2 : 3
        guard pts.count == need else { throw ForgeError(.invalidParams, "\(mode.rawValue) rectangle needs \(need) points") }
        var corners: [(Double, Double)]
        switch mode {
        case .corner:
            let (a, c) = (pts[0], pts[1])
            corners = [a, (c.0, a.1), c, (a.0, c.1)]
        case .center:
            let (m, c) = (pts[0], pts[1])
            let a = (2 * m.0 - c.0, 2 * m.1 - c.1)
            corners = [a, (c.0, a.1), c, (a.0, c.1)]
        case .threePoint:
            let (a, b, p) = (pts[0], pts[1], pts[2])
            let dx = b.0 - a.0, dy = b.1 - a.1
            let len2 = dx * dx + dy * dy
            guard len2 > 0 else { throw ForgeError(.invalidParams, "first two points coincide") }
            let t = ((p.0 - b.0) * -dy + (p.1 - b.1) * dx) / len2  // height along the perpendicular
            let c = (b.0 - dy * t, b.1 + dx * t)
            corners = [a, b, c, (a.0 - dy * t, a.1 + dx * t)]
        case .parallelogram:
            let (a, b, c) = (pts[0], pts[1], pts[2])
            corners = [a, b, c, (a.0 + c.0 - b.0, a.1 + c.1 - b.1)]
        }
        let area = (0..<4).reduce(0.0) { s, i in s + corners[i].0 * corners[(i + 1) % 4].1 - corners[(i + 1) % 4].0 * corners[i].1 }
        guard abs(area) > 1e-12 else { throw ForgeError(.invalidParams, "rectangle has zero area") }
        let lines = (0..<4).map { addLine(from: corners[$0], to: corners[($0 + 1) % 4], construction: construction) }
        try closeChain(lines)
        switch mode {
        case .corner, .center:
            try addConstraint(.horizontal, [lines[0]])
            try addConstraint(.horizontal, [lines[2]])
            try addConstraint(.vertical, [lines[1]])
            try addConstraint(.vertical, [lines[3]])
        case .threePoint:
            try addConstraint(.perpendicular, [lines[0], lines[1]])
            try addConstraint(.parallel, [lines[0], lines[2]])
            try addConstraint(.parallel, [lines[1], lines[3]])
        case .parallelogram:
            try addConstraint(.parallel, [lines[0], lines[2]])
            try addConstraint(.parallel, [lines[1], lines[3]])
        }
        var created = lines
        if mode == .center {
            let diag = addLine(from: corners[0], to: corners[2], construction: true)
            try addConstraint(.coincident, [entities[diag]!.points[0], entities[lines[0]]!.points[0]])
            try addConstraint(.coincident, [entities[diag]!.points[1], entities[lines[2]]!.points[0]])
            let center = addPoint(pts[0].0, pts[0].1, construction: true)
            try addConstraint(.midpoint, [center, diag])
            created += [diag, center]
        }
        return created
    }

    public enum SlotMode: String, Codable, Sendable, CaseIterable, SchemaEnum {
        case straight, center
    }

    /// Straight slot: arc centres at `a` and `b` (straight) or centred on `a` with one end at `b`
    /// (center), with the given width.
    public mutating func addSlot(_ mode: SlotMode, _ a: (Double, Double), _ b: (Double, Double), width: Double) throws -> [String] {
        guard width > 0 else { throw ForgeError(.invalidParams, "slot width must be positive") }
        var c1 = a, c2 = b
        if mode == .center { c1 = (2 * a.0 - b.0, 2 * a.1 - b.1) }
        let dx = c2.0 - c1.0, dy = c2.1 - c1.1
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0 else { throw ForgeError(.invalidParams, "slot centres coincide") }
        let r = width / 2
        let nx = -dy / len * r, ny = dx / len * r
        // Side lines (c1→c2 on the left, c2→c1 on the right) and end arcs, CCW around the slot.
        let right1 = (c1.0 - nx, c1.1 - ny), right2 = (c2.0 - nx, c2.1 - ny)
        let left1 = (c1.0 + nx, c1.1 + ny), left2 = (c2.0 + nx, c2.1 + ny)
        let bottom = addLine(from: right1, to: right2)
        let arc2 = addArc(center: c2, start: right2, end: left2)
        let top = addLine(from: left2, to: left1)
        let arc1 = addArc(center: c1, start: left1, end: right1)
        func E(_ id: String, _ i: Int) -> String { entities[id]!.points[i] }
        try addConstraint(.coincident, [E(bottom, 1), E(arc2, 1)])
        try addConstraint(.coincident, [E(arc2, 2), E(top, 0)])
        try addConstraint(.coincident, [E(top, 1), E(arc1, 1)])
        try addConstraint(.coincident, [E(arc1, 2), E(bottom, 0)])
        try addConstraint(.tangent, [bottom, arc2])
        try addConstraint(.tangent, [top, arc2])
        try addConstraint(.tangent, [top, arc1])
        try addConstraint(.tangent, [bottom, arc1])
        try addConstraint(.equal, [arc1, arc2])
        let axis = addLine(from: c1, to: c2, construction: true)
        try addConstraint(.coincident, [E(axis, 0), E(arc1, 0)])
        try addConstraint(.coincident, [E(axis, 1), E(arc2, 0)])
        var created = [bottom, arc2, top, arc1, axis]
        if mode == .center {
            let mid = addPoint(a.0, a.1, construction: true)
            try addConstraint(.midpoint, [mid, axis])
            created.append(mid)
        }
        return created
    }

    /// Regular polygon with a construction circle (inscribed: vertices on the circle;
    /// circumscribed: edge midpoints on the circle).
    public mutating func addPolygon(center: (Double, Double), sides: Int, radius: Double, rotation: Double, inscribed: Bool) throws -> [String] {
        guard (3...256).contains(sides) else { throw ForgeError(.invalidParams, "sides must be between 3 and 256") }
        guard radius > 0 else { throw ForgeError(.invalidParams, "radius must be positive") }
        let R = inscribed ? radius : radius / cos(.pi / Double(sides))
        let verts = (0..<sides).map { i -> (Double, Double) in
            let t = rotation + 2 * .pi * Double(i) / Double(sides)
            return (center.0 + R * cos(t), center.1 + R * sin(t))
        }
        let circle = addCircle(center: center, radius: radius, construction: true)
        let lines = (0..<sides).map { addLine(from: verts[$0], to: verts[($0 + 1) % sides]) }
        try closeChain(lines)
        for (i, l) in lines.enumerated() {
            if inscribed {
                try addConstraint(.onEntity, [entities[l]!.points[0], circle])
            } else {
                try addConstraint(.tangent, [l, circle])
            }
            if i > 0 { try addConstraint(.equal, [lines[0], l]) }
        }
        return [circle] + lines
    }

    /// Circle through three points.
    public static func circumcircle(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double)) throws -> (center: (Double, Double), radius: Double) {
        let d = 2 * (a.0 * (b.1 - c.1) + b.0 * (c.1 - a.1) + c.0 * (a.1 - b.1))
        guard abs(d) > 1e-12 else { throw ForgeError(.invalidParams, "the three points are collinear") }
        let a2 = a.0 * a.0 + a.1 * a.1, b2 = b.0 * b.0 + b.1 * b.1, c2 = c.0 * c.0 + c.1 * c.1
        let ux = (a2 * (b.1 - c.1) + b2 * (c.1 - a.1) + c2 * (a.1 - b.1)) / d
        let uy = (a2 * (c.0 - b.0) + b2 * (a.0 - c.0) + c2 * (b.0 - a.0)) / d
        return ((ux, uy), ((a.0 - ux) * (a.0 - ux) + (a.1 - uy) * (a.1 - uy)).squareRoot())
    }
}

extension Sketch {
    /// Sketch fillet between two lines that meet at a corner (SPEC 7.1 "fillet (sketch)").
    ///
    /// The lines are trimmed back to the tangent points and joined by a tangent arc with a
    /// radius dimension. A construction "virtual sharp" point stays at the intersection of the
    /// two (infinite) lines; every constraint that referenced the corner endpoints — and length
    /// dimensions of the two lines — is retargeted to it, so existing dimensions keep their
    /// meaning (as in SolidWorks). Returns [arc, sharp point].
    public mutating func filletCorner(_ lineA: String, _ lineB: String, radius r: Double) throws -> [String] {
        guard r > 0, r.isFinite else { throw ForgeError(.invalidParams, "fillet radius must be positive") }
        let c0 = try corner(lineA, lineB)
        let t = r / tan(c0.theta / 2)
        guard t < c0.lenA - c0.tol, t < c0.lenB - c0.tol else {
            throw ForgeError(
                .invalidParams, "radius \(r) mm is too large for these lines (needs \(t) mm of each line)", entities: [lineA, lineB],
                suggestions: [SuggestedFix(description: "Use the largest radius that fits", command: "sketch.fillet",
                                           params: ["sketch": .string(id), "lines": [.string(lineA), .string(lineB)], "radius": .number(0.9 * min(c0.lenA, c0.lenB) * tan(c0.theta / 2))])])
        }
        let prepared = try withVirtualSharp(c0)
        var s = prepared.0
        let sharp = prepared.1
        let (pa, pb, P, ua, ub, theta) = (c0.pa, c0.pb, c0.P, c0.ua, c0.ub, c0.theta)
        // 3. Trim the lines to the tangent points and insert the arc.
        let ta = (P.0 + ua.0 * t, P.1 + ua.1 * t), tb = (P.0 + ub.0 * t, P.1 + ub.1 * t)
        let bis = (ua.0 + ub.0, ua.1 + ub.1), bl = hypot(bis.0, bis.1)
        let d = r / sin(theta / 2)
        let c = (P.0 + bis.0 / bl * d, P.1 + bis.1 / bl * d)
        let ea = s.entities[pa]!, eb = s.entities[pb]!
        s.params[ea.params[0]] = ta.0
        s.params[ea.params[1]] = ta.1
        s.params[eb.params[0]] = tb.0
        s.params[eb.params[1]] = tb.1
        let ccw = (ta.0 - c.0) * (tb.1 - c.1) - (ta.1 - c.1) * (tb.0 - c.0) > 0
        let arc = ccw ? s.addArc(center: c, start: ta, end: tb) : s.addArc(center: c, start: tb, end: ta)
        let ae = s.entities[arc]!
        try s.addConstraint(.coincident, [pa, ccw ? ae.points[1] : ae.points[2]])
        try s.addConstraint(.coincident, [pb, ccw ? ae.points[2] : ae.points[1]])
        try s.addConstraint(.tangent, [lineA, arc])
        try s.addConstraint(.tangent, [lineB, arc])
        try s.addConstraint(.radius, [arc], value: r)
        s.resolve()
        if let rep = s.report, rep.status == .failed || !rep.conflicting.isEmpty {
            throw ForgeError(.solverFailed, "the fillet could not be solved with the existing constraints", entities: [lineA, lineB])
        }
        self = s
        return [arc, sharp]
    }
}

extension Sketch {
    struct Corner {
        var lineA: String, lineB: String
        var pa: String, pb: String
        var P: (Double, Double)
        var ua: (Double, Double), ub: (Double, Double)
        var theta: Double
        var lenA: Double, lenB: Double
        var tol: Double
    }

    /// Locate the shared corner of two lines and its geometry.
    func corner(_ lineA: String, _ lineB: String) throws -> Corner {
        let A = try entity(lineA), B = try entity(lineB)
        guard A.kind == .line, B.kind == .line, lineA != lineB else {
            throw ForgeError(.invalidParams, "needs two different lines", entities: [lineA, lineB])
        }
        let scale = max(1, params.map(abs).max() ?? 1)
        let tol = 1e-7 * scale
        var found: (String, String)?
        for pa in A.points {
            for pb in B.points {
                let (x1, y1) = point(pa), (x2, y2) = point(pb)
                if abs(x1 - x2) <= tol && abs(y1 - y2) <= tol { found = (pa, pb) }
            }
        }
        guard let (pa, pb) = found else {
            throw ForgeError(.invalidParams, "\(lineA) and \(lineB) do not meet at a common endpoint", entities: [lineA, lineB])
        }
        let otherA = A.points.first { $0 != pa }!, otherB = B.points.first { $0 != pb }!
        let P = point(pa)
        func unit(_ q: (Double, Double)) -> (Double, Double) {
            let dx = q.0 - P.0, dy = q.1 - P.1, l = hypot(dx, dy)
            return (dx / l, dy / l)
        }
        let ua = unit(point(otherA)), ub = unit(point(otherB))
        let theta = acos(max(-1, min(1, ua.0 * ub.0 + ua.1 * ub.1)))
        guard theta > 1e-6, theta < .pi - 1e-6 else {
            throw ForgeError(.invalidParams, "the lines are collinear at the corner", entities: [lineA, lineB])
        }
        return Corner(
            lineA: lineA, lineB: lineB, pa: pa, pb: pb, P: P, ua: ua, ub: ub, theta: theta,
            lenA: hypot(point(otherA).0 - P.0, point(otherA).1 - P.1), lenB: hypot(point(otherB).0 - P.0, point(otherB).1 - P.1), tol: tol)
    }

    /// Copy of the sketch with a construction "virtual sharp" at the corner: constraints on the
    /// corner endpoints and line-length dimensions are retargeted to it, the corner
    /// coincidence is removed, and the sharp is held on both infinite lines.
    func withVirtualSharp(_ c: Corner) throws -> (Sketch, String) {
        var s = self
        let (pa, pb, lineA, lineB) = (c.pa, c.pb, c.lineA, c.lineB)
        let sharp = s.addPoint(c.P.0, c.P.1, construction: true)
        for i in s.constraints.indices {
            var k = s.constraints[i]
            if k.kind == .coincident && Set(k.entities) == Set([pa, pb]) { continue }
            if k.entities.contains(pa) || k.entities.contains(pb) {
                k.entities = k.entities.map { $0 == pa || $0 == pb ? sharp : $0 }
            } else if k.kind.isDimension, k.entities.count == 1, k.entities[0] == lineA || k.entities[0] == lineB,
                k.kind == .distance || k.kind == .horizontalDistance || k.kind == .verticalDistance
            {
                let line = s.entities[k.entities[0]]!
                let cornerEnd = k.entities[0] == lineA ? pa : pb
                k.entities = line.points.map { $0 == cornerEnd ? sharp : $0 }
            }
            s.constraints[i] = k
        }
        s.constraints.removeAll {
            ($0.kind == .coincident && Set($0.entities) == Set([pa, pb])) || Set($0.entities).count != $0.entities.count
        }
        try s.addConstraint(.onEntity, [sharp, lineA])
        try s.addConstraint(.onEntity, [sharp, lineB])
        return (s, sharp)
    }

    /// Sketch chamfer between two lines (SPEC 7.1 "chamfer (sketch)"): distance–distance, or
    /// distance–angle when `angle` is given (angle measured from line A). Uses a virtual sharp
    /// like the fillet. Returns [chamfer line, sharp point].
    public mutating func chamferCorner(_ lineA: String, _ lineB: String, distance d1: Double, distance2: Double? = nil, angle: Double? = nil) throws -> [String] {
        guard d1 > 0, d1.isFinite else { throw ForgeError(.invalidParams, "chamfer distance must be positive") }
        let c0 = try corner(lineA, lineB)
        var d2 = distance2 ?? d1
        if let a = angle {
            guard a > 0, a < .pi - c0.theta else { throw ForgeError(.invalidParams, "chamfer angle must be between 0 and \((.pi - c0.theta) * 180 / .pi) degrees here") }
            // Triangle P–Ta–Tb: angle at Ta is `a`, at P is theta → law of sines.
            d2 = d1 * sin(a) / sin(.pi - a - c0.theta)
        }
        guard d2 > 0, d1 < c0.lenA - c0.tol, d2 < c0.lenB - c0.tol else {
            throw ForgeError(.invalidParams, "chamfer does not fit on the lines", entities: [lineA, lineB])
        }
        let prepared = try withVirtualSharp(c0)
        var s = prepared.0
        let sharp = prepared.1
        let ta = (c0.P.0 + c0.ua.0 * d1, c0.P.1 + c0.ua.1 * d1), tb = (c0.P.0 + c0.ub.0 * d2, c0.P.1 + c0.ub.1 * d2)
        let ea = s.entities[c0.pa]!, eb = s.entities[c0.pb]!
        s.params[ea.params[0]] = ta.0
        s.params[ea.params[1]] = ta.1
        s.params[eb.params[0]] = tb.0
        s.params[eb.params[1]] = tb.1
        let chamfer = s.addLine(from: ta, to: tb)
        let ce = s.entities[chamfer]!
        try s.addConstraint(.coincident, [c0.pa, ce.points[0]])
        try s.addConstraint(.coincident, [c0.pb, ce.points[1]])
        try s.addConstraint(.distance, [sharp, c0.pa], value: d1)
        if angle != nil {
            try s.addConstraint(.angle, [lineA, chamfer])
        } else {
            try s.addConstraint(.distance, [sharp, c0.pb], value: d2)
        }
        s.resolve()
        if let rep = s.report, rep.status == .failed || !rep.conflicting.isEmpty {
            throw ForgeError(.solverFailed, "the chamfer could not be solved with the existing constraints", entities: [lineA, lineB])
        }
        self = s
        return [chamfer, sharp]
    }
}

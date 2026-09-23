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
    mutating func inferRelations(newEntities: [String]) -> [InferredRelation] {
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

import ForgeCore
import Foundation

/// A point where a curve is crossed by another sketch curve.
struct Crossing {
    /// Parameter along the target: t ∈ [0, 1] for a line (start → end), counter-clockwise
    /// angle from the start for an arc, absolute angle for a circle.
    var param: Double
    var point: (Double, Double)
    var cutter: String
}

/// What a trim or extend did.
public struct TrimResult: Sendable {
    /// Curves created (the far piece of a split, or the arc left from a trimmed circle).
    public var created: [String] = []
    /// Curves deleted entirely.
    public var deleted: [String] = []
    /// Constraints removed because they described geometry that no longer exists.
    public var removedConstraints: [String] = []
    /// Relations added to hold new endpoints on the cutting curves.
    public var constraints: [String] = []
}

extension Sketch {
    // MARK: geometry helpers (current values)

    func circleOf(_ id: String) -> (c: (Double, Double), r: Double) {
        let e = entities[id]!
        let c = point(e.points[0])
        if e.kind == .circle { return (c, params[e.params[0]]) }
        let s = point(e.points[1])
        return (c, hypot(s.0 - c.0, s.1 - c.1))
    }

    /// Start angle and counter-clockwise sweep of an arc, sweep ∈ (0, 2π].
    func arcSpan(_ id: String) -> (a0: Double, sweep: Double) {
        let e = entities[id]!
        let c = point(e.points[0]), s = point(e.points[1]), t = point(e.points[2])
        let a0 = atan2(s.1 - c.1, s.0 - c.0)
        var sweep = atan2(t.1 - c.1, t.0 - c.0) - a0
        while sweep <= 1e-12 { sweep += 2 * .pi }
        return (a0, sweep)
    }

    public static func wrap(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x < 0 { x += 2 * .pi }
        return x
    }

    var lengthTolerance: Double { 1e-9 * max(1, params.map(abs).max() ?? 1) }

    /// Does point q (known to lie on the entity's carrier line/circle) lie within its extent?
    func withinExtent(_ id: String, _ q: (Double, Double), tol: Double) -> Bool {
        let e = entities[id]!
        switch e.kind {
        case .line:
            let a = point(e.points[0]), b = point(e.points[1])
            let dx = b.0 - a.0, dy = b.1 - a.1, l = hypot(dx, dy)
            let t = ((q.0 - a.0) * dx + (q.1 - a.1) * dy) / (l * l)
            return t >= -tol / l && t <= 1 + tol / l
        case .arc:
            let (c, r) = circleOf(id)
            let (a0, sweep) = arcSpan(id)
            let s = Self.wrap(atan2(q.1 - c.1, q.0 - c.0) - a0)
            return s <= sweep + tol / r || s >= 2 * .pi - tol / r
        case .ellipseArc:
            let r = max(params[e.params[0]], params[e.params[1]])
            let (phi0, sweep) = ellipseArcSpan(id)
            let s = Self.wrap(ellipseParam(id, q) - phi0)
            return s <= sweep + tol / r || s >= 2 * .pi - tol / r
        default:
            return true
        }
    }

    static func isElliptic(_ k: SketchEntityKind) -> Bool { k == .ellipse || k == .ellipseArc }

    /// Point of an ellipse (or partial ellipse's carrier) at parametric angle phi.
    func ellipsePoint(_ id: String, _ phi: Double) -> (Double, Double) {
        let e = entities[id]!
        let (cx, cy) = point(e.points[0])
        let a = params[e.params[0]], b = params[e.params[1]], rot = params[e.params[2]]
        let u = a * cos(phi), w = b * sin(phi)
        return (cx + u * cos(rot) - w * sin(rot), cy + u * sin(rot) + w * cos(rot))
    }

    /// Signed implicit function of a carrier: zero on it (line: signed distance; circle/arc:
    /// distance − radius; ellipse: normalised level − 1).
    func carrierLevel(_ id: String, _ q: (Double, Double)) -> Double {
        let e = entities[id]!
        switch e.kind {
        case .line:
            let a = point(e.points[0]), b = point(e.points[1])
            let dx = b.0 - a.0, dy = b.1 - a.1
            return (dx * (q.1 - a.1) - dy * (q.0 - a.0)) / hypot(dx, dy)
        case .circle, .arc:
            let (c, r) = circleOf(id)
            return hypot(q.0 - c.0, q.1 - c.1) - r
        default:
            let (cx, cy) = point(e.points[0])
            let a = params[e.params[0]], b = params[e.params[1]], rot = params[e.params[2]]
            let dx = q.0 - cx, dy = q.1 - cy
            let u = dx * cos(rot) + dy * sin(rot), w = -dx * sin(rot) + dy * cos(rot)
            return (u / a) * (u / a) + (w / b) * (w / b) - 1
        }
    }

    /// Where an ellipse's carrier meets another carrier: sign changes of the other carrier's
    /// level along the ellipse, refined by bisection. (Tangential touches are not cuts.)
    func ellipseIntersections(_ ellipse: String, _ other: String) -> [(Double, Double)] {
        let n = 720
        var out: [(Double, Double)] = []
        func f(_ phi: Double) -> Double { carrierLevel(other, ellipsePoint(ellipse, phi)) }
        func record(_ phi: Double) {
            let q = ellipsePoint(ellipse, phi)
            if !out.contains(where: { hypot($0.0 - q.0, $0.1 - q.1) < lengthTolerance * 100 }) { out.append(q) }
        }
        var prev = f(0)
        if prev == 0 { record(0) }
        for i in 1...n {
            let phi = 2 * Double.pi * Double(i) / Double(n)
            let cur = f(phi)
            if cur == 0 {
                record(phi)  // a sample exactly on the other carrier
            } else if prev != 0 && (prev < 0) != (cur < 0) {
                var lo = 2 * Double.pi * Double(i - 1) / Double(n), hi = phi
                let negativeAtLo = prev < 0
                for _ in 0..<80 {
                    let mid = (lo + hi) / 2, fm = f(mid)
                    if fm == 0 { (lo, hi) = (mid, mid); break }
                    if (fm < 0) == negativeAtLo { lo = mid } else { hi = mid }
                }
                record((lo + hi) / 2)
            }
            prev = cur
        }
        return out
    }

    /// Intersections of two carriers (infinite line, full circle or full ellipse).
    func carrierIntersections(_ a: String, _ b: String) -> [(Double, Double)] {
        let ea = entities[a]!, eb = entities[b]!
        if Self.isElliptic(ea.kind) { return ellipseIntersections(a, b) }
        if Self.isElliptic(eb.kind) { return ellipseIntersections(b, a) }
        func line(_ e: SketchEntity) -> ((Double, Double), (Double, Double)) { (point(e.points[0]), point(e.points[1])) }
        switch (ea.kind, eb.kind) {
        case (.line, .line):
            let (p, p2) = line(ea), (q, q2) = line(eb)
            let r = (p2.0 - p.0, p2.1 - p.1), s = (q2.0 - q.0, q2.1 - q.1)
            let den = r.0 * s.1 - r.1 * s.0
            guard abs(den) > 1e-12 * hypot(r.0, r.1) * hypot(s.0, s.1) else { return [] }
            let t = ((q.0 - p.0) * s.1 - (q.1 - p.1) * s.0) / den
            return [(p.0 + t * r.0, p.1 + t * r.1)]
        case (.line, .circle), (.line, .arc):
            let (p, p2) = line(ea)
            let (c, rad) = circleOf(b)
            let d = (p2.0 - p.0, p2.1 - p.1), f = (p.0 - c.0, p.1 - c.1)
            let A = d.0 * d.0 + d.1 * d.1, B = 2 * (f.0 * d.0 + f.1 * d.1), C = f.0 * f.0 + f.1 * f.1 - rad * rad
            var disc = B * B - 4 * A * C
            if disc < 0 && disc > -1e-9 * B * B { disc = 0 }
            guard disc >= 0 else { return [] }
            let sq = disc.squareRoot()
            let ts = sq == 0 ? [-B / (2 * A)] : [(-B - sq) / (2 * A), (-B + sq) / (2 * A)]
            return ts.map { (p.0 + $0 * d.0, p.1 + $0 * d.1) }
        case (.circle, .line), (.arc, .line):
            return carrierIntersections(b, a)
        case (.circle, .circle), (.circle, .arc), (.arc, .circle), (.arc, .arc):
            let (c1, r1) = circleOf(a), (c2, r2) = circleOf(b)
            let dx = c2.0 - c1.0, dy = c2.1 - c1.1, d = hypot(dx, dy)
            guard d > 1e-12, d <= r1 + r2 + 1e-12, d >= abs(r1 - r2) - 1e-12 else { return [] }
            let x = (d * d + r1 * r1 - r2 * r2) / (2 * d)
            let h = max(0, r1 * r1 - x * x).squareRoot()
            let m = (c1.0 + x * dx / d, c1.1 + x * dy / d)
            if h == 0 { return [m] }
            return [(m.0 - h * dy / d, m.1 + h * dx / d), (m.0 + h * dy / d, m.1 - h * dx / d)]
        default:
            return []  // ellipses are not cutters/targets yet
        }
    }

    /// Parameter of a point on the target curve (see `Crossing.param`).
    func curveParam(_ id: String, _ q: (Double, Double)) -> Double {
        let e = entities[id]!
        switch e.kind {
        case .line:
            let a = point(e.points[0]), b = point(e.points[1])
            let dx = b.0 - a.0, dy = b.1 - a.1
            return ((q.0 - a.0) * dx + (q.1 - a.1) * dy) / (dx * dx + dy * dy)
        case .arc:
            let (c, _) = circleOf(id)
            return Self.wrap(atan2(q.1 - c.1, q.0 - c.0) - arcSpan(id).a0)
        case .ellipseArc:
            return Self.wrap(ellipseParam(id, q) - ellipseArcSpan(id).phi0)
        case .ellipse:
            return Self.wrap(ellipseParam(id, q))
        default:
            let (c, _) = circleOf(id)
            return Self.wrap(atan2(q.1 - c.1, q.0 - c.0))
        }
    }

    /// Where other curves cross `id`, sorted along it. Crossings at the target's own ends are
    /// excluded (they are connections, not cut points).
    func crossings(_ id: String) -> [Crossing] {
        let tol = lengthTolerance * 10
        let e = entities[id]!
        var out: [Crossing] = []
        for other in entityOrder where other != id {
            guard let o = entities[other], o.kind != .point, o.kind != .spline else { continue }
            for q in carrierIntersections(id, other) where withinExtent(other, q, tol: tol) && withinExtent(id, q, tol: tol) {
                let t = curveParam(id, q)
                switch e.kind {
                case .line:
                    let l = hypot(point(e.points[1]).0 - point(e.points[0]).0, point(e.points[1]).1 - point(e.points[0]).1)
                    guard t * l > tol, (1 - t) * l > tol else { continue }
                case .arc:
                    let (_, r) = circleOf(id), sweep = arcSpan(id).sweep
                    guard t * r > tol, (sweep - t) * r > tol else { continue }
                case .ellipseArc:
                    let r = max(params[e.params[0]], params[e.params[1]]), sweep = ellipseArcSpan(id).sweep
                    guard t * r > tol, (sweep - t) * r > tol else { continue }
                default: break
                }
                if !out.contains(where: { abs($0.param - t) < 1e-12 && $0.cutter == other }) {
                    out.append(Crossing(param: t, point: q, cutter: other))
                }
            }
        }
        return out.sorted { $0.param < $1.param }
    }

    // MARK: constraint bookkeeping

    /// Constraints whose meaning depends on a curve's extent (length, midpoint, whole-curve
    /// symmetry, equal length) — they cannot survive a trim.
    func extentConstraints(_ curve: String) -> [String] {
        userConstraints.filter { c in
            guard c.entities.contains(curve) else { return false }
            switch c.kind {
            case .distance, .horizontalDistance, .verticalDistance: return c.entities == [curve]
            case .midpoint: return true
            case .offset: return c.alignedEnds != nil || c.tangentEnds != nil
            case .equal: return entities[curve]?.kind == .line
            case .symmetric: return c.entities.count == 3 && c.entities[2] != curve
            default: return false
            }
        }.map(\.id)
    }

    mutating func removeConstraints(_ ids: [String]) -> [String] {
        let set = Set(ids)
        let removed = constraints.filter { set.contains($0.id) && !$0.isInternal }.map(\.id)
        constraints.removeAll { set.contains($0.id) && !$0.isInternal }
        return removed
    }

    /// Constraints that reference a point, or use it as a tangency point.
    func constraintsOn(_ pointID: String) -> [String] {
        userConstraints.filter {
            $0.entities.contains(pointID) || $0.at == pointID || ($0.alignedEnds ?? []).contains(pointID)
                || ($0.tangentEnds ?? []).contains(pointID)
        }.map(\.id)
    }

    mutating func retarget(_ constraintIDs: [String], from old: String, to new: String) {
        for i in constraints.indices where constraintIDs.contains(constraints[i].id) {
            constraints[i].entities = constraints[i].entities.map { $0 == old ? new : $0 }
            if constraints[i].at == old { constraints[i].at = new }
            constraints[i].alignedEnds = constraints[i].alignedEnds?.map { $0 == old ? new : $0 }
            constraints[i].tangentEnds = constraints[i].tangentEnds?.map { $0 == old ? new : $0 }
        }
    }

    mutating func setPoint(_ id: String, _ q: (Double, Double)) {
        let e = entities[id]!
        params[e.params[0]] = q.0
        params[e.params[1]] = q.1
    }

    /// Hold a new endpoint on the curve that cut it: coincident with the cutter's endpoint if
    /// the cut is there, otherwise on the cutter. A relation holding that cutter endpoint on
    /// this point's curve is replaced (the coincidence implies it and makes it degenerate).
    mutating func attach(_ p: String, to cutter: String, _ result: inout TrimResult) throws {
        let tol = lengthTolerance * 10
        let q = point(p)
        let ce = entities[cutter]!
        let ends = ce.kind == .line ? ce.points : ce.kind == .arc || ce.kind == .ellipseArc ? Array(ce.points.dropFirst()) : []
        if let end = ends.first(where: { let r = point($0); return hypot(r.0 - q.0, r.1 - q.1) <= tol }) {
            if let owner = entities[p]?.owner {
                result.removedConstraints += removeConstraints(
                    userConstraints.filter { $0.kind == .onEntity && $0.entities == [end, owner] }.map(\.id))
            }
            if let k = try addUnlessImplied(.coincident, [p, end]) { result.constraints.append(k) }
            return
        }
        if let k = try addUnlessImplied(.onEntity, [p, cutter]) { result.constraints.append(k) }
    }

    // MARK: trim

    /// Power trim (SPEC 7.1 "trim"): removes the piece of `id` between the crossings on either
    /// side of `pick`. A curve with no crossings is deleted; a middle piece splits the curve.
    public mutating func trim(_ id: String, at pick: (Double, Double)) throws -> TrimResult {
        let e = try entity(id)
        guard e.kind != .point else { throw ForgeError(.invalidParams, "trim needs a curve", entities: [id]) }
        guard e.kind != .spline else {
            // NOT IMPLEMENTED: spline trimming (needs curve–curve intersection and knot insertion).
            throw ForgeError(.notImplemented, "trimming \(e.kind.rawValue)s is not implemented yet", entities: [id])
        }
        var s = self
        var result = TrimResult()
        let xs = s.crossings(id)
        let t = s.curveParam(id, pick)

        if e.kind == .circle || e.kind == .ellipse {
            guard !xs.isEmpty else { return try deleteWhole(id) }
            guard xs.count >= 2 else {
                throw ForgeError(.invalidParams, "a closed curve crossed only once cannot be trimmed (it needs two cut points)", entities: [id])
            }
            // The removed piece runs counter-clockwise from `lo` to `hi` around the pick.
            let hiIndex = xs.firstIndex { $0.param > t } ?? 0
            let hi = xs[hiIndex], lo = xs[(hiIndex + xs.count - 1) % xs.count]
            let arc = e.kind == .circle
                ? s.replaceCircle(id, withArcFrom: hi.point, to: lo.point, &result)
                : s.replaceEllipse(id, withArcFrom: hi.point, to: lo.point, &result)
            let ae = s.entities[arc]!
            try s.attach(ae.points[1], to: hi.cutter, &result)
            try s.attach(ae.points[2], to: lo.cutter, &result)
            result.created = [arc]
            try s.commitTrim(id)
            self = s
            return result
        }

        let lo = xs.last { $0.param < t }, hi = xs.first { $0.param > t }
        if lo == nil && hi == nil { return try deleteWhole(id) }
        result.removedConstraints += s.removeConstraints(s.extentConstraints(id))
        let curved = e.kind == .arc || e.kind == .ellipseArc
        let (start, end) = (e.points[curved ? 1 : 0], e.points[curved ? 2 : 1])
        switch (lo, hi) {
        case (nil, let hi?):
            result.removedConstraints += s.removeConstraints(s.constraintsOn(start))
            s.setPoint(start, hi.point)
            try s.attach(start, to: hi.cutter, &result)
        case (let lo?, nil):
            result.removedConstraints += s.removeConstraints(s.constraintsOn(end))
            s.setPoint(end, lo.point)
            try s.attach(end, to: lo.cutter, &result)
        case (let lo?, let hi?):
            // Split: the original keeps start → lo, a new curve takes hi → end.
            let farEnd = s.point(end)
            let piece: String
            switch e.kind {
            case .line: piece = s.addLine(from: hi.point, to: farEnd, construction: e.construction)
            case .arc: piece = s.addArc(center: s.circleOf(id).c, start: hi.point, end: farEnd, construction: e.construction)
            default: piece = s.ellipsePiece(of: id, from: hi.point, to: farEnd)
            }
            let pe = s.entities[piece]!
            let newEnd = pe.points[curved ? 2 : 1], newStart = pe.points[curved ? 1 : 0]
            s.retarget(s.constraintsOn(end), from: end, to: newEnd)
            s.setPoint(end, lo.point)
            try s.attach(end, to: lo.cutter, &result)
            try s.attach(newStart, to: hi.cutter, &result)
            // The two pieces stay on one carrier (ellipse pieces already share axes and rotation).
            let same: ConstraintKind = e.kind == .line ? .collinear : e.kind == .arc ? .coradial : .concentric
            if let k = try s.addUnlessImplied(same, [id, piece]) { result.constraints.append(k) }
            result.created = [piece]
        default:
            break
        }
        try s.commitTrim(id)
        self = s
        return result
    }

    /// Replaces a circle by a counter-clockwise arc on it; the arc takes over the circle's
    /// relations (and its centre's). Whole-circle symmetry cannot carry over and is removed.
    mutating func replaceCircle(_ id: String, withArcFrom a: (Double, Double), to b: (Double, Double), _ result: inout TrimResult) -> String {
        let e = entities[id]!
        let arc = addArc(center: circleOf(id).c, start: a, end: b, construction: e.construction)
        let ae = entities[arc]!
        let refs = userConstraints.filter { $0.entities.contains(id) || $0.entities.contains(e.points[0]) }
        let whole = refs.filter { $0.kind == .symmetric && $0.entities.count == 3 && $0.entities[2] != id }.map(\.id)
        result.removedConstraints += removeConstraints(whole)
        let keep = refs.map(\.id).filter { !whole.contains($0) }
        retarget(keep, from: id, to: arc)
        retarget(keep, from: e.points[0], to: ae.points[0])
        constraints.removeAll { $0.entities.contains(id) }
        entities.removeValue(forKey: e.points[0])
        entities.removeValue(forKey: id)
        entityOrder.removeAll { $0 == id || $0 == e.points[0] }
        result.deleted.append(id)
        return arc
    }

    /// Replaces an ellipse by a partial ellipse on it (sharing its axes and rotation), which
    /// takes over the ellipse's relations and its centre's.
    mutating func replaceEllipse(_ id: String, withArcFrom a: (Double, Double), to b: (Double, Double), _ result: inout TrimResult) -> String {
        let e = entities[id]!
        let arc = insertEllipseArc(center: point(e.points[0]), shape: e.params, from: ellipseParam(id, a), to: ellipseParam(id, b), construction: e.construction)
        let ae = entities[arc]!
        let keep = userConstraints.filter { $0.entities.contains(id) || $0.entities.contains(e.points[0]) }.map(\.id)
        retarget(keep, from: id, to: arc)
        retarget(keep, from: e.points[0], to: ae.points[0])
        constraints.removeAll { $0.entities.contains(id) }
        entities.removeValue(forKey: e.points[0])
        entities.removeValue(forKey: id)
        entityOrder.removeAll { $0 == id || $0 == e.points[0] }
        result.deleted.append(id)
        return arc
    }

    /// A new partial ellipse on the same ellipse as `id` (shared axes and rotation).
    mutating func ellipsePiece(of id: String, from a: (Double, Double), to b: (Double, Double)) -> String {
        let e = entities[id]!
        return insertEllipseArc(center: point(e.points[0]), shape: e.params, from: ellipseParam(id, a), to: ellipseParam(id, b), construction: e.construction)
    }

    // MARK: split

    /// Split entities (SPEC 7.1 "split entities"): a line or arc at one point into two pieces
    /// joined by a coincidence (and kept collinear / coradial); a circle at two points into two
    /// arcs. Length-type relations of the original are removed; the far end's relations move
    /// to the new piece.
    public mutating func split(_ id: String, at pts: [(Double, Double)]) throws -> TrimResult {
        let e = try entity(id)
        var s = self
        var result = TrimResult()
        let tol = s.lengthTolerance * 10
        func project(_ q: (Double, Double)) -> (Double, Double) {
            if e.kind == .line {
                let (a, b) = (s.point(e.points[0]), s.point(e.points[1]))
                let t = s.curveParam(id, q)
                return (a.0 + t * (b.0 - a.0), a.1 + t * (b.1 - a.1))
            }
            if Self.isElliptic(e.kind) { return s.ellipsePoint(id, s.ellipseParam(id, q)) }
            let (c, r) = s.circleOf(id)
            let l = hypot(q.0 - c.0, q.1 - c.1)
            guard l > 0 else { return q }
            return (c.0 + (q.0 - c.0) * r / l, c.1 + (q.1 - c.1) * r / l)
        }
        switch e.kind {
        case .line, .arc, .ellipseArc:
            guard pts.count == 1 else { throw ForgeError(.invalidParams, "split a line or arc at exactly one point", entities: [id]) }
            let p = project(pts[0])
            let t = s.curveParam(id, p)
            let span: Double, limit: Double
            switch e.kind {
            case .line:
                span = hypot(s.point(e.points[1]).0 - s.point(e.points[0]).0, s.point(e.points[1]).1 - s.point(e.points[0]).1)
                limit = 1
            case .arc: (span, limit) = (s.circleOf(id).r, s.arcSpan(id).sweep)
            default: (span, limit) = (max(s.params[e.params[0]], s.params[e.params[1]]), s.ellipseArcSpan(id).sweep)
            }
            guard t * span > tol, (limit - t) * span > tol else {
                throw ForgeError(.invalidParams, "the split point must lie inside \(id), not at or beyond its ends", entities: [id])
            }
            result.removedConstraints += s.removeConstraints(s.extentConstraints(id))
            let curved = e.kind != .line
            let end = e.points[curved ? 2 : 1]
            let farEnd = s.point(end)
            let piece: String
            switch e.kind {
            case .line: piece = s.addLine(from: p, to: farEnd, construction: e.construction)
            case .arc: piece = s.addArc(center: s.circleOf(id).c, start: p, end: farEnd, construction: e.construction)
            default: piece = s.ellipsePiece(of: id, from: p, to: farEnd)
            }
            let pe = s.entities[piece]!
            let (newStart, newEnd) = (pe.points[curved ? 1 : 0], pe.points[curved ? 2 : 1])
            s.retarget(s.constraintsOn(end), from: end, to: newEnd)
            s.setPoint(end, p)
            if let k = try s.addUnlessImplied(.coincident, [end, newStart]) { result.constraints.append(k) }
            // The pieces share a point, so what is left to say is: the piece's far end stays on
            // the original line (collinear's first row would be degenerate), or the centres
            // coincide (the equal radius then follows).
            if e.kind == .line {
                if let k = try s.addUnlessImplied(.onEntity, [newEnd, id]) { result.constraints.append(k) }
            } else if let k = try s.addUnlessImplied(.concentric, [id, piece]) {
                result.constraints.append(k)
            }
            result.created = [piece]
        case .circle, .ellipse:
            guard pts.count == 2 else { throw ForgeError(.invalidParams, "split a closed curve at exactly two points", entities: [id]) }
            let p1 = project(pts[0]), p2 = project(pts[1])
            guard hypot(p1.0 - p2.0, p1.1 - p2.1) > tol else { throw ForgeError(.invalidParams, "the two split points coincide", entities: [id]) }
            let a1: String, a2: String
            if e.kind == .circle {
                a1 = s.replaceCircle(id, withArcFrom: p1, to: p2, &result)
                a2 = s.addArc(center: s.circleOf(a1).c, start: p2, end: p1, construction: e.construction)
            } else {
                a1 = s.replaceEllipse(id, withArcFrom: p1, to: p2, &result)
                a2 = s.ellipsePiece(of: a1, from: p2, to: p1)
            }
            let (e1, e2) = (s.entities[a1]!, s.entities[a2]!)
            for (x, y) in [(e1.points[2], e2.points[1]), (e2.points[2], e1.points[1])] {
                if let k = try s.addUnlessImplied(.coincident, [x, y]) { result.constraints.append(k) }
            }
            // Concentric + both joints; the second arc's own radius equality is then implied.
            // (Equal radii would be singular when the split points are diametrically opposite.)
            if let k = try s.addUnlessImplied(.concentric, [a1, a2]) { result.constraints.append(k) }
            result.created = [a1, a2]
        default:
            // NOT IMPLEMENTED: spline splitting (knot insertion); splitting a point is meaningless.
            let later = e.kind == .spline
            throw ForgeError(later ? .notImplemented : .invalidParams, "\(e.kind.rawValue)s cannot be split\(later ? " yet" : "")", entities: [id])
        }
        try s.commitTrim(id)
        self = s
        return result
    }

    mutating func deleteWhole(_ id: String) throws -> TrimResult {
        let (ents, cons) = try delete(entities: [id])
        resolve()
        return TrimResult(created: [], deleted: ents.filter { $0 == id }, removedConstraints: cons, constraints: [])
    }

    mutating func commitTrim(_ id: String) throws {
        refreshDriven()
        let r = resolve()
        if r.status == .failed || !r.conflicting.isEmpty {
            throw ForgeError(
                .solverFailed, "the sketch cannot be solved after trimming \(id); relations on the trimmed curve conflict with its new ends",
                entities: [id] + r.conflicting)
        }
    }

    // MARK: extend

    /// Extend (SPEC 7.1 "extend"): moves the end of a line or arc nearest `pick` to the next
    /// curve it would reach. Relations on that end are dropped, and the end is held on the
    /// curve it reaches.
    public mutating func extend(_ id: String, near pick: (Double, Double)) throws -> TrimResult {
        let e = try entity(id)
        guard e.kind == .line || e.kind == .arc else { throw ForgeError(.invalidParams, "extend needs a line or an arc", entities: [id]) }
        var s = self
        let tol = s.lengthTolerance * 10
        let (startID, endID) = e.kind == .line ? (e.points[0], e.points[1]) : (e.points[1], e.points[2])
        let (ps, pe) = (s.point(startID), s.point(endID))
        let atEnd = hypot(pick.0 - pe.0, pick.1 - pe.1) <= hypot(pick.0 - ps.0, pick.1 - ps.1)
        let moving = atEnd ? endID : startID
        // Candidates: carrier intersections beyond the chosen end, within the other curve.
        var best: (d: Double, q: (Double, Double), cutter: String)?
        for other in s.entityOrder where other != id {
            guard let o = s.entities[other], o.kind != .point, o.kind != .spline else { continue }
            for q in s.carrierIntersections(id, other) where s.withinExtent(other, q, tol: tol) {
                let d: Double
                if e.kind == .line {
                    let t = s.curveParam(id, q), l = hypot(pe.0 - ps.0, pe.1 - ps.1)
                    d = atEnd ? (t - 1) * l : -t * l
                } else {
                    let (_, r) = s.circleOf(id), (_, sweep) = s.arcSpan(id)
                    let a = s.curveParam(id, q)  // CCW from start
                    guard a > sweep + tol / r else { continue }  // on the arc already
                    d = atEnd ? (a - sweep) * r : (2 * .pi - a) * r
                }
                if d > tol, d < (best?.d ?? .infinity) { best = (d, q, other) }
            }
        }
        guard let target = best else {
            throw ForgeError(.invalidParams, "\(id) does not reach any other curve when extended from that end", entities: [id])
        }
        var result = TrimResult()
        result.removedConstraints += s.removeConstraints(s.extentConstraints(id) + s.constraintsOn(moving))
        s.setPoint(moving, target.q)
        try s.attach(moving, to: target.cutter, &result)
        try s.commitTrim(id)
        self = s
        return result
    }
}

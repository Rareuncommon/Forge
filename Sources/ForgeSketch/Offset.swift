import ForgeCore
import Foundation

/// Result of an offset: the copies per side, and the relations added.
public struct OffsetResult: Sendable {
    /// Offset copies, in chain order, for each side produced (one, or two when bi-directional).
    public var sides: [[String]] = []
    /// Cap lines closing open chains (bi-directional with caps).
    public var caps: [String] = []
    public var constraints: [String] = []
    /// The offset dimension that drives every copy.
    public var dimension: String?
}

extension Sketch {
    /// One curve of a chain, in travel order.
    struct ChainSeg {
        var id: String
        /// Travel runs start → end (for arcs: counter-clockwise).
        var forward: Bool
    }

    struct Chain {
        var segs: [ChainSeg]
        var closed: Bool
    }

    /// The endpoint ids of a line or arc in its own start → end order.
    func endIDs(_ id: String) -> (String, String) {
        let e = entities[id]!
        return e.kind == .arc ? (e.points[1], e.points[2]) : (e.points[0], e.points[1])
    }

    func travelEnds(_ s: ChainSeg) -> (start: String, end: String) {
        let (a, b) = endIDs(s.id)
        return s.forward ? (a, b) : (b, a)
    }

    /// Unit tangent in the travel direction at a travel end (`atStart`) of a segment.
    func travelTangent(_ s: ChainSeg, atStart: Bool) -> (Double, Double) {
        let e = entities[s.id]!
        let (ts, te) = travelEnds(s)
        if e.kind == .line {
            let a = point(ts), b = point(te), l = hypot(b.0 - a.0, b.1 - a.1)
            return ((b.0 - a.0) / l, (b.1 - a.1) / l)
        }
        let (c, r) = circleOf(s.id)
        let q = point(atStart ? ts : te)
        let ccw = (-(q.1 - c.1) / r, (q.0 - c.0) / r)
        return s.forward ? ccw : (-ccw.0, -ccw.1)
    }

    /// Groups lines and arcs into chains joined end to end (by position).
    func chains(_ ids: [String]) throws -> [Chain] {
        let tol = lengthTolerance * 10
        func same(_ p: String, _ q: String) -> Bool {
            let a = point(p), b = point(q)
            return hypot(a.0 - b.0, a.1 - b.1) <= tol
        }
        var remaining = ids
        var out: [Chain] = []
        while let first = remaining.first {
            remaining.removeFirst()
            var segs = [ChainSeg(id: first, forward: true)]
            // Grow forward from the travel end, then backward from the travel start.
            for dir in [true, false] {
                while true {
                    let tip = dir ? travelEnds(segs.last!).end : travelEnds(segs.first!).start
                    let touching = remaining.filter { let (a, b) = endIDs($0); return same(a, tip) || same(b, tip) }
                    if touching.count > 1 {
                        throw ForgeError(.invalidParams, "more than two curves meet at \(tip); offset needs simple chains", entities: [tip] + touching)
                    }
                    guard let next = touching.first else { break }
                    remaining.removeAll { $0 == next }
                    let (a, _) = endIDs(next)
                    // Moving forward, the next segment starts at the tip; moving backward, it ends there.
                    let fwd = dir ? same(a, tip) : !same(a, tip)
                    if dir { segs.append(ChainSeg(id: next, forward: fwd)) } else { segs.insert(ChainSeg(id: next, forward: fwd), at: 0) }
                }
            }
            let closed = segs.count > 1 && same(travelEnds(segs.last!).end, travelEnds(segs.first!).start)
            out.append(Chain(segs: segs, closed: closed))
        }
        return out
    }

    /// Signed area enclosed by a closed chain (positive when travel is counter-clockwise).
    func chainArea(_ ch: Chain) -> Double {
        var area = 0.0
        for s in ch.segs {
            let (ts, te) = travelEnds(s)
            let a = point(ts), b = point(te)
            area += (a.0 * b.1 - b.0 * a.1) / 2
            if entities[s.id]!.kind == .arc {
                // Circular segment between the chord and the arc, signed by travel direction.
                let (_, r) = circleOf(s.id), sweep = arcSpan(s.id).sweep
                area += (s.forward ? 1 : -1) * r * r / 2 * (sweep - sin(sweep))
            }
        }
        return area
    }

    /// Offset (SPEC 7.1 "offset"): copies of chains of lines/arcs (and circles) at `distance`.
    /// Positive distance is to the left of each chain's travel direction; `toward` picks the side
    /// containing that point instead, and without it closed chains and circles go outward. One
    /// offset dimension drives every copy; copies of a chain are joined at its corners
    /// (extended or trimmed to meet) and open chains' ends stay square to the originals.
    public mutating func offset(
        _ ids: [String], distance d: Double, toward: (Double, Double)? = nil, reverse: Bool = false,
        bidirectional: Bool = false, capEnds: Bool = false, makeBaseConstruction: Bool = false
    ) throws -> OffsetResult {
        guard d > 0, d.isFinite else { throw ForgeError(.invalidParams, "offset distance must be positive") }
        guard !ids.isEmpty else { throw ForgeError(.invalidParams, "select the curves to offset") }
        var curves: [String] = [], circles: [String] = []
        for id in ids {
            let e = try entity(id)
            switch e.kind {
            case .line, .arc: curves.append(id)
            case .circle: circles.append(id)
            case .point: throw ForgeError(.invalidParams, "points cannot be offset", entities: [id])
            case .ellipse, .ellipseArc, .spline:
                // NOT IMPLEMENTED: the offset of an ellipse or spline is not a curve of the same kind
                // (needs spline approximation of offset curves).
                throw ForgeError(.notImplemented, "offsetting \(e.kind.rawValue)s is not implemented yet", entities: [id])
            }
        }
        var s = self
        var result = OffsetResult()
        let chains = try s.chains(curves)
        let signs: [Double] = bidirectional ? [1, -1] : [1]
        var master: String?
        func addOffset(_ orig: String, _ copy: String, aligned: [String], tangent: [String]) throws {
            let id = try s.addConstraint(
                .offset, [orig, copy], value: d, driven: false, linkedTo: master,
                alignedEnds: aligned.isEmpty ? nil : aligned, tangentEnds: tangent.isEmpty ? nil : tangent)
            if master == nil { master = id; result.dimension = id } else { result.constraints.append(id) }
        }

        for ch in chains {
            // δ > 0 offsets to the left of travel.
            var base = 1.0
            if let t = toward {
                let s0 = ch.segs[0]
                let (ts, _) = s.travelEnds(s0)
                let a = s.point(ts), u = s.travelTangent(s0, atStart: true)
                if s.entities[s0.id]!.kind == .line {
                    base = u.0 * (t.1 - a.1) - u.1 * (t.0 - a.0) >= 0 ? 1 : -1
                } else {
                    let (c, r) = s.circleOf(s0.id)
                    let inside = hypot(t.0 - c.0, t.1 - c.1) < r
                    base = (inside == s0.forward) ? 1 : -1  // left of counter-clockwise travel is inside
                }
            } else if ch.closed {
                base = s.chainArea(ch) > 0 ? -1 : 1  // outward
            }
            if reverse { base = -base }
            var sideCopies: [[String]] = []
            for sign in signs {
                let delta = base * sign * d
                // Offset carriers and endpoints (in each original's own orientation).
                var copies: [(start: (Double, Double), end: (Double, Double), center: (Double, Double)?)] = []
                for sg in ch.segs {
                    let e = s.entities[sg.id]!
                    let (a, b) = s.endIDs(sg.id)
                    if e.kind == .line {
                        let u = s.travelTangent(sg, atStart: true)
                        let n = (-u.1 * delta, u.0 * delta)
                        let (pa, pb) = (s.point(a), s.point(b))
                        copies.append(((pa.0 + n.0, pa.1 + n.1), (pb.0 + n.0, pb.1 + n.1), nil))
                    } else {
                        let (c, r) = s.circleOf(sg.id)
                        let r2 = sg.forward ? r - delta : r + delta
                        guard r2 > s.lengthTolerance * 100 else {
                            throw ForgeError(.invalidParams, "offset \(d) mm is larger than the radius of \(sg.id) on that side", entities: [sg.id])
                        }
                        func scale(_ q: (Double, Double)) -> (Double, Double) { (c.0 + (q.0 - c.0) * r2 / r, c.1 + (q.1 - c.1) * r2 / r) }
                        copies.append((scale(s.point(a)), scale(s.point(b)), c))
                    }
                }
                // Joints: consecutive copies meet at their carriers' intersection nearest the joint.
                var tangentJoint: [Bool] = Array(repeating: false, count: ch.segs.count)  // joint at segment k's travel start
                let jointCount = ch.closed ? ch.segs.count : ch.segs.count - 1
                for j in 0..<jointCount {
                    let i = j, k = (j + 1) % ch.segs.count
                    let ti = s.travelTangent(ch.segs[i], atStart: false), tk = s.travelTangent(ch.segs[k], atStart: true)
                    let joint = s.point(s.travelEnds(ch.segs[i]).end)
                    if abs(ti.0 * tk.1 - ti.1 * tk.0) < 1e-9 && ti.0 * tk.0 + ti.1 * tk.1 > 0 {
                        tangentJoint[k] = true
                        continue  // smooth joint: the offset ends already coincide
                    }
                    let q = try Self.meet(copies[i], s.entities[ch.segs[i].id]!.kind, copies[k], s.entities[ch.segs[k].id]!.kind, near: joint)
                    if ch.segs[i].forward { copies[i].end = q } else { copies[i].start = q }
                    if ch.segs[k].forward { copies[k].start = q } else { copies[k].end = q }
                }
                // Create the copies.
                var made: [String] = []
                for (sg, cp) in zip(ch.segs, copies) {
                    let e = s.entities[sg.id]!
                    let n = e.kind == .line
                        ? s.addLine(from: cp.start, to: cp.end, construction: e.construction)
                        : s.addArc(center: cp.center!, start: cp.start, end: cp.end, construction: e.construction)
                    made.append(n)
                }
                let copySeg = zip(ch.segs, made).map { ChainSeg(id: $1, forward: $0.forward) }
                // Joints first (coincidences), then one offset per copy.
                for j in 0..<jointCount {
                    let k = (j + 1) % ch.segs.count
                    if let c = try s.addUnlessImplied(.coincident, [s.travelEnds(copySeg[j]).end, s.travelEnds(copySeg[k]).start]) {
                        result.constraints.append(c)
                    }
                }
                for (idx, (sg, cp)) in zip(ch.segs, copySeg).enumerated() {
                    var aligned: [String] = [], tangent: [String] = []
                    if !ch.closed && idx == 0 { aligned.append(s.travelEnds(cp).start) }
                    if !ch.closed && idx == ch.segs.count - 1 { aligned.append(s.travelEnds(cp).end) }
                    if tangentJoint[idx] { tangent.append(s.travelEnds(cp).start) }
                    try addOffset(sg.id, cp.id, aligned: aligned, tangent: tangent)
                }
                sideCopies.append(made)
                result.sides.append(made)
            }
            if bidirectional && capEnds && !ch.closed {
                let (a, b) = (sideCopies[0], sideCopies[1])
                let firstA = ChainSeg(id: a.first!, forward: ch.segs.first!.forward), firstB = ChainSeg(id: b.first!, forward: ch.segs.first!.forward)
                let lastA = ChainSeg(id: a.last!, forward: ch.segs.last!.forward), lastB = ChainSeg(id: b.last!, forward: ch.segs.last!.forward)
                for (p, q) in [(s.travelEnds(firstA).start, s.travelEnds(firstB).start), (s.travelEnds(lastA).end, s.travelEnds(lastB).end)] {
                    let cap = s.addLine(from: s.point(p), to: s.point(q))
                    let (c0, c1) = s.endIDs(cap)
                    for (x, y) in [(c0, p), (c1, q)] {
                        if let c = try s.addUnlessImplied(.coincident, [x, y]) { result.constraints.append(c) }
                    }
                    result.caps.append(cap)
                }
            }
        }

        for id in circles {
            let e = s.entities[id]!
            let (c, r) = s.circleOf(id)
            var outward = true
            if let t = toward { outward = hypot(t.0 - c.0, t.1 - c.1) > r }
            if reverse { outward.toggle() }
            var made: [String] = []
            for sign in signs {
                let r2 = r + (outward ? 1 : -1) * sign * d
                guard r2 > s.lengthTolerance * 100 else {
                    throw ForgeError(.invalidParams, "offset \(d) mm is larger than the radius of \(id) on that side", entities: [id])
                }
                let n = s.addCircle(center: c, radius: r2, construction: e.construction)
                try addOffset(id, n, aligned: [], tangent: [])
                made.append(n)
            }
            result.sides.append(made)
        }

        if makeBaseConstruction {
            for id in ids { try s.setConstruction(id, true) }
        }
        s.resolve()
        if let rep = s.report, rep.status == .failed || !rep.conflicting.isEmpty {
            throw ForgeError(.solverFailed, "the offset could not be solved", entities: ids)
        }
        self = s
        return result
    }

    typealias OffsetCopy = (start: (Double, Double), end: (Double, Double), center: (Double, Double)?)

    /// Intersection of two offset carriers nearest a joint.
    static func meet(_ a: OffsetCopy, _ ka: SketchEntityKind, _ b: OffsetCopy, _ kb: SketchEntityKind, near j: (Double, Double)) throws
        -> (Double, Double)
    {
        func circle(_ c: OffsetCopy) -> ((Double, Double), Double) {
            (c.center!, hypot(c.start.0 - c.center!.0, c.start.1 - c.center!.1))
        }
        var pts: [(Double, Double)] = []
        switch (ka == .line, kb == .line) {
        case (true, true):
            let r = (a.end.0 - a.start.0, a.end.1 - a.start.1), s = (b.end.0 - b.start.0, b.end.1 - b.start.1)
            let den = r.0 * s.1 - r.1 * s.0
            if abs(den) > 1e-12 * hypot(r.0, r.1) * hypot(s.0, s.1) {
                let t = ((b.start.0 - a.start.0) * s.1 - (b.start.1 - a.start.1) * s.0) / den
                pts = [(a.start.0 + t * r.0, a.start.1 + t * r.1)]
            }
        case (true, false), (false, true):
            let (l, c) = ka == .line ? (a, b) : (b, a)
            let (o, rad) = circle(c)
            let d = (l.end.0 - l.start.0, l.end.1 - l.start.1), f = (l.start.0 - o.0, l.start.1 - o.1)
            let A = d.0 * d.0 + d.1 * d.1, B = 2 * (f.0 * d.0 + f.1 * d.1), C = f.0 * f.0 + f.1 * f.1 - rad * rad
            let disc = B * B - 4 * A * C
            if disc >= 0 {
                pts = [(-B - disc.squareRoot()) / (2 * A), (-B + disc.squareRoot()) / (2 * A)].map { (l.start.0 + $0 * d.0, l.start.1 + $0 * d.1) }
            }
        case (false, false):
            let (c1, r1) = circle(a), (c2, r2) = circle(b)
            let dx = c2.0 - c1.0, dy = c2.1 - c1.1, dd = hypot(dx, dy)
            if dd > 1e-12, dd <= r1 + r2, dd >= abs(r1 - r2) {
                let x = (dd * dd + r1 * r1 - r2 * r2) / (2 * dd), h = max(0, r1 * r1 - x * x).squareRoot()
                let m = (c1.0 + x * dx / dd, c1.1 + x * dy / dd)
                pts = [(m.0 - h * dy / dd, m.1 + h * dx / dd), (m.0 + h * dy / dd, m.1 - h * dx / dd)]
            }
        }
        guard let best = pts.min(by: { hypot($0.0 - j.0, $0.1 - j.1) < hypot($1.0 - j.0, $1.1 - j.1) }) else {
            throw ForgeError(.invalidParams, "the offset curves do not meet at a corner of the chain (the offset is too large for it)")
        }
        return best
    }
}

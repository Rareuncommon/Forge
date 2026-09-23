import ForgeCore
import Foundation

public struct ProfileLoop: Codable, Sendable, Hashable {
    /// Curves in traversal order.
    public var entities: [String]
    /// Whether each curve is traversed in its own direction.
    public var forward: [Bool]
    /// Signed area (mm², positive = counter-clockwise as traversed).
    public var signedAreaMM2: Double
    /// Index of the smallest loop containing this one (holes), or nil for outer loops.
    public var parent: Int?
    public var depth: Int

    enum CodingKeys: String, CodingKey {
        case entities, forward, parent, depth
        case signedAreaMM2 = "signed_area_mm2"
    }
}

public struct ProfileReport: Codable, Sendable, Hashable {
    public var loops: [ProfileLoop]
    /// Endpoints used by exactly one curve (open contour).
    public var openEnds: [String]
    /// Points shared by three or more curves.
    public var branchPoints: [String]
    /// Pairs of curves that cross each other (not at shared endpoints).
    public var intersections: [[String]]
    /// Sum over regions of (outer area − hole areas) with even/odd nesting (mm²).
    public var regionAreaMM2: Double
    /// Usable for a boss/cut feature: closed, non-branching, non-self-intersecting.
    public var valid: Bool
    public var issues: [String]

    enum CodingKeys: String, CodingKey {
        case loops, intersections, valid, issues
        case openEnds = "open_ends"
        case branchPoints = "branch_points"
        case regionAreaMM2 = "region_area_mm2"
    }
}

extension Sketch {
    /// Sampled polyline of a curve in sketch coordinates (for display, areas, intersection tests).
    public func polyline(_ id: String, segments: Int = 64) -> [(Double, Double)] {
        guard let e = entities[id] else { return [] }
        switch e.kind {
        case .point:
            return [point(id)]
        case .line:
            return [point(e.points[0]), point(e.points[1])]
        case .circle:
            let (cx, cy) = point(e.points[0]), r = params[e.params[0]]
            return (0...segments).map { i in
                let t = 2 * Double.pi * Double(i) / Double(segments)
                return (cx + r * cos(t), cy + r * sin(t))
            }
        case .arc:
            let (cx, cy) = point(e.points[0]), (sx, sy) = point(e.points[1]), (ex, ey) = point(e.points[2])
            let r = ((sx - cx) * (sx - cx) + (sy - cy) * (sy - cy)).squareRoot()
            let a0 = atan2(sy - cy, sx - cx)
            var sweep = atan2(ey - cy, ex - cx) - a0
            while sweep <= 0 { sweep += 2 * .pi }
            let n = max(2, Int((Double(segments) * sweep / (2 * .pi)).rounded(.up)))
            return (0...n).map { i in
                let t = a0 + sweep * Double(i) / Double(n)
                return (cx + r * cos(t), cy + r * sin(t))
            }
        case .ellipse:
            let (cx, cy) = point(e.points[0])
            let a = params[e.params[0]], b = params[e.params[1]], rot = params[e.params[2]]
            return (0...segments).map { i in
                let t = 2 * Double.pi * Double(i) / Double(segments)
                let u = a * cos(t), v = b * sin(t)
                return (cx + u * cos(rot) - v * sin(rot), cy + u * sin(rot) + v * cos(rot))
            }
        }
    }

    /// Exact area enclosed by a closed curve (circle/ellipse), else nil.
    func closedCurveArea(_ e: SketchEntity) -> Double? {
        switch e.kind {
        case .circle: return .pi * params[e.params[0]] * params[e.params[0]]
        case .ellipse: return .pi * params[e.params[0]] * params[e.params[1]]
        default: return nil
        }
    }

    /// Analyse the non-construction geometry as feature profiles (SPEC 7.1 "Check Sketch for
    /// Feature", "sketch contours/regions").
    public func profiles() -> ProfileReport {
        let curves = orderedEntities.filter { $0.kind != .point && !$0.construction }
        let scale = max(1, params.map(abs).max() ?? 1)
        let tol = 1e-7 * scale
        var issues: [String] = []

        // Nodes: endpoints merged by position.
        var nodes: [(Double, Double)] = []
        var nodeName: [String] = []
        func node(_ pid: String) -> Int {
            let (x, y) = point(pid)
            if let i = nodes.firstIndex(where: { abs($0.0 - x) <= tol && abs($0.1 - y) <= tol }) { return i }
            nodes.append((x, y))
            nodeName.append(pid)
            return nodes.count - 1
        }
        struct Edge { var id: String; var a: Int; var b: Int }
        var edges: [Edge] = []
        var loops: [ProfileLoop] = []
        for c in curves {
            switch c.kind {
            case .line: edges.append(Edge(id: c.id, a: node(c.points[0]), b: node(c.points[1])))
            case .arc: edges.append(Edge(id: c.id, a: node(c.points[1]), b: node(c.points[2])))
            case .circle, .ellipse:
                loops.append(ProfileLoop(entities: [c.id], forward: [true], signedAreaMM2: closedCurveArea(c)!, parent: nil, depth: 0))
            case .point: break
            }
        }
        var incident = [[Int]](repeating: [], count: nodes.count)
        for (i, e) in edges.enumerated() {
            incident[e.a].append(i)
            incident[e.b].append(i)
        }
        let openEnds = nodes.indices.filter { incident[$0].count == 1 }.map { nodeName[$0] }
        let branches = nodes.indices.filter { incident[$0].count >= 3 }.map { nodeName[$0] }
        if !openEnds.isEmpty { issues.append("open contour: \(openEnds.count) endpoint(s) are not connected (\(openEnds.joined(separator: ", ")))") }
        if !branches.isEmpty { issues.append("branching contour at \(branches.joined(separator: ", ")): three or more curves meet") }

        // Walk closed chains where every node has degree 2.
        var used = [Bool](repeating: false, count: edges.count)
        for start in edges.indices where !used[start] && edges[start].a != edges[start].b {
            used[start] = true
            var chain: [(Int, Bool)] = [(start, true)]
            let origin = edges[start].a
            var node = edges[start].b, current = start
            var ok = true
            while node != origin {
                guard incident[node].count == 2, let next = incident[node].first(where: { $0 != current }), !used[next] else {
                    ok = false
                    break
                }
                let forward = edges[next].a == node
                used[next] = true
                chain.append((next, forward))
                node = forward ? edges[next].b : edges[next].a
                current = next
            }
            guard ok else { continue }
            loops.append(ProfileLoop(
                entities: chain.map { edges[$0.0].id }, forward: chain.map { $0.1 }, signedAreaMM2: exactArea(chain.map { (edges[$0.0].id, $0.1) }),
                parent: nil, depth: 0))
        }

        // Crossing curves (sampled segment intersection, excluding shared endpoints).
        var crossings: [[String]] = []
        let polys = curves.map { ($0.id, polyline($0.id)) }
        for i in polys.indices {
            for j in (i + 1)..<polys.count where Self.polylinesCross(polys[i].1, polys[j].1, tol: tol) {
                crossings.append([polys[i].0, polys[j].0])
            }
        }
        if !crossings.isEmpty { issues.append("\(crossings.count) pair(s) of curves cross; split them where they intersect") }

        // Nesting by containment of a sample point, smallest container wins.
        let loopPolys = loops.map { loop -> [(Double, Double)] in
            loop.entities.flatMap { polyline($0) }
        }
        for i in loops.indices {
            let probe = loopPolys[i][0]
            var best: (Int, Double)?
            for j in loops.indices where j != i && abs(loops[j].signedAreaMM2) > abs(loops[i].signedAreaMM2) {
                if Self.contains(loopPolys[j], probe) && (best == nil || abs(loops[j].signedAreaMM2) < best!.1) {
                    best = (j, abs(loops[j].signedAreaMM2))
                }
            }
            loops[i].parent = best?.0
        }
        for i in loops.indices {
            var d = 0, p = loops[i].parent
            while let q = p { d += 1; p = loops[q].parent }
            loops[i].depth = d
        }
        let area = loops.reduce(0.0) { $0 + ($1.depth % 2 == 0 ? 1 : -1) * abs($1.signedAreaMM2) }
        if loops.isEmpty && issues.isEmpty { issues.append("no closed contours") }
        return ProfileReport(
            loops: loops, openEnds: openEnds, branchPoints: branches, intersections: crossings, regionAreaMM2: area,
            valid: !loops.isEmpty && openEnds.isEmpty && branches.isEmpty && crossings.isEmpty, issues: issues)
    }

    /// Exact signed area of a loop of lines and arcs: shoelace over the curve endpoints plus
    /// the circular segment of each arc (added when traversed counter-clockwise).
    func exactArea(_ chain: [(String, Bool)]) -> Double {
        var area = 0.0
        for (id, forward) in chain {
            let e = entities[id]!
            let (a, b): (String, String) = e.kind == .arc ? (e.points[1], e.points[2]) : (e.points[0], e.points[1])
            let (p, q) = forward ? (point(a), point(b)) : (point(b), point(a))
            area += (p.0 * q.1 - q.0 * p.1) / 2
            if e.kind == .arc {
                let (cx, cy) = point(e.points[0]), (sx, sy) = point(e.points[1]), (ex, ey) = point(e.points[2])
                let r2 = (sx - cx) * (sx - cx) + (sy - cy) * (sy - cy)
                var sweep = atan2(ey - cy, ex - cx) - atan2(sy - cy, sx - cx)
                while sweep <= 0 { sweep += 2 * .pi }
                let segment = r2 / 2 * (sweep - sin(sweep))
                area += forward ? segment : -segment
            }
        }
        return area
    }

    static func shoelace(_ p: [(Double, Double)]) -> Double {
        guard p.count > 2 else { return 0 }
        var s = 0.0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.0 * b.1 - b.0 * a.1
        }
        return s / 2
    }

    static func contains(_ poly: [(Double, Double)], _ q: (Double, Double)) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.1 > q.1) != (b.1 > q.1) && q.0 < (b.0 - a.0) * (q.1 - a.1) / (b.1 - a.1) + a.0 { inside.toggle() }
            j = i
        }
        return inside
    }

    static func polylinesCross(_ p: [(Double, Double)], _ q: [(Double, Double)], tol: Double) -> Bool {
        func seg(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), _ d: (Double, Double)) -> Bool {
            let d1 = (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0)
            let d2 = (b.0 - a.0) * (d.1 - a.1) - (b.1 - a.1) * (d.0 - a.0)
            let d3 = (d.0 - c.0) * (a.1 - c.1) - (d.1 - c.1) * (a.0 - c.0)
            let d4 = (d.0 - c.0) * (b.1 - c.1) - (d.1 - c.1) * (b.0 - c.0)
            let eps = tol * tol
            return ((d1 > eps && d2 < -eps) || (d1 < -eps && d2 > eps)) && ((d3 > eps && d4 < -eps) || (d3 < -eps && d4 > eps))
        }
        guard p.count > 1, q.count > 1 else { return false }
        for i in 0..<(p.count - 1) {
            for j in 0..<(q.count - 1) where seg(p[i], p[i + 1], q[j], q[j + 1]) { return true }
        }
        return false
    }
}

import ForgeCommands
import ForgeCore
import Foundation
import Testing

@testable import ForgeSketch

/// Cross-checks Forge's sketch solver against FreeCAD's planegcs (docs/adr/0003): same
/// degrees of freedom, same redundancy verdict, and — for fully defined sketches solved from
/// the same perturbed start — the same point positions. The oracle is an external process
/// (tools/planegcs-oracle/build.sh); these tests run only when FORGE_PLANEGCS_ORACLE names it.
@Suite("planegcs oracle", .enabled(if: PlanegcsOracle.path != nil, "set FORGE_PLANEGCS_ORACLE to tools/planegcs-oracle's binary"))
struct PlanegcsOracleTests {
    @Test(arguments: GoldenModelTests.modelURLs)
    func goldenSketchesAgree(_ url: URL) async throws {
        let script = try ForgeScript.load(url)
        let e = Engine()
        _ = try await e.run(script)
        let doc = try #require(await e.activeDocument)
        for sketch in doc.sketches.values.sorted(by: { $0.id < $1.id }) {
            try PlanegcsOracle.compare(sketch, label: "\(url.lastPathComponent)/\(sketch.id)")
        }
    }

    @Test(arguments: 0..<60)
    func randomSketchesAgree(_ seed: Int) throws {
        var rng = SplitMix(seed: UInt64(seed) &+ 0x5eed)
        let s = try PlanegcsOracle.randomSketch(&rng)
        try PlanegcsOracle.compare(s, label: "random-\(seed)")
    }
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum PlanegcsOracle {
    static let path: String? = ProcessInfo.processInfo.environment["FORGE_PLANEGCS_ORACLE"].flatMap {
        FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
    }

    struct Result {
        var status: Int
        var dof: Int
        var conflicting: [Int]
        var redundant: [Int]
        var params: [Int: Double]
    }

    /// The sketch in the oracle's input format, or nil if it uses something planegcs mapping
    /// does not cover yet (ellipses, splines, endpoint tangency, symmetric, offsets…).
    static func export(_ s: Sketch, params: [Double]) -> String? {
        var out: [String] = []
        var next = params.count
        var fixed = Set(s.entities[Sketch.originID]!.params)
        // Parameters no entity uses any more (left behind by deleted or trimmed geometry) are
        // not unknowns for Forge either.
        let used = Set(s.entities.values.flatMap(\.params))
        fixed.formUnion(params.indices.filter { !used.contains($0) })
        for c in s.constraints where c.kind == .fix {
            for id in c.entities {
                guard let e = s.entities[id] else { continue }
                fixed.formUnion(e.params)
                for p in e.points { fixed.formUnion(s.entities[p]!.params) }
            }
        }
        var extra: [(Int, Double)] = []
        func value(_ v: Double) -> Int {
            extra.append((next, v))
            fixed.insert(next)
            next += 1
            return next - 1
        }
        func pt(_ id: String) -> (Double, Double) {
            let e = s.entities[id]!
            return (params[e.params[0]], params[e.params[1]])
        }
        for e in s.orderedEntities {
            switch e.kind {
            case .point: out.append("point \(e.id) \(e.params[0]) \(e.params[1])")
            case .line: out.append("line \(e.id) \(e.points[0]) \(e.points[1])")
            case .circle: out.append("circle \(e.id) \(e.points[0]) \(e.params[0])")
            case .arc:
                let c = pt(e.points[0]), a = pt(e.points[1]), b = pt(e.points[2])
                var a1 = atan2(b.1 - c.1, b.0 - c.0)
                let a0 = atan2(a.1 - c.1, a.0 - c.0)
                while a1 <= a0 { a1 += 2 * .pi }
                // Radius and angles are planegcs unknowns tied to the points by its ArcRules.
                let r = next, t0 = next + 1, t1 = next + 2
                extra += [(r, hypot(a.0 - c.0, a.1 - c.1)), (t0, a0), (t1, a1)]
                next += 3
                out.append("arc \(e.id) \(e.points[0]) \(e.points[1]) \(e.points[2]) \(r) \(t0) \(t1)")
            case .ellipse, .ellipseArc, .spline:
                return nil
            }
        }
        for (i, c) in s.constraints.enumerated() where !c.isInternal && !c.driven {
            let tag = i + 1
            let k = c.entities.map { s.entities[$0]!.kind }
            let ids = c.entities.joined(separator: " ")
            let round: (SketchEntityKind) -> Bool = { $0 == .circle || $0 == .arc }
            switch c.kind {
            case .fix: continue
            case .coincident: out.append("c \(tag) coincident \(ids)")
            case .horizontal: out.append(k == [.line] ? "c \(tag) horizontal \(ids)" : "c \(tag) hpoints \(ids)")
            case .vertical: out.append(k == [.line] ? "c \(tag) vertical \(ids)" : "c \(tag) vpoints \(ids)")
            case .parallel: out.append("c \(tag) parallel \(ids)")
            case .perpendicular: out.append("c \(tag) perpendicular \(ids)")
            case .equal: out.append(k == [.line, .line] ? "c \(tag) equal \(ids)" : "c \(tag) equalradius \(ids)")
            case .concentric where k.allSatisfy(round): out.append("c \(tag) concentric \(ids)")
            case .onEntity where k[1] == .line: out.append("c \(tag) online \(ids)")
            case .onEntity where round(k[1]): out.append("c \(tag) oncircle \(ids)")
            case .tangent where k[0] == .line && round(k[1]) && c.at == nil: out.append("c \(tag) tangent \(ids)")
            case .radius: out.append("c \(tag) radius \(ids) \(value(c.value!))")
            case .diameter: out.append("c \(tag) diameter \(ids) \(value(c.value!))")
            case .angle: out.append("c \(tag) angle \(ids) \(value(c.value! * c.side))")
            case .distance where k == [.line]: out.append("c \(tag) length \(ids) \(value(c.value!))")
            case .distance where k == [.point, .point]: out.append("c \(tag) ppdistance \(ids) \(value(c.value!))")
            case .distance where k == [.point, .line]: out.append("c \(tag) pldistance \(ids) \(value(c.value!))")
            case .horizontalDistance, .verticalDistance:
                // Forge: (b − a)·side = value on x (horizontal) or y (vertical) of two points or a line's ends.
                let pts = k == [.line] ? s.entities[c.entities[0]]!.points : c.entities
                let axis = c.kind == .horizontalDistance ? 0 : 1
                let (pa, pb) = (s.entities[pts[0]]!.params[axis], s.entities[pts[1]]!.params[axis])
                out.append("c \(tag) difference \(pa) \(pb) \(value(c.value! * c.side))")
            case .symmetric where k == [.point, .point, .line]:
                // planegcs builds point symmetry from the direction between the two points, which
                // is undefined for a point on the axis (its own image): outside the oracle's range.
                let (a, b) = (pt(c.entities[0]), pt(c.entities[1]))
                if hypot(a.0 - b.0, a.1 - b.1) < 1e-9 * max(1, params.map(abs).max() ?? 1) { return nil }
                out.append("c \(tag) symmetric \(ids)")
            case .midpoint: out.append("c \(tag) midpoint \(ids)")
            case .collinear:
                // Both ends of the second line on the first.
                let l2 = s.entities[c.entities[1]]!
                out.append("c \(tag) online \(l2.points[0]) \(c.entities[0])")
                out.append("c \(tag) online \(l2.points[1]) \(c.entities[0])")
            case .coradial:
                out.append("c \(tag) concentric \(ids)")
                out.append("c \(tag) equalradius \(ids)")
            default: return nil
            }
        }
        var lines = params.enumerated().map { "p \($0.offset) \($0.element)" } + extra.map { "p \($0.0) \($0.1)" }
        lines += fixed.sorted().map { "fixed \($0)" }
        return (lines + out).joined(separator: "\n") + "\n"
    }

    static func run(_ input: String) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path!)
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        try p.run()
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        try inPipe.fileHandleForWriting.close()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var r = Result(status: -1, dof: -1, conflicting: [], redundant: [], params: [:])
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let w = line.split(separator: " ").map(String.init)
            switch w.first {
            case "status": r.status = Int(w[1])!
            case "dof": r.dof = Int(w[1])!
            case "conflicting": r.conflicting = w.dropFirst().compactMap { Int($0) }
            case "redundant": r.redundant = w.dropFirst().compactMap { Int($0) }
            case "param": r.params[Int(w[1])!] = Double(w[2])!
            case "error": throw ForgeError(.internalError, "oracle: \(line)")
            default: break
            }
        }
        return r
    }

    /// Compares DOF and the redundancy verdict, then (fully defined sketches) re-solves both
    /// from the same perturbed start and compares every point.
    static func compare(_ sketch: Sketch, label: String) throws {
        var s = sketch
        let ours = s.resolve()
        guard let input = export(s, params: s.params) else { print("ORACLE-SKIP", label); return }  // outside the mapped subset
        let theirs = try run(input)
        if let dir = ProcessInfo.processInfo.environment["FORGE_ORACLE_DUMP"],
            theirs.dof != ours.dof || theirs.redundant.isEmpty != ours.redundant.isEmpty || theirs.conflicting.isEmpty != ours.conflicting.isEmpty
        {
            let file = URL(fileURLWithPath: dir).appendingPathComponent(label.replacingOccurrences(of: "/", with: "_") + ".txt")
            try? input.write(to: file, atomically: true, encoding: .utf8)
        }
        #expect(theirs.dof == ours.dof, "\(label): DOF forge \(ours.dof) planegcs \(theirs.dof)")
        #expect(theirs.conflicting.isEmpty == ours.conflicting.isEmpty, "\(label): conflicting forge \(ours.conflicting) planegcs \(theirs.conflicting)")
        #expect(theirs.redundant.isEmpty == ours.redundant.isEmpty, "\(label): redundant forge \(ours.redundant) planegcs \(theirs.redundant)")
        guard ours.dof == 0, ours.redundant.isEmpty, ours.conflicting.isEmpty else { print("ORACLE-DIAG", label, ours.dof); return }

        // Perturb every free coordinate a little and let both solvers recover the unique solution.
        var rng = SplitMix(seed: UInt64(truncatingIfNeeded: label.hashValue))
        var start = s.params
        let originParams = Set(s.entities[Sketch.originID]!.params)
        // Small against the smallest feature, so both solvers stay on the same branch. A sketch
        // whose smallest feature is < 1e-3 of its size is ill-conditioned (distinct positions
        // satisfy every constraint to within tolerance), so positions are not compared.
        let smallest = s.curveSizes().values.min() ?? 1
        let scale = max(1, s.params.map(abs).max() ?? 1)
        guard smallest >= 1e-3 * scale else { print("ORACLE-ILLCOND", label); return }
        let amount = min(0.05, 0.01 * smallest)
        for i in start.indices where !originParams.contains(i) { start[i] += Double.random(in: -amount...amount, using: &rng) }
        var mine = s
        mine.params = start
        let myRep = mine.resolve()
        #expect(myRep.status == .fullyDefined, "\(label): forge re-solve from the perturbed start: \(myRep.status)")
        guard let perturbed = export(s, params: start) else { return }
        let r = try run(perturbed)
        #expect(r.status == 0 || r.status == 1, "\(label): planegcs status \(r.status)")
        let tol = 1e-6 * max(1, s.params.map(abs).max() ?? 1)
        // Diagnostics for a disagreement: does planegcs's answer satisfy Forge's constraints?
        var other = s
        for i in other.params.indices { other.params[i] = r.params[i] ?? other.params[i] }
        let theirWorst = other.constraints.filter { other.rowCount($0) > 0 }
            .flatMap { c in other.residuals(c) { other.params[$0] }.map { (c.id, abs($0)) } }.max { $0.1 < $1.1 }
        let mineWorst = mine.constraints.filter { mine.rowCount($0) > 0 }
            .flatMap { c in mine.residuals(c) { mine.params[$0] }.map { (c.id, abs($0)) } }.max { $0.1 < $1.1 }
        #expect((mineWorst?.1 ?? 0) <= tol, "\(label): forge re-solve leaves residual \(mineWorst?.1 ?? 0) on \(mineWorst?.0 ?? "")")
        // planegcs's line–circle tangency has no side, so from the same start it may converge to
        // the mirror branch (circle across the line). That answer does not satisfy Forge's
        // sided constraint and is a different solution, not a disagreement about this one.
        if let w = theirWorst, w.1 > tol {
            let c = s.constraints.first { $0.id == w.0 }!
            #expect(c.kind == .tangent, "\(label): planegcs's answer violates \(c.kind.rawValue) \(c.entities) by \(w.1)")
            print("ORACLE-BRANCH", label, c.id)
            return
        }
        print("ORACLE-POS", label)
        for e in s.orderedEntities where e.kind == .point {
            let (x, y) = (mine.params[e.params[0]], mine.params[e.params[1]])
            let (u, v) = (r.params[e.params[0]] ?? .nan, r.params[e.params[1]] ?? .nan)
            #expect(abs(x - u) < tol && abs(y - v) < tol, "\(label): \(e.id) forge (\(x), \(y)) planegcs (\(u), \(v))")
        }
    }

    /// A random sketch of the mapped subset: a closed polygon, a circle and an arc with a
    /// random mix of relations and dimensions (each kept only if Forge accepts it).
    static func randomSketch(_ rng: inout SplitMix) throws -> Sketch {
        var s = Sketch(id: "sketch-1", name: "Random", plane: .front)
        let n = Int.random(in: 3...6, using: &rng)
        let r0 = Double.random(in: 20...40, using: &rng)
        let pts: [(Double, Double)] = (0..<n).map { i in
            let t = 2 * Double.pi * Double(i) / Double(n) + Double.random(in: -0.2...0.2, using: &rng)
            let r = r0 * Double.random(in: 0.7...1.3, using: &rng)
            return (r * cos(t) + 50, r * sin(t) + 40)
        }
        var lines: [String] = []
        for i in 0..<n { lines.append(s.addLine(from: pts[i], to: pts[(i + 1) % n])) }
        for i in 0..<n {
            let a = s.entities[lines[i]]!.points[1], b = s.entities[lines[(i + 1) % n]]!.points[0]
            try s.addConstraint(.coincident, [a, b])
        }
        let circle = s.addCircle(center: (Double.random(in: -20...0, using: &rng), Double.random(in: -20...0, using: &rng)), radius: Double.random(in: 3...8, using: &rng))
        let arc = s.addArc(center: (120, 10), start: (130, 10), end: (120, 20))
        func attempt(_ k: ConstraintKind, _ ids: [String], _ v: Double? = nil) {
            _ = try? s.addConstraint(k, ids, value: v)
        }
        let first = s.entities[lines[0]]!.points[0]
        attempt(.coincident, [first, Sketch.originID])
        for _ in 0..<(2 * n + 4) {
            let l = lines.randomElement(using: &rng)!, m = lines.randomElement(using: &rng)!
            switch Int.random(in: 0..<9, using: &rng) {
            case 0: attempt(.horizontal, [l])
            case 1: attempt(.vertical, [l])
            case 2: attempt(.parallel, [l, m])
            case 3: attempt(.perpendicular, [l, m])
            case 4: attempt(.equal, [l, m])
            case 5: attempt(.distance, [l])
            case 6: attempt(.angle, [l, m])
            case 7: attempt(.radius, [[circle, arc].randomElement(using: &rng)!])
            default: attempt(.tangent, [l, circle])
            }
        }
        // Then dimension until fully defined (or out of attempts), so positions get compared.
        let points = s.orderedEntities.filter { $0.kind == .point && $0.id != Sketch.originID && !$0.construction }.map(\.id)
        for _ in 0..<60 where s.resolve().dof > 0 {
            let l = lines.randomElement(using: &rng)!, m = lines.randomElement(using: &rng)!
            let p = points.randomElement(using: &rng)!
            let centres = [s.entities[circle]!.points[0], s.entities[arc]!.points[0], s.entities[arc]!.points[1]]
            let q = [p, centres.randomElement(using: &rng)!].randomElement(using: &rng)!
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: attempt(.distance, [l])
            case 1: attempt(.angle, [l, m])
            case 2: attempt(.horizontalDistance, [Sketch.originID, q])
            case 3: attempt(.verticalDistance, [Sketch.originID, q])
            case 4: attempt(.radius, [[circle, arc].randomElement(using: &rng)!])
            default: attempt(.distance, [p, centres.randomElement(using: &rng)!])
            }
        }
        return s
    }
}

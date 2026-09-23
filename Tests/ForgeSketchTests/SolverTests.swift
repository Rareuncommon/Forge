import ForgeCore
import Foundation
import Testing

@testable import ForgeSketch

func near(_ a: Double, _ b: Double, _ tol: Double = 1e-7) -> Bool { abs(a - b) <= tol }
func near(_ a: (Double, Double), _ b: (Double, Double), _ tol: Double = 1e-7) -> Bool { near(a.0, b.0, tol) && near(a.1, b.1, tol) }

func newSketch() -> Sketch { Sketch(id: "sketch-1", name: "Sketch1", plane: .front) }

func ends(_ s: Sketch, _ line: String) -> (String, String) {
    let e = s.entities[line]!
    return (e.points[0], e.points[1])
}

@Suite("Sketch solver: degrees of freedom")
struct DOFTests {
    @Test func entityDegreesOfFreedom() {
        var s = newSketch()
        #expect(s.resolve().dof == 0)  // only the fixed origin
        s.addPoint(1, 2)
        #expect(s.resolve().dof == 2)
        s.addLine(from: (0, 5), to: (3, 7))
        #expect(s.resolve().dof == 6)
        s.addCircle(center: (10, 0), radius: 2)
        #expect(s.resolve().dof == 9)
        s.addArc(center: (20, 0), start: (22, 0), end: (20, 2))
        #expect(s.resolve().dof == 14)
        s.addEllipse(center: (30, 0), major: 4, minor: 2, rotation: 0.3)
        let r = s.resolve()
        #expect(r.dof == 19)
        #expect(r.status == .underDefined)
    }

    @Test func rectangleModesHaveExpectedFreedom() throws {
        var s = newSketch()
        _ = try s.addRectangle(.corner, [(0, 0), (40, 20)])
        #expect(s.resolve().dof == 4)  // x, y, width, height
        var c = newSketch()
        _ = try c.addRectangle(.center, [(0, 0), (40, 20)])
        #expect(c.resolve().dof == 4)
        var t = newSketch()
        _ = try t.addRectangle(.threePoint, [(0, 0), (30, 10), (25, 30)])
        #expect(t.resolve().dof == 5)  // + rotation
        var p = newSketch()
        _ = try p.addRectangle(.parallelogram, [(0, 0), (30, 0), (40, 20)])
        #expect(p.resolve().dof == 6)  // + shear
    }

    @Test func slotAndPolygonFreedom() throws {
        var s = newSketch()
        _ = try s.addSlot(.straight, (0, 0), (30, 0), width: 10)
        #expect(s.resolve().dof == 5)  // two centres + width
        #expect(s.report?.status == .underDefined)
        var p = newSketch()
        _ = try p.addPolygon(center: (0, 0), sides: 6, radius: 10, rotation: 0, inscribed: true)
        #expect(p.resolve().dof == 4)  // centre, size, rotation
        var q = newSketch()
        _ = try q.addPolygon(center: (0, 0), sides: 5, radius: 10, rotation: 0, inscribed: false)
        #expect(q.resolve().dof == 4)
    }
}

@Suite("Sketch solver: solving")
struct SolveTests {
    @Test func fullyDefinedRectangleFollowsDimensions() throws {
        var s = newSketch()
        let lines = try s.addRectangle(.corner, [(1, 1), (41, 21)])
        let (a, _) = ends(s, lines[0])
        try s.addConstraint(.coincident, [Sketch.originID, a])
        let w = try s.addConstraint(.distance, [lines[0]], value: 40)
        try s.addConstraint(.distance, [lines[1]], value: 20)
        let r = s.resolve()
        #expect(r.dof == 0)
        #expect(r.status == .fullyDefined)
        #expect(r.entityStates.values.allSatisfy { $0 == .fullyDefined })
        let (_, b) = ends(s, lines[1])
        #expect(near(s.point(b), (40, 20)))
        try s.setDimension(w, value: 65, driven: nil)
        #expect(near(s.point(b), (65, 20)))
        #expect(near(s.point(a), (0, 0)))
    }

    @Test func threeFourFiveTriangleHasARightAngle() throws {
        var s = newSketch()
        let l1 = s.addLine(from: (0, 0), to: (3.2, 0.1))
        let l2 = s.addLine(from: (3.2, 0.1), to: (2.9, 4.2))
        let l3 = s.addLine(from: (2.9, 4.2), to: (0, 0))
        try s.closeChain([l1, l2, l3])
        try s.addConstraint(.coincident, [Sketch.originID, ends(s, l1).0])
        try s.addConstraint(.horizontal, [l1])
        try s.addConstraint(.distance, [l1], value: 3)
        try s.addConstraint(.distance, [l2], value: 4)
        try s.addConstraint(.distance, [l3], value: 5)
        let angle = try s.addConstraint(.angle, [l1, l2], driven: true)
        #expect(s.report?.status == .fullyDefined)
        #expect(near(abs(try s.constraint(angle).value!), .pi / 2, 1e-9))
        #expect(near(s.point(ends(s, l2).1), (3, 4)))
    }

    @Test func tangentLineAndCircle() throws {
        var s = newSketch()
        let c = s.addCircle(center: (0, 0), radius: 4)
        let l = s.addLine(from: (-10, 5), to: (10, 5.5))
        try s.addConstraint(.coincident, [Sketch.originID, s.entities[c]!.points[0]])
        try s.addConstraint(.radius, [c], value: 5)
        try s.addConstraint(.horizontal, [l])
        try s.addConstraint(.tangent, [l, c])
        let (a, _) = ends(s, l)
        #expect(near(s.point(a).1, 5))
    }

    @Test func externalAndInternalCircleTangency() throws {
        var s = newSketch()
        let c1 = s.addCircle(center: (0, 0), radius: 10)
        let c2 = s.addCircle(center: (14, 0), radius: 3)  // close to external (13)
        let c3 = s.addCircle(center: (6, 0), radius: 3)  // close to internal (7)
        try s.addConstraint(.fix, [c1])
        try s.addConstraint(.tangent, [c1, c2])
        try s.addConstraint(.tangent, [c1, c3])
        func dist(_ c: String) -> Double {
            let (x, y) = s.point(s.entities[c]!.points[0])
            return (x * x + y * y).squareRoot()
        }
        #expect(near(dist(c2), 10 + s.params[s.entities[c2]!.params[0]]))
        #expect(near(dist(c3), 10 - s.params[s.entities[c3]!.params[0]]))
    }

    @Test func symmetricMidpointConcentricEqualParallelPerpendicular() throws {
        var s = newSketch()
        let axis = s.addLine(from: (0, -10), to: (0, 10), construction: true)
        try s.addConstraint(.vertical, [axis])
        try s.addConstraint(.onEntity, [Sketch.originID, axis])
        let p = s.addPoint(-3, 2), q = s.addPoint(4, 5)
        try s.addConstraint(.symmetric, [p, q, axis])
        #expect(near(s.point(p).0, -s.point(q).0, 1e-7) && near(s.point(p).1, s.point(q).1))

        let l1 = s.addLine(from: (10, 0), to: (20, 1)), l2 = s.addLine(from: (10, 5), to: (18, 9))
        try s.addConstraint(.parallel, [l1, l2])
        try s.addConstraint(.equal, [l1, l2])
        let l3 = s.addLine(from: (30, 0), to: (31, 8))
        try s.addConstraint(.perpendicular, [l1, l3])
        func dir(_ l: String) -> (Double, Double) {
            let (a, b) = ends(s, l)
            let (ax, ay) = s.point(a), (bx, by) = s.point(b)
            return (bx - ax, by - ay)
        }
        let d1 = dir(l1), d2 = dir(l2), d3 = dir(l3)
        #expect(near(d1.0 * d2.1 - d1.1 * d2.0, 0))
        #expect(near(d1.0 * d3.0 + d1.1 * d3.1, 0))
        #expect(near(hypot(d1.0, d1.1), hypot(d2.0, d2.1)))

        let m = s.addPoint(0, 0)
        try s.addConstraint(.midpoint, [m, l3])
        let (a3, b3) = ends(s, l3)
        #expect(near(s.point(m), ((s.point(a3).0 + s.point(b3).0) / 2, (s.point(a3).1 + s.point(b3).1) / 2)))

        let c1 = s.addCircle(center: (50, 0), radius: 2), c2 = s.addArc(center: (51, 1), start: (54, 1), end: (51, 4))
        try s.addConstraint(.concentric, [c1, c2])
        #expect(near(s.point(s.entities[c1]!.points[0]), s.point(s.entities[c2]!.points[0])))
    }

    @Test func arcKeepsEndpointsOnItsCircle() throws {
        var s = newSketch()
        let a = s.addArc(center: (0, 0), start: (5, 0), end: (0, 5))
        try s.addConstraint(.radius, [a], value: 8)
        let e = s.entities[a]!
        for p in e.points.dropFirst() {
            let (x, y) = s.point(p)
            let (cx, cy) = s.point(e.points[0])
            #expect(near(hypot(x - cx, y - cy), 8))
        }
    }

    @Test func solvingIsDeterministic() throws {
        func build() throws -> [Double] {
            var s = newSketch()
            let slot = try s.addSlot(.straight, (0, 0), (30, 3), width: 10)
            _ = try s.addPolygon(center: (50, 0), sides: 7, radius: 9, rotation: 0.2, inscribed: false)
            try s.addConstraint(.distance, [slot[0]], value: 33)
            return s.params
        }
        #expect(try build() == (try build()))
    }
}

@Suite("Sketch solver: diagnosis")
struct DiagnosisTests {
    @Test func redundantRelationIsRejected() throws {
        var s = newSketch()
        let l = s.addLine(from: (0, 0), to: (10, 0))
        try s.addConstraint(.horizontal, [l])
        let (a, b) = ends(s, l)
        do {
            try s.addConstraint(.horizontal, [a, b])
            Issue.record("expected redundancy error")
        } catch let e as ForgeError {
            #expect(e.code == .sketchRedundant)
        }
        #expect(s.userConstraints.count == 1)
    }

    @Test func conflictingDimensionIsRejectedWithDrivenSuggestion() throws {
        var s = newSketch()
        let l = s.addLine(from: (0, 0), to: (10, 0))
        try s.addConstraint(.distance, [l], value: 10)
        let (a, b) = ends(s, l)
        do {
            try s.addConstraint(.distance, [a, b], value: 20)
            Issue.record("expected conflict")
        } catch let e as ForgeError {
            #expect(e.code == .sketchConflict)
            #expect(e.suggestions.contains { $0.command == "sketch.add_dimension" && $0.params["driven"] == true })
        }
        // As a driven dimension it is accepted and reports the measured value.
        let d = try s.addConstraint(.distance, [a, b], driven: true)
        #expect(near(try s.constraint(d).value!, 10))
        // Redundant (same value) driving dimension is also refused.
        #expect(throws: ForgeError.self) { try s.addConstraint(.distance, [a, b], value: 10) }
    }

    @Test func impossibleTriangleFails() throws {
        var s = newSketch()
        let l1 = s.addLine(from: (0, 0), to: (1, 0))
        let l2 = s.addLine(from: (1, 0), to: (0.5, 0.8))
        let l3 = s.addLine(from: (0.5, 0.8), to: (0, 0))
        try s.closeChain([l1, l2, l3])
        try s.addConstraint(.distance, [l1], value: 1)
        try s.addConstraint(.distance, [l2], value: 1)
        do {
            try s.addConstraint(.distance, [l3], value: 5)
            Issue.record("expected failure")
        } catch let e as ForgeError {
            #expect(e.code == .solverFailed || e.code == .sketchConflict)
        }
        #expect(s.userConstraints.count == 5)  // 3 coincident + 2 lengths, unchanged
    }

    @Test func fixAndOriginRelations() throws {
        var s = newSketch()
        let p = s.addPoint(3, 4)
        try s.addConstraint(.fix, [p])
        #expect(s.report?.dof == 0)
        #expect(throws: ForgeError.self) { try s.addConstraint(.distance, [Sketch.originID, p], value: 7) }
        #expect(throws: ForgeError.self) { try s.addConstraint(.fix, [Sketch.originID]) }
    }

    @Test func invalidEntityCombinations() {
        var s = newSketch()
        let l = s.addLine(from: (0, 0), to: (1, 0)), c = s.addCircle(center: (0, 0), radius: 1)
        #expect(throws: ForgeError.self) { try s.addConstraint(.parallel, [l, c]) }
        #expect(throws: ForgeError.self) { try s.addConstraint(.coincident, [l, c]) }
        #expect(throws: ForgeError.self) { try s.addConstraint(.radius, [l], value: 1) }
        #expect(throws: ForgeError.self) { try s.addConstraint(.radius, [c], value: -1) }
        #expect(throws: ForgeError.self) { try s.addConstraint(.horizontal, [l], value: 3) }
    }
}

@Suite("Sketch dragging")
struct DragTests {
    @Test func freePointMovesExactly() throws {
        var s = newSketch()
        let p = s.addPoint(1, 1)
        try s.drag(p, to: (5, -2))
        #expect(near(s.point(p), (5, -2)))
    }

    @Test func constrainedPointStaysOnItsCurve() throws {
        var s = newSketch()
        let c = s.addCircle(center: (0, 0), radius: 5)
        try s.addConstraint(.fix, [c])
        let p = s.addPoint(5, 0)
        try s.addConstraint(.onEntity, [p, c])
        try s.drag(p, to: (0, 20))
        let (x, y) = s.point(p)
        #expect(near(hypot(x, y), 5))
        #expect(y > 4.9)  // moved toward the target
    }

    @Test func draggingAnEndpointStretchesAHorizontalLine() throws {
        var s = newSketch()
        let l = s.addLine(from: (0, 0), to: (10, 0))
        try s.addConstraint(.horizontal, [l])
        let (a, b) = ends(s, l)
        try s.addConstraint(.coincident, [Sketch.originID, a])
        try s.drag(b, to: (20, 3))
        #expect(near(s.point(b).1, 0))
        #expect(s.point(b).0 > 15)
    }
}

@Suite("Sketch profiles")
struct ProfileTests {
    @Test func rectangleWithHole() throws {
        var s = newSketch()
        _ = try s.addRectangle(.corner, [(0, 0), (40, 20)])
        s.addCircle(center: (20, 10), radius: 5)
        let r = s.profiles()
        #expect(r.valid)
        #expect(r.loops.count == 2)
        #expect(r.loops.filter { $0.depth == 1 }.count == 1)
        #expect(near(r.regionAreaMM2, 800 - .pi * 25, 1e-9))
    }

    @Test func slotAreaIsExact() throws {
        var s = newSketch()
        _ = try s.addSlot(.straight, (0, 0), (30, 0), width: 10)
        let r = s.profiles()
        #expect(r.valid)
        #expect(r.loops.count == 1)
        #expect(near(r.regionAreaMM2, 30 * 10 + .pi * 25, 1e-9))  // construction axis excluded
    }

    @Test func hexagonArea() throws {
        var s = newSketch()
        _ = try s.addPolygon(center: (0, 0), sides: 6, radius: 10, rotation: 0, inscribed: true)
        let r = s.profiles()
        #expect(near(r.regionAreaMM2, 3 * 3.0.squareRoot() / 2 * 100, 1e-9))
    }

    @Test func openAndCrossingContoursAreReported() throws {
        var s = newSketch()
        s.addLine(from: (0, 0), to: (10, 0))
        s.addLine(from: (10, 0), to: (10, 10))
        var r = s.profiles()
        #expect(!r.valid)
        #expect(r.openEnds.count == 2)
        s.addLine(from: (0, 5), to: (20, 5))
        r = s.profiles()
        #expect(!r.intersections.isEmpty)
    }
}

/// Property-based tests (SPEC §9): random sketches built from a known configuration, with
/// constraints measured from it; after perturbation the solver must restore a configuration
/// satisfying every constraint.
@Suite("Sketch solver properties")
struct SolverPropertyTests {
    struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    @Test(arguments: 0..<40)
    func perturbedSketchResolves(seed: Int) throws {
        var rng = LCG(state: UInt64(seed) &* 7919 &+ 17)
        func rnd(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo..<hi, using: &rng) }
        var s = newSketch()
        // Random closed polygon (star-shaped so it does not self-intersect) + a circle.
        let n = Int.random(in: 3...7, using: &rng)
        let pts = (0..<n).map { i -> (Double, Double) in
            let t = 2 * Double.pi * (Double(i) + rnd(0.1, 0.9)) / Double(n)
            let r = rnd(10, 40)
            return (r * cos(t), r * sin(t))
        }
        let lines = (0..<n).map { s.addLine(from: pts[$0], to: pts[($0 + 1) % n]) }
        try s.closeChain(lines)
        let circle = s.addCircle(center: (rnd(-5, 5), rnd(-5, 5)), radius: rnd(1, 4))
        // Dimensions measured from the configuration (always consistent).
        var dims: [String] = []
        for l in lines where Bool.random(using: &rng) {
            if let d = try? s.addConstraint(.distance, [l]) { dims.append(d) }
        }
        if let d = try? s.addConstraint(.radius, [circle]) { dims.append(d) }
        if let d = try? s.addConstraint(.distance, [Sketch.originID, s.entities[circle]!.points[0]]) { dims.append(d) }
        if n >= 4, let d = try? s.addConstraint(.angle, [lines[0], lines[1]]) { dims.append(d) }
        let targets = try dims.map { try s.constraint($0).value! }

        // Perturb every parameter and re-solve.
        for i in s.params.indices where i > 1 { s.params[i] += rnd(-0.5, 0.5) }
        let r = s.resolve()
        #expect(r.status != .failed && r.status != .conflicting, "seed \(seed): \(r.status)")
        #expect(r.maxResidual < 1e-8, "seed \(seed): residual \(r.maxResidual)")
        for (d, t) in zip(dims, targets) {
            let c = try s.constraint(d)
            let measured = s.measure(c) { s.params[$0] }
            #expect(near(measured, t, 1e-8), "seed \(seed): \(c.kind) \(measured) vs \(t)")
        }
    }
}

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

@Suite("Sketch fillet")
struct FilletTests {
    @Test func filletKeepsDimensionsAndAreaIsExact() throws {
        var s = newSketch()
        let lines = try s.addRectangle(.corner, [(0, 0), (40, 20)])
        try s.addConstraint(.coincident, [Sketch.originID, s.entities[lines[0]]!.points[0]])
        try s.addConstraint(.distance, [lines[0]], value: 40)
        try s.addConstraint(.distance, [lines[1]], value: 20)
        #expect(s.report?.dof == 0)
        // Fillet the corner at (40, 0) between the bottom and right edges.
        let created = try s.filletCorner(lines[0], lines[1], radius: 5)
        let r = s.resolve()
        #expect(r.status == .fullyDefined)
        #expect(r.dof == 0)
        // The virtual sharp stays at the original corner; the dimensions keep their meaning.
        #expect(near(s.point(created[1]), (40, 0)))
        #expect(near(s.point(s.entities[lines[1]]!.points[1]), (40, 20)))
        let p = s.profiles()
        #expect(p.valid)
        #expect(near(p.regionAreaMM2, 800 - (25 - .pi * 25 / 4), 1e-9))
        #expect(throws: ForgeError.self) { try s.filletCorner(lines[2], lines[3], radius: 50) }  // too large
    }

    @Test func filletAtAnAcuteCorner() throws {
        var s = newSketch()
        let a = s.addLine(from: (0, 0), to: (20, 0))
        let b = s.addLine(from: (0, 0), to: (10, 10))
        try s.addConstraint(.coincident, [s.entities[a]!.points[0], s.entities[b]!.points[0]])
        let arc = try s.filletCorner(a, b, radius: 2)[0]
        // 45° corner: tangent distance = r / tan(22.5°).
        let t = 2 / tan(Double.pi / 8)
        #expect(near(s.point(s.entities[a]!.points[0]), (t, 0), 1e-7))
        let e = s.entities[arc]!
        let (cx, cy) = s.point(e.points[0])
        #expect(near(cy, 2) && near(cx, t))
    }
}

@Suite("Sketch chamfer")
struct ChamferTests {
    func dimensionedRectangle() throws -> (Sketch, [String]) {
        var s = newSketch()
        let lines = try s.addRectangle(.corner, [(0, 0), (40, 20)])
        try s.addConstraint(.coincident, [Sketch.originID, s.entities[lines[0]]!.points[0]])
        try s.addConstraint(.distance, [lines[0]], value: 40)
        try s.addConstraint(.distance, [lines[1]], value: 20)
        return (s, lines)
    }

    @Test func distanceDistance() throws {
        var (s, lines) = try dimensionedRectangle()
        _ = try s.chamferCorner(lines[0], lines[1], distance: 5, distance2: 3)
        #expect(s.resolve().status == .fullyDefined)
        #expect(near(s.profiles().regionAreaMM2, 800 - 7.5, 1e-9))
        #expect(near(s.point(s.entities[lines[0]]!.points[1]), (35, 0)))
    }

    @Test func distanceAngle() throws {
        var (s, lines) = try dimensionedRectangle()
        _ = try s.chamferCorner(lines[0], lines[1], distance: 4, angle: .pi / 4)
        #expect(s.resolve().status == .fullyDefined)
        #expect(near(s.profiles().regionAreaMM2, 800 - 8, 1e-9))  // 45°: isosceles 4 x 4
        #expect(throws: ForgeError.self) { try s.chamferCorner(lines[2], lines[3], distance: 30) }
    }
}

@Suite("Sketch mirror and patterns")
struct MirrorPatternTests {
    /// A fixed vertical construction axis x = 0 through the origin.
    func withAxis() throws -> (Sketch, String) {
        var s = newSketch()
        let axis = s.addLine(from: (0, 0), to: (0, 30), construction: true)
        let (a, _) = ends(s, axis)
        try s.addConstraint(.coincident, [a, Sketch.originID])
        try s.addConstraint(.vertical, [axis])
        try s.addConstraint(.distance, [axis], value: 30)
        return (s, axis)
    }

    @Test func mirrorAddsNoFreedomAndCopiesFollow() throws {
        var (s, axis) = try withAxis()
        let line = s.addLine(from: (5, 0), to: (15, 10))
        let arc = s.addArc(center: (20, 0), start: (22, 0), end: (20, 2))
        let circle = s.addCircle(center: (10, 20), radius: 3)
        let dof = s.resolve().dof
        #expect(dof == 12)
        let (created, _) = try s.mirror([line, arc, circle], about: axis)
        #expect(created.count == 3)
        let r = s.resolve()
        #expect(r.dof == dof)
        #expect(r.redundant.isEmpty && r.conflicting.isEmpty)
        // Reflection across x = 0; the arc's sense reverses (start = image of the end).
        let (l0, l1) = ends(s, created[0])
        #expect(near(s.point(l0), (-5, 0)) && near(s.point(l1), (-15, 10)))
        let a = s.entities[created[1]]!
        #expect(near(s.point(a.points[0]), (-20, 0)) && near(s.point(a.points[1]), (-20, 2)) && near(s.point(a.points[2]), (-22, 0)))
        // Editing the original drives the copy.
        let rad = try s.addConstraint(.radius, [circle], value: 3)
        try s.setDimension(rad, value: 5, driven: nil)
        let c = s.entities[created[2]]!
        #expect(near(s.params[c.params[0]], 5))
        #expect(near(s.point(c.points[0]), (-10, 20)))
        try s.drag(arc, to: (25, 1))
        let ao = s.entities[arc]!
        let (cx, cy) = s.point(ao.points[0])
        #expect(near(s.point(a.points[0]), (-cx, cy), 1e-6))
    }

    @Test func mirroringAFilletedChainKeepsItConnectedWithoutRedundancy() throws {
        var s = newSketch()
        let axis = s.addLine(from: (-5, -10), to: (-5, 30), construction: true)
        try s.addConstraint(.vertical, [axis])
        let a = s.addLine(from: (0, 0), to: (20, 0))
        let b = s.addLine(from: (20, 0), to: (20, 15))
        try s.addConstraint(.coincident, [ends(s, a).1, ends(s, b).0])
        let arc = try s.filletCorner(a, b, radius: 4)[0]
        let before = s.resolve()
        let (created, added) = try s.mirror([a, b, arc], about: axis)
        let r = s.resolve()
        #expect(r.dof == before.dof)
        #expect(r.redundant.isEmpty && r.conflicting.isEmpty)
        #expect(created.count == 3 && !added.isEmpty)
        // The mirrored arc's ends sit on the mirrored lines' trimmed ends.
        let ma = s.entities[created[2]]!, la = s.entities[created[0]]!, lb = s.entities[created[1]]!
        let arcEnds = [s.point(ma.points[1]), s.point(ma.points[2])]
        #expect(arcEnds.contains { near($0, s.point(la.points[1]), 1e-6) })
        #expect(arcEnds.contains { near($0, s.point(lb.points[0]), 1e-6) })
        // Image of (20 - 4, 0) across x = -5 is (-26, 0).
        #expect(near(s.point(la.points[1]), (-26, 0), 1e-6))
        // Two open chains (original and copy).
        #expect(s.profiles().openEnds.count == 4)
    }

    @Test func mirrorRejectsTheAxisAndNonLines() throws {
        var (s, axis) = try withAxis()
        let circle = s.addCircle(center: (10, 20), radius: 3)
        #expect(throws: ForgeError.self) { try s.mirror([axis], about: axis) }
        #expect(throws: ForgeError.self) { try s.mirror([axis], about: circle) }
    }

    @Test func symmetricLinesAndCirclesAsWholes() throws {
        var (s, axis) = try withAxis()
        let l1 = s.addLine(from: (3, 1), to: (8, 6))
        let l2 = s.addLine(from: (-7.5, 6.2), to: (-3.1, 0.8))  // reversed and slightly off
        let c1 = s.addCircle(center: (10, 20), radius: 3)
        let c2 = s.addCircle(center: (-9, 21), radius: 2.5)
        let dof = s.resolve().dof
        try s.addConstraint(.symmetric, [l1, l2, axis])
        try s.addConstraint(.symmetric, [c1, c2, axis])
        let r = s.resolve()
        #expect(r.dof == dof - 4 - 3)
        #expect(r.redundant.isEmpty)
        let (a2, b2) = ends(s, l2), (a1, b1) = ends(s, l1)
        #expect(near(s.point(b2), (-s.point(a1).0, s.point(a1).1), 1e-7))
        #expect(near(s.point(a2), (-s.point(b1).0, s.point(b1).1), 1e-7))
        let e1 = s.entities[c1]!, e2 = s.entities[c2]!
        #expect(near(s.params[e1.params[0]], s.params[e2.params[0]]))
        #expect(throws: ForgeError.self) { try s.addConstraint(.symmetric, [l1, c1, axis]) }
    }

    @Test func linearPatternOfACircle() throws {
        var s = newSketch()
        let c = s.addCircle(center: (0, 0), radius: 2)
        let (created, _) = try s.linearPattern([c], direction: 0, spacing: 10, count: 3)
        #expect(created.count == 2)
        let centres = created.map { s.point(s.entities[$0[0]]!.points[0]) }
        #expect(near(centres[0], (10, 0)) && near(centres[1], (20, 0)))
        #expect(s.resolve().dof == 3 + 2 + 2)  // copies keep the seed radius
        #expect(s.resolve().redundant.isEmpty)
    }

    @Test func twoDirectionLinearPatternOfARectangle() throws {
        var s = newSketch()
        let rect = try s.addRectangle(.corner, [(0, 0), (4, 2)])
        let (created, _) = try s.linearPattern(rect, direction: 0, spacing: 10, count: 2, direction2: .pi / 2, spacing2: 5, count2: 2)
        #expect(created.count == 3)
        let r = s.resolve()
        // Seed: x, y, w, h. Each copy: sides parallel/equal to the seed → only its position.
        #expect(r.dof == 4 + 3 * 2)
        #expect(r.redundant.isEmpty && r.conflicting.isEmpty)
        let report = s.profiles()
        #expect(report.loops.count == 4)
        #expect(report.loops.allSatisfy { near(abs($0.signedAreaMM2), 8, 1e-9) })
    }

    @Test func circularPatternFullCircle() throws {
        var s = newSketch()
        let c = s.addCircle(center: (10, 0), radius: 2)
        let (created, _) = try s.circularPattern([c], center: (0, 0), angle: 2 * .pi, count: 4)
        let centres = created.map { s.point(s.entities[$0[0]]!.points[0]) }
        #expect(near(centres[0], (0, 10)) && near(centres[1], (-10, 0)) && near(centres[2], (0, -10)))
        #expect(s.resolve().dof == 3 + 3 * 2)
    }

    @Test func circularPatternPartialAngleIncludesBothEnds() throws {
        var s = newSketch()
        let l = s.addLine(from: (10, 0), to: (12, 0))
        let (created, _) = try s.circularPattern([l], center: (0, 0), angle: .pi / 2, count: 3)
        let (a, b) = ends(s, created[1][0])
        #expect(near(s.point(a), (0, 10)) && near(s.point(b), (0, 12)))
        let (m, _) = ends(s, created[0][0])
        #expect(near(s.point(m), (10 * cos(.pi / 4), 10 * sin(.pi / 4))))
    }
}

@Suite("Sketch trim and extend")
struct TrimExtendTests {
    @Test func trimAnEndBackToACrossingLine() throws {
        var s = newSketch()
        let h = s.addLine(from: (0, 0), to: (20, 0))
        let v = s.addLine(from: (10, -5), to: (10, 5))
        let len = try s.addConstraint(.distance, [h], value: 20)
        let dof = s.resolve().dof
        let r = try s.trim(h, at: (15, 0.1))
        #expect(r.removedConstraints == [len])
        #expect(r.constraints.count == 1)
        #expect(s.constraints.first { $0.id == r.constraints[0] }?.kind == .onEntity)
        let (a, b) = ends(s, h)
        #expect(near(s.point(a), (0, 0)) && near(s.point(b), (10, 0)))
        #expect(s.resolve().dof == dof + 1 - 1)  // length dimension gone, end held on the vertical
        _ = v
    }

    @Test func trimTheMiddleSplitsTheLine() throws {
        var s = newSketch()
        let h = s.addLine(from: (0, 0), to: (30, 0))
        s.addLine(from: (10, -5), to: (10, 5))
        s.addLine(from: (20, -5), to: (20, 5))
        try s.addConstraint(.horizontal, [h])
        let (_, oldEnd) = ends(s, h)
        try s.addConstraint(.fix, [oldEnd])
        let r = try s.trim(h, at: (15, 0))
        #expect(r.created.count == 1)
        let piece = r.created[0]
        let (a, b) = ends(s, h), (c, d) = ends(s, piece)
        #expect(near(s.point(a), (0, 0)) && near(s.point(b), (10, 0)))
        #expect(near(s.point(c), (20, 0)) && near(s.point(d), (30, 0)))
        // The fix on the old far end moved to the piece's end; the pieces are collinear.
        #expect(s.constraints.contains { $0.kind == .fix && $0.entities == [d] })
        #expect(s.constraints.contains { $0.kind == .collinear && Set($0.entities) == [h, piece] })
        let rep = s.resolve()
        #expect(rep.redundant.isEmpty && rep.conflicting.isEmpty)
    }

    @Test func trimmingACircleLeavesAnArcThatKeepsItsDimension() throws {
        var s = newSketch()
        let c = s.addCircle(center: (0, 0), radius: 10)
        s.addLine(from: (-20, 0), to: (20, 0))
        let dia = try s.addConstraint(.diameter, [c], value: 20)
        let r = try s.trim(c, at: (0, 10))
        #expect(r.deleted == [c] && r.created.count == 1)
        let arc = s.entities[r.created[0]]!
        #expect(arc.kind == .arc)
        // Lower half remains: counter-clockwise from (-10, 0) to (10, 0).
        #expect(near(s.point(arc.points[1]), (-10, 0)) && near(s.point(arc.points[2]), (10, 0)))
        #expect(s.constraints.first { $0.id == dia }?.entities == [arc.id])
        let rep = s.resolve()
        #expect(rep.redundant.isEmpty && rep.conflicting.isEmpty)
    }

    @Test func trimmingAnUncrossedCurveDeletesIt() throws {
        var s = newSketch()
        let l = s.addLine(from: (0, 0), to: (5, 5))
        let r = try s.trim(l, at: (2, 2))
        #expect(r.deleted == [l])
        #expect(s.entities[l] == nil)
    }

    @Test func trimTheMiddleOfAnArc() throws {
        var s = newSketch()
        let arc = s.addArc(center: (0, 0), start: (10, 0), end: (-10, 0))
        s.addLine(from: (0, 0), to: (0, 20))
        s.addLine(from: (5, 0), to: (5, 20))
        // Pick at 75°: between the crossings at 60° (x = 5) and 90° (x = 0).
        let r = try s.trim(arc, at: (10 * cos(75 * .pi / 180), 10 * sin(75 * .pi / 180)))
        let a = s.entities[arc]!, p = s.entities[r.created[0]]!
        #expect(near(s.point(a.points[2]), (5, 75.0.squareRoot())))
        #expect(near(s.point(p.points[1]), (0, 10)) && near(s.point(p.points[2]), (-10, 0)))
        let rep = s.resolve()
        #expect(rep.redundant.isEmpty && rep.conflicting.isEmpty)
    }

    @Test func extendLinesAndArcs() throws {
        var s = newSketch()
        let h = s.addLine(from: (0, 0), to: (5, 0))
        s.addLine(from: (10, -5), to: (10, 5))
        _ = try s.extend(h, near: (4, 0))
        #expect(near(s.point(ends(s, h).1), (10, 0)))
        #expect(throws: ForgeError.self) { try s.extend(h, near: (0.5, 0)) }

        var t = newSketch()
        let arc = t.addArc(center: (0, 0), start: (10, 0), end: (0, 10))
        t.addLine(from: (-6, 0), to: (-6, 20))
        _ = try t.extend(arc, near: (0, 10))
        #expect(near(t.point(t.entities[arc]!.points[2]), (-6, 8)))
    }

    @Test func ellipsesAreNotTrimmedYet() throws {
        var s = newSketch()
        let e = s.addEllipse(center: (0, 0), major: 5, minor: 3, rotation: 0)
        do {
            _ = try s.trim(e, at: (5, 0))
            Issue.record("expected not_implemented")
        } catch let err as ForgeError {
            #expect(err.code == .notImplemented)
        }
    }
}

@Suite("Sketch offset")
struct OffsetTests {
    func loopAreas(_ s: Sketch) -> [Double] { s.profiles().loops.map { abs($0.signedAreaMM2) }.sorted() }

    @Test func closedRectangleOffsetsOutwardAndFollowsItsDimension() throws {
        var s = newSketch()
        let rect = try s.addRectangle(.corner, [(0, 0), (40, 20)])
        let dof = s.resolve().dof
        let r = try s.offset(rect, distance: 5)
        let rep = s.resolve()
        #expect(rep.dof == dof)
        #expect(rep.redundant.isEmpty && rep.conflicting.isEmpty)
        #expect(r.sides.count == 1 && r.sides[0].count == 4)
        #expect(loopAreas(s).map { ($0 * 1e9).rounded() / 1e9 } == [800, 1500])
        // With the original fully defined, only the copy can move when the offset changes.
        try s.addConstraint(.distance, [rect[0]], value: 40)
        try s.addConstraint(.distance, [rect[1]], value: 20)
        try s.addConstraint(.fix, [ends(s, rect[0]).0])
        #expect(s.resolve().status == .fullyDefined)
        try s.setDimension(r.dimension!, value: 2, driven: nil)
        #expect(loopAreas(s).map { ($0 * 1e9).rounded() / 1e9 } == [800, 44 * 24])
    }

    @Test func slotOffsetKeepsTangentJointsWithoutRedundancy() throws {
        var s = newSketch()
        let slot = try s.addSlot(.straight, (0, 0), (30, 0), width: 10)
        let curves = slot.filter { s.entities[$0]!.kind != .point && !s.entities[$0]!.construction }
        let dof = s.resolve().dof
        _ = try s.offset(curves, distance: 3)
        let rep = s.resolve()
        #expect(rep.dof == dof)
        #expect(rep.redundant.isEmpty && rep.conflicting.isEmpty)
        let areas = loopAreas(s)
        #expect(areas.count == 2)
        #expect(near(areas[0], 30 * 10 + .pi * 25, 1e-7))
        #expect(near(areas[1], 30 * 16 + .pi * 64, 1e-7))
    }

    @Test func openChainOneSideThenBothSidesWithCaps() throws {
        var s = newSketch()
        let a = s.addLine(from: (0, 0), to: (10, 0))
        let b = s.addLine(from: (10, 0), to: (10, 10))
        try s.addConstraint(.coincident, [ends(s, a).1, ends(s, b).0])
        let dof = s.resolve().dof
        var one = s
        let r1 = try one.offset([a, b], distance: 2, toward: (5, 5))
        #expect(one.resolve().dof == dof)
        let (p, q) = ends(one, r1.sides[0][0]), (_, w) = ends(one, r1.sides[0][1])
        #expect(near(one.point(p), (0, 2)) && near(one.point(q), (8, 2)) && near(one.point(w), (8, 10)))

        let r2 = try s.offset([a, b], distance: 2, bidirectional: true, capEnds: true, makeBaseConstruction: true)
        #expect(r2.sides.count == 2 && r2.caps.count == 2)
        let rep = s.resolve()
        #expect(rep.dof == dof && rep.redundant.isEmpty && rep.conflicting.isEmpty)
        let prof = s.profiles()
        #expect(prof.valid)
        #expect(near(loopAreas(s)[0], 80, 1e-9))  // a 4 mm band along a 20 mm L (mitred)
    }

    @Test func circlesArcsAndErrors() throws {
        var s = newSketch()
        let c = s.addCircle(center: (0, 0), radius: 10)
        let r = try s.offset([c], distance: 3, toward: (0, 0))
        #expect(near(s.circleOf(r.sides[0][0]).r, 7))
        #expect(throws: ForgeError.self) { try s.offset([c], distance: 12, toward: (0, 0)) }
        let e = s.addEllipse(center: (30, 0), major: 5, minor: 3, rotation: 0)
        do {
            _ = try s.offset([e], distance: 1)
            Issue.record("expected not_implemented")
        } catch let err as ForgeError {
            #expect(err.code == .notImplemented)
        }
    }

    @Test func filletedChainOffsetsWithoutRedundancy() throws {
        var s = newSketch()
        let a = s.addLine(from: (0, 0), to: (20, 0))
        let b = s.addLine(from: (20, 0), to: (20, 15))
        try s.addConstraint(.coincident, [ends(s, a).1, ends(s, b).0])
        let arc = try s.filletCorner(a, b, radius: 4)[0]
        let dof = s.resolve().dof
        let r = try s.offset([a, arc, b], distance: 1.5, toward: (10, 5))
        let rep = s.resolve()
        #expect(rep.dof == dof)
        #expect(rep.redundant.isEmpty && rep.conflicting.isEmpty)
        let copyArc = r.sides[0].first { s.entities[$0]!.kind == .arc }!
        #expect(near(s.circleOf(copyArc).r, 2.5))
    }
}

@Suite("Sketch move, rotate, scale")
struct MoveRotateScaleTests {
    /// A 40 x 20 rectangle with its first corner on the origin and both sides dimensioned.
    func definedRectangle() throws -> (Sketch, [String]) {
        var s = newSketch()
        let r = try s.addRectangle(.corner, [(0, 0), (40, 20)])
        try s.addConstraint(.coincident, [ends(s, r[0]).0, Sketch.originID])
        try s.addConstraint(.distance, [r[0]], value: 40)
        try s.addConstraint(.distance, [r[1]], value: 20)
        #expect(s.resolve().status == .fullyDefined)
        return (s, r)
    }

    @Test func moveDetachesFromUnmovedGeometry() throws {
        var (s, r) = try definedRectangle()
        let res = try s.move(r, by: (10, 5))
        #expect(res.removed.count == 1)  // the coincidence with the origin
        #expect(near(s.point(ends(s, r[0]).0), (10, 5)) && near(s.point(ends(s, r[0]).1), (50, 5)))
        let rep = s.resolve()
        #expect(rep.dof == 2 && rep.conflicting.isEmpty)
    }

    @Test func keepingRelationsLetsTheSolverPullBack() throws {
        var (s, r) = try definedRectangle()
        let res = try s.move(r, by: (10, 5), keepRelations: true)
        #expect(res.removed.isEmpty)
        #expect(near(s.point(ends(s, r[0]).0), (0, 0), 1e-9))
        #expect(s.resolve().status == .fullyDefined)
    }

    @Test func rotateDropsHorizontalVerticalAndKeepsLengths() throws {
        var (s, r) = try definedRectangle()
        let res = try s.rotate(r, about: (0, 0), by: .pi / 6)
        // The origin coincidence (unmoved origin) and the 4 horizontal/vertical relations go.
        #expect(res.removed.count == 5)
        let (a, b) = ends(s, r[0])
        let rb: (Double, Double) = (40 * cos(Double.pi / 6), 40 * sin(Double.pi / 6))
        #expect(near(s.point(a), (0, 0)) && near(s.point(b), rb))
        let (_, c) = ends(s, r[1])
        let (cs, sn): (Double, Double) = (cos(.pi / 6), sin(.pi / 6))
        let expected: (Double, Double) = (40 * cs - 20 * sn, 40 * sn + 20 * cs)
        #expect(near(s.point(c), expected))
        #expect(s.resolve().conflicting.isEmpty)
    }

    @Test func halfTurnKeepsSignedDistances() throws {
        var s = newSketch()
        let p = s.addPoint(0, 0), q = s.addPoint(10, 3)
        try s.addConstraint(.horizontalDistance, [p, q], value: 10)
        _ = try s.rotate([p, q], about: (5, 0), by: .pi)
        #expect(near(s.point(p), (10, 0)) && near(s.point(q), (0, -3)))
        #expect(s.resolve().conflicting.isEmpty)
        #expect(s.constraints.count == 1)
    }

    @Test func scaleScalesRadiiAndDimensions() throws {
        var s = newSketch()
        let c = s.addCircle(center: (5, 0), radius: 5)
        let dim = try s.addConstraint(.radius, [c], value: 5)
        _ = try s.scale([c], about: (0, 0), by: 2)
        #expect(near(s.circleOf(c).r, 10) && near(s.circleOf(c).c, (10, 0)))
        #expect(s.constraints.first { $0.id == dim }?.value == 10)
    }

    @Test func copyLeavesTheOriginal() throws {
        var s = newSketch()
        let l = s.addLine(from: (10, 0), to: (20, 0))
        let res = try s.rotate([l], about: (0, 0), by: .pi / 2, copy: true)
        #expect(near(s.point(ends(s, l).0), (10, 0)))
        let (a, b) = ends(s, res.entities[0])
        #expect(near(s.point(a), (0, 10)) && near(s.point(b), (0, 20)))
    }
}

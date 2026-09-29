import ForgeCore
import Foundation
import Testing

@testable import ForgeSketch

@Suite("Dimension layout and first-dimension scaling")
struct DimensionLayoutTests {
    func near(_ a: Point2, _ b: Point2, _ tol: Double = 1e-9) -> Bool { abs(a.u - b.u) <= tol && abs(a.v - b.v) <= tol }
    func near(_ a: (Point2, Point2), _ b: (Point2, Point2)) -> Bool { near(a.0, b.0) && near(a.1, b.1) }

    @Test func lineLengthPulledAboveHasExtensionLinesAndArrows() throws {
        var s = newSketch()
        let l = s.addLine(from: (0, 0), to: (40, 0))
        let d = try #require(s.dimensionLayout(.distance, [l], label: Point2(20, 10)))
        // Extension lines from each end up to the dimension line at v = 10.
        #expect(d.extensions.count == 2)
        #expect(near(d.extensions[0], (Point2(0, 0), Point2(0, 10))) && near(d.extensions[1], (Point2(40, 0), Point2(40, 10))))
        // The dimension line between them, arrows pointing outward at its ends.
        #expect(d.segments.count == 1 && near(d.segments[0], (Point2(0, 10), Point2(40, 10))))
        #expect(d.arrows.count == 2)
        #expect(near(d.arrows[0].tip, Point2(0, 10)) && near(d.arrows[0].direction, Point2(-1, 0)))
        #expect(near(d.arrows[1].tip, Point2(40, 10)) && near(d.arrows[1].direction, Point2(1, 0)))
        #expect(d.text == Point2(20, 10))
        // Pulled past the end, the dimension line reaches the value.
        let out = try #require(s.dimensionLayout(.distance, [l], label: Point2(60, -8)))
        #expect(near(out.segments[0], (Point2(0, -8), Point2(60, -8))))
    }

    @Test func slantedLineMeasuredHorizontally() throws {
        var s = newSketch()
        let l = s.addLine(from: (0, 0), to: (30, 40))
        let d = try #require(s.dimensionLayout(.horizontalDistance, [l], label: Point2(15, 60)))
        #expect(near(d.extensions[0], (Point2(0, 0), Point2(0, 60))) && near(d.extensions[1], (Point2(30, 40), Point2(30, 60))))
        #expect(near(d.arrows[0].tip, Point2(0, 60)) && near(d.arrows[1].tip, Point2(30, 60)))
        // Aligned: the dimension line is parallel to the line, offset along its normal (-0.8, 0.6).
        let a = try #require(s.dimensionLayout(.distance, [l], label: Point2(15 - 8, 20 + 6)))
        #expect(near(a.segments[0], (Point2(-8, 6), Point2(22, 46))))
    }

    @Test func diameterAndRadiusLeaders() throws {
        var s = newSketch()
        let c = s.addCircle(center: (10, 10), radius: 5)
        let d = try #require(s.dimensionLayout(.diameter, [c], label: Point2(30, 10)))
        #expect(d.segments.count == 1 && near(d.segments[0], (Point2(5, 10), Point2(30, 10))))
        #expect(near(d.arrows[0].tip, Point2(15, 10)) && near(d.arrows[0].direction, Point2(1, 0)))
        #expect(near(d.arrows[1].tip, Point2(5, 10)) && near(d.arrows[1].direction, Point2(-1, 0)))
        let r = try #require(s.dimensionLayout(.radius, [c], label: Point2(10, 30)))
        #expect(near(r.segments[0], (Point2(10, 10), Point2(10, 30))))
        #expect(r.arrows.count == 1 && near(r.arrows[0].tip, Point2(10, 15)) && near(r.arrows[0].direction, Point2(0, 1)))
    }

    @Test func angleArcBetweenTwoLines() throws {
        var s = newSketch()
        let a = s.addLine(from: (0, 0), to: (10, 0))
        let b = s.addLine(from: (0, 0), to: (0, 10))
        let d = try #require(s.dimensionLayout(.angle, [a, b], label: Point2(5, 5)))
        let r = 50.0.squareRoot()
        // The arc (as chords) runs from the first line to the second at the value's distance.
        #expect(near(d.segments.first!.0, Point2(r, 0)) && near(d.segments.last!.1, Point2(0, r)))
        #expect(d.segments.allSatisfy { abs($0.0.length - r) < 1e-9 && abs($0.1.length - r) < 1e-9 })
        // Arrowheads point out of the arc along its tangents; no extension lines (the arc is on the lines).
        #expect(near(d.arrows[0].tip, Point2(r, 0)) && near(d.arrows[0].direction, Point2(0, -1)))
        #expect(near(d.arrows[1].tip, Point2(0, r)) && near(d.arrows[1].direction, Point2(-1, 0)))
        #expect(d.extensions.isEmpty)
        // Beyond the lines' ends: extension lines along them to the arc.
        let far = try #require(s.dimensionLayout(.angle, [a, b], label: Point2(10, 10)))
        let R = 200.0.squareRoot()
        #expect(far.extensions.count == 2)
        #expect(near(far.extensions[0], (Point2(10, 0), Point2(R, 0))) && near(far.extensions[1], (Point2(0, 10), Point2(0, R))))
    }

    @Test func firstLengthDimensionScalesTheWholeSketch() throws {
        var s = newSketch()
        let l1 = s.addLine(from: (0, 0), to: (40, 0))
        let l2 = s.addLine(from: (40, 0), to: (40, 20))
        let f = try s.scaleForFirstDimension(.distance, [l1], value: 20)
        #expect(f == 0.5)
        let (p, q) = ends(s, l2)
        #expect(s.point(p) == (20, 0) && s.point(q) == (20, 10))
        _ = try s.addConstraint(.distance, [l1], value: 20)
        // The second one does not scale: it drives its own entity only.
        #expect(try s.scaleForFirstDimension(.distance, [l2], value: 30) == nil)
    }

    @Test func noScalingForAnglesOrFixedGeometry() throws {
        var s = newSketch()
        let a = s.addLine(from: (0, 0), to: (10, 0))
        let b = s.addLine(from: (0, 0), to: (10, 10))
        #expect(try s.scaleForFirstDimension(.angle, [a, b], value: 1) == nil)
        _ = try s.addConstraint(.fix, [s.entities[b]!.points[1]])
        #expect(try s.scaleForFirstDimension(.distance, [a], value: 20) == nil)
    }

    @Test func valuePositionFollowsTheGeometryAndIsSaved() throws {
        var s = newSketch()
        let l = s.addLine(from: (0, 0), to: (40, 0))
        let c = try s.addConstraint(.distance, [l], value: 40)
        try s.setDimensionLabel(c, at: Point2(20, 10))
        #expect(s.constraints.first { $0.id == c }!.label == [0, 10])
        // Scaled ×2 about the origin: the value stays beside the line, twice as far.
        _ = try s.scale([l], about: (0, 0), by: 2)
        let moved = try #require(s.dimensionLayout(s.constraints.first { $0.id == c }!))
        #expect(near(moved.text, Point2(40, 20)))
        let back = try JSONDecoder().decode(Sketch.self, from: try JSONEncoder().encode(s))
        #expect(back.constraints.first { $0.id == c }!.label == [0, 20])
    }
}

import ForgeCore
import Foundation
import Testing

@testable import ForgeSketch

@Suite("Sketch snapping and measurement")
struct SnapTests {
    func sketch() -> (Sketch, String, String) {
        var s = newSketch()
        let l1 = s.addLine(from: (0, 0), to: (40, 0))
        let c = s.addCircle(center: (60, 30), radius: 5)
        return (s, l1, c)
    }

    @Test func snapsToEndpointsFirst() {
        let (s, l1, _) = sketch()
        let r = s.snap(Point2(39.6, 0.3), tolerance: 1)
        #expect(r.kind == .point && r.point == Point2(40, 0) && r.target == s.entities[l1]!.points[1])
    }

    @Test func snapsToMidpoint() {
        let (s, l1, _) = sketch()
        let r = s.snap(Point2(20.4, -0.5), tolerance: 1)
        #expect(r.kind == .midpoint && r.point == Point2(20, 0) && r.target == l1)
    }

    @Test func linesUpWithOtherEndpoints() {
        let (s, _, _) = sketch()
        // Above the right end of the line: x snaps to 40, with a guide from (40, 0).
        let r = s.snap(Point2(40.6, 17), tolerance: 1)
        #expect(r.kind == .aligned && r.point == Point2(40, 17))
        #expect(r.guides == [SketchSnap.Guide(from: Point2(40, 0), to: Point2(40, 17))])
        // Lined up with two points at once: x of the line end, y of the circle centre.
        let both = s.snap(Point2(40.5, 29.4), tolerance: 1)
        #expect(both.point == Point2(40, 30) && both.guides.count == 2)
    }

    @Test func horizontalFromTheStartWinsAndStillAligns() {
        let (s, _, _) = sketch()
        let r = s.snap(Point2(59.7, 10.4), tolerance: 1, from: Point2(0, 10))
        #expect(r.kind == .horizontal && r.point == Point2(60, 10))
        #expect(r.guides.first?.from == Point2(60, 30))
    }

    @Test func snapsOntoCurves() {
        let (s, _, c) = sketch()
        let r = s.snap(Point2(65.4, 30.2), tolerance: 1)
        #expect(r.kind == .onCurve && r.target == c)
        #expect(abs(hypot(r.point.u - 60, r.point.v - 30) - 5) < 0.05)
    }

    @Test func freeCursorIsUntouched() {
        let (s, _, _) = sketch()
        let r = s.snap(Point2(13.3, 21.7), tolerance: 1)
        #expect(r.kind == .none && r.point == Point2(13.3, 21.7))
    }

    @Test func measuresWhatSmartDimensionWouldAdd() {
        var s = newSketch()
        let a = s.addLine(from: (0, 0), to: (30, 40))
        let b = s.addLine(from: (0, 0), to: (10, 0))
        let c = s.addCircle(center: (0, 20), radius: 4)
        let arc = s.addArc(center: (50, 0), start: (53, 0), end: (50, 3))
        let p = s.addPoint(0, 10)
        #expect(s.measure([a]) == SketchMeasurement(kind: .distance, value: 50))
        #expect(s.measure([c]) == SketchMeasurement(kind: .diameter, value: 8))
        #expect(s.measure([arc])?.kind == .radius && near(s.measure([arc])!.value, 3))
        #expect(s.measure([a, b])?.kind == .angle && near(s.measure([a, b])!.value, atan2(4, 3)))
        #expect(s.measure([p, b]) == SketchMeasurement(kind: .distance, value: 10))
        #expect(s.measure([p, c]) == SketchMeasurement(kind: .distance, value: 10))
        #expect(s.measure([p, c], mode: .horizontalDistance) == SketchMeasurement(kind: .horizontalDistance, value: 0))
        let par = s.addLine(from: (0, 7), to: (10, 7))
        #expect(s.measure([b, par]) == SketchMeasurement(kind: .distance, value: 7))
    }
}

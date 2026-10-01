import ForgeCore
import ForgeSketch
import Foundation
import Testing
@testable import ForgeUI

@MainActor
@Suite("Desktop Split Entities")
struct SketchSplitWorkflowTests {
    private func sketchModel() async -> AppModel {
        let m = AppModel()
        await m.bootstrap()
        await m.newSketch(on: .front)
        return m
    }

    @Test func ribbonSplitCreatesJoinedLinePiecesAndUndoRestoresOriginal() async throws {
        let m = await sketchModel()
        await m.run("sketch.add_line", ["start": [0, 0], "end": [20, 0]])
        let sk = try #require(m.sketchState.sketch)
        let line = try #require(sk.orderedEntities.first { $0.kind == .line })
        m.ribbonTab = .sketch
        let button = try #require(m.ribbonGroups.flatMap(\.buttons).first { $0.id == "splitEntities" })
        #expect(button.enabled)
        button.action()
        #expect(m.sketchState.tool == .split && m.panelPage.title == "Split Entities")
        await m.sketchClick(Point2(7, 0), tolerance: 0.01, curve: "\(sk.id)/\(line.id)")
        #expect(m.lastError == nil)
        let split = try #require(m.sketchState.sketch)
        let pieces = split.orderedEntities.filter { $0.kind == .line }
        #expect(pieces.count == 2)
        let lengths = pieces.map { e in
            let a = split.point(e.points[0]), b = split.point(e.points[1])
            return hypot(b.0 - a.0, b.1 - a.1)
        }.sorted()
        #expect(abs(lengths[0] - 7) < 1e-7 && abs(lengths[1] - 13) < 1e-7)
        #expect(split.userConstraints.contains { $0.kind == .coincident })
        await m.run("edit.undo")
        #expect(m.sketchState.sketch?.orderedEntities.filter { $0.kind == .line }.count == 1)
        await m.run("edit.redo")
        #expect(m.sketchState.sketch?.orderedEntities.filter { $0.kind == .line }.count == 2)
    }

    @Test func circleWaitsForTwoClicksOnSameCurveAndEscapeCancelsPendingSplit() async throws {
        let m = await sketchModel()
        await m.run("sketch.add_circle", ["center": [0, 0], "radius": 5])
        await m.run("sketch.add_line", ["start": [10, 0], "end": [20, 0]])
        let sk = try #require(m.sketchState.sketch)
        let circle = try #require(sk.orderedEntities.first { $0.kind == .circle })
        let line = try #require(sk.orderedEntities.first { $0.kind == .line })
        let ref = "\(sk.id)/\(circle.id)"
        m.chooseTool(.split)
        await m.sketchClick(Point2(5, 0), tolerance: 0.01, curve: ref)
        #expect(m.sketchState.splitEntity == circle.id && m.sketchState.pending.count == 1)
        #expect(m.sketchState.sketch?.entities[circle.id]?.kind == .circle)
        await m.sketchClick(Point2(15, 0), tolerance: 0.01, curve: "\(sk.id)/\(line.id)")
        #expect(m.lastError?.code == .invalidParams)
        #expect(m.sketchState.splitEntity == circle.id)
        m.cancelSketchOperation()
        #expect(m.sketchState.tool == .split && m.sketchState.pending.isEmpty && m.sketchState.splitEntity == nil)
        await m.sketchClick(Point2(5, 0), tolerance: 0.01, curve: ref)
        await m.sketchClick(Point2(-5, 0), tolerance: 0.01, curve: ref)
        #expect(m.lastError == nil && m.sketchState.pending.isEmpty)
        let result = try #require(m.sketchState.sketch)
        #expect(result.orderedEntities.filter { $0.kind == .arc }.count == 2)
        #expect(result.orderedEntities.filter { $0.kind == .circle }.isEmpty)
        await m.run("edit.undo")
        #expect(m.sketchState.sketch?.orderedEntities.filter { $0.kind == .circle }.count == 1)
    }

    @Test func splitRejectsEntitiesFromAnotherSketch() async throws {
        let m = await sketchModel()
        await m.run("sketch.add_line", ["start": [0, 0], "end": [20, 0]])
        let line = try #require(m.sketchState.sketch?.orderedEntities.first { $0.kind == .line })
        m.chooseTool(.split)
        await m.sketchClick(Point2(7, 0), tolerance: 0.01, curve: "sketch-999/\(line.id)")
        #expect(m.lastError?.code == .invalidParams)
        #expect(m.sketchState.sketch?.orderedEntities.filter { $0.kind == .line }.count == 1)
    }
}

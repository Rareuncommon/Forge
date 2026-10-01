import ForgeCore
import ForgeSketch
import Foundation
import Testing
@testable import ForgeUI

@MainActor
@Suite("Desktop curved slots")
struct ArcSlotWorkflowTests {
    @Test func centerArcSlotProjectsEndAndExtrudesAnalyticArea() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.newSketch(on: .front)
        let id = try #require(m.activeSketch)
        m.sketchState.slotType = .arc
        m.chooseTool(.slot)
        for p in [Point2(0, 0), Point2(10, 0), Point2(0, 15)] {
            await m.sketchClick(p, tolerance: 0.001, curve: nil)
        }
        #expect(m.sketchState.pending.count == 3)
        #expect(m.sketchState.sketch?.orderedEntities.filter { $0.kind == .arc }.isEmpty == true)
        await m.sketchClick(Point2(0, 12), tolerance: 0.001, curve: nil)
        #expect(m.lastError == nil)
        #expect(m.sketchState.pending.isEmpty)
        let sk = try #require(m.sketchState.sketch)
        #expect(sk.orderedEntities.filter { $0.kind == .arc && !$0.construction }.count == 4)
        await m.run("sketch.exit")
        await m.run("body.extrude", ["sketch": .string(id), "depth": 3])
        #expect(m.lastError == nil)
        let doc = try #require(await m.engine.activeDocument)
        let body = try #require(doc.bodies.values.first)
        // quarter-circle centerline length 5π, width 4, two semicircular caps R2.
        #expect(abs(try body.shape.massProperties().volume - 72 * .pi) < 1e-6)
        await m.run("edit.undo")
        #expect(m.bodies.isEmpty)
        await m.run("edit.redo")
        #expect(m.bodies.count == 1)
    }

    @Test func threePointSlotAndConstructionOptionUseFourClicks() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.newSketch(on: .front)
        m.sketchState.slotType = .threePointArc
        m.sketchState.forConstruction = true
        m.chooseTool(.slot)
        for p in [Point2(10, 0), Point2(-10, 0), Point2(0, 10), Point2(0, 12)] {
            await m.sketchClick(p, tolerance: 0.001, curve: nil)
        }
        #expect(m.lastError == nil)
        let sk = try #require(m.sketchState.sketch)
        #expect(sk.orderedEntities.filter { $0.kind == .arc }.count == 5)
        #expect(sk.orderedEntities.filter { $0.kind == .arc }.allSatisfy { $0.construction })
        await m.run("edit.undo")
        #expect(m.sketchState.sketch?.orderedEntities.filter { $0.kind == .arc }.isEmpty == true)
        await m.run("edit.redo")
        #expect(m.sketchState.sketch?.orderedEntities.filter { $0.kind == .arc }.count == 5)
    }

    @Test func changingSlotTypeDiscardsIncompatibleClicksAndCanFinishNewSlot() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.newSketch(on: .front)
        m.chooseSlotType(.arc)
        m.chooseTool(.slot)
        for p in [Point2(0, 0), Point2(10, 0), Point2(0, 10)] {
            await m.sketchClick(p, tolerance: 0.001, curve: nil)
        }
        #expect(m.sketchState.pending.count == 3)
        // Invoke the actual shared desktop PropertyManager control.
        let control = try #require(m.panelPage.sections.flatMap(\.controls).first { $0.id == "type" })
        guard case .choice(_, _, _, let select) = control.kind else {
            Issue.record("Slot type must be a choice control")
            return
        }
        select(SlotType.straight.rawValue)
        #expect(m.sketchState.pending.isEmpty)
        #expect(m.sketchState.preview == nil)
        #expect(m.hoverLines.isEmpty)
        for p in [Point2(0, 0), Point2(10, 0), Point2(10, 2)] {
            await m.sketchClick(p, tolerance: 0.001, curve: nil)
        }
        #expect(m.lastError == nil)
        #expect(m.sketchState.pending.isEmpty)
        #expect(m.sketchState.sketch?.orderedEntities.filter { $0.kind == .arc }.count == 2)
    }

    @Test func collinearThreePointSlotRejectsWithoutGeometry() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.newSketch(on: .front)
        m.sketchState.slotType = .threePointArc
        m.chooseTool(.slot)
        for p in [Point2(0, 0), Point2(10, 0), Point2(5, 0), Point2(5, 2)] {
            await m.sketchClick(p, tolerance: 0.001, curve: nil)
        }
        #expect(m.lastError?.code == .invalidParams)
        #expect(m.sketchState.pending.isEmpty)
        #expect(m.sketchState.sketch?.orderedEntities.filter { $0.kind == .arc }.isEmpty == true)
    }
}

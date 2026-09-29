import ForgeCore
import ForgeRender
import ForgeSketch
import Foundation
import Testing
@testable import ForgeUI

/// The shared app model, driven headless as a front end would drive it.
@MainActor
@Suite("App model")
struct AppModelTests {
    func boxModel() async -> AppModel {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_box", ["width": 20, "height": 20, "depth": 20])
        return m
    }

    @Test func picksAccumulateWhileFilleting() async {
        let m = await boxModel()
        await m.select("body-1/edge-0", extend: false)
        m.begin(.fillet)
        await m.select("body-1/edge-1", extend: false)
        await m.select("body-1/edge-2", extend: false)
        #expect(m.filletItems == ["body-1/edge-0", "body-1/edge-1", "body-1/edge-2"])
        // Clicking a picked item again removes it; clicking empty space keeps the rest.
        await m.select("body-1/edge-1", extend: false)
        await m.select(nil, extend: false)
        #expect(m.filletItems == ["body-1/edge-0", "body-1/edge-2"])
    }

    @Test func picksReplaceOutsideOperations() async {
        let m = await boxModel()
        await m.select("body-1/edge-0", extend: false)
        await m.select("body-1/edge-1", extend: false)
        #expect(m.selection == ["body-1/edge-1"])
        await m.select("body-1/edge-2", extend: true)
        #expect(m.selection == ["body-1/edge-1", "body-1/edge-2"])
        await m.select(nil, extend: false)
        #expect(m.selection.isEmpty)
    }

    @Test func filletCommitsEveryPickedEdge() async throws {
        let m = await boxModel()
        m.begin(.fillet)
        for e in 0..<4 { await m.select("body-1/edge-\(e)", extend: false) }
        m.form.radius = "2"
        await m.commitOperation()
        #expect(m.operation == nil)
        let fillet = try #require(m.features.last)
        #expect(fillet.command == "body.fillet_edges")
        #expect(fillet.params["edges"]?.arrayValue?.count == 4)
    }

    @Test func filletPreviewReplacesTheBody() async {
        let m = await boxModel()
        m.begin(.fillet)
        await m.select("body-1/face-0", extend: false)
        await m.updatePreview()
        #expect(m.previewError == nil)
        #expect(m.preview.items.count == 1)
        #expect(m.preview.hidden == ["body-1"])
        #expect(m.preview.items.first?.color.a == 1)
        m.cancelOperation()
        #expect(m.preview.items.isEmpty && m.preview.hidden.isEmpty)
    }

    @Test func newBodyPreviewIsTranslucent() async {
        let m = AppModel()
        await m.bootstrap()
        m.begin(.primitive(.box))
        await m.updatePreview()
        #expect(m.preview.items.count == 1)
        #expect(m.preview.hidden.isEmpty)
        #expect((m.preview.items.first?.color.a ?? 1) < 1)
    }

    @Test func panelPagesDescribeTheOperation() async throws {
        let m = await boxModel()
        m.begin(.fillet)
        await m.select("body-1/edge-0", extend: false)
        await m.select("body-1/edge-3", extend: false)
        var page = m.panelPage
        #expect(page.title == "Fillet")
        #expect(page.ok != nil && page.cancel != nil)
        let items = page.sections.flatMap(\.controls).first { $0.id == "items" }
        guard case .list(let listed, _, true, _)? = items?.kind else { Issue.record("no items list"); return }
        #expect(listed == ["body-1 · edge-0", "body-1 · edge-3"])
        // Editing a field goes to the form, and OK commits it.
        let radius = try #require(page.sections.flatMap(\.controls).first { $0.id == "radius" })
        guard case .field(_, "mm", let get, let set, _) = radius.kind else { Issue.record("no radius field"); return }
        set("1.5")
        #expect(get() == "1.5" && m.form.radius == "1.5")
        page.ok?()
        for _ in 0..<50 where m.operation != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.operation == nil)
        #expect(m.features.last?.params["radius"] == 1.5)
    }

    @Test func pageSignatureTracksStructureNotValues() async {
        let m = AppModel()
        await m.bootstrap()
        m.begin(.primitive(.box))
        let a = m.panelPage.signature
        m.form.width = "77"
        #expect(m.panelPage.signature == a)
        m.begin(.extrude)
        #expect(m.panelPage.signature != a)
        let b = m.panelPage.signature
        m.form.direction2 = true
        #expect(m.panelPage.signature != b)
    }

    @Test func sketchToolPages() async {
        let m = AppModel()
        await m.bootstrap()
        await m.newSketch(on: .front)
        #expect(m.activeSketch != nil)
        #expect(m.panelPage.title == "Insert Line")
        m.chooseTool(.polygon)
        let sides = m.panelPage.sections.flatMap(\.controls).first { $0.id == "sides" }
        guard case .field(_, _, let get, let set, _)? = sides?.kind else { Issue.record("no sides"); return }
        set("99")
        #expect(get() == "40")
        m.chooseTool(nil)
        #expect(m.panelPage.cancel == nil)
    }

    @Test func sketchGridFollowsTheViewNotTheGeometry() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.newSketch(on: .front)
        // A view 100 mm high: about a dozen cells → 10 mm spacing.
        var cam = Camera()
        cam.orthoHalfHeight = 50
        m.projection = ViewProjection(camera: cam, width: 1200, height: 800)
        await Task.yield()
        let before = try #require(m.grid)
        #expect(before.step == 10)
        // Drawing a small line does not rescale the grid (it used to follow the geometry).
        await m.run("sketch.add_line", ["start": [0, 0], "end": [12, 0]])
        #expect(m.grid == before)
        // Zooming in 10× refines it to 1 mm.
        cam.orthoHalfHeight = 5
        m.projection = ViewProjection(camera: cam, width: 1200, height: 800)
        for _ in 0..<5 { await Task.yield() }
        #expect(m.grid?.step == 1)
        // Orbited to look down at 45° and panned off the plane: the grid is centred where the
        // view's centre ray meets the plane — (0, -300) for a target 300 mm in front of it —
        // not at the target's projection (0, 0).
        cam.orthoHalfHeight = 50
        cam.setBasis(back: Vec3(0, 1, 1).normalized, up: Vec3(0, 1, -1).normalized)
        cam.target = Vec3(0, 0, 300)
        m.projection = ViewProjection(camera: cam, width: 1200, height: 800)
        for _ in 0..<5 { await Task.yield() }
        #expect(m.grid?.centerU == 0 && m.grid?.centerV == -300)
    }

    @Test func smartDimensionFollowsThePointerAndIsPlacedByAClick() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.newSketch(on: .front)
        await m.run("sketch.add_line", ["start": [0, 0], "end": [30, 40]])
        let line = try #require(m.sketchState.sketch?.orderedEntities.first { $0.kind == .line }?.id)
        m.chooseTool(.dimension)
        await m.dimensionClick(line, at: Point2(15, 20), viewPoint: .zero)
        // Picked, not placed: no Modify box yet; the dimension is drawn at the pointer.
        #expect(m.dimensionEdit?.placed == false)
        #expect(m.dimensionPreview?.drawing != nil)
        // Pulled above the slanted line: horizontal (30); to its right: vertical (40); beside it: aligned (50).
        m.dimensionHover(Point2(15, 60))
        #expect(m.dimensionEdit?.measurement?.kind == .horizontalDistance && m.dimensionEdit?.measurement?.value == 30)
        m.dimensionHover(Point2(60, 20))
        #expect(m.dimensionEdit?.measurement?.kind == .verticalDistance)
        m.dimensionHover(Point2(25, 5))
        #expect(m.dimensionEdit?.measurement?.kind == .distance && m.dimensionEdit?.measurement?.value == 50)
        // A click on empty space places it; the Modify box opens there.
        await m.dimensionClick(nil, at: Point2(25, 5), viewPoint: CGPoint(x: 120, y: 80))
        #expect(m.dimensionEdit?.placed == true && m.dimensionEdit?.position == CGPoint(x: 120, y: 80))
        // The first dimension scales the sketch (50 → 25: the line's end halves) and refits the view.
        m.dimensionEdit?.text = "25"
        await m.commitDimension()
        #expect(m.dimensionEdit == nil)
        let sk = try #require(m.sketchState.sketch)
        let end = try #require(sk.entities[line]?.points[1])
        #expect(abs(sk.point(end).0 - 15) < 1e-9 && abs(sk.point(end).1 - 20) < 1e-9)
        guard case .fit? = m.viewportCommands.log.last else { Issue.record("no fit after scaling"); return }
        let label = try #require(m.annotations.first { $0.kind == .dimension })
        #expect(label.drawing != nil && abs(label.anchor.x - 12.5) < 1e-9 && abs(label.anchor.y - 2.5) < 1e-9)
    }
}

@MainActor
@Suite("Feature editing")
struct FeatureEditTests {
    @Test func editingAFilletRollsBackAndKeepsItsEdges() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_box", ["width": 20, "height": 20, "depth": 20])
        await m.run("body.fillet_edges", ["edges": ["body-1/edge-0"], "radius": 2])
        let fillet = try #require(m.features.last)
        m.editFeature(fillet)
        await m.editTask?.value
        // The model is rolled back to the box, with the fillet's edge picked on it.
        #expect(m.rollback == 1)
        #expect(m.filletItems == ["body-1/edge-0"])
        #expect(m.preview.items.count == 1)
        m.form.radius = "3"
        await m.commitOperation()
        #expect(m.operation == nil && m.rollback == nil)
        func volume() async throws -> Double {
            try await m.engine.execute("query.mass_properties", ["body": "body-1"]).result["volume_mm3"]!.doubleValue!
        }
        // A fillet of radius r on a 20 mm edge removes (1 - π/4)·r²·20.
        #expect(abs(try await volume() - (8000 - (1 - .pi / 4) * 9 * 20)) < 1e-6)
        // The edit is one undo step, back to radius 2.
        await m.run("edit.undo")
        #expect(abs(try await volume() - (8000 - (1 - .pi / 4) * 4 * 20)) < 1e-6)
    }

    @Test func cancellingAnEditRestoresTheModel() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_box", ["width": 20, "height": 20, "depth": 20])
        await m.run("body.fillet_edges", ["edges": ["body-1/edge-0"], "radius": 2])
        m.editFeature(try #require(m.features.last))
        await m.editTask?.value
        #expect(m.rollback == 1)
        m.cancelOperation()
        await m.run("feature.list")
        for _ in 0..<50 where m.rollback != nil { try await Task.sleep(nanoseconds: 10_000_000); await m.refresh() }
        #expect(m.rollback == nil)
        #expect(m.features.count == 2)
    }
}

@MainActor
@Suite("Sweep, loft and rib pages")
struct SweepLoftRibPageTests {
    @Test func loftPageCommitsTheTickedProfiles() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.run("sketch.create", ["plane": "front"])
        await m.run("sketch.add_rectangle", ["points": [[0, 0], [10, 10]]])
        await m.run("sketch.exit")
        await m.run("sketch.create", ["plane": "front", "offset": 10])
        await m.run("sketch.add_rectangle", ["points": [[0, 0], [10, 10]]])
        await m.run("sketch.exit")
        m.begin(.loft)
        #expect(m.form.loftProfiles == ["sketch-1", "sketch-2"])
        let page = m.panelPage
        #expect(page.sections.map(\.title) == ["Profiles", "Options"])
        await m.updatePreview()
        #expect(m.preview.items.count == 1)
        await m.commitOperation()
        #expect(m.features.last?.command == "body.loft")
        let v = try await m.engine.execute("query.mass_properties", ["body": "body-1"]).result["volume_mm3"]!.doubleValue!
        #expect(abs(v - 1000) < 1e-6)
    }

    @Test func sweepPageDefaultsToTheLastTwoSketches() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.run("sketch.create", ["plane": "front"])
        await m.run("sketch.add_line", ["start": [0, 0], "end": [30, 0]])
        await m.run("sketch.exit")
        m.begin(.sweep)
        // One sketch: the path, with a circular profile.
        #expect(m.form.sweepPath == "sketch-1" && m.form.sweepCircular)
        m.form.sweepDiameter = "2"
        await m.commitOperation()
        let v = try await m.engine.execute("query.mass_properties", ["body": "body-1"]).result["volume_mm3"]!.doubleValue!
        #expect(abs(v - .pi * 30) < 1e-6)
        // Editing it fills the page from the feature.
        m.editFeature(try #require(m.features.last))
        await m.editTask?.value
        #expect(m.operation == .sweep && m.form.sweepDiameter == "2")
        m.cancelOperation()
    }
}

@Suite("Icon geometry")
struct IconGeometryTests {
    @Test func everyIconParsesToDrawableLayers() {
        for icon in ForgeIcon.allCases {
            let layers = icon.drawing
            #expect(!layers.isEmpty, "\(icon)")
            for l in layers {
                #expect(!l.elements.isEmpty, "\(icon)")
                // Every path starts with a move and stays on the 24 × 24 grid (with a margin).
                guard case .move = l.elements.first else { Issue.record("\(icon) layer does not start with a move"); continue }
                for e in l.elements {
                    let pts: [Double]
                    switch e {
                    case .move(let x, let y), .line(let x, let y): pts = [x, y]
                    case .cubic(let a, let b, let c, let d, let x, let y): pts = [a, b, c, d, x, y]
                    case .close: pts = []
                    }
                    #expect(pts.allSatisfy { $0 > -3 && $0 < 27 }, "\(icon): \(pts)")
                }
            }
        }
    }

    @Test func relativeCommandsAndArcs() {
        // "M3 13 h7 v7 h-7 Z": a 7 × 7 square.
        #expect(IconGeometry.parse("M3 13 h7 v7 h-7 Z") == [.move(3, 13), .line(10, 13), .line(10, 20), .line(3, 20), .close])
        // A full circle of radius 3 as two half arcs ends where it started, in quarter-circle cubics.
        let circle = IconGeometry.parse("M9 12 a3 3 0 1 0 6 0 a3 3 0 1 0 -6 0 Z")
        #expect(circle.filter { if case .cubic = $0 { return true } else { return false } }.count == 4)
        if case .cubic(_, _, _, _, let x, let y) = circle[circle.count - 2] { #expect(abs(x - 9) < 1e-9 && abs(y - 12) < 1e-9) }
        #expect(ForgeIcon.fillet.geometry.hasPrefix("s M 5 20 L 20 20 L 20 5|"))
    }
}

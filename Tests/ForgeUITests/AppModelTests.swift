import ForgeCore
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
}

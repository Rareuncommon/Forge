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
}

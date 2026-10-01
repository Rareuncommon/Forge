import ForgeCore
import ForgeRender
import Testing
@testable import ForgeCommands

@Suite("Selection filters and candidate picking")
struct SelectionPickingTests {
    private func engine() async throws -> Engine {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10])
        try await e.execute("body.create_box", ["width": 10, "height": 10, "depth": 10, "origin": [0, 0, -20]])
        return e
    }

    @Test func candidateCommandFindsOccludedBodiesAndRespectsFilterAndVisibility() async throws {
        let e = try await engine()
        try await e.execute("selection.set_filter", ["filter": "bodies"])
        let params: JSONValue = ["x": 200, "y": 200, "view": ["width": 400, "height": 400, "orientation": "front"]]
        let all = try await e.execute("view.pick_candidates", params).result
        #expect(all["candidates"] == ["body-1", "body-2"])
        let front = try await e.execute("view.pick_candidates", ["x": 200, "y": 200,
            "include_occluded": false, "view": ["width": 400, "height": 400, "orientation": "front"]]).result
        #expect(front["candidates"] == ["body-1"])
        try await e.execute("view.set_visibility", ["bodies": ["body-1"], "visible": false])
        let visible = try await e.execute("view.pick_candidates", params).result
        #expect(visible["candidates"] == ["body-2"])
        let state = try await e.execute("document.state").result
        #expect(state["selection_filter"] == "bodies")
        // Filter is a viewing preference, preserved while model edits are undone.
        try await e.execute("edit.undo")
        #expect(await e.activeDocument?.selectionFilter == .bodies)
        await #expect(throws: ForgeError.self) {
            try await e.execute("view.pick_candidates", ["x": -1, "y": 20])
        }
        await #expect(throws: ForgeError.self) {
            try await e.execute("selection.set_filter", ["filter": "invalid"])
        }
    }

    @Test func facesDeduplicateTrianglesAndEdgesRemainOccludedDuringNormalPicking() async throws {
        let e = try await engine(), doc = try #require(await e.activeDocument)
        let ds = try DocumentScene(document: doc)
        let origin = Vec3(5, 5, 100), direction = Vec3(0, 0, -1)
        let faces = ds.pickCandidates(origin: origin, direction: direction, edgeTolerance: 0, filter: .faces, includeOccluded: true)
        #expect(faces.count == 4)
        #expect(Set(faces).count == 4)
        #expect(faces.prefix(2).allSatisfy { $0.hasPrefix("body-1/") })
        #expect(faces.suffix(2).allSatisfy { $0.hasPrefix("body-2/") })
        let edgeRay = Vec3(0, 5, 100)
        let edges = ds.pickCandidates(origin: edgeRay, direction: direction, edgeTolerance: 0.05, filter: .edges, includeOccluded: false)
        #expect(edges.count == 1)
        #expect(edges.first?.hasPrefix("body-1/edge-") == true)
        let allEdges = ds.pickCandidates(origin: edgeRay, direction: direction, edgeTolerance: 0.05, filter: .edges, includeOccluded: true)
        #expect(allEdges.count == 4)
    }

    @Test func explicitSelectionIsNotRestrictedAndNewDocumentResetsFilter() async throws {
        let e = try await engine()
        try await e.execute("selection.set_filter", ["filter": "edges"])
        try await e.execute("selection.set", ["entities": ["body-1"]])
        #expect(await e.activeDocument?.selection == ["body-1"])
        try await e.execute("document.new")
        #expect(await e.activeDocument?.selectionFilter == .all)
    }
}

import ForgeCore
import Foundation
import Testing
@testable import ForgeUI

@MainActor
@Suite("Plane selection from desktop trees")
struct PlaneTreeSelectionTests {
    @Test(arguments: [false, true])
    func primarySketchActionUsesClickedPlane(referencePlane: Bool) async throws {
        let model = AppModel()
        await model.bootstrap()
        var nodeID = "plane-top", planeID = "plane-top"
        if referencePlane {
            await model.run("plane.create", ["reference": "top", "offset": 30])
            let feature = try #require(model.features.last)
            nodeID = feature.id
            planeID = try #require(feature.createdBodies.first)
        }
        let node = try #require(model.treeNodes.first { $0.id == nodeID })
        try await click(node, model: model, expected: [planeID])
        model.ribbonTab = .features
        let button = try #require(model.ribbonGroups.flatMap(\.buttons).first { $0.id == "startSketch" })
        #expect(button.title == "Sketch on Plane")
        button.action()
        for _ in 0..<100 where model.sketchState.tool != .line && model.lastError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.lastError == nil && model.activeSketch != nil)
        let plane = try #require(model.sketchState.plane)
        #expect(abs(plane.normal.y) > 0.99)
        #expect(abs(plane.origin.y - (referencePlane ? 30 : 0)) < 1e-7)
        if referencePlane {
            #expect(model.sketchState.sketch?.placement == planeID)
        }
    }

    private func click(_ node: TreeNode, model: AppModel, expected: [String], extend: Bool = false) async throws {
        let select = try #require(node.select)
        select(extend)
        for _ in 0..<100 where model.selection != expected && model.lastError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.lastError == nil)
        #expect(model.selection == expected)
    }

    @Test func standardPlaneClickHighlightsAndOrientsWithoutStartingSketch() async throws {
        let model = AppModel()
        await model.bootstrap()
        let top = try #require(model.treeNodes.first { $0.id == "plane-top" })
        try await click(top, model: model, expected: ["plane-top"])
        #expect(model.treeNodes.first { $0.id == top.id }?.selected == true)
        #expect(model.canNormalTo && model.activeSketch == nil)
        await model.normalToSelection()
        guard case .normalTo(let plane)? = model.viewportCommands.log.last else { Issue.record("No Normal To command after plane click"); return }
        #expect(abs(plane.normal.y) > 0.99)
        let front = try #require(model.treeNodes.first { $0.id == "plane-front" })
        try await click(front, model: model, expected: ["plane-top", "plane-front"], extend: true)
        #expect(model.treeNodes.first { $0.id == front.id }?.selected == true)
        try await click(front, model: model, expected: ["plane-top"], extend: true)
        #expect(model.treeNodes.first { $0.id == front.id }?.selected == false)
    }

    @Test func referencePlaneFeatureClickHighlightsAndOrientsWithoutStartingSketch() async throws {
        let model = AppModel()
        await model.bootstrap()
        await model.run("plane.create", ["reference": "top", "offset": 30])
        let feature = try #require(model.features.last)
        let planeID = try #require(feature.createdBodies.first)
        let node = try #require(model.treeNodes.first { $0.id == feature.id })
        try await click(node, model: model, expected: [planeID])
        #expect(model.treeNodes.first { $0.id == feature.id }?.selected == true)
        #expect(model.canNormalTo && model.activeSketch == nil)
        await model.normalToSelection()
        guard case .normalTo(let plane)? = model.viewportCommands.log.last else { Issue.record("No Normal To command after reference plane click"); return }
        #expect(abs(plane.normal.y) > 0.99)
        #expect(abs(plane.origin.y - 30) < 1e-7)
        try await click(node, model: model, expected: [], extend: true)
        #expect(model.treeNodes.first { $0.id == feature.id }?.selected == false)
    }
}

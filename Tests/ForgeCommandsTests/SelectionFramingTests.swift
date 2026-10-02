import ForgeCore
import ForgeRender
import Foundation
import Testing
@testable import ForgeCommands

@Suite("Selection framing")
struct SelectionFramingTests {
    func engine() async throws -> Engine {
        let e = Engine()
        try await e.execute("document.new")
        try await e.execute("body.create_box", ["width": 10, "height": 20, "depth": 30])
        try await e.execute("body.create_box", ["width": 10, "height": 20, "depth": 30, "origin": [1000, 0, 0]])
        return e
    }
    func frame(_ e: Engine, _ refs: [String], camera: Camera? = nil, aspect: Double = 1) async throws -> ViewZoomToSelection.Output {
        var params: [String: JSONValue] = ["entities": .array(refs.map(JSONValue.string)), "aspect": .number(aspect)]
        if let camera { params["camera"] = try JSONCoding.toJSON(camera) }
        return try JSONCoding.fromJSON(ViewZoomToSelection.Output.self, await e.execute("view.zoom_to_selection", .object(params)).result)
    }

    @Test func explicitSubshapesAndUnionUseOnlySelectedBounds() async throws {
        let e = try await engine()
        let state = try await e.execute("document.state").result
        let single = try await frame(e, ["body-1"])
        let both = try await frame(e, ["body-1", "body-2"])
        #expect(abs(single.bounds!.max.x - 10) < 1e-6)
        #expect(abs(both.bounds!.max.x - 1010) < 1e-6)
        #expect(single.camera.orthoHalfHeight < both.camera.orthoHalfHeight / 10)
        let face = try await frame(e, ["body-1/face@feature-1:+z"])
        #expect(abs(face.bounds!.size.z) < 1e-6)
        #expect(abs(face.bounds!.center.z - 30) < 1e-6)
        let doc = try #require(await e.activeDocument)
        let body = try doc.body("body-1")
        let edge = try body.shape.edge(0)
        let edgeFrame = try await frame(e, ["body-1/edge-0"])
        #expect(abs(edgeFrame.bounds!.diagonal - (edge.end - edge.start).length) < 1e-6)
        let point = try body.shape.vertex(0)
        let vertex = try await frame(e, ["body-1/vertex-0"])
        #expect(vertex.bounds?.center == point)
        #expect(vertex.camera.target == point)
        #expect(vertex.camera.orthoHalfHeight >= 0.5)
        #expect(try await e.execute("document.state").result == state)
    }

    @Test func emptyHiddenAndReferenceSelectionsDoNotChangeCamera() async throws {
        let e = try await engine()
        var camera = Camera(target: Vec3(3, 4, 5), distance: 90, projection: .perspective)
        camera.setOrientation(.trimetric)
        let empty = try await frame(e, [], camera: camera)
        #expect(empty.bounds == nil && empty.camera == camera)
        try await e.execute("view.set_visibility", ["bodies": ["body-1"], "visible": false])
        let hidden = try await frame(e, ["body-1/face-0", "plane-front"], camera: camera)
        #expect(hidden.bounds == nil && hidden.camera == camera)
        #expect(hidden.skipped == ["body-1/face-0", "plane-front"])
        try await e.execute("view.isolate", ["bodies": ["body-2"]])
        let mixed = try await frame(e, ["body-1", "body-2"], camera: camera)
        #expect(mixed.framed == ["body-2"])
        #expect(abs(mixed.camera.target.x - 1005) < 1e-6)
        #expect(mixed.camera.orientation == camera.orientation && mixed.camera.projection == camera.projection)
        try await e.execute("selection.set", ["entities": ["body-2"]])
        let current = try JSONCoding.fromJSON(ViewZoomToSelection.Output.self, await e.execute("view.zoom_to_selection").result)
        #expect(current.bounds == mixed.bounds)
    }

    @Test func sketchGeometryUsesItsPlacementAndPointBounds() async throws {
        let e = try await engine()
        try await e.execute("sketch.create", ["plane": "front"])
        let empty = try await frame(e, ["sketch-1"])
        #expect(empty.bounds == nil)
        try await e.execute("sketch.add_line", ["start": [2, 3], "end": [8, 9]])
        let selected = try await frame(e, ["sketch-1/line-1"])
        #expect(selected.bounds?.min == Vec3(2, 3, 0))
        #expect(selected.bounds?.max == Vec3(8, 9, 0))
        let all = try await frame(e, ["sketch-1"])
        #expect(all.bounds == selected.bounds)
        let doc = try #require(await e.activeDocument)
        let sketch = try #require(doc.sketches["sketch-1"])
        let pointID = try sketch.entity("line-1").points[0]
        let point = try await frame(e, ["sketch-1/\(pointID)"])
        #expect(point.bounds?.center == Vec3(2, 3, 0))
        await #expect(throws: ForgeError.self) { try await frame(e, ["sketch-1/line-999"]) }
        await #expect(throws: ForgeError.self) { try await frame(e, ["sketch-1/"]) }
        try await e.execute("sketch.exit")
        try await e.execute("sketch.create", ["plane": "right"])
        try await e.execute("sketch.add_line", ["start": [2, 3], "end": [8, 9]])
        let placed = try await frame(e, ["sketch-2"])
        #expect(placed.bounds?.min == Vec3(0, 3, -8))
        #expect(placed.bounds?.max == Vec3(0, 9, -2))
    }

    @Test func fittedCameraRendersAndPicksSelectionDespiteDistantGeometry() async throws {
        let e = try await engine()
        try await e.execute("body.transform", ["body": "body-2", "translate": [100000, 0, 0]])
        for kind in [ProjectionKind.orthographic, .perspective] {
            var camera = Camera(projection: kind)
            camera.setOrientation(.front)
            let output = try await frame(e, ["body-1"], camera: camera, aspect: 0.5)
            #expect(output.camera.orientation == camera.orientation && output.camera.projection == kind)
            let view: JSONValue = ["camera": try JSONCoding.toJSON(output.camera), "width": 200, "height": 400]
            let pick = try await e.execute("view.pick", ["x": 100, "y": 200, "view": view]).result
            #expect(pick["hit"]?.stringValue?.hasPrefix("body-1/") == true)
            let candidates = try await e.execute("view.pick_candidates", ["x": 100, "y": 200, "view": view]).result
            #expect(candidates["candidates"]?.arrayValue?.isEmpty == false)
        }
    }

    @Test func rejectsStaleGeometryAndInvalidCameraInputs() async throws {
        let e = try await engine()
        for ref in ["body-1/face-999", "body-1/edge@missing", "body-1/vertex-999", "body-999"] {
            await #expect(throws: ForgeError.self) { try await frame(e, [ref]) }
        }
        for aspect in [0.0, -1, Double.infinity] {
            await #expect(throws: ForgeError.self) { try await frame(e, ["body-1"], aspect: aspect) }
        }
        var invalid = Camera()
        invalid.orientation = Quat(w: 0, x: 0, y: 0, z: 0)
        await #expect(throws: ForgeError.self) { try await frame(e, ["body-1"], camera: invalid) }
        invalid = Camera(fovY: .pi)
        await #expect(throws: ForgeError.self) { try await frame(e, ["body-1"], camera: invalid) }
    }
}

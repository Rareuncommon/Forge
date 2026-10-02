import ForgeCore
import ForgeCommands
import Testing
@testable import ForgeUI

@MainActor
@Suite("Desktop subentity measurement")
struct MeasureWorkflowTests {
    @Test func singleBodyReportsSizeAndPairReportsMinimumDistance() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_box", ["width": 10, "height": 20, "depth": 30])
        let first = try #require(m.bodies.first?.id)
        m.selection = [first]
        m.begin(.measure)
        await m.computeMeasure()
        let result = try #require(m.form.result)
        #expect(result["from_entity"]?["volume_mm3"]?.doubleValue == 6000)
        #expect(m.lastError == nil)
        await m.run("body.create_box", ["width": 10, "height": 20, "depth": 30, "origin": [40, 0, 0]])
        let second = try #require(m.bodies.first { $0.id != first }?.id)
        m.selection = [first, second]
        await m.computeMeasure()
        #expect(abs((m.form.result?["distance_mm"]?.doubleValue ?? -1) - 30) < 1e-6)
        m.selection = [first, second, "missing"]
        await m.computeMeasure()
        #expect(m.form.result == nil)
    }

    @Test func unsupportedSelectionDoesNotSilentlyBecomeSingleBodyMeasurement() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_box", ["width": 10, "height": 20, "depth": 30])
        let body = try #require(m.bodies.first?.id)
        await m.newSketch(on: .front)
        let sketch = try #require(m.activeSketch)
        await m.run("sketch.exit")
        m.selection = [body, sketch]
        m.begin(.measure)
        await m.computeMeasure()
        #expect(m.form.result == nil)
        #expect(m.lastError != nil)
    }

    @Test func angleModeSwitchesResultsAndReportsUnsupportedSelections() async throws {
        let m = AppModel()
        await m.bootstrap()
        await m.run("body.create_box", ["width": 10, "height": 20, "depth": 30])
        let faces = try await m.engine.execute("query.faces", ["body": "body-1"]).result["faces"]!.arrayValue!
        let side = try #require(faces.first { $0["normal"] == [1, 0, 0] }?["persistent_id"]?.stringValue)
        let top = try #require(faces.first { $0["normal"] == [0, 0, 1] }?["persistent_id"]?.stringValue)
        m.selection = [side, top]
        m.begin(.measure)
        m.form.measureMode = "angle"
        await m.computeMeasure()
        #expect(abs((m.form.result?["angle_degrees"]?.doubleValue ?? -1) - 90) < 1e-9)
        #expect(m.form.result?["distance_mm"] == nil)
        #expect(m.lastError == nil)
        m.form.measureMode = "distance"
        await m.computeMeasure()
        #expect(m.form.result?["distance_mm"] != nil)
        #expect(m.form.result?["angle_degrees"] == nil)
        m.form.measureMode = "angle"
        m.selection = ["body-1"]
        await m.computeMeasure()
        #expect(m.form.result == nil)
        #expect(m.lastError?.code == .invalidParams)
        m.selection = ["body-1", top]
        await m.computeMeasure()
        #expect(m.form.result == nil)
        #expect(m.lastError?.code == .notImplemented)
    }

    @Test func invalidReferenceReportsErrorInsteadOfBlankResults() async throws {
        let m = AppModel()
        await m.bootstrap()
        m.begin(.measure)
        m.selection = ["body-999/edge-1"]
        await m.computeMeasure()
        #expect(m.form.result == nil)
        #expect(m.lastError != nil)
    }
}

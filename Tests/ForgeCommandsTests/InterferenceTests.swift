import ForgeCore
import ForgeKernel
import Foundation
import Testing

@testable import ForgeCommands

@Suite("Multibody interference")
struct InterferenceTests {
    private func engine() async throws -> Engine {
        let e = Engine()
        try await e.execute("document.new")
        return e
    }

    private func box(_ e: Engine, origin: [Double] = [0, 0, 0], size: Double = 10, name: String = "Box") async throws {
        try await e.execute("body.create_box", ["width": .number(size), "height": .number(size), "depth": .number(size),
                                                "origin": .array(origin.map(JSONValue.number)), "name": .string(name)])
    }

    @Test func analyticOverlapAndContainedBody() async throws {
        let e = try await engine()
        try await box(e)
        try await box(e, origin: [5, 0, 0])
        try await box(e, origin: [1, 1, 1], size: 2)
        let result = try await e.execute("query.interference")
        #expect(result.result["checked_pairs"] == 3)
        #expect(result.result["interference_count"] == 2)
        let overlaps = try #require(result.result["interferences"]?.arrayValue)
        #expect(overlaps[0]["body_a"] == "body-1")
        #expect(overlaps[0]["body_b"] == "body-2")
        #expect(abs(try #require(overlaps[0]["volume_mm3"]?.doubleValue) - 500) < 1e-6)
        #expect(abs(try #require(overlaps[1]["volume_mm3"]?.doubleValue) - 8) < 1e-6)
        let min = try #require(overlaps[0]["bbox_mm"]?["min"]?.arrayValue).compactMap(\.doubleValue)
        let max = try #require(overlaps[0]["bbox_mm"]?["max"]?.arrayValue).compactMap(\.doubleValue)
        #expect(zip(min, [5.0, 0, 0]).allSatisfy { abs($0 - $1) < 1e-6 })
        #expect(zip(max, [10.0, 10, 10]).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func touchingAndSeparatedBodiesHaveNoInterference() async throws {
        let e = try await engine()
        for origin in [[0.0, 0, 0], [10, 0, 0], [20, 10, 0], [30, 20, 10], [100, 100, 100]] {
            try await box(e, origin: origin)
        }
        let out = try await e.execute("query.interference", ["min_volume_mm3": 0])
        #expect(out.result["checked_pairs"] == 10)
        #expect(out.result["interference_count"] == 0)
    }

    @Test func overlappingBoundingBoxesDoNotImplySolidOverlap() async throws {
        let e = try await engine()
        try await e.execute("body.create_sphere", ["radius": 1])
        try await e.execute("body.create_sphere", ["radius": 1, "center": [1.8, 1.8, 0]])
        // AABBs overlap 0.2 mm in X and Y, but centres are sqrt(6.48) > 2 mm apart.
        let out = try await e.execute("query.interference")
        #expect(out.result["checked_pairs"] == 1)
        #expect(out.result["interference_count"] == 0)
    }

    @Test func selectionIsDeterministicAndThresholdFiltersResults() async throws {
        let e = try await engine()
        try await box(e, name: "Outer")
        try await box(e, origin: [1, 1, 1], size: 2, name: "Inner")
        try await box(e, origin: [1, 1, 1], size: 3, name: "Third")
        let result = try await e.execute("query.interference", ["bodies": ["Inner", "Outer"], "min_volume_mm3": 9])
        #expect(result.result["bodies"] == ["body-1", "body-2"])
        #expect(result.result["checked_pairs"] == 1)
        #expect(result.result["interference_count"] == 0)
        let a = try await e.execute("query.interference", ["bodies": ["body-2", "body-1"]])
        let b = try await e.execute("query.interference", ["bodies": ["Outer", "Inner"]])
        #expect(a.result == b.result)
    }

    @Test func doesNotChangeGeometryFeaturesSelectionOrUndoHistory() async throws {
        let e = try await engine()
        try await box(e)
        try await box(e, origin: [5, 0, 0])
        try await e.execute("selection.set", ["entities": ["body-1"]])
        let before = try #require(await e.document(nil))
        let data = try before.orderedBodies.map { try $0.shape.brepData() }
        let out = try await e.execute("query.interference")
        let after = try #require(await e.document(nil))
        #expect(out.changes.isEmpty)
        #expect(before.features == after.features)
        #expect(before.selection == after.selection)
        #expect(data == (try after.orderedBodies.map { try $0.shape.brepData() }))
        try await e.execute("edit.undo")
        #expect(await e.document(nil)?.bodies.count == 1)
    }

    @Test func invalidInputsAreStructured() async throws {
        let e = try await engine()
        try await box(e, name: "Outer")
        try await box(e)
        let cases: [(JSONValue, ErrorCode)] = [
            (["bodies": []], .invalidParams),
            (["bodies": ["body-1"]], .invalidParams),
            (["bodies": ["body-1", "Outer"]], .invalidParams),
            (["bodies": ["body-1", "missing"]], .unknownEntity),
            (["min_volume_mm3": -1], .invalidParams),
            (["bodies": .array(Array(repeating: "body-1", count: 101))], .invalidParams),
        ]
        for (params, code) in cases {
            do {
                try await e.execute("query.interference", params)
                Issue.record("Expected \(code)")
            } catch let error as ForgeError {
                #expect(error.code == code)
            }
        }
        for value in [Double.infinity, Double.nan] {
            #expect(throws: ForgeError.self) { try QueryInterference.Params(minVolumeMM3: value).validate() }
        }
    }

    @Test func emptyAndSingleBodyDocumentsReturnNoPairs() async throws {
        let e = try await engine()
        #expect(try await e.execute("query.interference").result["checked_pairs"] == 0)
        try await box(e)
        #expect(try await e.execute("query.interference").result["checked_pairs"] == 0)
    }

    @Test func thresholdAlwaysUsesCubicMillimetres() async throws {
        let e = Engine()
        try await e.execute("document.new", ["units": ["length": "in"]])
        try await box(e, size: 1)
        try await box(e, size: 1)
        let out = try await e.execute("query.interference", ["min_volume_mm3": 1000])
        let overlap = try #require(out.result["interferences"]?.arrayValue?.first)
        #expect(abs(try #require(overlap["volume_mm3"]?.doubleValue) - pow(25.4, 3)) < 1e-6)
    }
}

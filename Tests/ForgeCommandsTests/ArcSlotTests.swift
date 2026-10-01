import ForgeCore
import Foundation
import Testing
@testable import ForgeCommands

@Suite("Arc slot commands")
struct ArcSlotTests {
    private func engine() async throws -> Engine {
        let engine = Engine()
        try await engine.execute("document.new")
        try await engine.execute("sketch.create", ["plane": "front"])
        return engine
    }

    private func area(_ engine: Engine) async throws -> Double {
        let result = try await engine.execute("sketch.check").result
        #expect(result["valid"] == true)
        return try #require(result["region_area_mm2"]?.doubleValue)
    }

    @Test func centerAndThreePointSlotsHaveAnalyticAreasAndSixDegreesOfFreedom() async throws {
        let cases: [(JSONValue, Double)] = [
            (["center": [0, 0], "start": [20, 0], "end": [0, 20], "width": 4], .pi / 2),
            (["center": [0, 0], "start": [20, 0], "end": [0, -20], "width": 4, "clockwise": true], .pi / 2),
            (["center": [0, 0], "start": [20, 0], "end": [0, 20], "width": 4, "clockwise": true], 3 * .pi / 2),
            (["mode": "three_point", "start": [20, 0], "end": [-20, 0], "through": [0, 20], "width": 4], .pi),
            (["mode": "three_point", "start": [20, 0], "end": [0, 20], "through": [-20, 0], "width": 4], 3 * .pi / 2),
        ]
        for (params, sweep) in cases {
            let e = try await engine()
            let result = try await e.execute("sketch.add_arc_slot", params).result
            #expect(result["created"]?.arrayValue?.count == 5)
            #expect(result["sketch"]?["dof"] == 6)
            #expect(result["sketch"]?["status"] == "under_defined")
            // Annular strip: (Ro²-Ri²)*theta/2 = R*w*theta. Two semicaps add pi*(w/2)².
            let expected = 20 * 4 * sweep + .pi * 4
            #expect(abs(try await area(e) - expected) < 1e-7)
            try await e.execute("sketch.exit")
            try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 3])
            let mass = try await e.execute("query.mass_properties", ["body": "body-1"]).result
            #expect(abs(try #require(mass["volume_mm3"]?.doubleValue) - expected * 3) < 1e-6)
        }
    }

    @Test func widthDimensionPreservesConcentricSidesAndSemicircularCaps() async throws {
        let e = try await engine()
        let slot = try await e.execute("sketch.add_arc_slot", ["center": [0, 0], "start": [20, 0], "end": [0, 20], "width": 4]).result
        let created = try #require(slot["created"]?.arrayValue)
        // Fix the five centreline parameters, leaving exactly the slot width free.
        let fixed = try await e.execute("sketch.add_relation", ["type": "fix", "entities": [created[4]]]).result
        #expect(fixed["sketch"]?["dof"] == 1)
        let width = try await e.execute("sketch.add_dimension", ["type": "diameter", "entities": [created[1]], "value": 4]).result
        #expect(width["sketch"]?["dof"] == 0)
        let dimension = try #require(width["constraints"]?.arrayValue?.first)
        try await e.execute("sketch.set_dimension", ["constraint": dimension, "value": 8])
        #expect(abs(try await area(e) - 96 * .pi) < 1e-6)
        try await e.execute("edit.undo")
        #expect(abs(try await area(e) - 44 * .pi) < 1e-6)
        try await e.execute("edit.redo")
        #expect(abs(try await area(e) - 96 * .pi) < 1e-6)
    }

    @Test func rotatedTranslatedSlotsKeepCapCentersOnCenterlineWhileWidthChanges() async throws {
        for rotation in [0.37, 1.21, Double.pi / 4 - 0.9 - 1e-7, Double.pi / 4 - 0.9 + 1e-7, -0.9 + 1e-8, Double.pi / 2 - 0.9 - 1e-8] {
            let e = try await engine()
            func point(_ angle: Double) -> JSONValue {
                .array([.number(43 + 20 * cos(angle)), .number(-17 + 20 * sin(angle))])
            }
            let slot = try await e.execute("sketch.add_arc_slot", ["center": [43, -17], "start": point(rotation), "end": point(rotation + 0.9), "width": 4]).result
            let ids = try #require(slot["created"]?.arrayValue)
            #expect(slot["sketch"]?["dof"] == 6)
            let rotated = try await e.execute("sketch.rotate", ["entities": .array(ids), "center": [43, -17], "angle": "90 deg", "keep_relations": true]).result
            #expect(rotated["sketch"]?["dof"] == 6)
            #expect(rotated["sketch"]?["status"] == "under_defined")
            let fixed = try await e.execute("sketch.add_relation", ["type": "fix", "entities": [ids[4]]]).result
            #expect(fixed["sketch"]?["dof"] == 1)
            let dimension = try await e.execute("sketch.add_dimension", ["type": "diameter", "entities": [ids[1]], "value": 4]).result
            #expect(dimension["sketch"]?["dof"] == 0)
            let constraint = try #require(dimension["constraints"]?.arrayValue?.first)
            try await e.execute("sketch.set_dimension", ["constraint": constraint, "value": 8])
            #expect(abs(try await area(e) - (20 * 8 * 0.9 + 16 * .pi)) < 1e-6)
            let entities = try #require(try await e.execute("sketch.get").result["entities"]?.arrayValue)
            let axis = try #require(entities.first { $0["id"] == ids[4] })
            for (index, endpoint) in [(1, "end"), (3, "start")] {
                let cap = try #require(entities.first { $0["id"] == ids[index] })
                for coordinate in 0..<2 {
                    let actual = try #require(cap["center"]?[coordinate]?.doubleValue)
                    let expected = try #require(axis[endpoint]?[coordinate]?.doubleValue)
                    #expect(abs(actual - expected) < 1e-7)
                }
            }
        }
    }

    @Test func straightSlotsSupportConstructionInBothModes() async throws {
        for mode in ["straight", "center"] {
            let e = try await engine()
            let result = try await e.execute("sketch.add_slot", ["mode": .string(mode), "start": [0, 0], "end": [20, 0], "width": 4, "construction": true]).result
            let ids = try #require(result["created"]?.arrayValue)
            let entities = try #require(try await e.execute("sketch.get").result["entities"]?.arrayValue)
            #expect(entities.filter { ids.contains($0["id"] ?? .null) }.allSatisfy { $0["construction"] == true })
        }
    }

    @Test func invalidSlotsAreRejectedWithoutMutatingTheSketch() async throws {
        let e = try await engine()
        let before = try await e.execute("sketch.get").result
        let invalid: [JSONValue] = [
            ["start": [20, 0], "end": [0, 20], "width": 4],
            ["center": [0, 0], "start": [20, 0], "end": [0, 21], "width": 4],
            ["center": [0, 0], "start": [20, 0], "end": [20, 0], "width": 4],
            ["center": [0, 0], "start": [0, 0], "end": [0, 0], "width": 4],
            ["center": [0, 0], "start": [20, 0], "end": [0, 20], "width": 40],
            ["center": [0, 0], "start": [20, 0], "end": [0, 20], "width": -1],
            ["center": [0, 0], "start": [20, 0], "end": [0, 20], "width": 4, "through": [10, 10]],
            ["mode": "three_point", "start": [0, 0], "end": [20, 0], "through": [10, 0], "width": 4],
            ["mode": "three_point", "start": [20, 0], "end": [0, 20], "through": [-20, 0], "width": 4, "clockwise": false],
            // A 354-degree sweep leaves insufficient clearance for the 4 mm rounded ends.
            ["center": [0, 0], "start": [20, 0], "end": [19.900083305560518, -1.996668332936563], "width": 4],
        ]
        for params in invalid {
            do {
                try await e.execute("sketch.add_arc_slot", params)
                Issue.record("Invalid arc slot was accepted: \(params)")
            } catch let error as ForgeError { #expect(error.code == .invalidParams) }
            #expect(try await e.execute("sketch.get").result == before)
        }
    }

    @Test func unitAwareDryRunConstructionAndPersistence() async throws {
        let e = try await engine()
        let params: JSONValue = ["center": ["1 in", "1 in"], "start": ["2 in", "1 in"], "end": ["1 in", "2 in"], "width": "0.1 in"]
        let before = try await e.execute("sketch.get").result
        try await e.execute("sketch.add_arc_slot", params, dryRun: true)
        #expect(try await e.execute("sketch.get").result == before)
        try await e.execute("sketch.add_arc_slot", params)
        let expected = 25.4 * 2.54 * .pi / 2 + .pi * pow(1.27, 2)
        #expect(abs(try await area(e) - expected) < 1e-6)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("forge-arc-slot-\(UUID().uuidString).forgepart")
        defer { try? FileManager.default.removeItem(at: path) }
        try await e.execute("sketch.exit")
        try await e.execute("body.extrude", ["sketch": "sketch-1", "depth": 5])
        try await e.execute("document.save", ["path": .string(path.path)])
        try await e.execute("document.new")
        try await e.execute("document.open", ["path": .string(path.path)])
        try await e.execute("document.regenerate")
        let mass = try await e.execute("query.mass_properties", ["body": "body-1"]).result
        #expect(abs(try #require(mass["volume_mm3"]?.doubleValue) - expected * 5) < 1e-5)
        let construction = try await engine()
        let result = try await construction.execute("sketch.add_arc_slot", ["center": [0, 0], "start": [20, 0], "end": [0, 20], "width": 4, "construction": true]).result
        let ids = try #require(result["created"]?.arrayValue)
        let entities = try #require(try await construction.execute("sketch.get").result["entities"]?.arrayValue)
        #expect(entities.filter { ids.contains($0["id"] ?? .null) }.allSatisfy { $0["construction"] == true })
    }
}

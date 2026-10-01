import ForgeCore
import ForgeSketch
import Foundation

extension Sketch {
    /// Select by the complete entity set, never by a transient loop ordinal or by one edge
    /// which could silently become part of a different contour after trim/split operations.
    func selectedProfileReport(contours: [[String]]?) throws -> ProfileReport {
        let report = profiles()
        guard let contours else { return report }
        guard !contours.isEmpty else { throw ForgeError(.invalidParams, "select at least one contour") }
        var seen = Set<[String]>()
        var selected = Set<String>()
        for selector in contours {
            let normalized = try selector.map { try localID($0, in: self) }.sorted()
            guard !normalized.isEmpty, Set(normalized).count == normalized.count, seen.insert(normalized).inserted else {
                throw ForgeError(.invalidParams, "contour selectors must be nonempty, unique sets of entity IDs")
            }
            guard let index = report.loops.firstIndex(where: { $0.entities.sorted() == normalized }),
                  report.loops[index].depth % 2 == 0 else {
                throw ForgeError(.referenceLost, "selected contour changed, is no longer closed, or is now a hole", entities: normalized.map { "\(id)/\($0)" },
                                 suggestions: [SuggestedFix(description: "Choose an available closed region", command: "sketch.regions", params: ["sketch": .string(id)])])
            }
            selected.formUnion(report.loops[index].entities)
            for hole in report.loops where hole.parent == index { selected.formUnion(hole.entities) }
        }
        // Explicit selection may ignore unrelated open/crossing geometry; the selected
        // boundaries themselves still undergo the complete profile validation.
        return profiles(including: selected)
    }
}

public struct SketchRegion: Codable, Sendable {
    /// Stable replay selector: sorted IDs of every curve of the outer contour.
    public var selector: [String]
    public var outerEntities: [String]
    public var holes: [[String]]
    public var areaMM2: Double
    /// Sampled display boundaries in sketch coordinates; not a replacement for kernel geometry.
    public var outerOutline: [[Double]]
    public var holeOutlines: [[[Double]]]
    enum CodingKeys: String, CodingKey {
        case selector, holes
        case outerEntities = "outer_entities", areaMM2 = "area_mm2"
        case outerOutline = "outer_outline", holeOutlines = "hole_outlines"
    }
}

public enum SketchRegions: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var sketch: String?
        public var at: Point2?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "at": "Optional sketch-coordinate point; return only closed regions containing it (excluding holes)",
        ]
    }
    public struct Output: Codable, Sendable {
        public var sketch: String
        public var regions: [SketchRegion]
        public var profileValid: Bool
        public var issues: [String]
        enum CodingKeys: String, CodingKey { case sketch, regions, issues; case profileValid = "profile_valid" }
    }
    public static let name = "sketch.regions"
    public static let summary = "List selectable closed sketch regions with stable contour selectors and optional point hit testing"
    public static let discussion = "Each region is one even-depth outer loop with its immediate holes; nested islands are separate regions. Pass selector arrays as body.extrude contours. Open geometry unrelated to a selected closed contour may be ignored. Crossing or branching geometry is not decomposed into intersection cells. Display outlines and point tests are sampled; extrusion geometry and area use the original curves."
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams]
    public static let examples: [JSONValue] = [[:], ["sketch": "sketch-1", "at": [5, 5]]]

    static func contains(_ point: Point2, outline: [[Double]]) -> Bool {
        guard outline.count > 2 else { return false }
        var inside = false
        var previous = outline.last!
        for current in outline {
            let dx = current[0] - previous[0], dy = current[1] - previous[1]
            let length2 = dx * dx + dy * dy
            if length2 > 0 {
                let t = max(0, min(1, ((point.u - previous[0]) * dx + (point.v - previous[1]) * dy) / length2))
                if hypot(point.u - previous[0] - t * dx, point.v - previous[1] - t * dy) < 1e-8 { return true }
            }
            if (current[1] > point.v) != (previous[1] > point.v),
                point.u < (previous[0] - current[0]) * (point.v - current[1]) / (previous[1] - current[1]) + current[0] {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let sketch = try ctx.requireDocument().sketch(p.sketch)
        let report = sketch.profiles()
        func outline(_ loop: ProfileLoop) -> [[Double]] {
            zip(loop.entities, loop.forward).flatMap { id, forward in
                let points = sketch.polyline(id).map { [$0.0, $0.1] }
                return forward ? points : Array(points.reversed())
            }
        }
        var regions: [SketchRegion] = []
        for (index, loop) in report.loops.enumerated() where loop.depth % 2 == 0 {
            let selector = loop.entities.sorted()
            let holes = report.loops.filter { $0.parent == index }
            let selected = sketch.profiles(including: Set(loop.entities + holes.flatMap(\.entities)))
            guard selected.valid else { continue }
            let outer = outline(loop), inner = holes.map(outline)
            if let point = p.at, !contains(point, outline: outer) || inner.contains(where: { contains(point, outline: $0) }) { continue }
            regions.append(SketchRegion(selector: selector, outerEntities: loop.entities, holes: holes.map(\.entities),
                                        areaMM2: selected.regionAreaMM2, outerOutline: outer, holeOutlines: inner))
        }
        regions.sort { $0.selector.lexicographicallyPrecedes($1.selector) }
        return Output(sketch: sketch.id, regions: regions, profileValid: report.valid, issues: report.issues)
    }
}

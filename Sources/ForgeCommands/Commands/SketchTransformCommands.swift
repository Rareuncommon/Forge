import ForgeCore
import ForgeSketch
import Foundation

public enum SketchMirror: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var entities: [String]
        public var axis: String
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "entities": "Curves and points to mirror (an endpoint of a mirrored curve comes with it)",
            "axis": "The line to mirror about (usually a construction centerline)",
        ]
        public func validate() throws {
            guard !entities.isEmpty else { throw ForgeError(.invalidParams, "give at least one entity to mirror") }
        }
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.mirror"
    public static let summary = "Mirror sketch entities about a line, adding symmetric relations so the copies follow the originals"
    public static let discussion = "Circles and arcs are related as wholes; lines and points by their endpoints; coincident, point-on-curve and tangent relations among the originals are re-created between the copies unless the symmetry already implies them. Ellipses are copied without a relation."
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams, .sketchConflict]
    public static let examples: [JSONValue] = [["entities": ["line-3", "arc-5"], "axis": "line-1"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let (created, added) = try s.mirror(try p.entities.map { try localID($0, in: s) }, about: try localID(p.axis, in: s))
        return finish(&ctx, doc, &s, created: created, constraints: added, infer: false)
    }
}

public struct SketchPatternResult: Codable, Sendable {
    public var sketch: SketchSummary
    /// Every created entity (all instances), in order.
    public var created: [String]
    /// Per instance (seed excluded): the copies of the seed entities, in the seed's order.
    public var instances: [[String]]
    public var constraints: [String]
}

public enum SketchPatternLinear: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var entities: [String]
        public var count: Int
        public var spacing: Length
        public var direction: Angle?
        public var along: String?
        public var count2: Int?
        public var spacing2: Length?
        public var direction2: Angle?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "entities": "Seed curves and points",
            "count": "Instances in direction 1, including the seed",
            "spacing": "Distance between instances in direction 1",
            "direction": FieldDoc("Direction 1 as an angle from the sketch x axis (or give 'along')", default: "0 deg"),
            "along": "A sketch line whose start→end direction is direction 1",
            "count2": FieldDoc("Instances in direction 2, including the seed row", default: 1),
            "spacing2": "Distance between rows in direction 2 (required when count2 > 1)",
            "direction2": FieldDoc("Direction 2 as an angle from the sketch x axis", default: "90 deg"),
        ]
        public func validate() throws {
            guard count >= 1, (count2 ?? 1) >= 1, count * (count2 ?? 1) >= 2 else {
                throw ForgeError(.invalidParams, "a pattern needs at least 2 instances in total")
            }
            try requirePositive(spacing, "spacing")
            guard direction == nil || along == nil else { throw ForgeError(.invalidParams, "give 'direction' or 'along', not both") }
            if (count2 ?? 1) > 1 {
                guard let s2 = spacing2 else { throw ForgeError(.invalidParams, "spacing2 is required when count2 > 1") }
                try requirePositive(s2, "spacing2")
            }
        }
    }
    public typealias Output = SketchPatternResult

    public static let name = "sketch.pattern_linear"
    public static let summary = "Linear sketch pattern in one or two directions; copies keep the seed's size and orientation"
    public static let discussion = "Instances are tied to the seed by equal (and, for lines, parallel) relations and keep the seed's internal topology. Their positions are placed exactly but are not yet driven by pattern spacing dimensions: editing the spacing means deleting and re-patterning."
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams]
    public static let examples: [JSONValue] = [
        ["entities": ["circle-4"], "count": 5, "spacing": 12],
        ["entities": ["circle-4"], "count": 3, "spacing": 10, "count2": 2, "spacing2": "0.5 in", "direction2": "90 deg"],
    ]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        var dir = p.direction?.radians ?? 0
        if let along = p.along {
            let l = try s.entity(try localID(along, in: s))
            guard l.kind == .line else { throw ForgeError(.invalidParams, "'along' must be a line", entities: ["\(s.id)/\(l.id)"]) }
            let (a, b) = (s.point(l.points[0]), s.point(l.points[1]))
            dir = atan2(b.1 - a.1, b.0 - a.0)
        }
        let (instances, added) = try s.linearPattern(
            try p.entities.map { try localID($0, in: s) }, direction: dir, spacing: p.spacing.millimeters, count: p.count,
            direction2: p.direction2?.radians ?? .pi / 2, spacing2: p.spacing2?.millimeters, count2: p.count2 ?? 1)
        let r = finish(&ctx, doc, &s, created: instances.flatMap { $0 }, constraints: added, infer: false)
        return SketchPatternResult(sketch: r.sketch, created: r.created, instances: instances, constraints: r.constraints)
    }
}

public enum SketchPatternCircular: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var entities: [String]
        public var count: Int
        public var angle: Angle?
        public var center: Point2?
        public var about: String?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "entities": "Seed curves and points",
            "count": "Instances including the seed",
            "angle": FieldDoc("Total angle, counter-clockwise; 360 deg spaces instances evenly around the circle, less places the last instance at the angle", default: "360 deg"),
            "center": FieldDoc("Pattern centre as coordinates (or give 'about')", default: "the sketch origin"),
            "about": "A sketch point, circle or arc whose centre is the pattern centre",
        ]
        public func validate() throws {
            guard count >= 2 else { throw ForgeError(.invalidParams, "count must be at least 2") }
            guard center == nil || about == nil else { throw ForgeError(.invalidParams, "give 'center' or 'about', not both") }
        }
    }
    public typealias Output = SketchPatternResult

    public static let name = "sketch.pattern_circular"
    public static let summary = "Circular sketch pattern about a centre; copies keep the seed's size"
    public static let discussion = "Instances are tied to the seed by equal relations and keep the seed's internal topology. Their angular positions are placed exactly but are not yet driven by pattern dimensions."
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams]
    public static let examples: [JSONValue] = [["entities": ["circle-2"], "count": 6], ["entities": ["line-5"], "count": 3, "angle": "90 deg", "about": "point-1"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        var c = p.center?.tuple ?? (0, 0)
        if let about = p.about {
            let e = try s.entity(try localID(about, in: s))
            switch e.kind {
            case .point: c = s.point(e.id)
            case .circle, .arc, .ellipse: c = s.point(e.points[0])
            case .line: throw ForgeError(.invalidParams, "'about' must be a point, circle, arc or ellipse", entities: ["\(s.id)/\(e.id)"])
            }
        }
        let (instances, added) = try s.circularPattern(
            try p.entities.map { try localID($0, in: s) }, center: c, angle: p.angle?.radians ?? 2 * .pi, count: p.count)
        let r = finish(&ctx, doc, &s, created: instances.flatMap { $0 }, constraints: added, infer: false)
        return SketchPatternResult(sketch: r.sketch, created: r.created, instances: instances, constraints: r.constraints)
    }
}

public struct SketchTrimOutput: Codable, Sendable {
    public var sketch: SketchSummary
    public var created: [String]
    public var deleted: [String]
    public var removedConstraints: [String]
    public var constraints: [String]

    enum CodingKeys: String, CodingKey {
        case sketch, created, deleted, constraints
        case removedConstraints = "removed_constraints"
    }

    init(_ ctx: CommandContext, _ s: Sketch, _ r: TrimResult) {
        sketch = SketchSummary(s, active: ctx.document.activeSketch == s.id)
        created = r.created
        deleted = r.deleted
        removedConstraints = r.removedConstraints
        constraints = r.constraints
    }
}

public enum SketchTrim: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var sketch: String?
        public var entity: String
        public var at: Point2
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "entity": "The line, arc or circle to trim",
            "at": "A point on (or near) the piece to remove, in sketch coordinates",
        ]
    }
    public typealias Output = SketchTrimOutput

    public static let name = "sketch.trim"
    public static let summary = "Power trim: remove the piece of a curve between the curves crossing it on either side of a point"
    public static let discussion = "An end piece moves the curve's end to the crossing; a middle piece splits the curve (the pieces stay collinear/coradial); a circle becomes an arc; a curve with no crossings is deleted. New ends are held on the crossing curves. Relations that depended on the removed extent (length, midpoint, equal length, whole-curve symmetry) or on a removed end are deleted and listed. Ellipses: not implemented."
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams, .notImplemented, .solverFailed]
    public static let examples: [JSONValue] = [["entity": "line-4", "at": [15, 0]], ["entity": "circle-7", "at": [0, 10]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let r = try s.trim(try localID(p.entity, in: s), at: p.at.tuple)
        ctx.commit(doc, s)
        return Output(ctx, s, r)
    }
}

public enum SketchExtend: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var sketch: String?
        public var entity: String
        public var near: Point2
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "entity": "The line or arc to extend",
            "near": "A point near the end to extend, in sketch coordinates",
        ]
    }
    public typealias Output = SketchTrimOutput

    public static let name = "sketch.extend"
    public static let summary = "Extend the nearer end of a line or arc to the next curve it reaches"
    public static let discussion = "Relations on the moved end and extent-dependent dimensions are deleted and listed; the new end is held on the reached curve."
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams, .solverFailed]
    public static let examples: [JSONValue] = [["entity": "line-4", "near": [4, 0]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let r = try s.extend(try localID(p.entity, in: s), near: p.near.tuple)
        ctx.commit(doc, s)
        return Output(ctx, s, r)
    }
}

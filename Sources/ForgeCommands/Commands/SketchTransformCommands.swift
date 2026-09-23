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
        let c = try transformCenter(p.center, p.about, in: s)
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

public struct SketchOffsetOutput: Codable, Sendable {
    public var sketch: SketchSummary
    public var created: [String]
    /// Copies per side, in chain order (two sides when bi-directional).
    public var sides: [[String]]
    public var caps: [String]
    /// The offset dimension that drives every copy (change it with sketch.set_dimension).
    public var dimension: String?
    public var constraints: [String]
}

public enum SketchOffset: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var entities: [String]
        public var distance: Length
        public var toward: Point2?
        public var reverse: Bool?
        public var bidirectional: Bool?
        public var capEnds: Bool?
        public var makeBaseConstruction: Bool?

        enum CodingKeys: String, CodingKey {
            case sketch, entities, distance, toward, reverse, bidirectional
            case capEnds = "cap_ends"
            case makeBaseConstruction = "make_base_construction"
        }

        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "entities": "Lines, arcs and circles to offset; lines/arcs joined end to end are offset as chains",
            "distance": "Offset distance",
            "toward": FieldDoc("A point on the side to offset to", default: "outward for closed chains and circles; left of the first curve's direction for open chains"),
            "reverse": FieldDoc("Offset to the other side", default: false),
            "bidirectional": FieldDoc("Offset to both sides", default: false),
            "cap_ends": FieldDoc("With bidirectional: close open chains with lines between the two copies' ends", default: false),
            "make_base_construction": FieldDoc("Turn the original curves into construction geometry", default: false),
        ]
        public func validate() throws {
            try requirePositive(distance, "distance")
            guard !entities.isEmpty else { throw ForgeError(.invalidParams, "give the curves to offset") }
            if capEnds == true && bidirectional != true { throw ForgeError(.invalidParams, "cap_ends needs bidirectional: true") }
        }
    }
    public typealias Output = SketchOffsetOutput

    public static let name = "sketch.offset"
    public static let summary = "Offset lines, arcs and circles (chains stay joined at their corners); one dimension drives every copy"
    public static let discussion = "Each copy gets an offset relation to its original, all linked to one driving offset dimension. Corners of a chain are extended/trimmed to meet; open chains' ends stay square to the originals. Ellipses: not implemented (their offset is not an ellipse)."
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams, .notImplemented, .solverFailed]
    public static let examples: [JSONValue] = [
        ["entities": ["line-1", "line-4", "line-7", "line-10"], "distance": 5],
        ["entities": ["line-1", "line-4"], "distance": "0.1 in", "bidirectional": true, "cap_ends": true],
    ]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let r = try s.offset(
            try p.entities.map { try localID($0, in: s) }, distance: p.distance.millimeters, toward: p.toward?.tuple,
            reverse: p.reverse ?? false, bidirectional: p.bidirectional ?? false, capEnds: p.capEnds ?? false,
            makeBaseConstruction: p.makeBaseConstruction ?? false)
        ctx.commit(doc, s)
        return Output(
            sketch: SketchSummary(s, active: ctx.document.activeSketch == s.id), created: r.sides.flatMap { $0 } + r.caps,
            sides: r.sides, caps: r.caps, dimension: r.dimension, constraints: r.constraints)
    }
}

public struct SketchTransformOutput: Codable, Sendable {
    public var sketch: SketchSummary
    /// The moved entities, or the created copies.
    public var entities: [String]
    public var removedConstraints: [String]
    public var constraints: [String]

    enum CodingKeys: String, CodingKey {
        case sketch, entities, constraints
        case removedConstraints = "removed_constraints"
    }
}

let transformEntitiesDoc: FieldDoc = "Curves and points to transform (endpoints of a selected curve come with it)"
let transformCopyDoc = FieldDoc("Transform copies and leave the originals (copies keep their mutual coincident/on-curve/tangent relations)", default: false)
let keepRelationsDoc = FieldDoc("Keep relations to geometry that does not move (the solver then pulls the result back into agreement)", default: false)

/// Resolves a transform centre given as coordinates or as a point/circle/arc entity.
func transformCenter(_ center: Point2?, _ about: String?, in s: Sketch) throws -> (Double, Double) {
    guard let about else { return center?.tuple ?? (0, 0) }
    let e = try s.entity(try localID(about, in: s))
    switch e.kind {
    case .point: return s.point(e.id)
    case .circle, .arc, .ellipse, .ellipseArc: return s.point(e.points[0])
    case .line, .spline: throw ForgeError(.invalidParams, "'about' must be a point, circle, arc or ellipse", entities: ["\(s.id)/\(e.id)"])
    }
}

func finishTransform(_ ctx: inout CommandContext, _ doc: Document, _ s: Sketch, _ r: (entities: [String], removed: [String], added: [String])) -> SketchTransformOutput {
    ctx.commit(doc, s)
    return SketchTransformOutput(
        sketch: SketchSummary(s, active: ctx.document.activeSketch == s.id), entities: r.entities, removedConstraints: r.removed, constraints: r.added)
}

public enum SketchMove: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var entities: [String]
        public var by: Point2?
        public var from: Point2?
        public var to: Point2?
        public var copy: Bool?
        public var keepRelations: Bool?
        enum CodingKeys: String, CodingKey {
            case sketch, entities, by, from, to, copy
            case keepRelations = "keep_relations"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc, "entities": transformEntitiesDoc,
            "by": "Displacement [dx, dy] (or give 'from' and 'to')",
            "from": "Base point of the move", "to": "Where the base point goes",
            "copy": transformCopyDoc, "keep_relations": keepRelationsDoc,
        ]
        public func validate() throws {
            guard (by != nil) != (from != nil && to != nil), (from == nil) == (to == nil) else {
                throw ForgeError(.invalidParams, "give 'by', or both 'from' and 'to'")
            }
        }
    }
    public typealias Output = SketchTransformOutput

    public static let name = "sketch.move"
    public static let summary = "Move (or copy) sketch entities by a displacement"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams, .sketchConflict]
    public static let examples: [JSONValue] = [["entities": ["line-1", "line-4"], "by": [10, 0]], ["entities": ["circle-2"], "from": [0, 0], "to": [5, 5], "copy": true]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let d = p.by?.tuple ?? (p.to!.u - p.from!.u, p.to!.v - p.from!.v)
        let r = try s.move(try p.entities.map { try localID($0, in: s) }, by: d, copy: p.copy ?? false, keepRelations: p.keepRelations ?? false)
        return finishTransform(&ctx, doc, s, r)
    }
}

public enum SketchRotate: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var entities: [String]
        public var angle: Angle
        public var center: Point2?
        public var about: String?
        public var copy: Bool?
        public var keepRelations: Bool?
        enum CodingKeys: String, CodingKey {
            case sketch, entities, angle, center, about, copy
            case keepRelations = "keep_relations"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc, "entities": transformEntitiesDoc,
            "angle": "Rotation angle, counter-clockwise",
            "center": FieldDoc("Centre of rotation (or give 'about')", default: "the sketch origin"),
            "about": "A point, circle or arc whose centre is the centre of rotation",
            "copy": transformCopyDoc, "keep_relations": keepRelationsDoc,
        ]
        public func validate() throws {
            guard center == nil || about == nil else { throw ForgeError(.invalidParams, "give 'center' or 'about', not both") }
        }
    }
    public typealias Output = SketchTransformOutput

    public static let name = "sketch.rotate"
    public static let summary = "Rotate (or copy-rotate) sketch entities about a centre"
    public static let discussion = "Horizontal/vertical relations and horizontal/vertical distances among the rotated geometry are deleted (a half turn keeps them, flipping signed distances)."
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams, .sketchConflict]
    public static let examples: [JSONValue] = [["entities": ["line-1"], "angle": "30 deg", "about": "point-0"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let c = try transformCenter(p.center, p.about, in: s)
        let r = try s.rotate(
            try p.entities.map { try localID($0, in: s) }, about: c, by: p.angle.radians, copy: p.copy ?? false, keepRelations: p.keepRelations ?? false)
        return finishTransform(&ctx, doc, s, r)
    }
}

public enum SketchScale: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var entities: [String]
        public var factor: Double
        public var center: Point2?
        public var about: String?
        public var copy: Bool?
        public var keepRelations: Bool?
        enum CodingKeys: String, CodingKey {
            case sketch, entities, factor, center, about, copy
            case keepRelations = "keep_relations"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc, "entities": transformEntitiesDoc,
            "factor": "Uniform scale factor (> 0)",
            "center": FieldDoc("Scale centre (or give 'about')", default: "the sketch origin"),
            "about": "A point, circle or arc whose centre is the scale centre",
            "copy": transformCopyDoc, "keep_relations": keepRelationsDoc,
        ]
        public func validate() throws {
            guard factor > 0, factor.isFinite else { throw ForgeError(.invalidParams, "factor must be positive") }
            guard center == nil || about == nil else { throw ForgeError(.invalidParams, "give 'center' or 'about', not both") }
        }
    }
    public typealias Output = SketchTransformOutput

    public static let name = "sketch.scale"
    public static let summary = "Scale (or copy-scale) sketch entities about a centre; dimensions among them scale too"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams, .sketchConflict]
    public static let examples: [JSONValue] = [["entities": ["circle-1"], "factor": 2]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let c = try transformCenter(p.center, p.about, in: s)
        let r = try s.scale(
            try p.entities.map { try localID($0, in: s) }, about: c, by: p.factor, copy: p.copy ?? false, keepRelations: p.keepRelations ?? false)
        return finishTransform(&ctx, doc, s, r)
    }
}

public enum SketchSplit: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var entity: String
        public var at: [Point2]
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "entity": "The line, arc or circle to split",
            "at": "Split points (projected onto the curve): one for a line or arc, two for a circle",
        ]
        public func validate() throws {
            guard at.count == 1 || at.count == 2 else { throw ForgeError(.invalidParams, "give one split point (line/arc) or two (circle)") }
        }
    }
    public typealias Output = SketchTrimOutput

    public static let name = "sketch.split"
    public static let summary = "Split a line or arc at a point, or a circle at two points, into pieces joined by coincident relations"
    public static let discussion = "Line pieces stay on one line, arc/circle pieces stay concentric; the far end's relations move to the new piece; length-type relations of the original are removed and listed. Ellipses: not implemented."
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams, .notImplemented, .solverFailed]
    public static let examples: [JSONValue] = [["entity": "line-4", "at": [[10, 0]]], ["entity": "circle-7", "at": [[5, 0], [-5, 0]]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let r = try s.split(try localID(p.entity, in: s), at: p.at.map(\.tuple))
        ctx.commit(doc, s)
        return Output(ctx, s, r)
    }
}

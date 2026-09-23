import ForgeCore
import ForgeSketch
import Foundation

// MARK: - Shared types

public enum StandardPlane: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case front, top, right

    var plane: SketchPlane {
        switch self {
        case .front: .front
        case .top: .top
        case .right: .right
        }
    }
}

/// Relation types accepted by sketch.add_relation (SPEC 7.1 "Relations").
public enum RelationType: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case coincident, onEntity = "on_entity", horizontal, vertical, parallel, perpendicular, tangent, equal,
        symmetric, midpoint, concentric, collinear, coradial, fix

    var kind: ConstraintKind { ConstraintKind(rawValue: rawValue)! }
}

/// Dimension types accepted by sketch.add_dimension (SPEC 7.1 "Dimensions").
public enum DimensionType: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case distance, horizontalDistance = "horizontal_distance", verticalDistance = "vertical_distance", radius, diameter, angle, offset

    var kind: ConstraintKind { ConstraintKind(rawValue: rawValue)! }
}

public struct SketchSummary: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var plane: String
    public var status: SolveStatus
    public var dof: Int
    public var entityCount: Int
    public var constraintCount: Int
    public var active: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, plane, status, dof, active
        case entityCount = "entity_count"
        case constraintCount = "constraint_count"
    }

    init(_ s: Sketch, active: Bool) {
        id = s.id
        name = s.name
        plane = s.plane.name
        status = s.report?.status ?? .underDefined
        dof = s.report?.dof ?? 0
        entityCount = s.entityOrder.count
        constraintCount = s.userConstraints.count
        self.active = active
    }
}

public struct SketchEntityView: Codable, Sendable, Hashable {
    public var id: String
    public var type: SketchEntityKind
    public var construction: Bool
    public var state: EntityState
    public var owner: String?
    public var points: [String]?
    public var at: [Double]?
    public var start: [Double]?
    public var end: [Double]?
    public var center: [Double]?
    public var radius: Double?
    public var lengthMM: Double?
    public var majorRadius: Double?
    public var minorRadius: Double?
    public var rotationDeg: Double?
    public var degree: Int?

    enum CodingKeys: String, CodingKey {
        case id, type, construction, state, owner, points, at, start, end, center, radius, degree
        case lengthMM = "length_mm"
        case majorRadius = "major_radius"
        case minorRadius = "minor_radius"
        case rotationDeg = "rotation_deg"
    }

    init(_ s: Sketch, _ e: SketchEntity) {
        id = e.id
        type = e.kind
        construction = e.construction
        state = s.report?.entityStates[e.id] ?? .underDefined
        owner = e.owner
        func p(_ id: String) -> [Double] { let (u, v) = s.point(id); return [u, v] }
        switch e.kind {
        case .point:
            at = p(e.id)
        case .line:
            points = e.points
            start = p(e.points[0])
            end = p(e.points[1])
            lengthMM = hypot(start![0] - end![0], start![1] - end![1])
        case .circle:
            points = e.points
            center = p(e.points[0])
            radius = s.params[e.params[0]]
        case .arc:
            points = e.points
            center = p(e.points[0])
            start = p(e.points[1])
            end = p(e.points[2])
            radius = hypot(start![0] - center![0], start![1] - center![1])
        case .ellipse:
            points = e.points
            center = p(e.points[0])
            majorRadius = s.params[e.params[0]]
            minorRadius = s.params[e.params[1]]
            rotationDeg = s.params[e.params[2]] * 180 / .pi
        case .spline:
            points = e.points  // control points; the first and last are the ends
            start = p(e.points.first!)
            end = p(e.points.last!)
            degree = e.degree
        }
    }
}

public struct SketchConstraintView: Codable, Sendable, Hashable {
    public var id: String
    public var type: ConstraintKind
    public var entities: [String]
    public var value: Double?
    public var unit: String?
    public var driven: Bool
    public var status: String

    init(_ s: Sketch, _ c: SketchConstraint) {
        id = c.id
        type = c.kind
        entities = c.entities
        driven = c.driven
        if let v = c.value, c.kind.isDimension {
            value = c.kind.isAngular ? v * 180 / .pi : v
            unit = c.kind.isAngular ? "deg" : "mm"
        }
        let r = s.report
        status = r?.conflicting.contains(c.id) == true ? "conflicting" : r?.redundant.contains(c.id) == true ? "redundant" : "ok"
    }
}

public struct SolverView: Codable, Sendable, Hashable {
    public var status: SolveStatus
    public var dof: Int
    public var iterations: Int
    public var maxResidual: Double
    public var redundant: [String]
    public var conflicting: [String]

    enum CodingKeys: String, CodingKey {
        case status, dof, iterations, redundant, conflicting
        case maxResidual = "max_residual"
    }

    init(_ r: SolveReport?) {
        status = r?.status ?? .underDefined
        dof = r?.dof ?? 0
        iterations = r?.iterations ?? 0
        maxResidual = r?.maxResidual ?? 0
        redundant = r?.redundant ?? []
        conflicting = r?.conflicting ?? []
    }
}

/// Result of every sketch-editing command: what was created, what was inferred, and the
/// sketch's new state (so an agent can verify without a second call).
public struct SketchEditResult: Codable, Sendable {
    public var sketch: SketchSummary
    public var created: [String]
    public var constraints: [String]
    public var inferred: [InferredRelation]
}

extension CommandContext {
    /// Load the target sketch (explicit id or the active one).
    func sketchForEdit(_ id: String?) throws -> (Document, Sketch) {
        let doc = try requireDocument()
        return (doc, try doc.sketch(id))
    }

    mutating func commit(_ doc: Document, _ sketch: Sketch) {
        var d = doc
        d.updateSketch(sketch)
        document = d
    }
}

/// Accept "line-3" or "sketch-1/line-3".
func localID(_ ref: String, in sketch: Sketch) throws -> String {
    if let slash = ref.firstIndex(of: "/") {
        let head = String(ref[..<slash])
        guard head == sketch.id else {
            throw ForgeError(.invalidParams, "'\(ref)' belongs to \(head), not \(sketch.id)", entities: [ref])
        }
        return String(ref[ref.index(after: slash)...])
    }
    return ref
}

func finish(_ ctx: inout CommandContext, _ doc: Document, _ sketch: inout Sketch, created: [String], constraints: [String] = [], infer: Bool) -> SketchEditResult {
    let inferred = infer ? sketch.inferRelations(newEntities: created) : []
    sketch.resolve()
    ctx.commit(doc, sketch)
    return SketchEditResult(
        sketch: SketchSummary(sketch, active: ctx.document.activeSketch == sketch.id), created: created,
        constraints: constraints + inferred.map(\.constraint), inferred: inferred)
}

let sketchParamDoc: FieldDoc = FieldDoc("Sketch id or name", default: "the sketch being edited")
let constructionDoc: FieldDoc = FieldDoc("Create as construction geometry (not part of profiles)", default: false)
let inferDoc: FieldDoc = FieldDoc("Add relations implied by exact coordinates: coincident with existing points, horizontal/vertical lines", default: true)

// MARK: - Sketch lifecycle

public enum SketchCreate: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var plane: StandardPlane?
        public var offset: Length?
        public var name: String?
        public static let fieldDocs: [String: FieldDoc] = [
            "plane": FieldDoc("Standard plane (Front = XY, Top = XZ, Right = YZ)", default: "front"),
            "offset": FieldDoc("Offset of the sketch plane along its normal", default: 0),
            "name": FieldDoc("Display name", default: "Sketch<n>"),
        ]
    }
    public struct Output: Codable, Sendable { public var sketch: SketchSummary }

    public static let name = "sketch.create"
    public static let summary = "Create a 2D sketch on a standard plane and start editing it"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.preconditionFailed]
    public static let examples: [JSONValue] = [["plane": "front"], ["plane": "top", "offset": "10 mm", "name": "Base"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        var plane = (p.plane ?? .front).plane
        if let o = p.offset { plane.origin = plane.origin + plane.normal * o.millimeters }
        let s = doc.addSketch(name: p.name, plane: plane)
        doc.activeSketch = s.id
        ctx.document = doc
        return Output(sketch: SketchSummary(s, active: true))
    }
}

public enum SketchEdit: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var sketch: String
        public static let fieldDocs: [String: FieldDoc] = ["sketch": "Sketch id or name"]
    }
    public struct Output: Codable, Sendable { public var sketch: SketchSummary }

    public static let name = "sketch.edit"
    public static let summary = "Enter edit mode on a sketch (it becomes the default target of sketch commands)"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.session
    public static let errors: [ErrorCode] = [.unknownEntity]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let s = try doc.sketch(p.sketch)
        doc.activeSketch = s.id
        ctx.document = doc
        return Output(sketch: SketchSummary(s, active: true))
    }
}

public enum SketchExit: Command {
    public typealias Params = NoParams
    public struct Output: Codable, Sendable { public var exited: String? }

    public static let name = "sketch.exit"
    public static let summary = "Leave sketch edit mode"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.session

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let was = doc.activeSketch
        doc.activeSketch = nil
        ctx.document = doc
        return Output(exited: was)
    }
}

public enum SketchRemove: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var sketch: String
        public static let fieldDocs: [String: FieldDoc] = ["sketch": "Sketch id or name"]
    }
    public struct Output: Codable, Sendable { public var deleted: String }

    public static let name = "sketch.remove"
    public static let summary = "Delete a whole sketch"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let s = try doc.sketch(p.sketch)
        try doc.removeSketch(s.id)
        ctx.document = doc
        return Output(deleted: s.id)
    }
}

public struct SketchParam: Codable, Sendable, SchemaDocumented {
    public var sketch: String?
    public static let fieldDocs: [String: FieldDoc] = ["sketch": sketchParamDoc]
}

public enum SketchGet: Command {
    public typealias Params = SketchParam
    public struct Output: Codable, Sendable {
        public var sketch: SketchSummary
        public var plane: SketchPlane
        public var entities: [SketchEntityView]
        public var constraints: [SketchConstraintView]
        public var solver: SolverView
    }

    public static let name = "sketch.get"
    public static let summary = "Sketch entities with coordinates and constraint state, constraints with values, and solver status (DOF, redundant/conflicting)"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity, .preconditionFailed]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let (doc, s) = try ctx.sketchForEdit(p.sketch)
        return Output(
            sketch: SketchSummary(s, active: doc.activeSketch == s.id), plane: s.plane,
            entities: s.orderedEntities.map { SketchEntityView(s, $0) },
            constraints: s.userConstraints.map { SketchConstraintView(s, $0) }, solver: SolverView(s.report))
    }
}

public enum SketchCheck: Command {
    public typealias Params = SketchParam
    public typealias Output = ProfileReport

    public static let name = "sketch.check"
    public static let summary = "Check a sketch for use by a feature: closed loops, nesting, region area, open ends, branches, crossings"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity, .preconditionFailed]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        try ctx.sketchForEdit(p.sketch).1.profiles()
    }
}

// MARK: - Geometry

public enum SketchAddPoint: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var sketch: String?
        public var at: Point2
        public var construction: Bool?
        public var infer: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc, "at": "Position", "construction": constructionDoc, "infer": inferDoc,
        ]
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.add_point"
    public static let summary = "Add a sketch point"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let examples: [JSONValue] = [["at": [10, 5]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let id = s.addPoint(p.at.u, p.at.v, construction: p.construction ?? false)
        return finish(&ctx, doc, &s, created: [id], infer: p.infer ?? true)
    }
}

public enum SketchAddLine: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var start: Point2
        public var end: Point2
        public var construction: Bool?
        public var midpoint: Bool?
        public var infer: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc, "start": "Start point", "end": "End point",
            "construction": FieldDoc("Construction line / centerline", default: false),
            "midpoint": FieldDoc("Midpoint line: 'start' is the midpoint and the line extends symmetrically to 'end'", default: false),
            "infer": inferDoc,
        ]
        public func validate() throws {
            guard start != end else { throw ForgeError(.invalidParams, "start and end coincide") }
        }
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.add_line"
    public static let summary = "Add a line (or centerline, or midpoint line)"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let examples: [JSONValue] = [["start": [0, 0], "end": [40, 0]], ["start": [0, -20], "end": [0, 20], "construction": true]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        var constraints: [String] = []
        let id: String
        var created: [String]
        if p.midpoint == true {
            let (m, e) = (p.start, p.end)
            id = s.addLine(from: (2 * m.u - e.u, 2 * m.v - e.v), to: e.tuple, construction: p.construction ?? false)
            let mid = s.addPoint(m.u, m.v, construction: true)
            constraints.append(try s.addConstraint(.midpoint, [mid, id]))
            created = [id, mid]
        } else {
            id = s.addLine(from: p.start.tuple, to: p.end.tuple, construction: p.construction ?? false)
            created = [id]
        }
        return finish(&ctx, doc, &s, created: created, constraints: constraints, infer: p.infer ?? true)
    }
}

public enum SketchAddCircle: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var center: Point2?
        public var radius: Length?
        public var through: [Point2]?
        public var construction: Bool?
        public var infer: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "center": "Centre (with 'radius')", "radius": "Radius (with 'center')",
            "through": "Perimeter circle: exactly three points on the circle (instead of center/radius)",
            "construction": constructionDoc, "infer": inferDoc,
        ]
        public func validate() throws {
            if let t = through {
                guard t.count == 3, center == nil, radius == nil else {
                    throw ForgeError(.invalidParams, "give either center + radius, or exactly three 'through' points")
                }
            } else {
                guard center != nil, let r = radius else { throw ForgeError(.invalidParams, "give center and radius, or three 'through' points") }
                try requirePositive(r, "radius")
            }
        }
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.add_circle"
    public static let summary = "Add a circle by centre and radius, or through three points (perimeter circle)"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let examples: [JSONValue] = [["center": [0, 0], "radius": 5], ["through": [[0, 0], [10, 0], [5, 5]]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let (c, r): ((Double, Double), Double)
        if let t = p.through {
            (c, r) = try Sketch.circumcircle(t[0].tuple, t[1].tuple, t[2].tuple)
        } else {
            (c, r) = (p.center!.tuple, p.radius!.millimeters)
        }
        let id = s.addCircle(center: c, radius: r, construction: p.construction ?? false)
        return finish(&ctx, doc, &s, created: [id], infer: p.infer ?? true)
    }
}

public enum ArcMode: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case center, threePoint = "three_point", tangent
}

public enum SketchAddArc: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var mode: ArcMode?
        public var center: Point2?
        public var start: Point2?
        public var end: Point2
        public var through: Point2?
        public var tangentTo: String?
        public var clockwise: Bool?
        public var construction: Bool?
        public var infer: Bool?

        enum CodingKeys: String, CodingKey {
            case sketch, mode, center, start, end, through, clockwise, construction, infer
            case tangentTo = "tangent_to"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "mode": FieldDoc("center: center + start + end; three_point: start + through + end; tangent: continues tangentially from the end of 'tangent_to'", default: "center"),
            "center": "Centre (center mode)",
            "start": "Start point (center and three_point modes)",
            "end": "End point (projected onto the circle in center mode)",
            "through": "A point on the arc between start and end (three_point mode)",
            "tangent_to": "Line or arc whose end the arc continues from (tangent mode)",
            "clockwise": FieldDoc("Sweep clockwise from start to end (center mode)", default: false),
            "construction": constructionDoc, "infer": inferDoc,
        ]
        public func validate() throws {
            switch mode ?? .center {
            case .center: guard center != nil, start != nil else { throw ForgeError(.invalidParams, "center mode needs center and start") }
            case .threePoint: guard start != nil, through != nil else { throw ForgeError(.invalidParams, "three_point mode needs start and through") }
            case .tangent: guard tangentTo != nil else { throw ForgeError(.invalidParams, "tangent mode needs tangent_to") }
            }
        }
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.add_arc"
    public static let summary = "Add an arc: centre-point, three-point, or tangent to the end of a line/arc"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity]
    public static let examples: [JSONValue] = [
        ["center": [0, 0], "start": [10, 0], "end": [0, 10]],
        ["mode": "three_point", "start": [0, 0], "through": [5, 3], "end": [10, 0]],
        ["mode": "tangent", "tangent_to": "line-1", "end": [30, 10]],
    ]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let construction = p.construction ?? false
        switch p.mode ?? .center {
        case .center:
            let c = p.center!.tuple, st = p.start!.tuple
            let r = hypot(st.0 - c.0, st.1 - c.1)
            guard r > 0 else { throw ForgeError(.invalidParams, "start coincides with center") }
            let ang = atan2(p.end.v - c.1, p.end.u - c.0)
            let en = (c.0 + r * cos(ang), c.1 + r * sin(ang))
            let id = p.clockwise == true
                ? s.addArc(center: c, start: en, end: st, construction: construction)
                : s.addArc(center: c, start: st, end: en, construction: construction)
            return finish(&ctx, doc, &s, created: [id], infer: p.infer ?? true)
        case .threePoint:
            let a = p.start!.tuple, m = p.through!.tuple, b = p.end.tuple
            let (c, _) = try Sketch.circumcircle(a, m, b)
            // CCW from a to b passes through m iff the three are counter-clockwise.
            let ccw = (m.0 - a.0) * (b.1 - a.1) - (m.1 - a.1) * (b.0 - a.0) > 0
            let id = ccw
                ? s.addArc(center: c, start: a, end: b, construction: construction)
                : s.addArc(center: c, start: b, end: a, construction: construction)
            return finish(&ctx, doc, &s, created: [id], infer: p.infer ?? true)
        case .tangent:
            let base = try s.entity(try localID(p.tangentTo!, in: s))
            let (P, t): ((Double, Double), (Double, Double))
            switch base.kind {
            case .line:
                let a = s.point(base.points[0]), b = s.point(base.points[1])
                P = b
                t = (b.0 - a.0, b.1 - a.1)
            case .arc:
                let c = s.point(base.points[0]), e = s.point(base.points[2])
                P = e
                t = (-(e.1 - c.1), e.0 - c.0)  // CCW tangent at the arc end
            default:
                throw ForgeError(.invalidParams, "tangent_to must be a line or an arc", entities: [base.id])
            }
            let tl = hypot(t.0, t.1)
            let n = (-t.1 / tl, t.0 / tl)  // left normal
            let w = (p.end.u - P.0, p.end.v - P.1)
            let wn = w.0 * n.0 + w.1 * n.1
            guard abs(wn) > 1e-12 else { throw ForgeError(.invalidParams, "end lies on the tangent line; use a line instead") }
            let r = (w.0 * w.0 + w.1 * w.1) / (2 * wn)
            let c = (P.0 + n.0 * r, P.1 + n.1 * r)
            let id = r > 0
                ? s.addArc(center: c, start: P, end: p.end.tuple, construction: construction)
                : s.addArc(center: c, start: p.end.tuple, end: P, construction: construction)
            let arc = s.entities[id]!
            let joint = r > 0 ? arc.points[1] : arc.points[2]
            let baseEnd = base.kind == .line ? base.points[1] : base.points[2]
            var constraints = [try s.addConstraint(.coincident, [baseEnd, joint])]
            constraints.append(try s.addConstraint(.tangent, [base.id, id]))
            return finish(&ctx, doc, &s, created: [id], constraints: constraints, infer: p.infer ?? true)
        }
    }
}

public enum SketchAddEllipse: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var center: Point2
        public var majorRadius: Length
        public var minorRadius: Length
        public var rotation: Angle?
        public var construction: Bool?

        enum CodingKeys: String, CodingKey {
            case sketch, center, rotation, construction
            case majorRadius = "major_radius"
            case minorRadius = "minor_radius"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc, "center": "Centre", "major_radius": "Semi-major axis", "minor_radius": "Semi-minor axis",
            "rotation": FieldDoc("Angle of the major axis from sketch +u", default: 0), "construction": constructionDoc,
        ]
        public func validate() throws {
            try requirePositive(majorRadius, "major_radius")
            try requirePositive(minorRadius, "minor_radius")
            guard minorRadius.millimeters <= majorRadius.millimeters else { throw ForgeError(.invalidParams, "minor_radius must not exceed major_radius") }
        }
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.add_ellipse"
    public static let summary = "Add an ellipse"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let examples: [JSONValue] = [["center": [0, 0], "major_radius": 20, "minor_radius": 10, "rotation": "30 deg"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let id = s.addEllipse(
            center: p.center.tuple, major: p.majorRadius.millimeters, minor: p.minorRadius.millimeters, rotation: p.rotation?.radians ?? 0,
            construction: p.construction ?? false)
        return finish(&ctx, doc, &s, created: [id], infer: false)
    }
}

public enum SketchAddRectangle: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var sketch: String?
        public var mode: Sketch.RectangleMode?
        public var points: [Point2]
        public var construction: Bool?
        public var infer: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "mode": FieldDoc("corner: two opposite corners; center: centre + a corner; three_point: three corners (any angle); parallelogram: three corners", default: "corner"),
            "points": "Defining points for the mode", "construction": constructionDoc, "infer": inferDoc,
        ]
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.add_rectangle"
    public static let summary = "Add a rectangle (corner, center, 3-point) or parallelogram with its relations"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let examples: [JSONValue] = [["points": [[0, 0], [40, 20]]], ["mode": "center", "points": [[0, 0], [20, 10]]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let before = Set(s.constraints.map(\.id))
        let created = try s.addRectangle(p.mode ?? .corner, p.points.map(\.tuple), construction: p.construction ?? false)
        let added = s.constraints.map(\.id).filter { !before.contains($0) }
        return finish(&ctx, doc, &s, created: created, constraints: added, infer: p.infer ?? true)
    }
}

public enum SketchAddSlot: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var mode: Sketch.SlotMode?
        public var start: Point2
        public var end: Point2
        public var width: Length
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "mode": FieldDoc("straight: start/end are the arc centres; center: start is the slot centre, end an arc centre", default: "straight"),
            "start": "First point", "end": "Second point", "width": "Slot width (arc diameter)",
        ]
        public func validate() throws { try requirePositive(width, "width") }
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.add_slot"
    public static let summary = "Add a straight or center-point slot with its tangency relations"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let examples: [JSONValue] = [["start": [0, 0], "end": [30, 0], "width": 8]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let before = Set(s.constraints.map(\.id))
        let created = try s.addSlot(p.mode ?? .straight, p.start.tuple, p.end.tuple, width: p.width.millimeters)
        let added = s.constraints.map(\.id).filter { !before.contains($0) && !$0.contains("#") }
        return finish(&ctx, doc, &s, created: created, constraints: added, infer: false)
    }
}

public enum SketchAddPolygon: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var center: Point2
        public var sides: Int
        public var radius: Length
        public var inscribed: Bool?
        public var rotation: Angle?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc, "center": "Centre", "sides": "Number of sides (3–256)",
            "radius": "Radius of the construction circle",
            "inscribed": FieldDoc("Vertices on the circle (true) or edges tangent to it (false)", default: true),
            "rotation": FieldDoc("Angle of the first vertex from sketch +u", default: 0),
        ]
        public func validate() throws {
            try requirePositive(radius, "radius")
            guard (3...256).contains(sides) else { throw ForgeError(.invalidParams, "sides must be between 3 and 256") }
        }
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.add_polygon"
    public static let summary = "Add a regular polygon with a construction circle"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let examples: [JSONValue] = [["center": [0, 0], "sides": 6, "radius": 10]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let before = Set(s.constraints.map(\.id))
        let created = try s.addPolygon(
            center: p.center.tuple, sides: p.sides, radius: p.radius.millimeters, rotation: p.rotation?.radians ?? 0, inscribed: p.inscribed ?? true)
        let added = s.constraints.map(\.id).filter { !before.contains($0) }
        return finish(&ctx, doc, &s, created: created, constraints: added, infer: false)
    }
}

// MARK: - Relations and dimensions

public enum SketchAddRelation: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var sketch: String?
        public var type: RelationType
        public var entities: [String]
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "type": "Relation type",
            "entities": "Entity ids (\"line-1\" or \"sketch-1/line-1\"). coincident: 2 points; on_entity: point + curve; horizontal/vertical: line or 2 points; parallel/perpendicular/collinear: 2 lines; tangent: line+circle/arc or 2 circles/arcs; equal: 2 lines or 2 circles/arcs; symmetric: 2 points, 2 lines, 2 circles or 2 arcs + the axis line; midpoint: point + line; concentric/coradial: 2 circles/arcs; fix: 1 entity",
        ]
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.add_relation"
    public static let summary = "Add a geometric relation; rejected with a structured error if it over-defines or contradicts the sketch"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.sketchConflict, .sketchRedundant, .solverFailed, .unknownEntity]
    public static let examples: [JSONValue] = [["type": "horizontal", "entities": ["line-1"]], ["type": "coincident", "entities": ["point-0", "point-2"]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let ids = try p.entities.map { try localID($0, in: s) }
        let c = try s.addConstraint(p.type.kind, ids)
        return finish(&ctx, doc, &s, created: [], constraints: [c], infer: false)
    }
}

public enum SketchAddDimension: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var sketch: String?
        public var type: DimensionType
        public var entities: [String]
        public var value: Quantity?
        public var driven: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "type": "distance (line length, point–point, point–line, line–line, centre–centre), horizontal_distance / vertical_distance (line or two points), radius, diameter, angle (two lines)",
            "entities": "Entity ids",
            "value": FieldDoc("Value (length or angle by type; units allowed)", default: "the current measured value"),
            "driven": FieldDoc("Reference dimension: measures without constraining", default: false),
        ]
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.add_dimension"
    public static let summary = "Add a driving or driven dimension; the sketch re-solves to satisfy it"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.sketchConflict, .sketchRedundant, .solverFailed, .unknownEntity]
    public static let examples: [JSONValue] = [
        ["type": "distance", "entities": ["line-1"], "value": "40 mm"],
        ["type": "angle", "entities": ["line-1", "line-4"], "value": "60 deg"],
        ["type": "radius", "entities": ["circle-9"], "driven": true],
    ]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let ids = try p.entities.map { try localID($0, in: s) }
        let kind = p.type.kind
        let v = try p.value.map { kind.isAngular ? try $0.angle() : try $0.length() }
        if p.driven == true, v != nil { throw ForgeError(.invalidParams, "a driven dimension measures its value; omit 'value'") }
        let c = try s.addConstraint(kind, ids, value: v, driven: p.driven ?? false)
        return finish(&ctx, doc, &s, created: [], constraints: [c], infer: false)
    }
}

public enum SketchSetDimension: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var constraint: String
        public var value: Quantity?
        public var driven: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc, "constraint": "Dimension id (\"constraint-7\")",
            "value": "New value (units allowed)", "driven": "Switch between driving (false) and driven (true)",
        ]
        public func validate() throws {
            guard value != nil || driven != nil else { throw ForgeError(.invalidParams, "give 'value' and/or 'driven'") }
        }
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.set_dimension"
    public static let summary = "Change a dimension's value (or toggle driven/driving) and re-solve"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.sketchConflict, .sketchRedundant, .solverFailed, .unknownEntity]
    public static let examples: [JSONValue] = [["constraint": "constraint-12", "value": "55 mm"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let id = try localID(p.constraint, in: s)
        let c = try s.constraint(id)
        let v = try p.value.map { c.kind.isAngular ? try $0.angle() : try $0.length() }
        try s.setDimension(id, value: v, driven: p.driven)
        return finish(&ctx, doc, &s, created: [], constraints: [id], infer: false)
    }
}

// MARK: - Editing

public enum SketchDelete: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var items: [String]
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "items": "Entity ids (curves take their endpoints and attached constraints) and/or constraint ids",
        ]
        public func validate() throws {
            guard !items.isEmpty else { throw ForgeError(.invalidParams, "'items' must not be empty") }
        }
    }
    public struct Output: Codable, Sendable {
        public var sketch: SketchSummary
        public var deletedEntities: [String]
        public var deletedConstraints: [String]

        enum CodingKeys: String, CodingKey {
            case sketch
            case deletedEntities = "deleted_entities"
            case deletedConstraints = "deleted_constraints"
        }
    }

    public static let name = "sketch.delete"
    public static let summary = "Delete sketch entities and/or constraints"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity]
    public static let examples: [JSONValue] = [["items": ["line-1", "constraint-3"]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let ids = try p.items.map { try localID($0, in: s) }
        let constraintIDs = ids.filter { id in s.constraints.contains { $0.id == id } }
        let entityIDs = ids.filter { !constraintIDs.contains($0) }
        try s.delete(constraints: constraintIDs)
        let (de, dc) = try s.delete(entities: entityIDs)
        s.resolve()
        ctx.commit(doc, s)
        return Output(sketch: SketchSummary(s, active: doc.activeSketch == s.id), deletedEntities: de, deletedConstraints: constraintIDs + dc)
    }
}

public enum SketchDrag: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var sketch: String?
        public var entity: String
        public var to: Point2
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "entity": "Point to drag (or a curve, translated by its first point)",
            "to": "Target position; constraints are kept and remaining freedom absorbs the move",
        ]
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.drag"
    public static let summary = "Drag geometry to see/use its remaining freedom while keeping all constraints"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .solverFailed]
    public static let examples: [JSONValue] = [["entity": "point-2", "to": [12, 7]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        try s.drag(try localID(p.entity, in: s), to: p.to.tuple)
        return finish(&ctx, doc, &s, created: [], infer: false)
    }
}

public enum SketchSetConstruction: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var sketch: String?
        public var entities: [String]
        public var construction: Bool
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc, "entities": "Entity ids", "construction": "true = construction geometry, false = regular",
        ]
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.set_construction"
    public static let summary = "Toggle construction geometry"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        for e in p.entities { try s.setConstruction(try localID(e, in: s), p.construction) }
        return finish(&ctx, doc, &s, created: [], infer: false)
    }
}

public enum SketchFillet: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var lines: [String]?
        public var corner: String?
        public var radius: Length
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "lines": "The two lines meeting at the corner (or give 'corner')",
            "corner": "A line endpoint at the corner; the two lines meeting there are filleted",
            "radius": "Fillet radius",
        ]
        public func validate() throws {
            try requirePositive(radius, "radius")
            guard (lines?.count == 2) != (corner != nil) else { throw ForgeError(.invalidParams, "give either two 'lines' or a 'corner' point") }
        }
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.fillet"
    public static let summary = "Round the corner between two lines with a tangent arc, keeping existing dimensions via a virtual sharp"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .solverFailed]
    public static let examples: [JSONValue] = [["lines": ["line-1", "line-4"], "radius": 5], ["corner": "point-3", "radius": "0.25 in"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let pair: [String]
        if let ls = p.lines {
            pair = try ls.map { try localID($0, in: s) }
        } else {
            let pid = try localID(p.corner!, in: s)
            let (x, y) = s.point(try s.entity(pid).id)
            let tol = 1e-7 * max(1, abs(x), abs(y))
            let meeting = s.orderedEntities.filter { e in
                e.kind == .line && e.points.contains { q in let (u, v) = s.point(q); return abs(u - x) <= tol && abs(v - y) <= tol }
            }
            guard meeting.count == 2 else {
                throw ForgeError(.invalidParams, "\(meeting.count) lines meet at \(pid); a corner needs exactly two", entities: meeting.map(\.id))
            }
            pair = meeting.map(\.id)
        }
        let before = Set(s.constraints.map(\.id))
        let created = try s.filletCorner(pair[0], pair[1], radius: p.radius.millimeters)
        let added = s.constraints.map(\.id).filter { !before.contains($0) && !$0.contains("#") }
        return finish(&ctx, doc, &s, created: created, constraints: added, infer: false)
    }
}

public enum SketchChamfer: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var lines: [String]
        public var distance: Length
        public var distance2: Length?
        public var angle: Angle?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "lines": "The two lines meeting at the corner (the first is the reference for distance and angle)",
            "distance": "Distance from the corner along the first line",
            "distance2": FieldDoc("Distance along the second line (distance–distance)", default: "same as distance"),
            "angle": "Angle between the first line and the chamfer (distance–angle); excludes distance2",
        ]
        public func validate() throws {
            guard lines.count == 2 else { throw ForgeError(.invalidParams, "give exactly two lines") }
            try requirePositive(distance, "distance")
            if let d2 = distance2 { try requirePositive(d2, "distance2") }
            if distance2 != nil && angle != nil { throw ForgeError(.invalidParams, "give distance2 or angle, not both") }
        }
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.chamfer"
    public static let summary = "Bevel the corner between two lines (distance–distance or distance–angle), keeping dimensions via a virtual sharp"
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .solverFailed]
    public static let examples: [JSONValue] = [["lines": ["line-1", "line-4"], "distance": 3], ["lines": ["line-1", "line-4"], "distance": 3, "angle": "30 deg"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let ids = try p.lines.map { try localID($0, in: s) }
        let before = Set(s.constraints.map(\.id))
        let created = try s.chamferCorner(ids[0], ids[1], distance: p.distance.millimeters, distance2: p.distance2?.millimeters, angle: p.angle?.radians)
        let added = s.constraints.map(\.id).filter { !before.contains($0) && !$0.contains("#") }
        return finish(&ctx, doc, &s, created: created, constraints: added, infer: false)
    }
}

public enum SketchAddSpline: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var through: [Point2]?
        public var poles: [Point2]?
        public var degree: Int?
        public var construction: Bool?
        public var infer: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "through": "Points the spline passes through, in order (interpolated with chord-length parameters)",
            "poles": "Control points instead of through points; the curve starts at the first and ends at the last",
            "degree": FieldDoc("Polynomial degree 1…5 (reduced to points − 1 when there are fewer points)", default: 3),
            "construction": constructionDoc, "infer": inferDoc,
        ]
        public func validate() throws {
            guard (through == nil) != (poles == nil) else { throw ForgeError(.invalidParams, "give either 'through' or 'poles'") }
            guard (through ?? poles ?? []).count >= 2 else { throw ForgeError(.invalidParams, "a spline needs at least 2 points") }
            if let d = degree, !(1...Sketch.maxSplineDegree).contains(d) {
                throw ForgeError(.invalidParams, "degree must be 1…\(Sketch.maxSplineDegree)")
            }
        }
    }
    public typealias Output = SketchEditResult

    public static let name = "sketch.add_spline"
    public static let summary = "Add a spline through points (or by control points); its control points are sketch points you can relate and dimension"
    public static let discussion = "Clamped uniform B-spline, identical in the sketch and in the solid. 'through' points are interpolated once; afterwards the spline is edited through its control points (listed in 'points'; interior ones are construction handles). Point-on-spline relations, spline trim/split/offset and curvature tools are not implemented yet."
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.invalidParams]
    public static let examples: [JSONValue] = [
        ["through": [[0, 0], [10, 5], [20, -5], [30, 0]]],
        ["poles": [[0, 0], [0, 20], [30, 20], [30, 0]], "degree": 3],
    ]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, s) = try ctx.sketchForEdit(p.sketch)
        let degree = p.degree ?? 3
        let id = p.through != nil
            ? try s.addSpline(through: p.through!.map(\.tuple), degree: degree, construction: p.construction ?? false)
            : try s.addSpline(poles: p.poles!.map(\.tuple), degree: degree, construction: p.construction ?? false)
        return finish(&ctx, doc, &s, created: [id], infer: p.infer ?? true)
    }
}

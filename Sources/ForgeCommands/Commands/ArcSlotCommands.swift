import ForgeCore
import ForgeSketch
import Foundation

/// A curved slot is the constant-width offset of an open circular centreline,
/// closed by semicircular ends. Both construction modes create the same editable geometry.
public enum SketchAddArcSlot: Command {
    public enum Mode: String, Codable, Sendable, CaseIterable, SchemaEnum {
        case center, threePoint = "three_point"
    }

    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var mode: Mode?
        public var center: Point2?
        public var start: Point2
        public var end: Point2
        public var through: Point2?
        public var width: Length
        public var clockwise: Bool?
        public var construction: Bool?

        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "mode": FieldDoc("center: centre plus two centreline endpoints; three_point: endpoints plus a point traversed by the centreline", default: "center"),
            "center": "Centre of the circular centreline (center mode only)",
            "start": "Start of the slot centreline, at the first semicircular end centre",
            "end": "End of the slot centreline, at the second semicircular end centre",
            "through": "Point on the circular centreline between start and end (three_point mode only); selects the minor or major arc",
            "width": "Full slot width, strictly smaller than the centreline diameter",
            "clockwise": FieldDoc("Traverse from start to end clockwise (center mode only)", default: false),
            "construction": constructionDoc,
        ]

        public func validate() throws {
            try requirePositive(width, "width")
            switch mode ?? .center {
            case .center:
                guard center != nil, through == nil else {
                    throw ForgeError(.invalidParams, "center mode needs center, start and end; through is only valid in three_point mode")
                }
            case .threePoint:
                guard through != nil, center == nil, clockwise == nil else {
                    throw ForgeError(.invalidParams, "three_point mode needs start, end and through; do not also give center or clockwise")
                }
            }
        }
    }

    public typealias Output = SketchEditResult
    public static let name = "sketch.add_arc_slot"
    public static let summary = "Add a centerpoint or three-point arc slot with concentric sides and tangent rounded ends"
    public static let discussion = "Creates four boundary arcs and one construction centreline arc with six remaining degrees of freedom. Centre-mode endpoints must have the same radius; clockwise selects traversal. Three-point mode follows the arc through the supplied third point. Rejects coincident/collinear points, collapsed inner radii and overlapping end caps. Curves remain editable using ordinary sketch dimensions and relations; no grouped Fix Slot/Equal Slots relation is implied."
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.invalidParams, .preconditionFailed, .sketchConflict, .sketchRedundant, .solverFailed]
    public static let examples: [JSONValue] = [
        ["center": [0, 0], "start": [20, 0], "end": [0, 20], "width": 4],
        ["mode": "three_point", "start": [20, 0], "end": [-20, 0], "through": [0, 20], "width": "4 mm"],
    ]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, sketch) = try ctx.sketchForEdit(p.sketch)
        let center: (Double, Double)
        let clockwise: Bool
        switch p.mode ?? .center {
        case .center:
            guard let c = p.center else { throw ForgeError(.invalidParams, "center is required") }
            center = c.tuple
            clockwise = p.clockwise ?? false
        case .threePoint:
            guard let through = p.through else { throw ForgeError(.invalidParams, "through is required") }
            (center, _) = try Sketch.circumcircle(p.start.tuple, through.tuple, p.end.tuple)
            let cross = (through.u - p.start.u) * (p.end.v - p.start.v) - (through.v - p.start.v) * (p.end.u - p.start.u)
            clockwise = cross < 0
        }
        let start = clockwise ? p.end.tuple : p.start.tuple
        let end = clockwise ? p.start.tuple : p.end.tuple
        let radius = hypot(start.0 - center.0, start.1 - center.1)
        let endRadius = hypot(end.0 - center.0, end.1 - center.1)
        let halfWidth = p.width.millimeters / 2
        let tolerance = max(1e-8, radius * 1e-9)
        guard radius.isFinite, endRadius.isFinite, center.0.isFinite, center.1.isFinite,
              radius > tolerance, abs(radius - endRadius) <= tolerance else {
            throw ForgeError(.invalidParams, "arc slot endpoints must have the same positive distance from the center")
        }
        guard halfWidth.isFinite, halfWidth > 0, radius - halfWidth > tolerance else {
            throw ForgeError(.invalidParams, "slot width must be smaller than twice the centreline radius")
        }
        var sweep = atan2(end.1 - center.1, end.0 - center.0) - atan2(start.1 - center.1, start.0 - center.0)
        if sweep < 0 { sweep += 2 * .pi }
        guard sweep > 1e-8, sweep < 2 * .pi - 1e-8 else {
            throw ForgeError(.invalidParams, "arc slot start and end must be different points")
        }
        // For major arcs the end caps face one another across the omitted arc. Avoid a
        // self-intersecting contour (and the zero-clearance touching case). For minor
        // arcs the outward half-caps face away from one another and may be very close.
        guard sweep <= .pi || hypot(end.0 - start.0, end.1 - start.1) > 2 * halfWidth + tolerance else {
            throw ForgeError(.invalidParams, "arc slot end caps overlap; reduce width or sweep")
        }
        func radial(_ point: (Double, Double), _ distance: Double) -> (Double, Double) {
            let length = hypot(point.0 - center.0, point.1 - center.1)
            return (center.0 + (point.0 - center.0) * distance / length,
                    center.1 + (point.1 - center.1) * distance / length)
        }
        let a = radial(start, radius), b = radial(end, radius)
        let outerA = radial(a, radius + halfWidth), outerB = radial(b, radius + halfWidth)
        let innerA = radial(a, radius - halfWidth), innerB = radial(b, radius - halfWidth)
        let construction = p.construction ?? false
        // Internal equal-radius rows yield to the composite's joins/tangencies/dimensions
        // during rank diagnosis, but remain enforced by the solver. This avoids duplicate
        // radial rows and ill-conditioned pivots near cardinal orientations after fixing
        // the centreline, without introducing any coordinate-axis-dependent relation.
        let outer = sketch.addArc(center: center, start: outerA, end: outerB, construction: construction, radiusYieldsToRelations: true)
        let endCap = sketch.addArc(center: b, start: outerB, end: innerB, construction: construction, radiusYieldsToRelations: true)
        let inner = sketch.addArc(center: center, start: innerA, end: innerB, construction: construction, radiusYieldsToRelations: true)
        let startCap = sketch.addArc(center: a, start: innerA, end: outerA, construction: construction, radiusYieldsToRelations: true)
        let axis = sketch.addArc(center: center, start: a, end: b, construction: true, radiusYieldsToRelations: true)
        func point(_ entity: String, _ index: Int) -> String { sketch.entities[entity]!.points[index] }
        var relations: [String] = []
        func relate(_ kind: ConstraintKind, _ entities: [String]) throws {
            relations.append(try sketch.addConstraint(kind, entities))
        }
        try relate(.coincident, [point(outer, 2), point(endCap, 1)])
        try relate(.coincident, [point(endCap, 2), point(inner, 2)])
        try relate(.coincident, [point(inner, 1), point(startCap, 1)])
        try relate(.coincident, [point(startCap, 2), point(outer, 1)])
        try relate(.concentric, [outer, inner])
        try relate(.concentric, [outer, axis])
        try relate(.coincident, [point(axis, 1), point(startCap, 0)])
        // The axis equal-radius row yields to these exact endpoint joins: its radius
        // equality follows from the concentric sides and four tangent semicircular caps.
        try relate(.coincident, [point(axis, 2), point(endCap, 0)])
        try relate(.tangent, [outer, endCap])
        try relate(.tangent, [inner, endCap])
        try relate(.tangent, [outer, startCap])
        try relate(.tangent, [inner, startCap])
        return finish(&ctx, doc, &sketch, created: [outer, endCap, inner, startCap, axis], constraints: relations, infer: false)
    }
}

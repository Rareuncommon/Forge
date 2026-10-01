import ForgeCore
import ForgeKernel
import ForgeSketch
import Foundation

public enum SketchConvertEntities: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var entities: [String]
        public var construction: Bool?
        public var fixed: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": sketchParamDoc,
            "entities": "Model edge or face references; faces convert all boundary edges, duplicate edges are included once",
            "construction": constructionDoc,
            "fixed": FieldDoc("Fix converted curves at their projected positions", default: true),
        ]
        public func validate() throws {
            guard !entities.isEmpty else { throw ForgeError(.invalidParams, "select at least one model edge or face") }
        }
    }
    public typealias Output = SketchEditResult
    public static let name = "sketch.convert_entities"
    public static let summary = "Project model edges or face boundaries into a sketch as independent curves"
    public static let discussion = "Creates exact orthogonal projections of straight edges and circles/arcs parallel to the sketch plane. Curves are detached snapshots: later source edits do not resize them. Curved edges oblique to the plane, ellipses, splines and degenerate projections are rejected atomically. Fixed by default; set fixed: false for editable geometry."
    public static let category = CommandCategory.sketch
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams, .unsupported, .referenceLost]
    public static let examples: [JSONValue] = [["entities": ["body-1/face-5"]], ["entities": ["body-1/edge-0"], "construction": true, "fixed": false]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var (doc, sketch) = try ctx.sketchForEdit(p.sketch)
        var seen = Set<String>()
        var edges: [Shape.EdgeInfo] = []
        for reference in p.entities {
            let ref = try EntityRef.parse(reference)
            guard ref.kind == .edge || ref.kind == .face else {
                throw ForgeError(.invalidParams, "select model edges or faces", entities: [reference])
            }
            let body = try doc.body(ref.body)
            for index in try doc.edgeIndices([reference], of: body) {
                if seen.insert("\(body.id)/edge-\(index)").inserted { edges.append(try body.shape.edge(index)) }
            }
        }
        func project(_ point: Vec3) -> (Double, Double) {
            let relative = point - sketch.plane.origin
            return (relative.dot(sketch.plane.xAxis), relative.dot(sketch.plane.yAxis))
        }
        var created: [String] = []
        var constraints: [String] = []
        for edge in edges {
            guard !edge.isDegenerate else { throw ForgeError(.unsupported, "a degenerate edge cannot be converted") }
            let start = project(edge.start), end = project(edge.end)
            let id: String
            switch edge.curveType {
            case .line:
                guard hypot(end.0 - start.0, end.1 - start.1) > 1e-7 else {
                    throw ForgeError(.unsupported, "an edge projects to a point on this sketch plane")
                }
                id = sketch.addLine(from: start, to: end, construction: p.construction ?? false)
            case .circle:
                guard let center3 = edge.circleCenter, let axis = edge.circleAxis, let radius = edge.circleRadius,
                      axis.cross(sketch.plane.normal).length < 1e-8 else {
                    throw ForgeError(.unsupported, "circular edges must be parallel to the sketch plane; oblique circle projection is not implemented")
                }
                let center = project(center3)
                if abs(edge.length - 2 * .pi * radius) <= max(1e-7, radius * 1e-8) {
                    id = sketch.addCircle(center: center, radius: radius, construction: p.construction ?? false)
                } else {
                    let mid = project(edge.midpoint)
                    func angle(_ point: (Double, Double)) -> Double { atan2(point.1 - center.1, point.0 - center.0) }
                    func positive(_ angle: Double) -> Double { let a = angle.truncatingRemainder(dividingBy: 2 * .pi); return a < 0 ? a + 2 * .pi : a }
                    let ccw = positive(angle(mid) - angle(start)) < positive(angle(end) - angle(start))
                    id = sketch.addArc(center: center, start: ccw ? start : end, end: ccw ? end : start, construction: p.construction ?? false)
                }
            default:
                throw ForgeError(.unsupported, "conversion supports straight edges and circular edges parallel to the sketch plane")
            }
            created.append(id)
            if p.fixed ?? true { constraints.append(try sketch.addConstraint(.fix, [id])) }
        }
        return finish(&ctx, doc, &sketch, created: created, constraints: constraints, infer: false)
    }
}

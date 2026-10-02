import ForgeCore
import ForgeKernel
import ForgeRender
import ForgeSketch
import Foundation

/// Read-only selection framing, shared by desktop and headless view workflows.
public enum ViewZoomToSelection: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var entities: [String]?
        public var camera: Camera?
        public var aspect: Double?
        public static let fieldDocs: [String: FieldDoc] = [
            "entities": FieldDoc("Explicit body/face/edge/vertex or sketch/entity references; [] frames nothing", default: "current selection"),
            "camera": "Current camera; omitted uses the standard isometric orthographic view. Returned camera can be passed as view.camera to render/pick.",
            "aspect": FieldDoc("Viewport width divided by height; must be finite and positive", default: 1),
        ]
        public func validate() throws {
            try camera?.validate()
            if let aspect, !(aspect.isFinite && aspect > 0) { throw ForgeError(.invalidParams, "aspect must be finite and positive") }
        }
    }
    public struct Output: Codable, Sendable {
        public var camera: Camera
        public var bounds: BoundingBox?
        public var framed: [String]
        public var skipped: [String]
    }
    public static let name = "view.zoom_to_selection"
    public static let summary = "Frame selected visible geometry while preserving camera orientation and projection"
    public static let discussion = "Returns a camera and union bounds without changing the document or selection. Empty/all-excluded selections leave the supplied camera unchanged. Hidden/isolation-excluded bodies, reference planes and sketch constraints are skipped. Body subshapes use tight kernel bounds; sketches use the same sampled polylines as the viewport, including independent points; whole sketches exclude the fixed origin and owned definition points. Point selections use a 1 mm minimum framing box. Rectangle zoom-to-area remains unsupported."
    public static let category = CommandCategory.view
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.invalidParams, .unknownEntity, .referenceLost, .kernelFailure]
    public static let examples: [JSONValue] = [[:], ["entities": ["body-1/face-0"], "aspect": 1.5]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        var camera = p.camera ?? Camera()
        if p.camera == nil { camera.setOrientation(.isometric) }
        var bounds: BoundingBox?
        var framed: [String] = [], skipped: [String] = []
        func include(_ box: BoundingBox) { bounds = bounds.map { $0.union(box) } ?? box }
        for reference in p.entities ?? doc.selection {
            let parts = reference.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if let head = parts.first, let sketch = doc.sketches[head] {
                let entities: [String]
                if parts.count == 1 {
                    // Whole-sketch framing includes drawn curves and independent points,
                    // not the fixed origin or owned construction/control points.
                    entities = sketch.orderedEntities.filter { $0.id != Sketch.originID && ($0.kind != .point || $0.owner == nil) }.map(\.id)
                }
                else if sketch.entities[parts[1]] != nil { entities = [parts[1]] }
                else if sketch.constraints.contains(where: { $0.id == parts[1] }) {
                    skipped.append(reference)
                    continue
                } else { throw ForgeError(.unknownEntity, "no sketch entity '\(reference)'", entities: [reference]) }
                var hadPoints = false
                for entity in entities {
                    for (u, v) in sketch.polyline(entity) {
                        let point = sketch.plane.point(u, v)
                        include(BoundingBox(min: point, max: point))
                        hadPoints = true
                    }
                }
                if hadPoints { framed.append(reference) } else { skipped.append(reference) }
                continue
            }
            if (reference.hasPrefix("plane-") && StandardPlane(rawValue: String(reference.dropFirst(6))) != nil) || doc.refPlanes[reference] != nil {
                skipped.append(reference)
                continue
            }
            let ref = try EntityRef.parse(reference)
            let body = try doc.body(ref.body)
            let boxes: [BoundingBox]
            switch ref.kind {
            case .body: boxes = [try body.shape.boundingBox()]
            case .face:
                boxes = try doc.faceIndices([reference], of: body, sets: true).map { try body.shape.subshape(.face, index: $0).boundingBox() }
            case .edge:
                boxes = try doc.edgeIndices([reference], of: body).map { try body.shape.subshape(.edge, index: $0).boundingBox() }
            case .vertex:
                guard let i = ref.index, i < (try body.shape.topology().vertices) else {
                    throw ForgeError(.unknownEntity, "no vertex '\(reference)'", entities: [reference])
                }
                let point = try body.shape.vertex(i)
                boxes = [BoundingBox(min: point, max: point)]
            }
            if doc.isBodyVisible(body.id) {
                for box in boxes { include(box) }
                framed.append(reference)
            } else { skipped.append(reference) }
        }
        if let bounds { camera.fitSelection(bounds, aspect: p.aspect ?? 1) }
        return Output(camera: camera, bounds: bounds, framed: framed, skipped: skipped)
    }
}

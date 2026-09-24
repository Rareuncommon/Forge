import ForgeCore
import ForgeKernel
import ForgeSketch
import Foundation

// Reference geometry (docs/research §2.2). Planes are features: they regenerate, and
// sketches on them follow.

public enum PlaneCreate: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var reference: String
        public var offset: Length?
        public var flip: Bool?
        public var name: String?
        public static let fieldDocs: [String: FieldDoc] = [
            "reference": "First reference: front, top, right, a reference plane, or a planar face (\"body-1/face-3\")",
            "offset": FieldDoc("Offset distance along the reference's normal (negative: the other side)", default: 0),
            "flip": FieldDoc("Flip the plane's normal", default: false),
            "name": FieldDoc("Display name", default: "Plane<n>"),
        ]
        public func validate() throws {}
    }
    public struct Output: Codable, Sendable {
        public var plane: String
        public var name: String
        public var origin: [Double]
        public var normal: [Double]
    }

    public static let name = "plane.create"
    public static let summary = "Reference plane offset from a standard plane, another plane or a planar face"
    public static let discussion = "Recorded as a Plane feature: when the face it references moves, the plane and the sketches on it move too. Angle, three-point and mid planes are not implemented yet."
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams]
    public static let examples: [JSONValue] = [["reference": "top", "offset": 25], ["reference": "body-1/face-4", "offset": 5]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        var plane = try doc.resolvePlacement(p.reference)
        if let o = p.offset { plane.origin = plane.origin + plane.normal * o.millimeters }
        if p.flip == true { plane.yAxis = plane.yAxis * -1 }
        let r = doc.addRefPlane(name: p.name, plane: plane)
        ctx.document = doc
        let n = r.plane.normal
        return Output(plane: r.id, name: r.name, origin: [r.plane.origin.x, r.plane.origin.y, r.plane.origin.z], normal: [n.x, n.y, n.z])
    }
}

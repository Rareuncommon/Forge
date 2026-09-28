import ForgeCore
import ForgeKernel
import Foundation

// Applied features (docs/research §2.5): Chamfer, Shell, Draft. Each is recorded as a
// feature (docs/adr/0011); their face and edge references are stored by persistent name
// (docs/adr/0002).

public enum ChamferType: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case equalDistance = "equal_distance", distanceDistance = "distance_distance", angleDistance = "angle_distance"
}

public enum BodyChamferEdges: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var body: String?
        public var edges: [String]
        public var type: ChamferType?
        public var distance: Length
        public var distance2: Length?
        public var angle: Angle?

        public static let fieldDocs: [String: FieldDoc] = [
            "body": FieldDoc("Body for bare edge indices", default: "taken from the references"),
            "edges": "Edge references (\"body-1/edge-3\") or indices; a face stands for all its edges; several bodies are allowed",
            "type": FieldDoc("equal_distance, distance_distance (distance on the first face of each edge, distance2 on the other) or angle_distance", default: "equal_distance"),
            "distance": "Chamfer distance (the first one)",
            "distance2": "Second distance, for distance_distance",
            "angle": "Chamfer angle from the first face, for angle_distance",
        ]
        public func validate() throws {
            try requirePositive(distance, "distance")
            guard !edges.isEmpty else { throw ForgeError(.invalidParams, "'edges' must not be empty") }
            switch type ?? .equalDistance {
            case .distanceDistance:
                guard let d2 = distance2 else { throw ForgeError(.invalidParams, "distance2 is required for distance_distance") }
                try requirePositive(d2, "distance2")
            case .angleDistance:
                guard let a = angle, a.radians > 0, a.radians < .pi / 2 else {
                    throw ForgeError(.invalidParams, "angle between 0 and 90 degrees is required for angle_distance")
                }
            case .equalDistance: break
            }
        }
    }
    public typealias Output = BodyResult

    public static let name = "body.chamfer_edges"
    public static let summary = "Chamfer edges of a body: equal distance, two distances, or angle and distance"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .kernelFailure]
    public static let examples: [JSONValue] = [
        ["body": "body-1", "edges": ["body-1/edge-0"], "distance": 1],
        ["body": "body-1", "edges": ["body-1/edge-0"], "type": "angle_distance", "distance": 2, "angle": "30 deg"],
    ]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        var changed: [String] = []
        for (b, idx) in try edgesByBody(p.edges, body: p.body, doc) {
            let shape: Shape
            do {
                switch p.type ?? .equalDistance {
                case .equalDistance: shape = try Kernel.chamfer(b.shape, edges: idx, distance: p.distance.millimeters)
                case .distanceDistance: shape = try Kernel.chamfer(b.shape, edges: idx, distance: p.distance.millimeters, distance2: p.distance2!.millimeters)
                case .angleDistance: shape = try Kernel.chamfer(b.shape, edges: idx, distance: p.distance.millimeters, angle: p.angle!.radians)
                }
            } catch var e as ForgeError {
                e.entities = idx.map { "\(b.id)/edge-\($0)" }
                throw e
            }
            try doc.replaceShape(of: b.id, with: try Naming.named(shape, [NamedShape(b)], feature: doc.currentFeature), producedBy: name)
            changed.append(b.id)
        }
        ctx.document = doc
        return Output(body: try BodySummary(try doc.body(changed[0])), bodies: changed.count > 1 ? changed : nil)
    }
}

public enum BodyShell: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var body: String
        public var faces: [String]?
        public var thickness: Length
        public var outward: Bool?

        public static let fieldDocs: [String: FieldDoc] = [
            "body": "Body to hollow",
            "faces": FieldDoc("Faces to remove (open); none gives a closed hollow body", default: "none"),
            "thickness": "Wall thickness",
            "outward": FieldDoc("Shell outward: the original body becomes the cavity", default: false),
        ]
        public func validate() throws { try requirePositive(thickness, "thickness") }
    }
    public typealias Output = BodyResult

    public static let name = "body.shell"
    public static let summary = "Shell: hollow a body to a wall thickness, removing the selected faces"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .kernelFailure]
    public static let examples: [JSONValue] = [["body": "body-1", "faces": ["body-1/face-5"], "thickness": 2]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let b = try doc.body(p.body)
        let idx = try doc.faceIndices(p.faces ?? [], of: b, sets: true)
        let shape: Shape
        do {
            shape = try Kernel.shell(b.shape, openFaces: idx, thickness: p.thickness.millimeters, outward: p.outward ?? false)
        } catch var e as ForgeError {
            e.entities = [b.id] + idx.map { "\(b.id)/face-\($0)" }
            throw e
        }
        let roles = NamingRoles(fromEdge: "rim", fromFace: "wall")
        try doc.replaceShape(of: b.id, with: try Naming.named(shape, [NamedShape(b)], feature: doc.currentFeature, roles: roles), producedBy: name)
        ctx.document = doc
        return Output(body: try BodySummary(try doc.body(b.id)))
    }
}

public enum BodyDraft: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var body: String
        public var neutralPlane: String
        public var faces: [String]
        public var angle: Angle
        public var reverse: Bool?

        enum CodingKeys: String, CodingKey {
            case body, faces, angle, reverse
            case neutralPlane = "neutral_plane"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "body": "Body to draft",
            "neutral_plane": "A planar face of the body: the faces keep their size there; the pull direction is its outward normal",
            "faces": "Faces to draft",
            "angle": "Draft angle",
            "reverse": FieldDoc("Reverse the pull direction", default: false),
        ]
        public func validate() throws {
            guard angle.radians > 0, angle.radians < .pi / 2 else { throw ForgeError(.invalidParams, "angle must be between 0 and 90 degrees") }
            guard !faces.isEmpty else { throw ForgeError(.invalidParams, "'faces' must not be empty") }
        }
    }
    public typealias Output = BodyResult

    public static let name = "body.draft"
    public static let summary = "Draft (neutral plane): taper faces by an angle about a neutral plane, as for molding"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .kernelFailure, .invalidParams]
    public static let examples: [JSONValue] = [["body": "body-1", "neutral_plane": "body-1/face-4", "faces": ["body-1/face-0", "body-1/face-1"], "angle": "3 deg"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let b = try doc.body(p.body)
        let neutral = try doc.faceIndices([p.neutralPlane], of: b, sets: false)[0]
        let info = try b.shape.face(neutral)
        guard info.surfaceType == .plane else {
            throw ForgeError(.invalidParams, "the neutral plane must be a planar face", entities: ["\(b.id)/face-\(neutral)"])
        }
        let idx = try doc.faceIndices(p.faces, of: b, sets: true)
        let pull = (p.reverse ?? false) ? info.normal * -1 : info.normal
        let shape: Shape
        do {
            shape = try Kernel.draft(b.shape, faces: idx, neutralOrigin: info.centroid, pull: pull, angle: p.angle.radians)
        } catch var e as ForgeError {
            e.entities = idx.map { "\(b.id)/face-\($0)" }
            throw e
        }
        try doc.replaceShape(of: b.id, with: try Naming.named(shape, [NamedShape(b)], feature: doc.currentFeature), producedBy: name)
        ctx.document = doc
        return Output(body: try BodySummary(try doc.body(b.id)))
    }
}

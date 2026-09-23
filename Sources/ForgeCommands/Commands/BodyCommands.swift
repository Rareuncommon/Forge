import ForgeCore
import ForgeKernel
import Foundation

// Direct body creation and modification (M0 kernel-level commands; see Document.swift).

func requirePositive(_ l: Length, _ name: String) throws {
    guard l.millimeters > 0 else {
        throw ForgeError(.invalidParams, "'\(name)' must be greater than zero (got \(l))", details: ["parameter": .string(name)])
    }
}

func requireNonZero(_ v: Vec3?, _ name: String) throws {
    if let v, v.length < 1e-12 {
        throw ForgeError(.invalidParams, "'\(name)' must be a non-zero direction", details: ["parameter": .string(name)])
    }
}

public enum BodyCreateBox: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var width: Length
        public var height: Length
        public var depth: Length
        public var origin: Point3?
        public var centered: Bool?
        public var name: String?
        public static let fieldDocs: [String: FieldDoc] = [
            "width": "Size along X",
            "height": "Size along Y",
            "depth": "Size along Z",
            "origin": FieldDoc("Minimum corner (or centre if 'centered')", default: [0, 0, 0]),
            "centered": FieldDoc("Treat 'origin' as the box centre", default: false),
            "name": FieldDoc("Body display name", default: "Body<n>"),
        ]
        public func validate() throws {
            try requirePositive(width, "width")
            try requirePositive(height, "height")
            try requirePositive(depth, "depth")
        }
    }
    public typealias Output = BodyResult

    public static let name = "body.create_box"
    public static let summary = "Create a rectangular block body"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let preconditions = ["An open document"]
    public static let errors: [ErrorCode] = [.preconditionFailed, .kernelFailure]
    public static let examples: [JSONValue] = [
        ["width": 100, "height": 50, "depth": 20],
        ["width": "2 in", "height": "1 in", "depth": "0.5 in", "origin": [0, 0, "-0.25 in"], "name": "Plate"],
    ]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let size = Vec3(p.width.millimeters, p.height.millimeters, p.depth.millimeters)
        let o = p.origin?.mm ?? .zero
        let shape = try Kernel.box(origin: p.centered == true ? o - size * 0.5 : o, size: size)
        let body = doc.addBody(name: p.name, shape: shape, producedBy: name)
        ctx.document = doc
        return Output(body: try BodySummary(body))
    }
}

public enum BodyCreateCylinder: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var radius: Length
        public var height: Length
        public var origin: Point3?
        public var axis: Vec3?
        public var name: String?
        public static let fieldDocs: [String: FieldDoc] = [
            "radius": "Cylinder radius",
            "height": "Length along the axis",
            "origin": FieldDoc("Centre of the base circle", default: [0, 0, 0]),
            "axis": FieldDoc("Axis direction", default: [0, 0, 1]),
            "name": FieldDoc("Body display name", default: "Body<n>"),
        ]
        public func validate() throws {
            try requirePositive(radius, "radius")
            try requirePositive(height, "height")
            try requireNonZero(axis, "axis")
        }
    }
    public typealias Output = BodyResult

    public static let name = "body.create_cylinder"
    public static let summary = "Create a solid cylinder body"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let preconditions = ["An open document"]
    public static let errors: [ErrorCode] = [.preconditionFailed, .kernelFailure]
    public static let examples: [JSONValue] = [["radius": 5, "height": 20], ["radius": "0.25 in", "height": 30, "axis": [1, 0, 0]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let shape = try Kernel.cylinder(
            origin: p.origin?.mm ?? .zero, axis: p.axis ?? .unitZ, radius: p.radius.millimeters, height: p.height.millimeters)
        let body = doc.addBody(name: p.name, shape: shape, producedBy: name)
        ctx.document = doc
        return Output(body: try BodySummary(body))
    }
}

public enum BodyCreateSphere: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var radius: Length
        public var center: Point3?
        public var name: String?
        public static let fieldDocs: [String: FieldDoc] = [
            "radius": "Sphere radius",
            "center": FieldDoc("Centre point", default: [0, 0, 0]),
            "name": FieldDoc("Body display name", default: "Body<n>"),
        ]
        public func validate() throws { try requirePositive(radius, "radius") }
    }
    public typealias Output = BodyResult

    public static let name = "body.create_sphere"
    public static let summary = "Create a solid sphere body"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let preconditions = ["An open document"]
    public static let errors: [ErrorCode] = [.preconditionFailed, .kernelFailure]
    public static let examples: [JSONValue] = [["radius": 10, "center": [0, 0, 0]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let shape = try Kernel.sphere(center: p.center?.mm ?? .zero, radius: p.radius.millimeters)
        let body = doc.addBody(name: p.name, shape: shape, producedBy: name)
        ctx.document = doc
        return Output(body: try BodySummary(body))
    }
}

public enum BodyCreateCone: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var baseRadius: Length
        public var topRadius: Length
        public var height: Length
        public var origin: Point3?
        public var axis: Vec3?
        public var name: String?

        enum CodingKeys: String, CodingKey {
            case height, origin, axis, name
            case baseRadius = "base_radius"
            case topRadius = "top_radius"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "base_radius": "Radius at the origin (may be 0 for a point)",
            "top_radius": "Radius at the far end (may be 0 for a point)",
            "height": "Length along the axis",
            "origin": FieldDoc("Centre of the base", default: [0, 0, 0]),
            "axis": FieldDoc("Axis direction", default: [0, 0, 1]),
            "name": FieldDoc("Body display name", default: "Body<n>"),
        ]
        public func validate() throws {
            try requirePositive(height, "height")
            try requireNonZero(axis, "axis")
            guard baseRadius.millimeters >= 0, topRadius.millimeters >= 0,
                baseRadius.millimeters + topRadius.millimeters > 0, baseRadius != topRadius
            else {
                throw ForgeError(.invalidParams, "cone radii must be >= 0, not both zero, and different (use body.create_cylinder for equal radii)")
            }
        }
    }
    public typealias Output = BodyResult

    public static let name = "body.create_cone"
    public static let summary = "Create a solid cone or truncated cone (frustum) body"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let preconditions = ["An open document"]
    public static let errors: [ErrorCode] = [.preconditionFailed, .kernelFailure]
    public static let examples: [JSONValue] = [["base_radius": 10, "top_radius": 0, "height": 20]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let shape = try Kernel.cone(
            origin: p.origin?.mm ?? .zero, axis: p.axis ?? .unitZ, radius1: p.baseRadius.millimeters, radius2: p.topRadius.millimeters,
            height: p.height.millimeters)
        let body = doc.addBody(name: p.name, shape: shape, producedBy: name)
        ctx.document = doc
        return Output(body: try BodySummary(body))
    }
}

public enum BodyCreateTorus: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var majorRadius: Length
        public var minorRadius: Length
        public var origin: Point3?
        public var axis: Vec3?
        public var name: String?

        enum CodingKeys: String, CodingKey {
            case origin, axis, name
            case majorRadius = "major_radius"
            case minorRadius = "minor_radius"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "major_radius": "Distance from the axis to the tube centre",
            "minor_radius": "Tube radius (must be smaller than major_radius)",
            "origin": FieldDoc("Centre", default: [0, 0, 0]),
            "axis": FieldDoc("Axis of revolution", default: [0, 0, 1]),
            "name": FieldDoc("Body display name", default: "Body<n>"),
        ]
        public func validate() throws {
            try requirePositive(majorRadius, "major_radius")
            try requirePositive(minorRadius, "minor_radius")
            try requireNonZero(axis, "axis")
            guard minorRadius.millimeters < majorRadius.millimeters else {
                throw ForgeError(.invalidParams, "minor_radius (\(minorRadius)) must be smaller than major_radius (\(majorRadius))")
            }
        }
    }
    public typealias Output = BodyResult

    public static let name = "body.create_torus"
    public static let summary = "Create a solid torus body"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let preconditions = ["An open document"]
    public static let errors: [ErrorCode] = [.preconditionFailed, .kernelFailure]
    public static let examples: [JSONValue] = [["major_radius": 20, "minor_radius": 4]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let shape = try Kernel.torus(
            origin: p.origin?.mm ?? .zero, axis: p.axis ?? .unitZ, majorRadius: p.majorRadius.millimeters, minorRadius: p.minorRadius.millimeters)
        let body = doc.addBody(name: p.name, shape: shape, producedBy: name)
        ctx.document = doc
        return Output(body: try BodySummary(body))
    }
}

public enum BodyBoolean: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var operation: Kernel.BooleanOp
        public var target: String
        public var tool: String
        public var keepTool: Bool?

        enum CodingKeys: String, CodingKey {
            case operation, target, tool
            case keepTool = "keep_tool"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "operation": "fuse (add), cut (subtract tool from target) or common (intersect)",
            "target": "Body that receives the result (keeps its id)",
            "tool": "Body combined with the target",
            "keep_tool": FieldDoc("Keep the tool body instead of consuming it", default: false),
        ]
    }
    public struct Output: Codable, Sendable {
        public var body: BodySummary
        public var consumed: [String]
    }

    public static let name = "body.boolean"
    public static let summary = "Combine two bodies: fuse, cut or common (intersect)"
    public static let discussion = "The result replaces the target body (same id); coplanar faces are merged. The tool body is deleted unless keep_tool is true."
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let preconditions = ["Target and tool are distinct bodies in the document"]
    public static let errors: [ErrorCode] = [.unknownEntity, .booleanFailed, .emptyResult]
    public static let examples: [JSONValue] = [["operation": "cut", "target": "body-1", "tool": "body-2"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let target = try doc.body(p.target), tool = try doc.body(p.tool)
        guard target.id != tool.id else {
            throw ForgeError(.invalidParams, "target and tool must be different bodies", entities: [target.id])
        }
        let result: Shape
        do {
            result = try Kernel.boolean(p.operation, target.shape, tool.shape)
        } catch var e as ForgeError {
            e.entities = [target.id, tool.id]
            if e.code == .emptyResult {
                e.suggestions.append(SuggestedFix(description: "Measure the gap between the bodies", command: "query.measure", params: ["from": .string(target.id), "to": .string(tool.id)]))
            }
            throw e
        }
        try doc.replaceShape(of: target.id, with: result, producedBy: name)
        var consumed: [String] = []
        if p.keepTool != true {
            try doc.removeBody(tool.id)
            consumed.append(tool.id)
        }
        ctx.document = doc
        return Output(body: try BodySummary(try doc.body(target.id)), consumed: consumed)
    }
}

public struct RotationParams: Codable, Sendable, SchemaDocumented {
    public var axis: Vec3
    public var angle: Angle
    public var origin: Point3?
    public static let fieldDocs: [String: FieldDoc] = [
        "axis": "Rotation axis direction",
        "angle": "Rotation angle (right-hand rule)",
        "origin": FieldDoc("Point the axis passes through", default: [0, 0, 0]),
    ]
}

public enum BodyTransform: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var body: String
        public var translate: Point3?
        public var rotate: RotationParams?
        public var copy: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "body": "Body to move",
            "translate": "Translation vector (applied after rotation)",
            "rotate": "Rotation about an axis",
            "copy": FieldDoc("Create a transformed copy instead of moving the body", default: false),
        ]
        public func validate() throws {
            guard translate != nil || rotate != nil else {
                throw ForgeError(.invalidParams, "give 'translate' and/or 'rotate'")
            }
            try requireNonZero(rotate?.axis, "rotate.axis")
        }
    }
    public typealias Output = BodyResult

    public static let name = "body.transform"
    public static let summary = "Move/rotate a body, or create a moved copy"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .kernelFailure]
    public static let examples: [JSONValue] = [
        ["body": "body-1", "translate": [10, 0, 0]],
        ["body": "body-1", "rotate": ["axis": [0, 0, 1], "angle": "90 deg"], "copy": true],
    ]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let b = try doc.body(p.body)
        var shape = b.shape
        if let r = p.rotate {
            shape = try Kernel.transform(shape, .rotation(axis: r.axis, angle: r.angle.radians, origin: r.origin?.mm ?? .zero))
        }
        if let t = p.translate {
            shape = try Kernel.transform(shape, .translation(t.mm))
        }
        let out: Body
        if p.copy == true {
            out = doc.addBody(name: "\(b.name)-copy", shape: shape, producedBy: name)
        } else {
            try doc.replaceShape(of: b.id, with: shape, producedBy: name)
            out = try doc.body(b.id)
        }
        ctx.document = doc
        return Output(body: try BodySummary(out))
    }
}

/// Resolve edge references ("body-1/edge-3" or bare index "3") against a body.
func resolveEdges(_ refs: [String], body: Body) throws -> [Int] {
    let count = try body.shape.topology().edges
    return try refs.map { r in
        let idx: Int
        if let i = Int(r) {
            idx = i
        } else {
            let ref = try EntityRef.parse(r)
            guard ref.kind == .edge, ref.body == body.id, let i = ref.index else {
                throw ForgeError(.invalidParams, "'\(r)' is not an edge of \(body.id)", entities: [r])
            }
            idx = i
        }
        guard idx >= 0, idx < count else {
            throw ForgeError(.unknownEntity, "\(body.id) has no edge \(idx) (it has \(count) edges)", entities: ["\(body.id)/edge-\(idx)"],
                             suggestions: [SuggestedFix(description: "List the body's edges", command: "query.edges", params: ["body": .string(body.id)])])
        }
        return idx
    }
}

public enum BodyFilletEdges: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var body: String
        public var edges: [String]
        public var radius: Length
        public static let fieldDocs: [String: FieldDoc] = [
            "body": "Body to fillet",
            "edges": "Edge references (\"body-1/edge-3\") or indices (\"3\")",
            "radius": "Constant fillet radius",
        ]
        public func validate() throws {
            try requirePositive(radius, "radius")
            guard !edges.isEmpty else { throw ForgeError(.invalidParams, "'edges' must not be empty") }
        }
    }
    public typealias Output = BodyResult

    public static let name = "body.fillet_edges"
    public static let summary = "Round edges of a body with a constant-radius fillet"
    public static let discussion = "Kernel-level fillet on transient edge indices. The parametric Fillet feature with persistent references arrives with the feature tree (M2)."
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .kernelFailure]
    public static let examples: [JSONValue] = [["body": "body-1", "edges": ["body-1/edge-0"], "radius": 2]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let b = try doc.body(p.body)
        let idx = try resolveEdges(p.edges, body: b)
        let shape: Shape
        do {
            shape = try Kernel.fillet(b.shape, edges: idx, radius: p.radius.millimeters)
        } catch var e as ForgeError {
            e.entities = idx.map { "\(b.id)/edge-\($0)" }
            e.suggestions.append(SuggestedFix(description: "Try a smaller radius", command: name, params: ["body": .string(b.id), "edges": .array(p.edges.map { .string($0) }), "radius": .number(p.radius.millimeters / 2)]))
            throw e
        }
        try doc.replaceShape(of: b.id, with: shape, producedBy: name)
        ctx.document = doc
        return Output(body: try BodySummary(try doc.body(b.id)))
    }
}

public enum BodyDelete: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var body: String
        public static let fieldDocs: [String: FieldDoc] = ["body": "Body id or unique name"]
    }
    public struct Output: Codable, Sendable { public var deleted: String }

    public static let name = "body.delete"
    public static let summary = "Delete a body"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let b = try doc.body(p.body)
        try doc.removeBody(b.id)
        ctx.document = doc
        return Output(deleted: b.id)
    }
}

public enum BodyRename: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var body: String
        public var name: String
        public static let fieldDocs: [String: FieldDoc] = ["body": "Body id or unique name", "name": "New display name"]
        public func validate() throws {
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ForgeError(.invalidParams, "name must not be empty") }
        }
    }
    public typealias Output = BodyResult

    public static let name = "body.rename"
    public static let summary = "Rename a body"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let b = try doc.body(p.body)
        try doc.renameBody(b.id, to: p.name)
        ctx.document = doc
        return Output(body: try BodySummary(try doc.body(b.id)))
    }
}


import ForgeCore
import ForgeKernel
import ForgeSketch
import Foundation

// Linear Pattern, Circular Pattern and Mirror of features (docs/research §2.7). A pattern
// repeats the tool of each seed feature — the extrusion, revolution or holes — at the
// instance placements, and combines it the way the seed does (merged boss, cut, holes). It
// is recorded as a feature, so it follows the seed when either regenerates.

enum PatternSeeds {
    static let supported: Set<String> = ["body.extrude", "body.revolve", "body.hole"]

    /// Re-run each seed with the given instance placements only.
    static func apply(_ features: [String], _ transforms: [Transform3], _ ctx: inout CommandContext) throws -> [String] {
        guard !transforms.isEmpty else { throw ForgeError(.invalidParams, "the pattern has no instances besides the seed") }
        var doc = try ctx.requireDocument()
        var changed: [String] = []
        for ref in features {
            let i = try doc.featureIndex(ref)
            let seed = doc.features[i]
            guard supported.contains(seed.command) else {
                throw ForgeError(
                    .unsupported, "\(seed.name) cannot be patterned yet: patterns repeat extrusions, revolutions and Hole Wizard holes",
                    entities: [seed.id])
            }
            guard var p = seed.params.objectValue else { continue }
            p["instances"] = .array(transforms.map { .array($0.m.map { .number($0) }) })
            p["instances_only"] = true
            // Boss instances join the body they touch, as in SolidWorks.
            if seed.command != "body.hole" && p["operation"]?.stringValue != "cut" { p["merge"] = true }
            p.removeValue(forKey: "name")
            let d = try ctx.registry.descriptor(seed.command)
            ctx.document = doc
            let out = try d.invoke(.object(p), doc.units, &ctx)
            doc = ctx.document
            for id in (out["bodies"]?.arrayValue?.compactMap(\.stringValue) ?? []) + [out["body"]?["id"]?.stringValue].compactMap({ $0 })
            where !changed.contains(id) {
                changed.append(id)
            }
        }
        return changed
    }

    /// A direction: x/y/z (optionally -x…), a linear edge ("body-1/edge-3"), a sketch line
    /// ("sketch-1/line-2") or "dx, dy, dz".
    static func direction(_ s: String, _ doc: Document) throws -> Vec3 {
        let line = try axis(s, doc)
        return line.direction
    }

    /// An axis (a line through a point): x/y/z through the origin, a linear edge or a sketch line.
    static func axis(_ s: String, _ doc: Document) throws -> (origin: Vec3, direction: Vec3) {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        let sign: Double = t.hasPrefix("-") ? -1 : 1
        switch t.trimmingCharacters(in: CharacterSet(charactersIn: "-")) {
        case "x": return (.zero, .unitX * sign)
        case "y": return (.zero, .unitY * sign)
        case "z": return (.zero, .unitZ * sign)
        default: break
        }
        let parts = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 3 {
            let v = Vec3(parts[0], parts[1], parts[2])
            guard v.length > 1e-12 else { throw ForgeError(.invalidParams, "the direction is zero") }
            return (.zero, v.normalized)
        }
        if let r = EntityRef(parsing: s), r.kind == .edge, let i = r.index {
            let e = try doc.body(r.body).shape.edge(i)
            guard e.curveType == .line else { throw ForgeError(.invalidParams, "\(s) is not a straight edge", entities: [s]) }
            return (e.start, (e.end - e.start).normalized)
        }
        let sp = s.split(separator: "/").map(String.init)
        if sp.count == 2, let sk = doc.sketches[sp[0]], let e = sk.entities[sp[1]], e.kind == .line {
            let a = sk.point(e.points[0]), b = sk.point(e.points[1])
            let pa = sk.plane.point(a.0, a.1), pb = sk.plane.point(b.0, b.1)
            return (pa, (pb - pa).normalized)
        }
        throw ForgeError(.invalidParams, "'\(s)' is not a direction (x, y, z, a straight edge, a sketch line or \"dx, dy, dz\")", entities: [s])
    }
}

public struct PatternOutput: Codable, Sendable {
    public var instances: Int
    public var bodies: [String]
}

public enum PatternLinear: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var features: [String]
        public var direction: String
        public var spacing: Length
        public var count: Int
        public var reverse: Bool?
        public var direction2: String?
        public var spacing2: Length?
        public var count2: Int?
        public static let fieldDocs: [String: FieldDoc] = [
            "features": "Features to pattern (extrusions, revolutions, Hole Wizard holes), by id or name",
            "direction": "Direction 1: x, y, z (-x…), a straight edge, a sketch line or \"dx, dy, dz\"",
            "spacing": "Distance between instances",
            "count": "Number of instances in Direction 1, including the seed",
            "reverse": FieldDoc("Reverse Direction 1", default: false),
            "direction2": "Optional Direction 2",
            "spacing2": "Spacing in Direction 2",
            "count2": FieldDoc("Instances in Direction 2, including the seed row", default: 1),
        ]
        public func validate() throws {
            try requirePositive(spacing, "spacing")
            guard count >= 1, (count2 ?? 1) >= 1, count * (count2 ?? 1) >= 2, count * (count2 ?? 1) <= 1000 else {
                throw ForgeError(.invalidParams, "the pattern needs 2 to 1000 instances")
            }
            guard !features.isEmpty else { throw ForgeError(.invalidParams, "choose the features to pattern") }
            if direction2 != nil, (count2 ?? 1) > 1, spacing2 == nil { throw ForgeError(.invalidParams, "spacing2 is required with direction2") }
        }
    }
    public typealias Output = PatternOutput

    public static let name = "pattern.linear"
    public static let summary = "Linear Pattern of features along one or two directions"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.invalidParams, .unknownEntity, .unsupported]
    public static let examples: [JSONValue] = [
        ["features": ["M6 Clearance Hole1"], "direction": "x", "spacing": 20, "count": 4],
        ["features": ["Boss-Extrude2"], "direction": "x", "spacing": 15, "count": 3, "direction2": "y", "spacing2": 15, "count2": 2],
    ]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let d1 = try PatternSeeds.direction(p.direction, doc) * ((p.reverse ?? false) ? -1 : 1)
        let d2 = try p.direction2.map { try PatternSeeds.direction($0, doc) }
        var ts: [Transform3] = []
        for i in 0..<p.count {
            for j in 0..<(p.count2 ?? 1) where i != 0 || j != 0 {
                var v = d1 * (Double(i) * p.spacing.millimeters)
                if let d2, let s2 = p.spacing2 { v = v + d2 * (Double(j) * s2.millimeters) }
                ts.append(.translation(v))
            }
        }
        let bodies = try PatternSeeds.apply(p.features, ts, &ctx)
        return Output(instances: ts.count + 1, bodies: bodies)
    }
}

public enum PatternCircular: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var features: [String]
        public var axis: String
        public var count: Int
        public var angle: Angle?
        public var equalSpacing: Bool?
        public var reverse: Bool?

        enum CodingKeys: String, CodingKey {
            case features, axis, count, angle, reverse
            case equalSpacing = "equal_spacing"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "features": "Features to pattern, by id or name",
            "axis": "Axis: x, y, z (through the origin), a straight edge or a sketch line",
            "count": "Number of instances, including the seed",
            "angle": FieldDoc("Total angle with equal spacing, or the angle between instances", default: "360 deg"),
            "equal_spacing": FieldDoc("Spread the instances evenly over the angle", default: true),
            "reverse": FieldDoc("Reverse the direction of rotation", default: false),
        ]
        public func validate() throws {
            guard count >= 2, count <= 1000 else { throw ForgeError(.invalidParams, "count must be 2 to 1000") }
            guard !features.isEmpty else { throw ForgeError(.invalidParams, "choose the features to pattern") }
            if let a = angle, a.radians <= 0 { throw ForgeError(.invalidParams, "angle must be positive") }
        }
    }
    public typealias Output = PatternOutput

    public static let name = "pattern.circular"
    public static let summary = "Circular Pattern of features about an axis"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.invalidParams, .unknownEntity, .unsupported]
    public static let examples: [JSONValue] = [["features": ["M6 Clearance Hole1"], "axis": "z", "count": 6]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let ax = try PatternSeeds.axis(p.axis, doc)
        let total = p.angle?.radians ?? 2 * .pi
        let full = abs(total - 2 * .pi) < 1e-9
        let step = (p.equalSpacing ?? true) ? (full ? total / Double(p.count) : total / Double(p.count - 1)) : total
        let s: Double = (p.reverse ?? false) ? -1 : 1
        let ts = (1..<p.count).map { Transform3.rotation(axis: ax.direction, angle: s * step * Double($0), origin: ax.origin) }
        let bodies = try PatternSeeds.apply(p.features, ts, &ctx)
        return Output(instances: p.count, bodies: bodies)
    }
}

public enum PatternMirror: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var features: [String]
        public var plane: String
        public static let fieldDocs: [String: FieldDoc] = [
            "features": "Features to mirror, by id or name",
            "plane": "Mirror plane: front, top, right, a reference plane or a planar face",
        ]
        public func validate() throws {
            guard !features.isEmpty else { throw ForgeError(.invalidParams, "choose the features to mirror") }
        }
    }
    public typealias Output = PatternOutput

    public static let name = "pattern.mirror"
    public static let summary = "Mirror features about a plane or planar face"
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.invalidParams, .unknownEntity, .unsupported]
    public static let examples: [JSONValue] = [["features": ["Boss-Extrude2"], "plane": "right"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let plane = try doc.resolvePlacement(p.plane)
        let bodies = try PatternSeeds.apply(p.features, [.reflection(origin: plane.origin, normal: plane.normal)], &ctx)
        return Output(instances: 2, bodies: bodies)
    }
}

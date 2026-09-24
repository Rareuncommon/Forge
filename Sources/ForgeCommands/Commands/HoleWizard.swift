import ForgeCore
import ForgeKernel
import ForgeSketch
import Foundation

// Hole Wizard (docs/research §2.6): standard holes at the points of a sketch, drilled into
// the bodies below the sketch plane. ISO metric sizes; clearance diameters from ISO 273,
// counterbores for ISO 4762 socket head cap screws, countersinks (90°) for ISO 10642, tap
// drills for coarse threads (ISO 261 / ISO 2306).

public enum HoleType: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case hole, counterbore, countersink, tapped
}

public enum HoleFit: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case close, normal, loose
}

public enum HoleEnd: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case blind, throughAll = "through_all"
}

/// One ISO metric size: clearance (close, normal, loose), counterbore, countersink, tap drill.
struct ISOHoleSize: Sendable {
    let name: String
    let clearance: (close: Double, normal: Double, loose: Double)
    let counterbore: (diameter: Double, depth: Double)
    let countersink: Double
    let tapDrill: Double
    let pitch: Double

    static let table: [ISOHoleSize] = [
        ISOHoleSize(name: "M2", clearance: (2.2, 2.4, 2.6), counterbore: (4.4, 2.3), countersink: 4.4, tapDrill: 1.6, pitch: 0.4),
        ISOHoleSize(name: "M2.5", clearance: (2.7, 2.9, 3.1), counterbore: (5.4, 2.8), countersink: 5.5, tapDrill: 2.05, pitch: 0.45),
        ISOHoleSize(name: "M3", clearance: (3.2, 3.4, 3.6), counterbore: (6.5, 3.3), countersink: 6.72, tapDrill: 2.5, pitch: 0.5),
        ISOHoleSize(name: "M4", clearance: (4.3, 4.5, 4.8), counterbore: (8.0, 4.4), countersink: 8.96, tapDrill: 3.3, pitch: 0.7),
        ISOHoleSize(name: "M5", clearance: (5.3, 5.5, 5.8), counterbore: (10.0, 5.4), countersink: 11.2, tapDrill: 4.2, pitch: 0.8),
        ISOHoleSize(name: "M6", clearance: (6.4, 6.6, 7.0), counterbore: (11.0, 6.5), countersink: 13.44, tapDrill: 5.0, pitch: 1.0),
        ISOHoleSize(name: "M8", clearance: (8.4, 9.0, 10.0), counterbore: (15.0, 8.6), countersink: 17.92, tapDrill: 6.8, pitch: 1.25),
        ISOHoleSize(name: "M10", clearance: (10.5, 11.0, 12.0), counterbore: (18.0, 10.8), countersink: 22.4, tapDrill: 8.5, pitch: 1.5),
        ISOHoleSize(name: "M12", clearance: (13.0, 13.5, 14.5), counterbore: (20.0, 13.0), countersink: 26.88, tapDrill: 10.2, pitch: 1.75),
        ISOHoleSize(name: "M16", clearance: (17.0, 17.5, 18.5), counterbore: (26.0, 17.5), countersink: 33.6, tapDrill: 14.0, pitch: 2.0),
        ISOHoleSize(name: "M20", clearance: (21.0, 22.0, 24.0), counterbore: (33.0, 21.5), countersink: 40.32, tapDrill: 17.5, pitch: 2.5),
    ]

    static func named(_ s: String) -> ISOHoleSize? { table.first { $0.name.lowercased() == s.lowercased() } }
}

public enum BodyHole: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String
        public var type: HoleType?
        public var size: String?
        public var fit: HoleFit?
        public var diameter: Length?
        public var endCondition: HoleEnd?
        public var depth: Length?
        public var drillPoint: Bool?
        public var counterboreDiameter: Length?
        public var counterboreDepth: Length?
        public var countersinkDiameter: Length?
        public var threadDepth: Length?
        public var reverse: Bool?
        public var scope: [String]?
        public var instances: [[Double]]?
        public var instancesOnly: Bool?

        enum CodingKeys: String, CodingKey {
            case sketch, type, size, fit, diameter, depth, reverse, scope, instances
            case instancesOnly = "instances_only"
            case endCondition = "end_condition"
            case drillPoint = "drill_point"
            case counterboreDiameter = "counterbore_diameter"
            case counterboreDepth = "counterbore_depth"
            case countersinkDiameter = "countersink_diameter"
            case threadDepth = "thread_depth"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": "Sketch whose points (not construction, not the origin) are the hole centres; its plane is where the holes start",
            "type": FieldDoc("hole, counterbore, countersink or tapped", default: "hole"),
            "size": "ISO metric size: M2, M2.5, M3, M4, M5, M6, M8, M10, M12, M16, M20",
            "fit": FieldDoc("Clearance fit for hole, counterbore and countersink: close, normal or loose (ISO 273)", default: "normal"),
            "diameter": "Explicit hole diameter (overrides the size's)",
            "end_condition": FieldDoc("blind or through_all", default: "through_all"),
            "depth": "Hole depth for blind (to the shoulder of the drill point)",
            "drill_point": FieldDoc("Blind holes end in a 118° drill point", default: true),
            "counterbore_diameter": "Overrides the counterbore diameter (ISO 4762)",
            "counterbore_depth": "Overrides the counterbore depth",
            "countersink_diameter": "Overrides the countersink diameter (90°, ISO 10642)",
            "thread_depth": "Tapped holes: thread depth (recorded as the cosmetic thread; the hole is the tap drill)",
            "reverse": FieldDoc("Drill along the sketch normal instead of against it", default: false),
            "scope": FieldDoc("Bodies the holes cut", default: "all bodies"),
            "instances": "Pattern instances: extra placements of the same holes, as 3×4 row-major transforms",
            "instances_only": FieldDoc("Drill only the instances (used by pattern.* features)", default: false),
        ]
        public func validate() throws {
            guard size != nil || diameter != nil else { throw ForgeError(.invalidParams, "give a size (M6…) or a diameter") }
            if let s = size, ISOHoleSize.named(s) == nil {
                throw ForgeError(.invalidParams, "unknown size '\(s)'; ISO sizes: \(ISOHoleSize.table.map(\.name).joined(separator: ", "))")
            }
            if let d = diameter { try requirePositive(d, "diameter") }
            if (endCondition ?? .throughAll) == .blind {
                guard let d = depth else { throw ForgeError(.invalidParams, "depth is required for a blind hole") }
                try requirePositive(d, "depth")
            }
            if (type ?? .hole) == .counterbore && size == nil && (counterboreDiameter == nil || counterboreDepth == nil) {
                throw ForgeError(.invalidParams, "a counterbore without a size needs counterbore_diameter and counterbore_depth")
            }
            if (type ?? .hole) == .countersink && size == nil && countersinkDiameter == nil {
                throw ForgeError(.invalidParams, "a countersink without a size needs countersink_diameter")
            }
        }
    }
    public struct Output: Codable, Sendable {
        public var bodies: [String]
        public var holes: Int
        /// Diameters actually used (mm).
        public var diameter: Double
        public var counterbore: [Double]?
        public var countersink: Double?
        /// Tapped holes: the thread, e.g. "M6x1.0", and its depth.
        public var thread: String?
    }

    public static let name = "body.hole"
    public static let summary = "Hole Wizard: clearance, counterbore, countersink or tapped holes at the points of a sketch"
    public static let discussion = "ISO metric sizes (ISO 273 clearance fits, ISO 4762 counterbores, 90° countersinks for ISO 10642, coarse tap drills). The holes start at the sketch plane and go into the material (against the sketch normal unless reverse). Tapped holes are drilled to the tap drill; the thread is recorded, not modelled (cosmetic)."
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.invalidParams, .unknownEntity, .emptyResult, .kernelFailure]
    public static let examples: [JSONValue] = [
        ["sketch": "sketch-2", "type": "counterbore", "size": "M6"],
        ["sketch": "sketch-2", "size": "M4", "end_condition": "blind", "depth": 12],
        ["sketch": "sketch-2", "type": "tapped", "size": "M8", "end_condition": "blind", "depth": 16, "thread_depth": 12],
    ]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let sk = try doc.sketch(p.sketch)
        let centres = sk.orderedEntities.filter { $0.kind == .point && !$0.construction && $0.owner == nil && $0.id != Sketch.originID }
        guard !centres.isEmpty else {
            throw ForgeError(
                .preconditionFailed, "sketch \(sk.id) has no points to place holes at", entities: [sk.id],
                suggestions: [SuggestedFix(description: "Add a point for each hole", command: "sketch.add_point", params: ["sketch": .string(sk.id), "at": [0, 0]])])
        }
        let type = p.type ?? .hole
        let iso = p.size.flatMap(ISOHoleSize.named)
        let fit = p.fit ?? .normal
        let d: Double = p.diameter?.millimeters ?? {
            guard let iso else { return 0 }
            if type == .tapped { return iso.tapDrill }
            switch fit {
            case .close: return iso.clearance.close
            case .normal: return iso.clearance.normal
            case .loose: return iso.clearance.loose
            }
        }()
        let dir = sk.plane.normal * ((p.reverse ?? false) ? 1 : -1)
        // Depth: blind, or through every body in scope along the drilling direction.
        let depth: Double
        if (p.endCondition ?? .throughAll) == .blind {
            depth = p.depth!.millimeters
        } else {
            let bodies = try FeatureScope.bodies(doc, p.scope)
            var far = 0.0
            for b in bodies {
                let bb = try b.shape.boundingBox()
                for x in [bb.min.x, bb.max.x] { for y in [bb.min.y, bb.max.y] { for z in [bb.min.z, bb.max.z] {
                    far = max(far, (Vec3(x, y, z) - sk.plane.origin).dot(dir))
                } } }
            }
            guard far > 1e-9 else { throw ForgeError(.emptyResult, "there is no material to drill on that side of the sketch plane; try reverse") }
            depth = far + 1
        }
        var cbore: (Double, Double)?
        var csink: Double?
        switch type {
        case .counterbore:
            cbore = (p.counterboreDiameter?.millimeters ?? iso!.counterbore.diameter, p.counterboreDepth?.millimeters ?? iso!.counterbore.depth)
            guard cbore!.0 > d, cbore!.1 < depth else { throw ForgeError(.invalidParams, "the counterbore must be wider than the hole and shallower than it") }
        case .countersink:
            csink = p.countersinkDiameter?.millimeters ?? iso!.countersink
            guard csink! > d else { throw ForgeError(.invalidParams, "the countersink must be wider than the hole") }
        default:
            break
        }
        let drillPoint = (p.endCondition ?? .throughAll) == .blind && (p.drillPoint ?? true)
        var tool: Shape?
        for c in centres {
            let (u, v) = sk.point(c.id)
            let top = sk.plane.point(u, v)
            var parts: [Shape] = [try Kernel.cylinder(origin: top, axis: dir, radius: d / 2, height: depth)]
            if drillPoint {
                // 118° point: height r / tan 59°.
                parts.append(try Kernel.cone(origin: top + dir * depth, axis: dir, radius1: d / 2, radius2: 0, height: d / 2 / tan(59 * Double.pi / 180)))
            }
            if let (cd, ch) = cbore { parts.append(try Kernel.cylinder(origin: top, axis: dir, radius: cd / 2, height: ch)) }
            if let cs = csink { parts.append(try Kernel.cone(origin: top, axis: dir, radius1: cs / 2, radius2: d / 2, height: (cs - d) / 2)) }
            for part in parts { tool = try tool.map { try Kernel.boolean(.fuse, $0, part) } ?? part }
        }
        let tools = try FeatureScope.tools(tool!, p.instances, only: p.instancesOnly)
        let modified = try FeatureScope.apply(tools, cut: true, merge: false, &doc, p.scope, name: nil, producedBy: name)
        ctx.document = doc
        let thread = type == .tapped ? iso.map { "\($0.name)x\(String(format: "%.2g", $0.pitch))" } : nil
        return Output(
            bodies: modified, holes: centres.count, diameter: d, counterbore: cbore.map { [$0.0, $0.1] }, countersink: csink,
            thread: thread.map { t in p.threadDepth.map { "\(t) depth \(String(format: "%g", $0.millimeters))" } ?? t })
    }
}

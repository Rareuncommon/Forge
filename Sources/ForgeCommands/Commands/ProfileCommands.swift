import ForgeCore
import ForgeKernel
import ForgeSketch
import Foundation

extension Sketch {
    /// The sketch's closed profile as kernel loops grouped into regions (outer loop + holes),
    /// in model coordinates. Throws a structured error listing the profile issues if the
    /// sketch is not a valid feature profile.
    func profileLoops() throws -> (loops: [[ProfileSegment]], regions: [Int]) {
        let report = profiles()
        guard report.valid else {
            throw ForgeError(
                .preconditionFailed, "sketch \(id) is not a valid profile: " + report.issues.joined(separator: "; "),
                entities: (report.openEnds + report.branchPoints).map { "\(id)/\($0)" },
                suggestions: [SuggestedFix(description: "Inspect the profile", command: "sketch.check", params: ["sketch": .string(id)])])
        }
        func P(_ pid: String) -> Vec3 {
            let (u, v) = point(pid)
            return plane.point(u, v)
        }
        func segments(_ loop: ProfileLoop) -> [ProfileSegment] {
            zip(loop.entities, loop.forward).map { (eid, fwd) -> ProfileSegment in
                let e = entities[eid]!
                switch e.kind {
                case .line:
                    let a = P(e.points[0]), b = P(e.points[1])
                    return fwd ? .line(a, b) : .line(b, a)
                case .arc:
                    let (cx, cy) = point(e.points[0]), (sx, sy) = point(e.points[1]), (ex, ey) = point(e.points[2])
                    let r = hypot(sx - cx, sy - cy)
                    let a0 = atan2(sy - cy, sx - cx)
                    var sweep = atan2(ey - cy, ex - cx) - a0
                    while sweep <= 0 { sweep += 2 * .pi }
                    let mid = plane.point(cx + r * cos(a0 + sweep / 2), cy + r * sin(a0 + sweep / 2))
                    let a = P(e.points[1]), b = P(e.points[2])
                    return fwd ? .arc(a, mid, b) : .arc(b, mid, a)
                case .circle:
                    return .circle(center: P(e.points[0]), normal: plane.normal, radius: params[e.params[0]])
                case .ellipse:
                    let rot = params[e.params[2]]
                    let dir = plane.xAxis * cos(rot) + plane.yAxis * sin(rot)
                    return .ellipse(center: P(e.points[0]), normal: plane.normal, majorDirection: dir,
                                    majorRadius: params[e.params[0]], minorRadius: params[e.params[1]])
                case .ellipseArc:
                    // Same edge whichever way the loop runs (the wire builder orients it).
                    let rot = params[e.params[2]]
                    let dir = plane.xAxis * cos(rot) + plane.yAxis * sin(rot)
                    let (phi0, sweep) = ellipseArcSpan(eid)
                    return .ellipseArc(
                        center: P(e.points[0]), normal: plane.normal, majorDirection: dir,
                        majorRadius: params[e.params[0]], minorRadius: params[e.params[1]], from: phi0, to: phi0 + sweep)
                case .spline:
                    // Clamped uniform knots are symmetric, so reversing the poles reverses the curve.
                    let poles = e.points.map(P)
                    return .bspline(poles: fwd ? poles : poles.reversed(), degree: e.degree ?? 3)
                case .point:
                    preconditionFailure("points are not profile curves")
                }
            }
        }
        // Region = an even-depth loop followed by its direct (odd-depth) children.
        var loops: [[ProfileSegment]] = [], regions: [Int] = []
        for (i, loop) in report.loops.enumerated() where loop.depth % 2 == 0 {
            loops.append(segments(loop))
            regions.append(i)
            for hole in report.loops where hole.parent == i {
                loops.append(segments(hole))
                regions.append(i)
            }
        }
        return (loops, regions)
    }
}

public enum ExtrudeDirection: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case normal, reverse, midPlane = "mid_plane"
}

/// SolidWorks' extrude end conditions (docs/research §2.4) that need no face reference.
public enum EndCondition: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case blind, throughAll = "through_all", throughAllBoth = "through_all_both", midPlane = "mid_plane", upToVertex = "up_to_vertex"
}

public enum FeatureOperation: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case boss, cut
}

public struct ExtrudeDirection2: Codable, Sendable, SchemaDocumented {
    public var endCondition: EndCondition?
    public var depth: Length?
    public var vertex: Point3?

    enum CodingKeys: String, CodingKey {
        case depth, vertex
        case endCondition = "end_condition"
    }
    public static let fieldDocs: [String: FieldDoc] = [
        "end_condition": FieldDoc("blind, through_all or up_to_vertex", default: "blind"),
        "depth": "Depth for blind",
        "vertex": "Point the extrusion reaches for up_to_vertex (model coordinates)",
    ]
}

/// Where the bodies the result merges into or cuts are, and combining with them.
enum FeatureScope {
    /// Bodies in scope: the given ids, else all bodies.
    static func bodies(_ doc: Document, _ scope: [String]?) throws -> [Body] {
        try scope.map { try $0.map { try doc.body($0) } } ?? doc.orderedBodies
    }

    /// Cut `tool` from every body in scope it touches; returns the modified ids.
    static func cut(_ tool: Shape, _ doc: inout Document, _ scope: [String]?, producedBy: String) throws -> [String] {
        var modified: [String] = []
        for b in try bodies(doc, scope) {
            guard let d = try? Kernel.distance(tool, b.shape), d.distance < 1e-7 else { continue }
            // Touching is not cutting: only a body that loses volume is modified.
            let result = try Kernel.boolean(.cut, b.shape, tool)
            let before = try b.shape.massProperties().volume, after = try result.massProperties().volume
            guard after < before - 1e-9 * max(1, before) else { continue }
            try doc.replaceShape(of: b.id, with: result, producedBy: producedBy)
            modified.append(b.id)
        }
        guard !modified.isEmpty else {
            throw ForgeError(.emptyResult, "the cut does not reach any body" + (scope == nil ? "" : " in its feature scope") + "; reverse it or use through_all")
        }
        return modified
    }

    /// Merge `solid` into the bodies in scope it touches (the first keeps its id, the others
    /// are consumed); returns that id, or nil when it touches none.
    static func merge(_ solid: Shape, _ doc: inout Document, _ scope: [String]?, producedBy: String) throws -> String? {
        let touching = try bodies(doc, scope).filter { b in ((try? Kernel.distance(solid, b.shape))?.distance ?? 1) < 1e-7 }
        guard let first = touching.first else { return nil }
        var result = try Kernel.boolean(.fuse, first.shape, solid)
        for b in touching.dropFirst() {
            result = try Kernel.boolean(.fuse, result, b.shape)
            try doc.removeBody(b.id)
        }
        try doc.replaceShape(of: first.id, with: result, producedBy: producedBy)
        return first.id
    }
}

public enum BodyExtrude: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var depth: Length?
        public var direction: ExtrudeDirection?
        public var endCondition: EndCondition?
        public var reverse: Bool?
        public var vertex: Point3?
        public var direction2: ExtrudeDirection2?
        public var operation: FeatureOperation?
        public var merge: Bool?
        public var scope: [String]?
        public var name: String?

        enum CodingKeys: String, CodingKey {
            case sketch, depth, direction, reverse, vertex, direction2, operation, merge, scope, name
            case endCondition = "end_condition"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": FieldDoc("Sketch whose closed profile is extruded", default: "the sketch being edited"),
            "depth": "Direction 1 depth for blind (total depth for mid_plane)",
            "direction": FieldDoc("Legacy shorthand: normal, reverse (= reverse: true) or mid_plane (= end_condition mid_plane)", default: "normal"),
            "end_condition": FieldDoc(
                "Direction 1 end condition: blind, through_all (through every body in scope), through_all_both, mid_plane, up_to_vertex",
                default: "blind"),
            "reverse": FieldDoc("Extrude against the sketch normal", default: false),
            "vertex": "Point Direction 1 reaches, for up_to_vertex (model coordinates)",
            "direction2": "Also extrude the other way (not with mid_plane or through_all_both)",
            "operation": FieldDoc("boss (add material) or cut (remove it from the bodies in scope)", default: "boss"),
            "merge": FieldDoc("Boss: merge the result into the bodies it touches instead of making a new body", default: false),
            "scope": FieldDoc("Bodies a cut or merge affects", default: "all bodies"),
            "name": FieldDoc("Body display name for a new body", default: "Body<n>"),
        ]
        public func validate() throws {
            let ec = endCondition ?? (direction == .midPlane ? .midPlane : .blind)
            if ec == .blind || ec == .midPlane {
                guard let depth else { throw ForgeError(.invalidParams, "depth is required for \(ec.rawValue)") }
                try requirePositive(depth, "depth")
            }
            if ec == .upToVertex && vertex == nil { throw ForgeError(.invalidParams, "vertex is required for up_to_vertex") }
            if let d2 = direction2 {
                if ec == .midPlane || ec == .throughAllBoth { throw ForgeError(.invalidParams, "direction2 does not combine with \(ec.rawValue)") }
                switch d2.endCondition ?? .blind {
                case .blind:
                    guard let d = d2.depth else { throw ForgeError(.invalidParams, "direction2.depth is required for blind") }
                    try requirePositive(d, "direction2.depth")
                case .upToVertex where d2.vertex == nil: throw ForgeError(.invalidParams, "direction2.vertex is required for up_to_vertex")
                case .midPlane, .throughAllBoth: throw ForgeError(.invalidParams, "direction2 end condition must be blind, through_all or up_to_vertex")
                default: break
                }
            }
        }
    }
    public typealias Output = BodyResult

    public static let name = "body.extrude"
    public static let summary = "Extruded Boss/Base or Extruded Cut from a sketch's closed profile (holes and islands kept)"
    public static let discussion = """
        SolidWorks' Extrude: Direction 1 end condition (blind, through all, through all both, mid plane, up to vertex) with         reverse, an optional Direction 2, boss or cut, merge result and feature scope. Recorded as a feature: editing the         sketch or feature.edit regenerates it. Draft, thin feature and the up-to-surface end conditions are not implemented yet.
        """
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.preconditionFailed, .unknownEntity, .kernelFailure, .emptyResult]
    public static let examples: [JSONValue] = [
        ["sketch": "sketch-1", "depth": 10], ["depth": "0.5 in", "direction": "mid_plane"],
        ["sketch": "sketch-2", "end_condition": "through_all", "operation": "cut"],
        ["sketch": "sketch-1", "depth": 10, "direction2": ["depth": 4], "merge": true],
    ]

    /// Signed extent of the bodies in scope along the sketch normal, relative to the plane.
    static func extent(_ doc: Document, _ scope: [String]?, origin: Vec3, normal n: Vec3) throws -> (min: Double, max: Double) {
        let bodies = try FeatureScope.bodies(doc, scope)
        guard !bodies.isEmpty else {
            throw ForgeError(.preconditionFailed, "through all needs bodies to go through; use blind for the first feature")
        }
        var lo = Double.infinity, hi = -Double.infinity
        for b in bodies {
            let bb = try b.shape.boundingBox()
            for x in [bb.min.x, bb.max.x] { for y in [bb.min.y, bb.max.y] { for z in [bb.min.z, bb.max.z] {
                let t = (Vec3(x, y, z) - origin).dot(n)
                lo = Swift.min(lo, t)
                hi = Swift.max(hi, t)
            } } }
        }
        return (lo, hi)
    }

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let sk = try doc.sketch(p.sketch)
        let (loops, regions) = try sk.profileLoops()
        let face = try Kernel.faces(loops: loops, regions: regions)
        let n = sk.plane.normal, origin = sk.plane.origin
        let ec = p.endCondition ?? (p.direction == .midPlane ? .midPlane : .blind)
        let s1: Double = (p.reverse ?? false) || p.direction == .reverse ? -1 : 1
        let margin = 1.0
        // The extrusion as an interval [a, b] along the sketch normal.
        func reach(_ cond: EndCondition, depth: Length?, vertex: Point3?, sign: Double) throws -> Double {
            switch cond {
            case .blind:
                return depth!.millimeters
            case .throughAll:
                let e = try extent(doc, p.scope, origin: origin, normal: n)
                let t = sign > 0 ? e.max : -e.min
                guard t > 1e-9 else { throw ForgeError(.emptyResult, "there is no material on that side of the sketch to go through") }
                return t + margin
            case .upToVertex:
                let t = (vertex!.mm - origin).dot(n) * sign
                guard t > 1e-9 else { throw ForgeError(.invalidParams, "the vertex is not on the extrusion side of the sketch plane") }
                return t
            case .midPlane, .throughAllBoth:
                preconditionFailure("handled by the caller")
            }
        }
        var a: Double, b: Double
        switch ec {
        case .midPlane:
            let d = p.depth!.millimeters
            (a, b) = (-d / 2, d / 2)
        case .throughAllBoth:
            let e = try extent(doc, p.scope, origin: origin, normal: n)
            (a, b) = (e.min - margin, e.max + margin)
        default:
            let t1 = try reach(ec, depth: p.depth, vertex: p.vertex, sign: s1)
            let t2 = try p.direction2.map { d2 in try reach(d2.endCondition ?? .blind, depth: d2.depth, vertex: d2.vertex, sign: -s1) } ?? 0
            (a, b) = s1 > 0 ? (-t2, t1) : (-t1, t2)
        }
        let start = a == 0 ? face : try Kernel.transform(face, .translation(n * a))
        let solid = try Kernel.extrude(start, by: n * (b - a))

        if p.operation == .cut {
            let modified = try FeatureScope.cut(solid, &doc, p.scope, producedBy: name)
            ctx.document = doc
            return Output(body: try BodySummary(try doc.body(modified[0])), bodies: modified)
        }
        if p.merge == true, let id = try FeatureScope.merge(solid, &doc, p.scope, producedBy: name) {
            ctx.document = doc
            return Output(body: try BodySummary(try doc.body(id)), bodies: [id])
        }
        let body = doc.addBody(name: p.name, shape: solid, producedBy: name)
        ctx.document = doc
        return Output(body: try BodySummary(body))
    }
}

public enum BodyRevolve: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var axis: String
        public var angle: Angle?
        public var operation: FeatureOperation?
        public var merge: Bool?
        public var scope: [String]?
        public var name: String?
        public static let fieldDocs: [String: FieldDoc] = [
            "operation": FieldDoc("boss (add material) or cut (remove it from the bodies in scope)", default: "boss"),
            "merge": FieldDoc("Boss: merge the result into the bodies it touches", default: false),
            "scope": FieldDoc("Bodies a cut or merge affects", default: "all bodies"),
            "sketch": FieldDoc("Sketch whose closed profile is revolved", default: "the sketch being edited"),
            "axis": "A line in the sketch (usually a construction centerline) to revolve about",
            "angle": FieldDoc("Revolution angle, counter-clockwise about the axis direction (start → end)", default: "360 deg"),
            "name": FieldDoc("Body display name", default: "Body<n>"),
        ]
        public func validate() throws {
            if let a = angle, !(a.radians > 0 && a.radians <= 2 * .pi + 1e-12) {
                throw ForgeError(.invalidParams, "angle must be in (0, 360] degrees")
            }
        }
    }
    public typealias Output = BodyResult

    public static let name = "body.revolve"
    public static let summary = "Revolved Boss/Base or Revolved Cut: a sketch's closed profile about a sketch line"
    public static let discussion = "Recorded as a feature: editing the sketch or feature.edit regenerates it. Direction 2 and the up-to end conditions are not implemented yet."
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.preconditionFailed, .unknownEntity, .kernelFailure]
    public static let examples: [JSONValue] = [["sketch": "sketch-1", "axis": "line-1"], ["axis": "line-7", "angle": "180 deg"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let sk = try doc.sketch(p.sketch)
        let axisID = try localID(p.axis, in: sk)
        let axisEntity = try sk.entity(axisID)
        guard axisEntity.kind == .line else { throw ForgeError(.invalidParams, "the revolve axis must be a line", entities: ["\(sk.id)/\(axisID)"]) }
        let (ax, ay) = sk.point(axisEntity.points[0]), (bx, by) = sk.point(axisEntity.points[1])
        let origin = sk.plane.point(ax, ay), dir = sk.plane.point(bx, by) - origin
        let (loops, regions) = try sk.profileLoops()
        let face = try Kernel.faces(loops: loops, regions: regions)
        let solid: Shape
        do {
            solid = try Kernel.revolve(face, origin: origin, axis: dir, angle: p.angle?.radians ?? 2 * .pi)
        } catch var e as ForgeError {
            e.entities = ["\(sk.id)/\(axisID)"]
            throw e
        }
        if p.operation == .cut {
            let modified = try FeatureScope.cut(solid, &doc, p.scope, producedBy: name)
            ctx.document = doc
            return Output(body: try BodySummary(try doc.body(modified[0])), bodies: modified)
        }
        if p.merge == true, let id = try FeatureScope.merge(solid, &doc, p.scope, producedBy: name) {
            ctx.document = doc
            return Output(body: try BodySummary(try doc.body(id)), bodies: [id])
        }
        let body = doc.addBody(name: p.name, shape: solid, producedBy: name)
        ctx.document = doc
        return Output(body: try BodySummary(body))
    }
}

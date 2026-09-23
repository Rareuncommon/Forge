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

public enum BodyExtrude: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var depth: Length
        public var direction: ExtrudeDirection?
        public var name: String?
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": FieldDoc("Sketch whose closed profile is extruded", default: "the sketch being edited"),
            "depth": "Extrusion depth (total depth for mid_plane)",
            "direction": FieldDoc("normal (along the sketch normal), reverse, or mid_plane (symmetric)", default: "normal"),
            "name": FieldDoc("Body display name", default: "Body<n>"),
        ]
        public func validate() throws { try requirePositive(depth, "depth") }
    }
    public typealias Output = BodyResult

    public static let name = "body.extrude"
    public static let summary = "Extrude a sketch's closed profile (with holes and islands) into a new solid body"
    public static let discussion = "Kernel-level blind extrusion. The parametric Extrude feature (end conditions, draft, thin, cut) arrives with the feature tree in M2; combine with body.boolean meanwhile."
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.preconditionFailed, .unknownEntity, .kernelFailure]
    public static let examples: [JSONValue] = [["sketch": "sketch-1", "depth": 10], ["depth": "0.5 in", "direction": "mid_plane"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let sk = try doc.sketch(p.sketch)
        let (loops, regions) = try sk.profileLoops()
        var face = try Kernel.faces(loops: loops, regions: regions)
        let n = sk.plane.normal, d = p.depth.millimeters
        let v: Vec3
        switch p.direction ?? .normal {
        case .normal: v = n * d
        case .reverse: v = n * -d
        case .midPlane:
            face = try Kernel.transform(face, .translation(n * (-d / 2)))
            v = n * d
        }
        let solid = try Kernel.extrude(face, by: v)
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
        public var name: String?
        public static let fieldDocs: [String: FieldDoc] = [
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
    public static let summary = "Revolve a sketch's closed profile about a sketch line into a new solid body"
    public static let discussion = "Kernel-level revolve; the parametric Revolve feature arrives with the feature tree in M2."
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
        let body = doc.addBody(name: p.name, shape: solid, producedBy: name)
        ctx.document = doc
        return Output(body: try BodySummary(body))
    }
}

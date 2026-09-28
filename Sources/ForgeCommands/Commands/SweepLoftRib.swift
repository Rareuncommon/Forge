import ForgeCore
import ForgeKernel
import ForgeSketch
import Foundation

// Sweep, Loft and Rib (docs/research §2.4). Each is recorded as a feature (docs/adr/0011)
// and names its faces (docs/adr/0002): sweep and loft sides after the profile curves they
// come from, caps start_cap / end_cap; rib faces after the rib's sketch lines.

extension Sketch {
    /// The sketch's curves (or `only` these) as one connected chain, in order: a path for a
    /// sweep or the profile of a rib. Open chains run from one free end; a single closed
    /// curve (circle, ellipse) is allowed.
    func pathChain(_ only: [String]? = nil) throws -> (segments: [ProfileSegment], ids: [String]) {
        let curves = try (only.map { try $0.map { try entity(localID($0, in: self)) } } ?? orderedEntities.filter { $0.kind != .point && !$0.construction })
            .filter { $0.kind != .point }
        guard !curves.isEmpty else {
            throw ForgeError(.preconditionFailed, "sketch \(id) has no curves for a path", entities: [id])
        }
        if curves.count == 1, [.circle, .ellipse].contains(curves[0].kind) {
            return ([profileSegment(curves[0].id, forward: true)], [curves[0].id])
        }
        let scale = max(1, params.map(abs).max() ?? 1)
        let tol = 1e-7 * scale
        var nodes: [(Double, Double)] = []
        func node(_ pid: String) -> Int {
            let (x, y) = point(pid)
            if let i = nodes.firstIndex(where: { abs($0.0 - x) <= tol && abs($0.1 - y) <= tol }) { return i }
            nodes.append((x, y))
            return nodes.count - 1
        }
        var ends: [(a: Int, b: Int)] = []
        for c in curves {
            switch c.kind {
            case .line: ends.append((node(c.points[0]), node(c.points[1])))
            case .arc, .ellipseArc: ends.append((node(c.points[1]), node(c.points[2])))
            case .spline: ends.append((node(c.points.first!), node(c.points.last!)))
            default:
                throw ForgeError(.invalidParams, "a closed curve (\(c.id)) can only be a path on its own", entities: ["\(id)/\(c.id)"])
            }
        }
        var degree = [Int](repeating: 0, count: nodes.count)
        for e in ends { degree[e.a] += 1; degree[e.b] += 1 }
        if let branch = degree.firstIndex(where: { $0 > 2 }) {
            throw ForgeError(.invalidParams, "the path branches at (\(nodes[branch].0), \(nodes[branch].1)); a path is one chain of curves", entities: [id])
        }
        var current = degree.firstIndex(of: 1) ?? ends[0].a
        var used = [Bool](repeating: false, count: curves.count)
        var segments: [ProfileSegment] = [], ids: [String] = []
        while let i = ends.indices.first(where: { !used[$0] && (ends[$0].a == current || ends[$0].b == current) }) {
            used[i] = true
            let forward = ends[i].a == current
            segments.append(profileSegment(curves[i].id, forward: forward))
            ids.append(curves[i].id)
            current = forward ? ends[i].b : ends[i].a
        }
        guard used.allSatisfy({ $0 }) else {
            throw ForgeError(.invalidParams, "the path's curves are not connected into one chain", entities: curves.filter { c in !used[curves.firstIndex { $0.id == c.id }!] }.map { "\(id)/\($0.id)" })
        }
        return (segments, ids)
    }
}

extension ProfileSegment {
    /// Start point and unit tangent at the start.
    var start: (point: Vec3, tangent: Vec3)? {
        switch self {
        case .line(let a, let b): return (a, (b - a).normalized)
        case .arc(let a, let m, let b):
            let n = (m - a).cross(b - m).normalized
            guard let c = Self.circumcentre(a, m, b) else { return nil }
            return (a, n.cross(a - c).normalized)
        case .bspline(let poles, _): return poles.count > 1 ? (poles[0], (poles[1] - poles[0]).normalized) : nil
        default: return nil
        }
    }

    static func circumcentre(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Vec3? {
        let ab = b - a, ac = c - a
        let n = ab.cross(ac)
        let d = 2 * n.dot(n)
        guard d > 1e-18 else { return nil }
        return a + (n.cross(ab) * ac.dot(ac) + ac.cross(n) * ab.dot(ab)) * (1 / d)
    }
}

// MARK: - Sweep

public enum BodySweep: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var profile: String?
        public var path: String
        public var pathEntities: [String]?
        public var circularDiameter: Length?
        public var orientation: Kernel.SweepOrientation?
        public var operation: FeatureOperation?
        public var merge: Bool?
        public var scope: [String]?
        public var name: String?

        enum CodingKeys: String, CodingKey {
            case profile, path, orientation, operation, merge, scope, name
            case pathEntities = "path_entities"
            case circularDiameter = "circular_diameter"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "profile": "Sketch with the closed profile, placed at the start of the path (not with circular_diameter)",
            "path": "Sketch holding the path: one chain of lines, arcs and splines (or one circle/ellipse)",
            "path_entities": FieldDoc("Curves of the path sketch to use", default: "all its non-construction curves"),
            "circular_diameter": "Circular profile: sweep a circle of this diameter, centred on the path's start and normal to it (no profile sketch)",
            "orientation": FieldDoc("follow_path (the profile turns with the path) or keep_normal_constant", default: "follow_path"),
            "operation": FieldDoc("boss (add material) or cut (remove it from the bodies in scope)", default: "boss"),
            "merge": FieldDoc("Boss: merge the result into the bodies it touches", default: false),
            "scope": FieldDoc("Bodies a cut or merge affects", default: "all bodies"),
            "name": FieldDoc("Body display name", default: "Body<n>"),
        ]
        public func validate() throws {
            guard (profile == nil) != (circularDiameter == nil) else {
                throw ForgeError(.invalidParams, "give either a profile sketch or circular_diameter")
            }
            if let d = circularDiameter { try requirePositive(d, "circular_diameter") }
        }
    }
    public typealias Output = BodyResult

    public static let name = "body.sweep"
    public static let summary = "Swept Boss/Base or Swept Cut: a closed profile (or a circle) along a path sketch"
    public static let discussion = """
        The profile sketch should lie at the start of the path, crossing it. Recorded as a feature: editing either sketch \
        regenerates it. Guide curves, twist along the path and thin sweeps are not implemented yet.
        """
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.preconditionFailed, .invalidParams, .kernelFailure, .emptyResult]
    public static let examples: [JSONValue] = [
        ["profile": "sketch-2", "path": "sketch-1"],
        ["path": "sketch-1", "circular_diameter": 4],
        ["profile": "sketch-3", "path": "sketch-1", "operation": "cut"],
    ]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let pathSketch = try doc.sketch(p.path)
        let (segments, pathIDs) = try pathSketch.pathChain(p.pathEntities)
        let path = try Kernel.wire(segments)
        let feature = doc.currentFeature
        let face: Shape
        var edgeNames: [String]
        if let d = p.circularDiameter {
            guard let start = segments[0].start else {
                throw ForgeError(.invalidParams, "a circular profile needs a path that starts with a line, arc or spline", entities: ["\(pathSketch.id)/\(pathIDs[0])"])
            }
            face = try Kernel.faces(loops: [[.circle(center: start.point, normal: start.tangent, radius: d.millimeters / 2)]], regions: [0])
            edgeNames = ["circle"]
        } else {
            let sk = try doc.sketch(p.profile)
            let (loops, regions, ids) = try sk.profileLoopsWithIDs()
            face = try Kernel.faces(loops: loops, regions: regions)
            edgeNames = try Naming.profileEdges(face, segmentIDs: ids)
        }
        let solid: Shape
        do {
            solid = try Kernel.sweep(face, along: path, orientation: p.orientation ?? .followPath)
        } catch var e as ForgeError {
            e.entities = [pathSketch.id] + (p.profile.map { [$0] } ?? [])
            e.suggestions.append(SuggestedFix(description: "Check the path", command: "sketch.get", params: ["sketch": .string(pathSketch.id)]))
            throw e
        }
        let named = try Naming.named(solid, [NamedShape(face, faces: [], edges: edgeNames)], feature: feature, roles: NamingRoles(fromEdge: "side"))
        let ids = try FeatureScope.apply([named], cut: p.operation == .cut, merge: p.merge == true, &doc, p.scope, name: p.name, producedBy: name)
        ctx.document = doc
        return Output(body: try BodySummary(try doc.body(ids[0])), bodies: ids.count > 1 || p.operation == .cut || p.merge == true ? ids : nil)
    }
}

// MARK: - Loft

public enum BodyLoft: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var profiles: [String]
        public var ruled: Bool?
        public var operation: FeatureOperation?
        public var merge: Bool?
        public var scope: [String]?
        public var name: String?
        public static let fieldDocs: [String: FieldDoc] = [
            "profiles": "Sketches with one closed profile each, in loft order (at least two)",
            "ruled": FieldDoc("Join consecutive profiles with ruled (straight) faces instead of a smooth surface", default: false),
            "operation": FieldDoc("boss (add material) or cut (remove it from the bodies in scope)", default: "boss"),
            "merge": FieldDoc("Boss: merge the result into the bodies it touches", default: false),
            "scope": FieldDoc("Bodies a cut or merge affects", default: "all bodies"),
            "name": FieldDoc("Body display name", default: "Body<n>"),
        ]
        public func validate() throws {
            guard profiles.count >= 2 else { throw ForgeError(.invalidParams, "a loft needs at least two profiles") }
            guard Set(profiles).count == profiles.count else { throw ForgeError(.invalidParams, "each profile can be used once") }
        }
    }
    public typealias Output = BodyResult

    public static let name = "body.loft"
    public static let summary = "Lofted Boss/Base or Lofted Cut through two or more profile sketches"
    public static let discussion = """
        Each profile is one closed loop (inner loops are ignored). Recorded as a feature: editing a profile sketch \
        regenerates it. Guide curves, centerline, start/end tangency and points as end profiles are not implemented yet.
        """
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.preconditionFailed, .invalidParams, .kernelFailure, .emptyResult]
    public static let examples: [JSONValue] = [["profiles": ["sketch-1", "sketch-2"]], ["profiles": ["sketch-1", "sketch-2", "sketch-3"], "ruled": true]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        var sections: [NamedShape] = []
        for ref in p.profiles {
            let sk = try doc.sketch(ref)
            let (loops, regions, ids) = try sk.profileLoopsWithIDs()
            guard Set(regions).count == 1 else {
                throw ForgeError(.invalidParams, "\(sk.name) has \(Set(regions).count) separate profiles; a loft profile is one closed loop", entities: [sk.id])
            }
            let face = try Kernel.faces(loops: [loops[0]], regions: [0])
            // Sketch-qualified: the profiles' entity ids repeat between sketches.
            let names = try Naming.profileEdges(face, segmentIDs: ids.map { "\(sk.id).\($0)" })
            sections.append(NamedShape(face, faces: [], edges: names))
        }
        let solid: Shape
        do {
            solid = try Kernel.loft(sections.map(\.shape), ruled: p.ruled ?? false)
        } catch var e as ForgeError {
            e.entities = p.profiles
            throw e
        }
        let named = try Naming.named(solid, sections, feature: doc.currentFeature, roles: NamingRoles(fromEdge: "side"))
        let ids = try FeatureScope.apply([named], cut: p.operation == .cut, merge: p.merge == true, &doc, p.scope, name: p.name, producedBy: name)
        ctx.document = doc
        return Output(body: try BodySummary(try doc.body(ids[0])), bodies: ids.count > 1 || p.operation == .cut || p.merge == true ? ids : nil)
    }
}

// MARK: - Rib

public enum RibDirection: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case parallelToSketch = "parallel_to_sketch", normalToSketch = "normal_to_sketch"
}

public enum RibThicknessSide: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case both, first, second
}

public enum BodyRib: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var sketch: String?
        public var thickness: Length
        public var direction: RibDirection?
        public var thicknessSide: RibThicknessSide?
        public var flip: Bool?
        public var scope: [String]?

        enum CodingKeys: String, CodingKey {
            case sketch, thickness, direction, flip, scope
            case thicknessSide = "thickness_side"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "sketch": FieldDoc("Sketch with the rib's open profile: one chain of lines", default: "the sketch being edited"),
            "thickness": "Rib thickness",
            "direction": FieldDoc(
                "parallel_to_sketch (material grows in the sketch plane from the profile to the body) or normal_to_sketch (grows along the sketch normal)",
                default: "parallel_to_sketch"),
            "thickness_side": FieldDoc(
                "both (centred on the profile), first or second side: across the sketch plane for parallel_to_sketch, in the sketch plane for normal_to_sketch",
                default: "both"),
            "flip": FieldDoc("Grow the material the other way", default: "the side that meets the body"),
            "scope": FieldDoc("Bodies the rib meets and joins", default: "all bodies"),
        ]
        public func validate() throws { try requirePositive(thickness, "thickness") }
    }
    public typealias Output = BodyResult

    public static let name = "body.rib"
    public static let summary = "Rib: a wall of a thickness from an open sketch profile, extended until it meets the body"
    public static let discussion = """
        The profile's ends are extended linearly and the material grows from the profile until it meets the body \
        (which it joins); a side where it never meets the body is refused. Profiles with arcs or splines, draft and \
        normal_to_sketch with more than one line are not implemented yet.
        """
    public static let category = CommandCategory.body
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.preconditionFailed, .invalidParams, .emptyResult, .kernelFailure]
    public static let examples: [JSONValue] = [["sketch": "sketch-3", "thickness": 3], ["sketch": "sketch-3", "thickness": 2, "direction": "normal_to_sketch"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let sk = try doc.sketch(p.sketch)
        let (segments, ids) = try sk.pathChain()
        var points: [Vec3] = []
        for s in segments {
            guard case .line(let a, let b) = s else {
                throw ForgeError(.notImplemented, "rib profiles with arcs or splines are not implemented yet; use lines", entities: ids.map { "\(sk.id)/\($0)" })
            }
            if points.isEmpty { points.append(a) }
            points.append(b)
        }
        guard (points.last! - points.first!).length > 1e-9 else {
            throw ForgeError(.invalidParams, "a rib profile is open; this chain is closed", entities: [sk.id])
        }
        let bodies = try FeatureScope.bodies(doc, p.scope)
        guard !bodies.isEmpty else { throw ForgeError(.preconditionFailed, "a rib needs a body to meet") }
        let direction = p.direction ?? .parallelToSketch
        if direction == .normalToSketch && segments.count > 1 {
            throw ForgeError(.notImplemented, "normal_to_sketch ribs from more than one line are not implemented yet", entities: [sk.id])
        }
        // Far enough to cross every body in scope.
        var reach = 10.0
        for b in bodies {
            let bb = try b.shape.boundingBox()
            reach = max(reach, 2 * (bb.max - bb.min).length + 2 * (bb.max - points[0]).length)
        }
        let n = sk.plane.normal.normalized
        let t = p.thickness.millimeters
        let (lo, hi): (Double, Double) = switch p.thicknessSide ?? .both {
        case .both: (-t / 2, t / 2)
        case .first: (0, t)
        case .second: (-t, 0)
        }
        // Ends extended along their own directions.
        var ext = points
        ext[0] = points[0] - (points[1] - points[0]).normalized * reach
        ext[ext.count - 1] = points[ext.count - 1] + (points[ext.count - 1] - points[ext.count - 2]).normalized * reach
        let u = (points.last! - points.first!).normalized
        let w = n.cross(u).normalized
        let profileWire = try Kernel.wire(segments)
        let feature = doc.currentFeature

        /// The rib grown to side `s` (±1), or nil when it never meets the body there.
        func rib(_ s: Double) throws -> NamedShape? {
            let grow = direction == .parallelToSketch ? w * s : n * s
            let slab: Shape
            var edgeNames: [String]
            if direction == .parallelToSketch {
                // The region swept from the profile toward `grow`, thick across the sketch plane.
                let far = [ext.last! + grow * reach, ext[0] + grow * reach]
                let loop = ext + far
                let segs: [ProfileSegment] = loop.indices.map { .line(loop[$0], loop[($0 + 1) % loop.count]) }
                let face = try Kernel.faces(loops: [segs], regions: [0])
                edgeNames = try Naming.profileEdges(face, segmentIDs: ids + ["end", "far", "end"])
                slab = try Kernel.extrude(try Kernel.transform(face, .translation(n * lo)), by: n * (hi - lo))
            } else {
                // The profile thickened in the sketch plane, grown along the normal.
                let a = points[0], b = points[1]
                let loop = [a + w * lo, b + w * lo, b + w * hi, a + w * hi]
                let segs: [ProfileSegment] = loop.indices.map { .line(loop[$0], loop[($0 + 1) % 4]) }
                let face = try Kernel.faces(loops: [segs], regions: [0])
                edgeNames = try Naming.profileEdges(face, segmentIDs: ["\(ids[0]).first", "end", "\(ids[0]).second", "end"])
                slab = try Kernel.extrude(face, by: grow * reach)
            }
            let roles = NamingRoles(fromEdge: "rib", firstCap: "rib_face", lastCap: "rib_face")
            var cut = NamedShape(slab, faces: try Naming.derive(slab, operands: [NamedShape(slab, faces: [], edges: edgeNames)], feature: feature, roles: roles))
            for b in bodies {
                guard ((try? Kernel.distance(cut.shape, b.shape))?.distance ?? 1) < 1e-7 else { continue }
                cut = try Naming.named(try Kernel.boolean(.cut, cut.shape, b.shape), [cut, NamedShape(b)], feature: feature)
            }
            // The piece that holds the profile, bounded by the body before the slab's far end.
            let pieces = try cut.shape.solids().filter { ((try? Kernel.distance($0, profileWire))?.distance ?? 1) < 1e-6 }
            guard !pieces.isEmpty else { return nil }
            var kept: NamedShape?
            for piece in pieces {
                let bb = try piece.boundingBox()
                var far = -Double.infinity, lowU = Double.infinity, highU = -Double.infinity
                for x in [bb.min.x, bb.max.x] { for y in [bb.min.y, bb.max.y] { for z in [bb.min.z, bb.max.z] {
                    let q = Vec3(x, y, z) - points[0]
                    far = max(far, q.dot(grow))
                    lowU = min(lowU, q.dot(u))
                    highU = max(highU, q.dot(u))
                } } }
                let span = (ext.last! - points[0]).dot(u), start = (ext[0] - points[0]).dot(u)
                guard far < reach - 1e-3, direction == .normalToSketch || (lowU > start + 1e-3 && highU < span - 1e-3) else { return nil }
                let named = try Naming.transfer(from: cut, to: piece)
                kept = try kept.map { try Naming.named(try Kernel.boolean(.fuse, $0.shape, named.shape), [$0, named], feature: feature) } ?? named
            }
            return kept
        }

        let result: NamedShape
        if let flip = p.flip {
            guard let r = try rib(flip ? -1 : 1) else {
                throw ForgeError(.emptyResult, "the rib does not meet the body on that side", entities: [sk.id],
                                 suggestions: [SuggestedFix(description: "Grow it the other way", command: name, params: ["sketch": .string(sk.id), "thickness": .number(t), "flip": .bool(!flip)])])
            }
            result = r
        } else if let r = try rib(1) ?? rib(-1) {
            result = r
        } else {
            throw ForgeError(.emptyResult, "the rib does not meet the body on either side of its profile", entities: [sk.id])
        }
        guard let id = try FeatureScope.merge(result, &doc, p.scope, producedBy: name) else {
            throw ForgeError(.emptyResult, "the rib does not touch a body", entities: [sk.id])
        }
        ctx.document = doc
        return Output(body: try BodySummary(try doc.body(id)))
    }
}

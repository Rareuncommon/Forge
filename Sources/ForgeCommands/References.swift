import ForgeCore
import ForgeKernel
import Foundation

// Resolving face and edge references, transient or named (docs/adr/0002, Naming.swift).

/// What a named reference pointed at when it was stored: ranks repair candidates when the
/// name is lost.
public struct RefDescriptor: Codable, Sendable, Hashable {
    /// "face" or "edge"
    public var kind: String
    /// Surface or curve type.
    public var type: String
    public var centroid: [Double]
    /// Area (faces, mm²) or length (edges, mm).
    public var size: Double
}

extension Document {
    /// Face indices of `body` that references designate: "body-1/face-3", "body-1/face@name" or
    /// a bare index. A split name gives all its pieces when `sets`, otherwise it fails.
    func faceIndices(_ refs: [String], of body: Body, sets: Bool) throws -> [Int] {
        let count = try body.shape.topology().faces
        var out: [Int] = []
        for r in refs {
            let found: [Int]
            if let i = Int(r) {
                found = [i]
            } else {
                let ref = try EntityRef.parse(r)
                guard ref.kind == .face, ref.body == body.id else {
                    throw ForgeError(.invalidParams, "'\(r)' is not a face of \(body.id)", entities: [r])
                }
                if let n = ref.name {
                    found = try resolveNamed(r, n, kind: .face, in: body, sets: sets)
                } else {
                    found = [ref.index!]
                }
            }
            for i in found {
                guard i >= 0, i < count else {
                    throw ForgeError(
                        .unknownEntity, "\(body.id) has no face \(i) (it has \(count) faces)", entities: ["\(body.id)/face-\(i)"],
                        suggestions: [SuggestedFix(description: "List the body's faces", command: "query.faces", params: ["body": .string(body.id)])])
                }
                if !out.contains(i) { out.append(i) }
            }
        }
        return out
    }

    /// Edge indices of `body` that references designate: edges (transient, named or bare
    /// indices) and faces, which stand for all their edges.
    func edgeIndices(_ refs: [String], of body: Body) throws -> [Int] {
        let t = try body.shape.topology()
        var out: [Int] = []
        func add(_ i: Int) { if !out.contains(i) { out.append(i) } }
        for r in refs {
            if let i = Int(r) {
                guard i >= 0, i < t.edges else { throw noEdge(body, i, t.edges) }
                add(i)
                continue
            }
            let ref = try EntityRef.parse(r)
            guard ref.body == body.id, ref.kind == .edge || ref.kind == .face else {
                throw ForgeError(.invalidParams, "'\(r)' is not an edge or face of \(body.id)", entities: [r])
            }
            if ref.kind == .edge {
                let found = try ref.name.map { try resolveNamed(r, $0, kind: .edge, in: body, sets: true) } ?? [ref.index!]
                for i in found {
                    guard i < t.edges else { throw noEdge(body, i, t.edges) }
                    add(i)
                }
            } else {
                // A face stands for all its edges (SolidWorks: fillet/chamfer a face's boundary).
                for f in try faceIndices([r], of: body, sets: true) {
                    for e in 0..<t.edges where try body.shape.edge(e).faces.contains(f) { add(e) }
                }
            }
        }
        return out
    }

    private func noEdge(_ body: Body, _ idx: Int, _ count: Int) -> ForgeError {
        ForgeError(
            .unknownEntity, "\(body.id) has no edge \(idx) (it has \(count) edges)", entities: ["\(body.id)/edge-\(idx)"],
            suggestions: [SuggestedFix(description: "List the body's edges", command: "query.edges", params: ["body": .string(body.id)])])
    }

    private func resolveNamed(_ ref: String, _ name: String, kind: EntityRef.Kind, in body: Body, sets: Bool) throws -> [Int] {
        guard let naming = body.naming else {
            throw ForgeError(.referenceLost, "\(body.id) has no persistent names, so \(ref) cannot be resolved", entities: [ref])
        }
        let found = kind == .face ? naming.resolveFace(name) : naming.resolveEdge(name)
        if found.count == 1 || (sets && !found.isEmpty) { return found }
        let what = kind == .face ? "face" : "edge"
        if found.count > 1 {
            // Split, where one entity is needed: the pieces are the candidates.
            throw lost(
                ref, body: body, kind: kind, candidates: found,
                message: "the \(what) \(ref) was split into \(found.count) pieces; choose one")
        }
        throw lost(ref, body: body, kind: kind, candidates: try rankedCandidates(for: ref, kind: kind, in: body), message: "the \(what) \(ref) no longer exists")
    }

    /// reference_lost with repair suggestions (feature.repair_reference) for the candidates.
    private func lost(_ ref: String, body: Body, kind: EntityRef.Kind, candidates: [Int], message: String) -> ForgeError {
        let feature = namingFeature.flatMap { id in features.first { $0.id == id } }
        let fixes = candidates.prefix(3).map { i -> SuggestedFix in
            let new = EntityRef(body: body.id, kind: kind, index: i).description
            let label = (kind == .face ? body.naming?.faces[i] : body.naming?.edges[i]) ?? new
            if let feature {
                return SuggestedFix(
                    description: "Use \(label) in \(feature.name)", command: "feature.repair_reference",
                    params: ["feature": .string(feature.id), "old": .string(ref), "new": .string(new)])
            }
            return SuggestedFix(description: "Use \(label)", command: "query.entity", params: ["ref": .string(new)])
        }
        var details: [String: JSONValue] = ["candidates": .array(candidates.map { .string(EntityRef(body: body.id, kind: kind, index: $0).description) })]
        if let d = feature?.references?[ref], let j = try? JSONCoding.toJSON(d) { details["was"] = j }
        return ForgeError(
            .referenceLost, message + (feature.map { " (\($0.name))" } ?? ""), entities: [ref],
            suggestions: fixes + [SuggestedFix(description: "List the body's \(kind == .face ? "faces" : "edges")", command: kind == .face ? "query.faces" : "query.edges", params: ["body": .string(body.id)])],
            details: .object(details))
    }

    /// Entities of the same kind ranked by similarity to what the reference was (type,
    /// position, size), best first.
    private func rankedCandidates(for ref: String, kind: EntityRef.Kind, in body: Body) throws -> [Int] {
        let t = try body.shape.topology()
        let n = kind == .face ? t.faces : t.edges
        guard let was = namingFeature.flatMap({ id in features.first { $0.id == id } })?.references?[ref] else { return Array(0..<min(n, 3)) }
        let c0 = Vec3(was.centroid[0], was.centroid[1], was.centroid[2])
        let scale = max(1e-6, kind == .face ? was.size.squareRoot() : was.size)
        let scored = try (0..<n).map { i -> (Int, Double) in
            let d = try Self.describe(body, kind: kind, index: i)
            let c = Vec3(d.centroid[0], d.centroid[1], d.centroid[2])
            let typePenalty = d.type == was.type ? 0.0 : 10.0
            let sizeTerm = abs(d.size - was.size) / max(d.size, was.size, 1e-9)
            return (i, typePenalty + (c - c0).length / scale + sizeTerm)
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0)
    }

    static func describe(_ body: Body, kind: EntityRef.Kind, index i: Int) throws -> RefDescriptor {
        if kind == .face {
            let f = try body.shape.face(i)
            return RefDescriptor(kind: "face", type: f.surfaceType.rawValue, centroid: f.centroid.array, size: f.area)
        }
        let e = try body.shape.edge(i)
        return RefDescriptor(kind: "edge", type: e.curveType.rawValue, centroid: e.midpoint.array, size: e.length)
    }

    /// A transient face/edge reference as a persistent one ("body-1/edge-3" →
    /// "body-1/edge@A|B"), with what it designates; other strings unchanged.
    func persistentRef(_ ref: String, defaultBody: String?, bareKind: EntityRef.Kind?) -> (ref: String, descriptor: RefDescriptor?) {
        var parsed: EntityRef?
        if let i = Int(ref), let b = defaultBody, let k = bareKind {
            parsed = EntityRef(body: b, kind: k, index: i)
        } else if let r = EntityRef(parsing: ref), r.name == nil, r.kind == .face || r.kind == .edge, r.index != nil {
            parsed = r
        }
        guard let r = parsed, let i = r.index, let b = try? body(r.body), let naming = b.naming else { return (ref, nil) }
        let names = r.kind == .face ? naming.faces : naming.edges
        guard i < names.count else { return (ref, nil) }
        let named = EntityRef(body: b.id, kind: r.kind, name: names[i]).description
        return (named, try? Self.describe(b, kind: r.kind, index: i))
    }

    /// Feature parameters with every transient face/edge reference made persistent, and the
    /// descriptors of what they designate. Bare indices in "edges"/"faces"/"neutral_plane"
    /// belong to "body".
    func persistentParams(_ params: JSONValue) -> (params: JSONValue, references: [String: RefDescriptor]) {
        var refs: [String: RefDescriptor] = [:]
        let body = params["body"]?.stringValue
        func walk(_ v: JSONValue, bare: EntityRef.Kind?) -> JSONValue {
            switch v {
            case .string(let s):
                let (named, d) = persistentRef(s, defaultBody: body, bareKind: bare)
                if let d { refs[named] = d }
                return .string(named)
            case .array(let a):
                return .array(a.map { walk($0, bare: bare) })
            case .object(let o):
                var out: [String: JSONValue] = [:]
                for (k, x) in o {
                    let kind: EntityRef.Kind? = k == "edges" ? .edge : (k == "faces" || k == "neutral_plane") ? .face : nil
                    out[k] = k == "body" || k == "sketch" || k == "features" ? x : walk(x, bare: kind)
                }
                return .object(out)
            default:
                return v
            }
        }
        return (walk(params, bare: nil), refs)
    }

    /// The current transient reference for a named one ("body-1/edge@A|B" → "body-1/edge-7"),
    /// or nil when it does not resolve to exactly one entity. Transient references pass through.
    public func transientRefs(_ ref: String) -> [String] {
        guard let r = EntityRef(parsing: ref), let n = r.name, let b = bodies[r.body], let naming = b.naming else { return [ref] }
        let found = r.kind == .face ? naming.resolveFace(n) : naming.resolveEdge(n)
        return found.map { EntityRef(body: b.id, kind: r.kind, index: $0).description }
    }
}

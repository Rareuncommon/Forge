import ForgeCore
import ForgeKernel
import Foundation

// Persistent (topological) naming, docs/adr/0002.
//
// Every face of a body carries a name made from the feature that created it and its role in
// that feature: "feature-2:side(line-3)", "feature-1:+z", "feature-5:blend(<edge name>)".
// Names follow faces through later operations by the kernel's history (FaceHistory): a face
// that a cut trims, a boolean moves into another body or a fillet shortens keeps its name.
// A face split in pieces gives each piece the same base name, told apart by "#k" in a
// geometric order; a face merged from several keeps all their names.
//
// An edge is named by the faces it separates: "A|B" (sorted), "~k" when two faces meet
// along several edges. Features store references as names ("body-1/edge@A|B"), so an
// upstream change that renumbers the kernel's indices does not move them. A name that no
// longer exists either resolves to all the pieces it split into (for features that take
// sets: fillet, chamfer, shell, draft faces) or fails with reference_lost and ranked repair
// candidates — never a silent rebind.

/// Persistent names of a body's faces and edges, by transient index.
public struct TopoNames: Sendable, Hashable {
    /// Unique name of each face.
    public var faces: [String]
    /// Base names each face carries: the pieces of a split face share one; a merged face has several.
    public var faceBases: [[String]]
    /// Unique name of each edge.
    public var edges: [String]
    /// Faces adjacent to each edge.
    public var edgeFaces: [[Int]]

    /// Names for `shape` from each face's base names.
    public static func make(bases rawBases: [[String]], shape: Shape) throws -> TopoNames {
        let t = try shape.topology()
        precondition(rawBases.count == t.faces, "one base-name list per face")
        let bases = rawBases.map { Array(Set($0)).sorted() }
        var faces = bases.map { $0.first ?? "face" }
        for (primary, group) in Dictionary(grouping: faces.indices, by: { faces[$0] }) where group.count > 1 {
            let keys = try group.map { (i: $0, key: try shape.face($0).centroid) }
            for (k, e) in keys.sorted(by: { Naming.precedes($0.key, $1.key) }).enumerated() { faces[e.i] = "\(primary)#\(k + 1)" }
        }
        var edges: [String] = []
        var edgeFaces: [[Int]] = []
        var mids: [Vec3] = []
        for e in 0..<t.edges {
            let info = try shape.edge(e)
            let adj = Array(Set(info.faces)).sorted()
            edgeFaces.append(adj)
            mids.append(info.midpoint)
            edges.append(adj.isEmpty ? "free" : adj.map { faces[$0] }.sorted().joined(separator: "|"))
        }
        for (base, group) in Dictionary(grouping: edges.indices, by: { edges[$0] }) where group.count > 1 {
            for (k, i) in group.sorted(by: { Naming.precedes(mids[$0], mids[$1]) }).enumerated() { edges[i] = "\(base)~\(k + 1)" }
        }
        return TopoNames(faces: faces, faceBases: bases, edges: edges, edgeFaces: edgeFaces)
    }

    /// Faces a name designates: the face with that name, else every piece of the face it was
    /// (same base name). Empty when nothing carries it any more.
    public func resolveFace(_ name: String) -> [Int] {
        if let i = faces.firstIndex(of: name) { return [i] }
        let base = Naming.faceBase(name)
        return faceBases.indices.filter { faceBases[$0].contains(base) }
    }

    /// Edges a name designates: the edge with that name, else every edge between the faces
    /// (or pieces of the faces) it named.
    public func resolveEdge(_ name: String) -> [Int] {
        if let i = edges.firstIndex(of: name) { return [i] }
        let parts = Naming.edgeParts(name).map(Naming.faceBase)
        guard !parts.isEmpty else { return [] }
        return edgeFaces.indices.filter { e in
            let adj = edgeFaces[e]
            switch (parts.count, adj.count) {
            case (1, 1): return faceBases[adj[0]].contains(parts[0])
            case (2, 2):
                let (a, b) = (faceBases[adj[0]], faceBases[adj[1]])
                return (a.contains(parts[0]) && b.contains(parts[1])) || (a.contains(parts[1]) && b.contains(parts[0]))
            case (2, 1):
                // A seam: one face on both sides.
                return parts[0] == parts[1] && faceBases[adj[0]].contains(parts[0])
            default: return false
            }
        }
    }
}

/// How an operation's generated faces are named.
struct NamingRoles {
    /// Faces generated from an input edge: "blend" (fillet, chamfer), "side" (extrude), "swept" (revolve).
    var fromEdge = "blend"
    var fromVertex = "corner"
    /// Faces generated from an input face (shell walls).
    var fromFace = "wall"
    var firstCap = "start_cap"
    var lastCap = "end_cap"
}

/// A shape with the base names of its faces, and names for its edges when they are the
/// generators of later faces (a profile's edges carry the sketch entities they came from).
struct NamedShape {
    var shape: Shape
    var faces: [[String]]
    var edges: [String]?

    init(_ shape: Shape, faces: [[String]], edges: [String]? = nil) {
        self.shape = shape
        self.faces = faces
        self.edges = edges
    }

    init(_ body: Body) {
        shape = body.shape
        faces = body.naming?.faceBases ?? []
        edges = body.naming?.edges
    }
}

enum Naming {
    /// Geometric order used to number the pieces of a split name (never kernel order).
    static func precedes(_ a: Vec3, _ b: Vec3) -> Bool {
        let q = { (v: Double) in (v * 1e6).rounded() }
        if q(a.x) != q(b.x) { return a.x < b.x }
        if q(a.y) != q(b.y) { return a.y < b.y }
        return q(a.z) < q(b.z)
    }

    /// A face name without its split ordinal: "A#2" → "A".
    static func faceBase(_ name: String) -> String {
        stripOrdinal(name, "#")
    }

    /// The face names of an edge name: "A|B~2" → ["A", "B"] (split at the top level only).
    static func edgeParts(_ name: String) -> [String] {
        let n = stripOrdinal(name, "~")
        var parts: [String] = [], depth = 0, current = ""
        for ch in n {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            if ch == "|" && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts.filter { !$0.isEmpty }
    }

    private static func stripOrdinal(_ name: String, _ mark: Character) -> String {
        guard let i = name.lastIndex(of: mark), !name[name.index(after: i)...].isEmpty,
            name[name.index(after: i)...].allSatisfy(\.isNumber), !name[i...].contains(")")
        else { return name }
        return String(name[..<i])
    }

    /// Base names of a result's faces from its history and the names of the operands.
    static func derive(_ result: Shape, operands: [NamedShape?], feature: String, roles: NamingRoles = NamingRoles()) throws -> [[String]] {
        let count = try result.topology().faces
        var same = [[String]](repeating: [], count: count)
        var made = [[String]](repeating: [], count: count)
        for r in result.history?.records ?? [] where r.outputIndex < count {
            let op = r.operand < operands.count ? operands[r.operand] : nil
            switch r.input {
            case .face:
                let bases = op.flatMap { r.inputIndex < $0.faces.count ? $0.faces[r.inputIndex] : nil } ?? []
                if r.relation == .same {
                    same[r.outputIndex] += bases.isEmpty ? ["\(feature):face"] : bases
                } else {
                    made[r.outputIndex].append("\(feature):\(roles.fromFace)(\(bases.first ?? "face"))")
                }
            case .edge:
                let gen = op?.edges.flatMap { r.inputIndex < $0.count ? $0[r.inputIndex] : nil }
                made[r.outputIndex].append("\(feature):\(roles.fromEdge)" + (gen.map { "(\($0))" } ?? ""))
            case .vertex:
                made[r.outputIndex].append("\(feature):\(roles.fromVertex)")
            case .firstCap:
                made[r.outputIndex].append("\(feature):\(roles.firstCap)")
            case .lastCap:
                made[r.outputIndex].append("\(feature):\(roles.lastCap)")
            case .segment:
                break
            }
        }
        return (0..<count).map { i in !same[i].isEmpty ? same[i] : !made[i].isEmpty ? made[i] : ["\(feature):new"] }
    }

    /// `result` of an operation on `operands`, named.
    static func named(_ result: Shape, _ operands: [NamedShape?], feature: String, roles: NamingRoles = NamingRoles()) throws -> NamedShape {
        NamedShape(result, faces: try derive(result, operands: operands, feature: feature, roles: roles))
    }

    /// Names for `part`, a piece of `whole` (the same faces, extracted without history):
    /// each face takes the names of the face of `whole` with the same centroid and area.
    static func transfer(from whole: NamedShape, to part: Shape) throws -> NamedShape {
        let wn = try whole.shape.topology().faces
        let wf = try (0..<wn).map { try whole.shape.face($0) }
        let faces = try (0..<(try part.topology().faces)).map { i -> [String] in
            let f = try part.face(i)
            let match = wf.firstIndex { ($0.centroid - f.centroid).length < 1e-6 && abs($0.area - f.area) < 1e-6 * max(1, f.area) }
            return match.flatMap { $0 < whole.faces.count ? whole.faces[$0] : nil } ?? ["face"]
        }
        return NamedShape(part, faces: faces)
    }

    /// Names of a profile's edges: the sketch entity each was built from.
    static func profileEdges(_ face: Shape, segmentIDs: [String]) throws -> [String] {
        var names = [String](repeating: "curve", count: try face.topology().edges)
        for r in face.history?.records ?? [] where r.input == .segment && r.outputIndex < names.count && r.inputIndex < segmentIDs.count {
            names[r.outputIndex] = segmentIDs[r.inputIndex]
        }
        return names
    }

    /// Primitive faces named by what they are: box "+x"…"-z", cylinder/cone "side", "top",
    /// "bottom", sphere/torus "surface".
    static func primitive(_ shape: Shape, feature: String, box: Bool = false, axis: Vec3 = .unitZ) throws -> [[String]] {
        let n = try shape.topology().faces
        return try (0..<n).map { i in
            let f = try shape.face(i)
            let role: String
            switch f.surfaceType {
            case .plane where box: role = axisRole(f.normal.normalized) ?? "plane"
            case .plane: role = f.normal.dot(axis) > 0 ? "top" : "bottom"
            case .cylinder, .cone: role = "side"
            default: role = "surface"
            }
            return ["\(feature):\(role)"]
        }
    }

    /// "+x", "-y"… for an axis-aligned normal.
    static func axisRole(_ d: Vec3) -> String? {
        for (v, name) in [(Vec3.unitX, "x"), (Vec3.unitY, "y"), (Vec3.unitZ, "z")] {
            let c = d.dot(v)
            if abs(c) > 0.999 { return (c > 0 ? "+" : "-") + name }
        }
        return nil
    }
}

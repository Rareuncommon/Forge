import ForgeCore
import ForgeKernel
import ForgeSketch
import Foundation

/// A solid (or other B-rep) body in a document.
///
/// M0 note: bodies are direct kernel results created by `body.*` commands. The parametric
/// feature tree (ForgeModel, M2) will own body creation; these commands then remain as the
/// low-level "direct" API used by tests and by the regeneration engine itself.
public struct Body: Sendable {
    public let id: String
    public var name: String
    public var shape: Shape
    /// Command that last produced this body's geometry.
    public var producedBy: String

    public init(id: String, name: String, shape: Shape, producedBy: String) {
        self.id = id
        self.name = name
        self.shape = shape
        self.producedBy = producedBy
    }
}

/// Complete, value-typed document state. Copying is cheap (shapes are shared immutable
/// references), which is what makes snapshots for undo, transactions and dry-run trivial.
public struct Document: Sendable {
    public let id: String
    public var name: String
    public var units: UnitSystem
    public internal(set) var bodyOrder: [String] = []
    public internal(set) var bodies: [String: Body] = [:]
    /// Explicit, queryable selection (SPEC §5.4: no hidden state). Entity reference strings.
    public var selection: [String] = []
    var nextBodyNumber = 1

    /// Sketches in creation order.
    public private(set) var sketchOrder: [String] = []
    public internal(set) var sketches: [String: Sketch] = [:]
    /// The sketch being edited (explicit edit-mode state, SPEC §5.4). Sketch commands default to it.
    public var activeSketch: String?
    var nextSketchNumber = 1

    /// The feature tree (docs/adr/0011): every body-producing command, in regeneration order.
    /// Bodies are the result of replaying it (see Features.swift).
    public internal(set) var features: [Feature] = []
    /// Features at index >= rollback are rolled back (not regenerated); nil = none.
    public internal(set) var rollback: Int?
    var nextFeatureNumber = 1
    var featureNameCounters: [String: Int] = [:]
    /// Bodies that exist without a feature (from v1 files): the start of every regeneration.
    public internal(set) var baseBodies: [Body] = []
    /// Display names given with body.rename, applied after regeneration.
    var bodyNames: [String: String] = [:]
    /// First feature whose inputs changed since the last regeneration.
    var dirtyFrom: Int?
    /// Body state before each feature (regeneration cache; not persisted).
    var snapshots: [BodyState] = []
    /// Ids the next addBody calls must use (a feature re-creating its bodies on regeneration).
    var pendingBodyIDs: [String] = []

    public init(id: String, name: String, units: UnitSystem = .mmgs) {
        self.id = id
        self.name = name
        self.units = units
    }

    /// Bodies in creation order (stable ordering, SPEC §5.4).
    public var orderedBodies: [Body] { bodyOrder.compactMap { bodies[$0] } }

    public mutating func addBody(name: String?, shape: Shape, producedBy: String) -> Body {
        let id: String
        if pendingBodyIDs.isEmpty {
            id = "body-\(nextBodyNumber)"
            nextBodyNumber += 1
        } else {
            id = pendingBodyIDs.removeFirst()
        }
        let body = Body(id: id, name: name ?? "Body\(id.dropFirst(5))", shape: shape, producedBy: producedBy)
        bodies[id] = body
        bodyOrder.append(id)
        return body
    }

    public mutating func replaceShape(of id: String, with shape: Shape, producedBy: String) throws {
        guard var b = bodies[id] else { throw unknownBody(id) }
        b.shape = shape
        b.producedBy = producedBy
        bodies[id] = b
    }

    public mutating func renameBody(_ id: String, to name: String) throws {
        guard bodies[id] != nil else { throw unknownBody(id) }
        bodies[id]!.name = name
        bodyNames[id] = name
    }

    public mutating func removeBody(_ id: String) throws {
        guard bodies.removeValue(forKey: id) != nil else { throw unknownBody(id) }
        bodyOrder.removeAll { $0 == id }
        pruneSelection()
    }

    /// Rebuild a document from persisted parts (document.open).
    public static func restore(
        id: String, name: String, units: UnitSystem, bodies: [Body], sketches: [Sketch], nextBody: Int, nextSketch: Int
    ) -> Document {
        var d = Document(id: id, name: name, units: units)
        for b in bodies {
            d.bodies[b.id] = b
            d.bodyOrder.append(b.id)
        }
        for var s in sketches {
            s.resolve()
            d.sketches[s.id] = s
            d.sketchOrder.append(s.id)
        }
        d.nextBodyNumber = nextBody
        d.nextSketchNumber = nextSketch
        return d
    }

    // MARK: sketches

    public var orderedSketches: [Sketch] { sketchOrder.compactMap { sketches[$0] } }

    public mutating func addSketch(name: String?, plane: SketchPlane) -> Sketch {
        let id = "sketch-\(nextSketchNumber)"
        nextSketchNumber += 1
        var sk = Sketch(id: id, name: name ?? "Sketch\(id.dropFirst(7))", plane: plane)
        sk.resolve()
        sketches[id] = sk
        sketchOrder.append(id)
        return sk
    }

    /// The sketch with this id, or the active sketch when `id` is nil.
    public func sketch(_ id: String?) throws -> Sketch {
        guard let id = id ?? activeSketch else {
            throw ForgeError(
                .preconditionFailed, "no sketch given and no sketch is being edited",
                suggestions: [
                    SuggestedFix(description: "Create a sketch on the Front plane", command: "sketch.create", params: ["plane": "front"]),
                    SuggestedFix(description: "Edit an existing sketch", command: "sketch.edit", params: ["sketch": .string(sketchOrder.last ?? "sketch-1")]),
                ])
        }
        if let s = sketches[id] { return s }
        let byName = orderedSketches.filter { $0.name == id }
        if byName.count == 1 { return byName[0] }
        throw ForgeError(
            .unknownEntity, "no sketch '\(id)'" + (sketchOrder.isEmpty ? "" : "; sketches: \(sketchOrder.joined(separator: ", "))"), entities: [id],
            suggestions: [SuggestedFix(description: "List document state", command: "document.state")])
    }

    public mutating func updateSketch(_ s: Sketch) {
        precondition(sketches[s.id] != nil)
        sketches[s.id] = s
        markDirty(usingSketch: s.id)
        pruneSelection()
    }

    public mutating func removeSketch(_ id: String) throws {
        let s = try sketch(id)
        sketches.removeValue(forKey: s.id)
        sketchOrder.removeAll { $0 == s.id }
        if activeSketch == s.id { activeSketch = nil }
        if let i = features.firstIndex(where: { $0.isSketch && $0.sketchID == s.id }) {
            features.remove(at: i)
            markDirty(from: i)
        }
        markDirty(usingSketch: s.id)
        pruneSelection()
    }

    // MARK: references

    /// Whether a reference string names something that currently exists: "body-1",
    /// "body-1/face-3", "sketch-2", "sketch-2/line-5".
    public func referenceExists(_ ref: String) -> Bool {
        let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
        guard let head = parts.first else { return false }
        if let sk = sketches[head] {
            return parts.count == 1 || sk.entities[parts[1]] != nil || sk.constraints.contains { $0.id == parts[1] }
        }
        guard let r = EntityRef(parsing: ref), let b = bodies[r.body] else { return false }
        guard let i = r.index, let t = try? b.shape.topology() else { return true }
        switch r.kind {
        case .body: return true
        case .face: return i < t.faces
        case .edge: return i < t.edges
        case .vertex: return i < t.vertices
        }
    }

    mutating func pruneSelection() {
        selection = selection.filter { referenceExists($0) }
    }

    public func body(_ id: String) throws -> Body {
        if let b = bodies[id] { return b }
        // Allow addressing by unique display name as a convenience.
        let byName = orderedBodies.filter { $0.name == id }
        if byName.count == 1 { return byName[0] }
        throw unknownBody(id)
    }

    func unknownBody(_ id: String) -> ForgeError {
        let known = bodyOrder.joined(separator: ", ")
        return ForgeError(
            .unknownEntity, "no body '\(id)' in document '\(self.id)'" + (known.isEmpty ? " (document has no bodies)" : "; bodies: \(known)"),
            entities: [id],
            suggestions: [SuggestedFix(description: "List bodies in the document", command: "query.bodies")])
    }
}

/// Reference to a body or a topological sub-entity: "body-1", "body-1/face-3", "body-1/edge-0".
///
/// M0: sub-entity indices are transient kernel indices (valid for the current geometry of
/// the body only). Persistent naming (docs/adr/0002) replaces them in M2.
public struct EntityRef: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable { case body, face, edge, vertex }
    public var body: String
    public var kind: Kind
    public var index: Int?

    public init(body: String, kind: Kind = .body, index: Int? = nil) {
        self.body = body
        self.kind = kind
        self.index = index
    }

    public init?(parsing s: String) {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        body = String(first)
        if parts.count == 1 {
            kind = .body
            index = nil
            return
        }
        guard parts.count == 2 else { return nil }
        let sub = parts[1]
        guard let dash = sub.lastIndex(of: "-"), let k = Kind(rawValue: String(sub[..<dash])), k != .body,
            let i = Int(sub[sub.index(after: dash)...]), i >= 0
        else { return nil }
        kind = k
        index = i
    }

    public var description: String {
        kind == .body ? body : "\(body)/\(kind.rawValue)-\(index ?? 0)"
    }

    public static func parse(_ s: String) throws -> EntityRef {
        guard let r = EntityRef(parsing: s) else {
            throw ForgeError(
                .invalidParams, "'\(s)' is not an entity reference (expected 'body-1', 'body-1/face-0', 'body-1/edge-3' or 'body-1/vertex-2')",
                entities: [s])
        }
        return r
    }
}

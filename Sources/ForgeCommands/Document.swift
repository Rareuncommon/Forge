import ForgeCore
import ForgeKernel
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
    public private(set) var bodyOrder: [String] = []
    public private(set) var bodies: [String: Body] = [:]
    /// Explicit, queryable selection (SPEC §5.4: no hidden state). Entity reference strings.
    public var selection: [String] = []
    var nextBodyNumber = 1

    public init(id: String, name: String, units: UnitSystem = .mmgs) {
        self.id = id
        self.name = name
        self.units = units
    }

    /// Bodies in creation order (stable ordering, SPEC §5.4).
    public var orderedBodies: [Body] { bodyOrder.compactMap { bodies[$0] } }

    public mutating func addBody(name: String?, shape: Shape, producedBy: String) -> Body {
        let id = "body-\(nextBodyNumber)"
        nextBodyNumber += 1
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
    }

    public mutating func removeBody(_ id: String) throws {
        guard bodies.removeValue(forKey: id) != nil else { throw unknownBody(id) }
        bodyOrder.removeAll { $0 == id }
        selection.removeAll { EntityRef(parsing: $0)?.body == id }
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

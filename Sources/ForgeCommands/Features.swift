import ForgeCore
import ForgeKernel
import ForgeSketch
import Foundation

// The feature tree (docs/adr/0011). A feature is a recorded body-producing command
// invocation — `body.extrude`, `body.fillet_edges`, `body.create_box`… — with its parameters.
// Bodies are the result of replaying the features in order against the current sketches, so
// editing a sketch dimension, a feature's parameters, suppressing, deleting or rolling back a
// feature regenerates the model. Replays go through the same Command implementations as the
// first run, so a feature always means exactly what its command means.
//
// Sketches are features too (`sketch.create`, no geometry of their own) so the tree keeps
// SolidWorks' order: a sketch, then the features built from it.
//
// Body ids are stable: a feature re-creates its bodies with the ids it produced first, so
// suppressing or deleting an earlier feature never renumbers later bodies.
//
// Limitation until ADR 0002 names land: fillet edges are stored as transient indices of the
// regenerated body; an upstream change that renumbers edges can move the fillet. Such edits
// are flagged by a warning status when the edge count of the body changes.

public struct Feature: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// The command replayed on regeneration ("sketch.create" for sketches).
    public var command: String
    public var params: JSONValue
    public var suppressed: Bool
    /// Bodies the feature created the first time it ran; regeneration re-uses these ids.
    public var createdBodies: [String]
    public var status: FeatureStatus
    /// Fillet: edge count of the body when the edges were picked (detects renumbering).
    public var edgeCount: Int?

    public var isSketch: Bool { command == "sketch.create" }
    public var sketchID: String? { params["sketch"]?.stringValue }

    enum CodingKeys: String, CodingKey {
        case id, name, command, params, suppressed, status
        case createdBodies = "created_bodies"
        case edgeCount = "edge_count"
    }
}

public struct FeatureStatus: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable { case ok, warning, error, suppressed, rolledBack = "rolled_back" }
    public var state: State
    public var error: ForgeError?

    public static let ok = FeatureStatus(state: .ok, error: nil)
}

/// Body state between features (regeneration cache).
struct BodyState: Sendable {
    var bodies: [String: Body]
    var order: [String]
}

extension Document {
    /// Commands whose invocations become features.
    public static let featureCommands: Set<String> = [
        "body.extrude", "body.revolve", "body.boolean", "body.transform", "body.fillet_edges", "body.delete",
        "body.create_box", "body.create_cylinder", "body.create_sphere", "body.create_cone", "body.create_torus",
    ]

    /// Feature name stem, SolidWorks style ("Boss-Extrude" → "Boss-Extrude1").
    static func featureStem(_ command: String, _ params: JSONValue) -> String {
        switch command {
        case "body.extrude": params["operation"]?.stringValue == "cut" ? "Cut-Extrude" : "Boss-Extrude"
        case "body.revolve": params["operation"]?.stringValue == "cut" ? "Cut-Revolve" : "Revolve"
        case "body.boolean": "Combine"
        case "body.transform": params["copy"]?.boolValue == true ? "Body-Move/Copy" : "Body-Move"
        case "body.fillet_edges": "Fillet"
        case "body.delete": "Body-Delete/Keep"
        case "body.create_box": "Box"
        case "body.create_cylinder": "Cylinder"
        case "body.create_sphere": "Sphere"
        case "body.create_cone": "Cone"
        case "body.create_torus": "Torus"
        default: "Feature"
        }
    }

    /// Record a feature for a command that just ran (at the rollback position).
    mutating func recordFeature(command: String, params: JSONValue, createdBodies: [String], sketchName: String? = nil, edgeCount: Int? = nil) {
        let id = "feature-\(nextFeatureNumber)"
        nextFeatureNumber += 1
        let name: String
        if let sketchName {
            name = sketchName
        } else {
            let stem = Self.featureStem(command, params)
            let n = (featureNameCounters[stem] ?? 0) + 1
            featureNameCounters[stem] = n
            name = "\(stem)\(n)"
        }
        let f = Feature(id: id, name: name, command: command, params: params, suppressed: false, createdBodies: createdBodies, status: .ok, edgeCount: edgeCount)
        let at = rollback ?? features.count
        features.insert(f, at: at)
        if let r = rollback { rollback = r + 1 }
        // The body state before later features changed; their snapshots are stale.
        if snapshots.count > at { snapshots.removeSubrange(at...) }
    }

    func featureIndex(_ ref: String) throws -> Int {
        if let i = features.firstIndex(where: { $0.id == ref }) { return i }
        let byName = features.indices.filter { features[$0].name == ref }
        if byName.count == 1 { return byName[0] }
        throw ForgeError(
            .unknownEntity, "no feature '\(ref)'" + (features.isEmpty ? "" : "; features: \(features.map(\.name).joined(separator: ", "))"),
            entities: [ref], suggestions: [SuggestedFix(description: "List the feature tree", command: "feature.list")])
    }

    mutating func markDirty(from index: Int) {
        dirtyFrom = min(dirtyFrom ?? index, index)
    }

    /// A sketch changed: regenerate from the first feature built from it.
    mutating func markDirty(usingSketch id: String) {
        if let i = features.firstIndex(where: { !$0.isSketch && $0.params["sketch"]?.stringValue == id }) { markDirty(from: i) }
    }

    var currentBodyState: BodyState { BodyState(bodies: bodies, order: bodyOrder) }

    mutating func restoreBodies(_ s: BodyState) {
        bodies = s.bodies
        bodyOrder = s.order
    }

    /// Replay the features from `start` (all when 0) and record each one's status. Errors do
    /// not stop the walk: a failed feature contributes nothing, later ones still run.
    mutating func regenerate(from start: Int = 0, registry: CommandRegistry) {
        let begin = min(start, snapshots.count)
        if begin == 0 {
            restoreBodies(BodyState(bodies: Dictionary(uniqueKeysWithValues: baseBodies.map { ($0.id, $0) }), order: baseBodies.map(\.id)))
            snapshots = []
        } else {
            restoreBodies(snapshots[begin])
            snapshots.removeSubrange(begin...)
        }
        let limit = rollback ?? features.count
        for i in begin..<features.count {
            snapshots.append(currentBodyState)
            var f = features[i]
            defer { features[i] = f }
            if i >= limit {
                f.status = FeatureStatus(state: .rolledBack, error: nil)
                continue
            }
            if f.suppressed {
                f.status = FeatureStatus(state: .suppressed, error: nil)
                continue
            }
            if f.isSketch {
                let report = f.sketchID.flatMap { sketches[$0]?.report }
                f.status = report?.status == .conflicting || report?.status == .failed
                    ? FeatureStatus(state: .warning, error: ForgeError(.sketchConflict, "the sketch is over defined or cannot be solved"))
                    : .ok
                continue
            }
            let before = currentBodyState
            let edgeCounts = Dictionary(uniqueKeysWithValues: before.order.compactMap { id in (try? bodies[id]?.shape.topology().edges).map { (id, $0) } })
            do {
                guard let d = try? registry.descriptor(f.command) else {
                    throw ForgeError(.unknownCommand, "unknown command '\(f.command)'")
                }
                pendingBodyIDs = f.createdBodies
                var session = SessionState()
                session.adopt(self, path: nil)
                var ctx = CommandContext(session: session, documentID: id, registry: registry, dryRun: false)
                _ = try d.invoke(f.params, units, &ctx)
                let after = ctx.document
                restoreBodies(after.currentBodyState)
                nextBodyNumber = max(nextBodyNumber, after.nextBodyNumber)
                f.status = .ok
                // Fillet edges are indices (see the file comment): warn when the body they
                // index was rebuilt with a different number of edges.
                if f.command == "body.fillet_edges", let b = f.params["body"]?.stringValue, let n = edgeCounts[b],
                    let recorded = f.edgeCount, recorded != n
                {
                    f.status = FeatureStatus(
                        state: .warning,
                        error: ForgeError(.referenceLost, "the edges of \(b) changed upstream; check that the fillet is on the intended edges", entities: [b]))
                }
            } catch {
                restoreBodies(before)
                f.status = FeatureStatus(state: .error, error: ForgeError.wrap(error))
            }
            pendingBodyIDs = []
        }
        for (id, name) in bodyNames where bodies[id] != nil { bodies[id]!.name = name }
        dirtyFrom = nil
        pruneSelection()
    }
}

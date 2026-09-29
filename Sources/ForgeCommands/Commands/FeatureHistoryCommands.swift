import ForgeCore
import Foundation

public enum FeatureGet: Command {
    public typealias Params = FeatureRef
    public typealias Output = FeatureView
    public static let name = "feature.get"
    public static let summary = "Inspect one feature's parameters, outputs and regeneration status"
    public static let category = CommandCategory.feature
    public static let undo = UndoBehavior.none
    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        return FeatureView(doc.features[try doc.featureIndex(p.feature)])
    }
}

public struct FeatureDependencyOutput: Codable, Sendable {
    public var feature: String
    public var parents: [String]
    public var children: [String]
    public var ancestors: [String]
    public var descendants: [String]
}

public enum FeatureDependencies: Command {
    public typealias Params = FeatureRef
    public typealias Output = FeatureDependencyOutput
    public static let name = "feature.dependencies"
    public static let summary = "Inspect a feature's direct and transitive parent/child relationships"
    public static let discussion = "Returns feature ids in history order. Includes sketches, placement references, pattern seeds, body modification order and implicit all-body scope. Dependencies are conservative for suppressed features."
    public static let category = CommandCategory.feature
    public static let undo = UndoBehavior.none
    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let id = doc.features[try doc.featureIndex(p.feature)].id
        let graph = doc.historyDependencies(registry: ctx.registry)
        let children = graph.reduce(into: [String: Set<String>]()) { result, pair in
            for parent in pair.value { result[parent, default: []].insert(pair.key) }
        }
        func closure(_ edges: [String: Set<String>]) -> Set<String> {
            var found = Set<String>(), pending = Array(edges[id] ?? [])
            while let next = pending.popLast() {
                if found.insert(next).inserted { pending += edges[next] ?? [] }
            }
            return found
        }
        func ordered(_ ids: Set<String>) -> [String] { doc.features.map(\.id).filter(ids.contains) }
        return Output(feature: id, parents: ordered(graph[id] ?? []), children: ordered(children[id] ?? []),
                      ancestors: ordered(closure(graph)), descendants: ordered(closure(children)))
    }
}

public enum FeatureReorder: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var feature: String
        public var before: String?
        public static let fieldDocs: [String: FieldDoc] = [
            "feature": "Feature id or unique name to move",
            "before": FieldDoc("Move immediately before this feature id or name; omit to move to the end", default: "end"),
        ]
    }
    public typealias Output = FeatureTreeOutput
    public static let name = "feature.reorder"
    public static let summary = "Move a feature in history after validating dependencies and rebuilding the proposed order"
    public static let discussion = "Refuses moves across parent/child relationships or changes to implicit body scopes. The entire proposed model must rebuild without errors or reference warnings; failed moves leave the document unchanged. Roll forward to the end before reordering."
    public static let category = CommandCategory.feature
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.invalidParams, .unknownEntity]
    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        guard doc.rollback == nil else {
            throw ForgeError(.invalidParams, "Roll forward before reordering features", suggestions: [SuggestedFix(description: "Roll forward to the end", command: "feature.rollback")])
        }
        let index = try doc.featureIndex(p.feature)
        let destination = try p.before.map { try doc.featureIndex($0) } ?? doc.features.count
        if index == destination || index + 1 == destination { return FeatureTreeOutput(doc) }
        let original = doc.historyDependencies(registry: ctx.registry)
        let originalBodies = Set(doc.bodyOrder)
        let originalPlanes = Set(doc.refPlaneOrder)
        let feature = doc.features.remove(at: index)
        doc.features.insert(feature, at: destination > index ? destination - 1 : destination)
        let positions = Dictionary(uniqueKeysWithValues: doc.features.enumerated().map { ($0.element.id, $0.offset) })
        for child in doc.features {
            for parent in original[child.id] ?? [] where positions[parent, default: -1] >= positions[child.id, default: 0] {
                throw ForgeError(.invalidParams, "Cannot move \(child.name) before its parent \(parent)", entities: [child.id, parent],
                                 suggestions: [SuggestedFix(description: "Inspect dependencies", command: "feature.dependencies", params: ["feature": .string(child.id)])])
            }
        }
        doc.regenerate(from: 0, registry: ctx.registry)
        if let failed = doc.features.first(where: { $0.status.state == .error || $0.status.error?.code == .referenceLost }) {
            throw ForgeError(.invalidParams, "Proposed order cannot rebuild \(failed.name): \(failed.status.error?.message ?? "reference warning")", entities: [failed.id])
        }
        guard Set(doc.bodyOrder) == originalBodies, Set(doc.refPlaneOrder) == originalPlanes else {
            throw ForgeError(.invalidParams, "This move changes which body or plane ids survive regeneration", entities: [feature.id])
        }
        let proposed = doc.historyDependencies(registry: ctx.registry)
        guard original == proposed else {
            throw ForgeError(.invalidParams, "This move changes body scope or reference dependencies; use explicit feature scopes before reordering", entities: [feature.id])
        }
        ctx.document = doc
        return FeatureTreeOutput(doc)
    }
}

extension Document {
    /// Replay a copy to inspect each body's last writer; never mutate the queried document.
    /// Scope dependencies include every candidate body, even when geometry currently misses it.
    func historyDependencies(registry: CommandRegistry) -> [String: Set<String>] {
        var replay = self
        if replay.rollback != nil || replay.dirtyFrom != nil || replay.snapshots.count != replay.features.count {
            replay.rollback = nil
            replay.regenerate(from: 0, registry: registry)
        }
        let creators = features.reduce(into: [String: String]()) { result, f in
            for output in f.createdBodies { result[output] = f.id }
            if f.isSketch, let sketch = f.sketchID { result[sketch] = f.id }
        }
        var writers = [String: String](), graph = [String: Set<String>]()
        let refKeys: Set<String> = ["body", "target", "tool", "scope", "edges", "faces", "neutral_plane", "reference", "plane", "face", "sketch", "profile", "profiles", "path", "features", "axis", "direction", "direction2"]
        for (i, f) in features.enumerated() {
            let before = replay.snapshots[i]
            let after = i + 1 < replay.snapshots.count ? replay.snapshots[i + 1] : replay.currentBodyState
            var parents = Set<String>()
            func add(_ id: String?) { if let id, id != f.id { parents.insert(id) } }
            func reference(_ value: String) {
                let root = String(value.split(separator: "/", maxSplits: 1).first ?? Substring(value))
                let body = before.bodies[root] ?? before.bodies.values.first(where: { $0.name == root })
                let bodyID = body?.id ?? root
                add(writers[bodyID] ?? creators[bodyID])
                if let plane = before.planes[root] ?? before.planes.values.first(where: { $0.name == root }) { add(creators[plane.id]) }
                if let j = try? featureIndex(value) { add(features[j].id) }
                // Persistent topology names can refer to older generators than the last body writer.
                for match in value.matches(of: #/feature-[0-9]+:/#) { add(String(match.output.dropLast())) }
            }
            func walk(_ value: JSONValue, relevant: Bool = false) {
                switch value {
                case .string(let s): if relevant { reference(s) }
                case .array(let a): for v in a { walk(v, relevant: relevant) }
                case .object(let o): for (k, v) in o { walk(v, relevant: refKeys.contains(k)) }
                default: break
                }
            }
            walk(f.params)
            if f.isSketch, let sid = f.sketchID, let placement = sketches[sid]?.placement { reference(placement) }
            let implicitScope = (f.params["scope"] == nil || f.params["scope"]?.isNull == true) && (
                f.params["operation"]?.stringValue == "cut" || f.params["merge"]?.boolValue == true ||
                f.command == "body.hole" || f.command == "body.rib" || f.command.hasPrefix("pattern.") ||
                ["through_all", "through_all_both"].contains(f.params["end_condition"]?.stringValue ?? "") ||
                ["through_all", "through_all_both"].contains(f.params["direction2"]?["end_condition"]?.stringValue ?? ""))
            if implicitScope { for body in before.order { add(writers[body] ?? creators[body]) } }
            graph[f.id] = parents
            for body in Set(before.order + after.order) {
                if before.bodies[body]?.shape !== after.bodies[body]?.shape { writers[body] = f.id }
            }
            for output in f.createdBodies { writers[output] = f.id }
        }
        return graph
    }
}

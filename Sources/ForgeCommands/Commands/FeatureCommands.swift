import ForgeCore
import Foundation

// Feature tree commands (docs/adr/0011 §6): list, edit, rename, suppress, delete, roll back,
// regenerate. Features are created by the body commands themselves (body.extrude records a
// Boss-Extrude feature, and so on).

public struct FeatureView: Codable, Sendable {
    public var id: String
    public var name: String
    /// The command the feature replays ("sketch.create" for a sketch).
    public var command: String
    public var params: JSONValue
    public var suppressed: Bool
    /// ok, warning, error, suppressed or rolled_back.
    public var state: String
    public var error: String?
    public var errorCode: String?
    public var createdBodies: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, command, params, suppressed, state, error
        case errorCode = "error_code"
        case createdBodies = "created_bodies"
    }

    init(_ f: Feature) {
        id = f.id
        name = f.name
        command = f.command
        params = f.params
        suppressed = f.suppressed
        state = f.status.state.rawValue
        error = f.status.error?.message
        errorCode = f.status.error?.code.rawValue
        createdBodies = f.createdBodies
    }
}

public struct FeatureTreeOutput: Codable, Sendable {
    public var features: [FeatureView]
    /// Number of active features (features from this index on are rolled back); null = all.
    public var rollback: Int?

    init(_ doc: Document) {
        features = doc.features.map(FeatureView.init)
        rollback = doc.rollback
    }
}

public struct FeatureRef: Codable, Sendable, SchemaDocumented {
    public var feature: String
    public static let fieldDocs: [String: FieldDoc] = ["feature": "Feature id (feature-3) or name (Boss-Extrude1)"]
}

public enum FeatureList: Command {
    public typealias Params = NoParams
    public typealias Output = FeatureTreeOutput

    public static let name = "feature.list"
    public static let summary = "The feature tree: every feature in regeneration order with its parameters and status"
    public static let category = CommandCategory.feature
    public static let undo = UndoBehavior.none

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        FeatureTreeOutput(try ctx.requireDocument())
    }
}

public enum FeatureEdit: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var feature: String
        public var params: JSONValue
        public var replace: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "feature": "Feature id or name",
            "params": "New parameters of the feature's command (see help.describe_command for it); merged into the current ones",
            "replace": FieldDoc("Replace all parameters instead of merging", default: false),
        ]
    }
    public typealias Output = FeatureTreeOutput

    public static let name = "feature.edit"
    public static let summary = "Change a feature's parameters (e.g. an extrusion's depth) and regenerate the model"
    public static let discussion = "Later features regenerate on the new result. A feature that can no longer be built keeps its place in the tree with an error status (features after it still regenerate)."
    public static let category = CommandCategory.feature
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams]
    public static let examples: [JSONValue] = [["feature": "Boss-Extrude1", "params": ["depth": 25]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let i = try doc.featureIndex(p.feature)
        let f = doc.features[i]
        guard !f.isSketch else {
            throw ForgeError(
                .invalidParams, "\(f.name) is a sketch; edit it with sketch.edit and the sketch commands", entities: [f.id],
                suggestions: [SuggestedFix(description: "Edit the sketch", command: "sketch.edit", params: ["sketch": .string(f.sketchID ?? "")])])
        }
        guard let changes = p.params.objectValue else { throw ForgeError(.invalidParams, "params must be an object") }
        var merged = p.replace == true ? [:] : (f.params.objectValue ?? [:])
        for (k, v) in changes { merged[k] = v }
        let d = try ctx.registry.descriptor(f.command)
        let problems = SchemaValidator.validate(.object(merged), against: d.paramsSchema)
        if !problems.isEmpty { throw ForgeError(.invalidParams, problems.joined(separator: "; "), entities: [f.id]) }
        try d.check(.object(merged), doc.units)
        doc.features[i].params = .object(merged)
        doc.regenerate(from: i, registry: ctx.registry)
        ctx.document = doc
        return FeatureTreeOutput(doc)
    }
}

public enum FeatureRename: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var feature: String
        public var name: String
        public static let fieldDocs: [String: FieldDoc] = ["feature": "Feature id or name", "name": "New name"]
    }
    public typealias Output = FeatureTreeOutput

    public static let name = "feature.rename"
    public static let summary = "Rename a feature in the tree"
    public static let category = CommandCategory.feature
    public static let undo = UndoBehavior.undoable
    public static let examples: [JSONValue] = [["feature": "Boss-Extrude1", "name": "Base Plate"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let i = try doc.featureIndex(p.feature)
        let name = p.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ForgeError(.invalidParams, "the name is empty") }
        doc.features[i].name = name
        if let s = doc.features[i].sketchID, var sk = doc.sketches[s] {
            sk.name = name
            doc.sketches[s] = sk
        }
        ctx.document = doc
        return FeatureTreeOutput(doc)
    }
}

public enum FeatureSuppress: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var feature: String
        public var suppressed: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "feature": "Feature id or name",
            "suppressed": FieldDoc("true to suppress, false to unsuppress", default: true),
        ]
    }
    public typealias Output = FeatureTreeOutput

    public static let name = "feature.suppress"
    public static let summary = "Suppress (or unsuppress) a feature: the model regenerates without it"
    public static let category = CommandCategory.feature
    public static let undo = UndoBehavior.undoable
    public static let examples: [JSONValue] = [["feature": "Fillet1"], ["feature": "Fillet1", "suppressed": false]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let i = try doc.featureIndex(p.feature)
        doc.features[i].suppressed = p.suppressed ?? true
        doc.regenerate(from: i, registry: ctx.registry)
        ctx.document = doc
        return FeatureTreeOutput(doc)
    }
}

public enum FeatureDelete: Command {
    public typealias Params = FeatureRef
    public typealias Output = FeatureTreeOutput

    public static let name = "feature.delete"
    public static let summary = "Delete a feature (a sketch feature deletes the sketch) and regenerate"
    public static let discussion = "Features that used what it produced report errors after regeneration; delete or edit them too."
    public static let category = CommandCategory.feature
    public static let undo = UndoBehavior.undoable
    public static let examples: [JSONValue] = [["feature": "Fillet1"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let i = try doc.featureIndex(p.feature)
        let f = doc.features[i]
        if f.isSketch, let s = f.sketchID, doc.sketches[s] != nil {
            try doc.removeSketch(s)  // also removes the feature
        } else {
            doc.features.remove(at: i)
        }
        if let r = doc.rollback, i < r { doc.rollback = r - 1 }
        doc.regenerate(from: i, registry: ctx.registry)
        ctx.document = doc
        return FeatureTreeOutput(doc)
    }
}

public enum FeatureRollback: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var before: String?
        public static let fieldDocs: [String: FieldDoc] = [
            "before": FieldDoc("Roll back to just before this feature (id or name); omit to roll forward to the end", default: "end")
        ]
    }
    public typealias Output = FeatureTreeOutput

    public static let name = "feature.rollback"
    public static let summary = "Move the rollback bar: features from the given one on are not regenerated; new features insert there"
    public static let category = CommandCategory.feature
    public static let undo = UndoBehavior.undoable
    public static let examples: [JSONValue] = [["before": "Fillet1"], [:]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        let old = doc.rollback ?? doc.features.count
        let new = try p.before.map { try doc.featureIndex($0) } ?? doc.features.count
        doc.rollback = new >= doc.features.count ? nil : new
        doc.regenerate(from: min(old, new), registry: ctx.registry)
        ctx.document = doc
        return FeatureTreeOutput(doc)
    }
}

public enum DocumentRegenerate: Command {
    public typealias Params = NoParams
    public typealias Output = FeatureTreeOutput

    public static let name = "document.regenerate"
    public static let summary = "Rebuild every feature from the start (Ctrl+Q in SolidWorks)"
    public static let category = CommandCategory.feature
    public static let undo = UndoBehavior.undoable

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        doc.regenerate(from: 0, registry: ctx.registry)
        ctx.document = doc
        return FeatureTreeOutput(doc)
    }
}

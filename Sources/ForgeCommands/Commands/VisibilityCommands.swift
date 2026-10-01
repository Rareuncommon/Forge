import ForgeCore

public struct BodyVisibilityState: Codable, Sendable {
    public var hiddenBodies: [String]
    public var visibleBodies: [String]
    public var isolatedBodies: [String]?
    enum CodingKeys: String, CodingKey {
        case hiddenBodies = "hidden_bodies", visibleBodies = "visible_bodies", isolatedBodies = "isolated_bodies"
    }
    public init(_ doc: Document) {
        hiddenBodies = doc.bodyOrder.filter { doc.hiddenBodyIDs.contains($0) }
        visibleBodies = doc.bodyOrder.filter { doc.isBodyVisible($0) }
        isolatedBodies = doc.isolatedBodyIDs.map { ids in doc.bodyOrder.filter { ids.contains($0) } }
    }
}

public enum ViewSetVisibility: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var bodies: [String]
        public var visible: Bool
        public static let fieldDocs: [String: FieldDoc] = ["bodies": "Body IDs or names to show or hide", "visible": "True shows bodies; false hides them"]
        public func validate() throws {
            guard !bodies.isEmpty else { throw ForgeError(.invalidParams, "choose at least one body") }
        }
    }
    public static let name = "view.set_visibility"
    public static let summary = "Show or hide bodies without changing their geometry"
    public static let discussion = "Ordinary visibility is saved with the document. During isolation, changes affect only the temporary isolation whitelist. Hidden bodies cannot be picked in rendered views; geometry queries and file exports still include them."
    public static let category = CommandCategory.view
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams]
    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> BodyVisibilityState {
        var doc = try ctx.requireDocument()
        let ids = Set(try p.bodies.map { try doc.body($0).id })
        if var isolation = doc.isolatedBodyIDs {
            if p.visible { isolation.formUnion(ids) } else { isolation.subtract(ids) }
            doc.isolatedBodyIDs = isolation
        } else if p.visible { doc.hiddenBodyIDs.subtract(ids) }
        else { doc.hiddenBodyIDs.formUnion(ids) }
        ctx.document = doc
        return BodyVisibilityState(doc)
    }
}

public enum ViewIsolate: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var bodies: [String]
        public static let fieldDocs: [String: FieldDoc] = ["bodies": "Bodies to show exclusively until Exit Isolation; may include hidden bodies"]
        public func validate() throws {
            guard !bodies.isEmpty else { throw ForgeError(.invalidParams, "choose at least one body to isolate") }
        }
    }
    public static let name = "view.isolate"
    public static let summary = "Temporarily show only the specified bodies"
    public static let discussion = "Exit Isolation restores saved visibility. Isolation is not saved in document packages; new bodies remain outside the isolation whitelist."
    public static let category = CommandCategory.view
    public static let undo = UndoBehavior.undoable
    public static let errors: [ErrorCode] = [.unknownEntity, .invalidParams]
    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> BodyVisibilityState {
        var doc = try ctx.requireDocument()
        doc.isolatedBodyIDs = Set(try p.bodies.map { try doc.body($0).id })
        ctx.document = doc
        return BodyVisibilityState(doc)
    }
}

public enum ViewExitIsolation: Command {
    public typealias Params = NoParams
    public static let name = "view.exit_isolation"
    public static let summary = "Exit isolation and restore ordinary body visibility"
    public static let category = CommandCategory.view
    public static let undo = UndoBehavior.undoable
    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> BodyVisibilityState {
        var doc = try ctx.requireDocument()
        doc.isolatedBodyIDs = nil
        ctx.document = doc
        return BodyVisibilityState(doc)
    }
}

public enum ViewShowAll: Command {
    public typealias Params = NoParams
    public static let name = "view.show_all"
    public static let summary = "Show all bodies and exit isolation"
    public static let category = CommandCategory.view
    public static let undo = UndoBehavior.undoable
    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> BodyVisibilityState {
        var doc = try ctx.requireDocument()
        doc.hiddenBodyIDs = []
        doc.isolatedBodyIDs = nil
        ctx.document = doc
        return BodyVisibilityState(doc)
    }
}

import ForgeCore
import Foundation

// Document management, undo/redo and transactions. These act on session state and are
// themselves not undoable (UndoBehavior.session).

public struct UnitsParams: Codable, Sendable, SchemaDocumented {
    public var length: LengthUnit?
    public var angle: AngleUnit?
    public static let fieldDocs: [String: FieldDoc] = [
        "length": FieldDoc("Length unit for bare numbers", default: "mm"),
        "angle": FieldDoc("Angle unit for bare numbers", default: "deg"),
    ]
}

public enum DocumentNew: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var name: String?
        public var units: UnitsParams?
        public static let fieldDocs: [String: FieldDoc] = [
            "name": FieldDoc("Display name", default: "Part<n>"),
            "units": "Document unit system; bare numbers in later commands use these units",
        ]
    }
    public struct Output: Codable, Sendable { public var document: DocumentSummary }

    public static let name = "document.new"
    public static let summary = "Create a new empty part document and make it active"
    public static let category = CommandCategory.document
    public static let undo = UndoBehavior.session
    public static let examples: [JSONValue] = [[:], ["name": "Bracket", "units": ["length": "in"]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let units = UnitSystem(length: p.units?.length ?? .millimeter, angle: p.units?.angle ?? .degree)
        let doc = ctx.session.createDocument(name: p.name, units: units)
        return Output(document: DocumentSummary(doc, active: true))
    }
}

public enum DocumentList: Command {
    public typealias Params = NoParams
    public struct Output: Codable, Sendable {
        public var documents: [DocumentSummary]
        public var active: String?
    }

    public static let name = "document.list"
    public static let summary = "List open documents"
    public static let category = CommandCategory.document
    public static let undo = UndoBehavior.none

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let s = ctx.session
        return Output(
            documents: s.documentOrder.compactMap { id in s.documents[id].map { DocumentSummary($0.document, active: id == s.activeDocumentID) } },
            active: s.activeDocumentID)
    }
}

public enum DocumentActivate: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var document: String
        public static let fieldDocs: [String: FieldDoc] = ["document": "Document id (e.g. \"doc-1\")"]
    }
    public struct Output: Codable, Sendable { public var active: String }

    public static let name = "document.activate"
    public static let summary = "Make a document the active one (the default target of commands)"
    public static let category = CommandCategory.document
    public static let undo = UndoBehavior.session
    public static let errors: [ErrorCode] = [.unknownEntity]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        guard ctx.session.documents[p.document] != nil else {
            throw ForgeError(.unknownEntity, "no open document '\(p.document)'", entities: [p.document],
                             suggestions: [SuggestedFix(description: "List open documents", command: "document.list")])
        }
        ctx.session.activeDocumentID = p.document
        return Output(active: p.document)
    }
}

public enum DocumentClose: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var document: String?
        public static let fieldDocs: [String: FieldDoc] = ["document": FieldDoc("Document id", default: "active document")]
    }
    public struct Output: Codable, Sendable {
        public var closed: String
        public var active: String?
    }

    public static let name = "document.close"
    public static let summary = "Close a document, discarding unsaved changes and its undo history"
    public static let category = CommandCategory.document
    public static let undo = UndoBehavior.session
    public static let errors: [ErrorCode] = [.unknownEntity, .preconditionFailed]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        guard let id = p.document ?? ctx.session.activeDocumentID, ctx.session.documents[id] != nil else {
            throw ForgeError(.unknownEntity, "no such open document", suggestions: [SuggestedFix(description: "List open documents", command: "document.list")])
        }
        ctx.session.documents.removeValue(forKey: id)
        ctx.session.documentOrder.removeAll { $0 == id }
        if ctx.session.activeDocumentID == id { ctx.session.activeDocumentID = ctx.session.documentOrder.last }
        return Output(closed: id, active: ctx.session.activeDocumentID)
    }
}

public enum DocumentState: Command {
    public typealias Params = NoParams
    public struct Output: Codable, Sendable {
        public var document: DocumentSummary
        public var bodies: [BodySummary]
        public var sketches: [SketchSummary]
        public var activeSketch: String?
        public var selection: [String]
        public var undo: [String]
        public var redo: [String]
        public var transaction: String?

        enum CodingKeys: String, CodingKey {
            case document, bodies, sketches, selection, undo, redo, transaction
            case activeSketch = "active_sketch"
        }
    }

    public static let name = "document.state"
    public static let summary = "Full explicit state of the active document: bodies, sketches, sketch being edited, selection, undo/redo stacks, open transaction"
    public static let discussion = "Nothing about the session is hidden: everything that affects how later commands behave is returned here (SPEC §5.4)."
    public static let category = CommandCategory.document
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.preconditionFailed]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let s = ctx.session.documents[doc.id]!
        return Output(
            document: DocumentSummary(doc, active: doc.id == ctx.session.activeDocumentID),
            bodies: try doc.orderedBodies.map(BodySummary.init),
            sketches: doc.orderedSketches.map { SketchSummary($0, active: $0.id == doc.activeSketch) }, activeSketch: doc.activeSketch,
            selection: doc.selection,
            undo: s.undoLabels, redo: s.redoLabels, transaction: s.transactionLabel)
    }
}

public enum EditUndo: Command {
    public typealias Params = NoParams
    public struct Output: Codable, Sendable { public var undone: String }

    public static let name = "edit.undo"
    public static let summary = "Undo the last change (a command or a committed transaction)"
    public static let category = CommandCategory.edit
    public static let undo = UndoBehavior.session
    public static let errors: [ErrorCode] = [.nothingToUndo, .transactionActive, .preconditionFailed]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        return Output(undone: try ctx.session.undo(documentID: doc.id))
    }
}

public enum EditRedo: Command {
    public typealias Params = NoParams
    public struct Output: Codable, Sendable { public var redone: String }

    public static let name = "edit.redo"
    public static let summary = "Redo the last undone change"
    public static let category = CommandCategory.edit
    public static let undo = UndoBehavior.session
    public static let errors: [ErrorCode] = [.nothingToRedo, .transactionActive, .preconditionFailed]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        return Output(redone: try ctx.session.redo(documentID: doc.id))
    }
}

public enum TransactionBegin: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var label: String?
        public static let fieldDocs: [String: FieldDoc] = ["label": FieldDoc("Name of the undo step the transaction becomes", default: "transaction")]
    }
    public struct Output: Codable, Sendable { public var label: String }

    public static let name = "transaction.begin"
    public static let summary = "Start grouping subsequent changes into one atomic, undoable step"
    public static let discussion = "Commit to keep the changes as a single undo step, or roll back to discard them all. Transactions do not nest."
    public static let category = CommandCategory.edit
    public static let undo = UndoBehavior.session
    public static let errors: [ErrorCode] = [.transactionActive, .preconditionFailed]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let label = p.label ?? "transaction"
        try ctx.session.beginTransaction(documentID: doc.id, label: label)
        return Output(label: label)
    }
}

public struct TransactionEndOutput: Codable, Sendable {
    public var label: String
    public var changes: ChangeSet
}

public enum TransactionCommit: Command {
    public typealias Params = NoParams
    public typealias Output = TransactionEndOutput

    public static let name = "transaction.commit"
    public static let summary = "Commit the open transaction as one undo step"
    public static let category = CommandCategory.edit
    public static let undo = UndoBehavior.session
    public static let errors: [ErrorCode] = [.noTransaction, .preconditionFailed]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let (label, changes) = try ctx.session.commitTransaction(documentID: doc.id)
        return Output(label: label, changes: changes)
    }
}

public enum TransactionRollback: Command {
    public typealias Params = NoParams
    public typealias Output = TransactionEndOutput

    public static let name = "transaction.rollback"
    public static let summary = "Discard every change made since the transaction began"
    public static let category = CommandCategory.edit
    public static let undo = UndoBehavior.session
    public static let errors: [ErrorCode] = [.noTransaction, .preconditionFailed]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let (label, changes) = try ctx.session.rollbackTransaction(documentID: doc.id)
        return Output(label: label, changes: changes)
    }
}

// MARK: - Discovery (also exposed as dedicated MCP tools)

public enum HelpListCommands: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var category: CommandCategory?
        public static let fieldDocs: [String: FieldDoc] = ["category": FieldDoc("Only list this category", default: "all")]
    }
    public struct Output: Codable, Sendable { public var commands: [JSONValue] }

    public static let name = "help.list_commands"
    public static let summary = "List every command (name, summary, category), sorted by name"
    public static let category = CommandCategory.help
    public static let undo = UndoBehavior.none

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        Output(commands: ctx.registry.all.filter { p.category == nil || $0.category == p.category }.map(\.brief))
    }
}

public enum HelpDescribeCommand: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var name: String
        public static let fieldDocs: [String: FieldDoc] = ["name": "Command name, e.g. \"body.create_box\""]
    }
    public typealias Output = JSONValue

    public static let name = "help.describe_command"
    public static let summary = "Full documentation of one command: parameter and result JSON Schemas, errors, undo behaviour, examples"
    public static let category = CommandCategory.help
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownCommand]
    public static let examples: [JSONValue] = [["name": "body.create_box"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        try ctx.registry.descriptor(p.name).documentation
    }
}

public enum HelpSearchCommands: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var query: String
        public var limit: Int?
        public static let fieldDocs: [String: FieldDoc] = [
            "query": "Free text, e.g. \"fillet edge\" or \"export step\"",
            "limit": FieldDoc("Maximum results", default: 20),
        ]
    }
    public struct Output: Codable, Sendable { public var commands: [JSONValue] }

    public static let name = "help.search_commands"
    public static let summary = "Search commands by name and description (ranked)"
    public static let category = CommandCategory.help
    public static let undo = UndoBehavior.none
    public static let examples: [JSONValue] = [["query": "cylinder"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        Output(commands: ctx.registry.search(p.query, limit: max(1, p.limit ?? 20)).map(\.brief))
    }
}

extension CommandCategory: SchemaEnum {}

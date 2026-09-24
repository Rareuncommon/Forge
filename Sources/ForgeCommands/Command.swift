import ForgeCore
import Foundation

/// How a command interacts with undo/redo.
public enum UndoBehavior: String, Codable, Sendable {
    /// Mutates the document; recorded as one undo step (or folded into the open transaction).
    case undoable
    /// Read-only; never recorded.
    case none
    /// Changes session state (selection, active document, undo stacks, transactions) and is
    /// deliberately not undoable itself.
    case session
}

public enum CommandCategory: String, Codable, Sendable, CaseIterable {
    case document, sketch, body, feature, query, selection, view, export, edit, help
}

/// Parameters for commands that take none.
public struct NoParams: Codable, Sendable, SchemaDocumented {
    public init() {}
    public static let fieldDocs: [String: FieldDoc] = [:]
}

/// Params types may implement semantic validation separately from decoding (decoding must
/// stay validation-free for schema extraction — see ForgeCore/Schema.swift).
public protocol ValidatableParams {
    func validate() throws
}

/// A typed command. Every user-visible capability is one of these (SPEC §3, §5.1).
public protocol Command: SendableMetatype {
    associatedtype Params: Decodable & SchemaDocumented & SendableMetatype
    associatedtype Output: Codable & Sendable

    /// Dotted, stable name, e.g. "body.create_box".
    static var name: String { get }
    static var summary: String { get }
    /// Longer human-readable documentation.
    static var discussion: String { get }
    static var category: CommandCategory { get }
    static var undo: UndoBehavior { get }
    /// Human-readable preconditions (also enforced in `run`).
    static var preconditions: [String] { get }
    /// Error codes this command can produce, beyond generic invalid_params.
    static var errors: [ErrorCode] { get }
    /// Example parameter objects. Each must decode and validate; tests enforce this.
    static var examples: [JSONValue] { get }
    /// Whether the command supports `dry_run` (read-only and undoable commands do).
    static var supportsDryRun: Bool { get }

    static func run(_ params: Params, _ ctx: inout CommandContext) throws -> Output
}

extension Command {
    public static var discussion: String { "" }
    public static var preconditions: [String] { [] }
    public static var errors: [ErrorCode] { [] }
    public static var examples: [JSONValue] { [] }
    public static var supportsDryRun: Bool { undo != .session }
}

/// What a command runs against. Document commands use `document`; session-level commands
/// (undo, transactions, document management) use `session`.
public struct CommandContext: Sendable {
    public var session: SessionState
    public let documentID: String?
    public let registry: CommandRegistry
    public let dryRun: Bool

    public var hasDocument: Bool { documentID.flatMap { session.documents[$0] } != nil }

    /// The target document. Throws a structured precondition error if there is none.
    public func requireDocument() throws -> Document {
        guard let id = documentID, let d = session.documents[id]?.document else {
            throw ForgeError(
                .preconditionFailed, "no open document",
                suggestions: [SuggestedFix(description: "Create a new part document", command: "document.new", params: ["name": "Part1"])])
        }
        return d
    }

    /// Mutable access to the target document.
    public var document: Document {
        get { (try? requireDocument()) ?? Document(id: "", name: "") }
        set {
            guard let id = documentID, session.documents[id] != nil else { return }
            session.documents[id]!.document = newValue
        }
    }
}

/// Type-erased command description + invoker, stored in the registry.
public struct CommandDescriptor: Sendable {
    public let name: String
    public let summary: String
    public let discussion: String
    public let category: CommandCategory
    public let undo: UndoBehavior
    public let preconditions: [String]
    public let errors: [ErrorCode]
    public let examples: [JSONValue]
    public let supportsDryRun: Bool
    public let paramsSchema: JSONValue
    public let resultSchema: JSONValue
    let invoke: @Sendable (JSONValue, UnitSystem, inout CommandContext) throws -> JSONValue
    /// Decode + validate only (used for example checking and dry validation).
    let check: @Sendable (JSONValue, UnitSystem) throws -> Void

    public init<C: Command>(_ type: C.Type) {
        name = C.name
        summary = C.summary
        discussion = C.discussion
        category = C.category
        undo = C.undo
        preconditions = C.preconditions
        errors = C.errors
        examples = C.examples
        supportsDryRun = C.supportsDryRun
        do {
            paramsSchema = try SchemaBuilder.schema(for: C.Params.self)
            resultSchema = try SchemaBuilder.schema(for: C.Output.self)
        } catch {
            // A command whose schema cannot be derived is a programming error caught by tests.
            fatalError("schema extraction failed for \(C.name): \(error)")
        }
        let decode: @Sendable (JSONValue, UnitSystem) throws -> C.Params = { json, units in
            let data = try JSONCoding.encoder().encode(json)
            let decoder = JSONCoding.decoder()
            decoder.userInfo[.unitSystem] = units
            let p = try decoder.decode(C.Params.self, from: data)
            try (p as? any ValidatableParams)?.validate()
            return p
        }
        check = { json, units in _ = try decode(json, units) }
        invoke = { json, units, ctx in
            let p = try decode(json, units)
            let out = try C.run(p, &ctx)
            return try JSONCoding.toJSON(out)
        }
    }

    /// Machine-readable documentation (describe_command).
    public var documentation: JSONValue {
        var o: [String: JSONValue] = [
            "name": .string(name),
            "summary": .string(summary),
            "category": .string(category.rawValue),
            "undo": .string(undo.rawValue),
            "supports_dry_run": .bool(supportsDryRun),
            "params": paramsSchema,
            "result": resultSchema,
            "errors": .array((errors + [.invalidParams]).map { .string($0.rawValue) }),
            "preconditions": .array(preconditions.map { .string($0) }),
            "examples": .array(examples),
        ]
        if !discussion.isEmpty { o["discussion"] = .string(discussion) }
        return .object(o)
    }

    public var brief: JSONValue {
        ["name": .string(name), "summary": .string(summary), "category": .string(category.rawValue)]
    }
}

/// The catalog of available commands. Plugins extend it by registering more commands.
public struct CommandRegistry: Sendable {
    public private(set) var descriptors: [String: CommandDescriptor] = [:]

    public init() {}

    public mutating func register<C: Command>(_ type: C.Type) {
        precondition(descriptors[C.name] == nil, "duplicate command \(C.name)")
        descriptors[C.name] = CommandDescriptor(type)
    }

    public func descriptor(_ name: String) throws -> CommandDescriptor {
        if let d = descriptors[name] { return d }
        let suggestions = search(name, limit: 3).map {
            SuggestedFix(description: "Did you mean '\($0.name)'? \($0.summary)", command: "help.describe_command", params: ["name": .string($0.name)])
        }
        throw ForgeError(.unknownCommand, "unknown command '\(name)'", suggestions: suggestions)
    }

    /// Commands sorted by name (stable ordering).
    public var all: [CommandDescriptor] { descriptors.values.sorted { $0.name < $1.name } }

    /// Ranked search over names, summaries and discussions.
    public func search(_ query: String, limit: Int = 20) -> [CommandDescriptor] {
        let terms = query.lowercased().split(whereSeparator: { " ._-".contains($0) }).map(String.init)
        guard !terms.isEmpty else { return Array(all.prefix(limit)) }
        var scored: [(CommandDescriptor, Int)] = []
        for d in all {
            let name = d.name.lowercased(), summary = d.summary.lowercased(), disc = d.discussion.lowercased()
            var score = 0
            for t in terms {
                if name == t { score += 20 }
                if name.split(whereSeparator: { "._".contains($0) }).contains(where: { $0 == t }) { score += 10 }
                else if name.contains(t) { score += 6 }
                if summary.contains(t) { score += 3 }
                if disc.contains(t) { score += 1 }
            }
            if score == 0, SchemaValidator.levenshtein(query.lowercased(), name) <= 3 { score = 5 }
            if score > 0 { scored.append((d, score)) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
        return scored.prefix(limit).map(\.0)
    }
}

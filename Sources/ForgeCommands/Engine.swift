import ForgeCore
import Foundation

/// One recorded command invocation — the unit of scripts, macros and journals.
public struct Invocation: Codable, Sendable, Hashable {
    public var command: String
    public var params: JSONValue

    public init(_ command: String, _ params: JSONValue = .object([:])) {
        self.command = command
        self.params = params
    }
}

/// Entities touched by a command (SPEC §5.1 dry_run: "what would change").
public struct ChangeSet: Codable, Sendable, Hashable {
    public var created: [String] = []
    public var modified: [String] = []
    public var deleted: [String] = []

    public var isEmpty: Bool { created.isEmpty && modified.isEmpty && deleted.isEmpty }

    static func diff(_ before: Document?, _ after: Document?) -> ChangeSet {
        var c = ChangeSet()
        let b = before?.bodies ?? [:], a = after?.bodies ?? [:]
        for id in after?.bodyOrder ?? [] {
            if let old = b[id] {
                if old.shape !== a[id]!.shape || old.name != a[id]!.name { c.modified.append(id) }
            } else {
                c.created.append(id)
            }
        }
        for id in before?.bodyOrder ?? [] where a[id] == nil { c.deleted.append(id) }
        let bs = before?.sketches ?? [:], asx = after?.sketches ?? [:]
        for id in after?.sketchOrder ?? [] {
            if let old = bs[id] {
                if old != asx[id]! { c.modified.append(id) }
            } else {
                c.created.append(id)
            }
        }
        for id in before?.sketchOrder ?? [] where asx[id] == nil { c.deleted.append(id) }
        return c
    }
}

public struct CommandOutcome: Codable, Sendable {
    public var command: String
    public var document: String?
    public var dryRun: Bool
    public var result: JSONValue
    public var changes: ChangeSet

    enum CodingKeys: String, CodingKey {
        case command, document, result, changes
        case dryRun = "dry_run"
    }
}

public struct BatchOutcome: Codable, Sendable {
    public var outcomes: [CommandOutcome]
    public var failedIndex: Int?
    public var error: ForgeError?
    public var committed: Bool

    enum CodingKeys: String, CodingKey {
        case outcomes, error, committed
        case failedIndex = "failed_index"
    }
}

struct UndoEntry: Sendable {
    var label: String
    var before: Document
    var after: Document
}

struct OpenTransaction: Sendable {
    var label: String
    var snapshot: Document
    var journalCount: Int
}

/// Per-document session state: the document plus its history.
public struct DocumentSession: Sendable {
    public var document: Document
    var undoStack: [UndoEntry] = []
    var redoStack: [UndoEntry] = []
    var transaction: OpenTransaction?
    /// Every successfully committed mutating/session invocation, replayable as a script.
    public internal(set) var journal: [Invocation] = []
    /// Where the document was last saved or opened from.
    public internal(set) var path: String?

    public var undoLabels: [String] { undoStack.map(\.label) }
    public var redoLabels: [String] { redoStack.map(\.label) }
    public var transactionLabel: String? { transaction?.label }
}

/// All state owned by the engine.
public struct SessionState: Sendable {
    public var documents: [String: DocumentSession] = [:]
    public var documentOrder: [String] = []
    public var activeDocumentID: String?
    var nextDocumentNumber = 1
    public static let undoLimit = 200

    public init() {}

    public mutating func adopt(_ doc: Document, path: String?) {
        var s = DocumentSession(document: doc)
        s.path = path
        documents[doc.id] = s
        documentOrder.append(doc.id)
        activeDocumentID = doc.id
    }

    public mutating func nextDocumentID() -> String {
        defer { nextDocumentNumber += 1 }
        return "doc-\(nextDocumentNumber)"
    }

    public mutating func createDocument(name: String?, units: UnitSystem) -> Document {
        let id = "doc-\(nextDocumentNumber)"
        nextDocumentNumber += 1
        let doc = Document(id: id, name: name ?? "Part\(documentOrder.count + 1)", units: units)
        documents[id] = DocumentSession(document: doc)
        documentOrder.append(id)
        activeDocumentID = id
        return doc
    }
}

/// The command bus. Every client — UI, MCP, CLI scripts, macros, plugins — executes through
/// here (SPEC §3 "Single command bus"). An actor: commands run serially off the main thread.
public actor Engine {
    public nonisolated let registry: CommandRegistry
    public private(set) var state = SessionState()

    public init(registry: CommandRegistry = .standard) {
        self.registry = registry
    }

    // MARK: execution

    /// Execute one command. `document` defaults to the active document.
    @discardableResult
    public func execute(_ command: String, _ params: JSONValue = .object([:]), dryRun: Bool = false, document: String? = nil)
        throws -> CommandOutcome
    {
        let d = try registry.descriptor(command)
        if dryRun && !d.supportsDryRun {
            throw ForgeError(.unsupported, "'\(command)' changes session state and cannot be dry-run")
        }
        let params = params.isNull ? .object([:]) : params
        let problems = SchemaValidator.validate(params, against: d.paramsSchema)
        if !problems.isEmpty {
            throw ForgeError(
                .invalidParams, problems.joined(separator: "; "),
                suggestions: [SuggestedFix(description: "Show the parameter schema", command: "help.describe_command", params: ["name": .string(command)])],
                details: ["problems": .array(problems.map { .string($0) })])
        }
        let docID = document ?? state.activeDocumentID
        if let docID, state.documents[docID] == nil {
            throw ForgeError(
                .unknownEntity, "no open document '\(docID)'", entities: [docID],
                suggestions: [SuggestedFix(description: "List open documents", command: "document.list")])
        }
        let units = docID.flatMap { state.documents[$0]?.document.units } ?? .mmgs
        var ctx = CommandContext(session: state, documentID: docID, registry: registry, dryRun: dryRun)
        let before = docID.flatMap { state.documents[$0]?.document }

        let result: JSONValue
        do {
            result = try d.invoke(params, units, &ctx)
        } catch {
            throw ForgeError.wrap(error)
        }
        if let docID, let before, var doc = ctx.session.documents[docID]?.document {
            Self.maintainFeatureTree(&doc, before: before, command: command, params: params, registry: registry)
            ctx.session.documents[docID]!.document = doc
        }
        let after = docID.flatMap { ctx.session.documents[$0]?.document }
        let changes = d.undo == .undoable ? ChangeSet.diff(before, after) : ChangeSet()
        let outcome = CommandOutcome(command: command, document: ctx.documentID ?? ctx.session.activeDocumentID, dryRun: dryRun, result: result, changes: changes)
        if dryRun { return outcome }

        switch d.undo {
        case .none:
            break
        case .session:
            state = ctx.session
            if let id = ctx.session.activeDocumentID, command != "edit.undo", command != "edit.redo",
                !command.hasPrefix("transaction."), state.documents[id] != nil
            {
                state.documents[id]!.journal.append(Invocation(command, params))
            }
        case .undoable:
            state = ctx.session
            guard let docID, let before, let after else { break }
            var s = state.documents[docID]!
            s.journal.append(Invocation(command, params))
            if s.transaction == nil {
                s.undoStack.append(UndoEntry(label: command, before: before, after: after))
                if s.undoStack.count > SessionState.undoLimit { s.undoStack.removeFirst() }
                s.redoStack.removeAll()
            }
            state.documents[docID] = s
        }
        return outcome
    }

    /// After a command: record body-producing commands and new sketches as features
    /// (docs/adr/0011), and regenerate when a sketch or feature they depend on changed.
    static func maintainFeatureTree(_ doc: inout Document, before: Document, command: String, params: JSONValue, registry: CommandRegistry) {
        if Document.featureCommands.contains(command) {
            var p = params.objectValue ?? [:]
            // Freeze defaults that depend on edit state, so the feature replays the same way.
            if p["sketch"] == nil, let active = before.activeSketch,
                (try? registry.descriptor(command))?.paramsSchema["properties"]?["sketch"] != nil
            {
                p["sketch"] = .string(active)
            }
            // Seed features by id, so renaming them does not break the pattern.
            if let seeds = p["features"]?.arrayValue {
                p["features"] = .array(seeds.map { s in s.stringValue.flatMap { try? doc.featureIndex($0) }.map { .string(doc.features[$0].id) } ?? s })
            }
            let created = doc.bodyOrder.filter { before.bodies[$0] == nil } + doc.refPlaneOrder.filter { before.refPlanes[$0] == nil }
            var edges: Int?
            if let b = p["body"]?.stringValue, let body = try? before.body(b), let t = try? body.shape.topology() {
                // Edge (or face) count when the references were picked: detects renumbering.
                if command == "body.fillet_edges" || command == "body.chamfer_edges" { edges = t.edges }
                if command == "body.shell" || command == "body.draft" { edges = t.faces }
            }
            doc.recordFeature(command: command, params: .object(p), createdBodies: created, edgeCount: edges)
        } else if command == "sketch.create", let id = doc.sketchOrder.first(where: { before.sketches[$0] == nil }) {
            doc.recordFeature(command: "sketch.create", params: ["sketch": .string(id)], createdBodies: [], sketchName: doc.sketches[id]?.name)
        }
        if let from = doc.dirtyFrom { doc.regenerate(from: from, registry: registry) }
    }

    /// Run commands against a scratch copy of the session and return the document they
    /// produce, with the ids they created or modified. The session is left exactly as it was:
    /// no undo entry, no journal line. Used for live previews (the extrude the user is
    /// setting up, drawn before OK).
    public func preview(_ items: [Invocation]) throws -> (document: Document?, changes: ChangeSet) {
        let saved = state
        defer { state = saved }
        var changes = ChangeSet()
        for i in items {
            let o = try execute(i.command, i.params)
            changes.created += o.changes.created.filter { !changes.created.contains($0) }
            changes.modified += o.changes.modified.filter { !changes.modified.contains($0) && !changes.created.contains($0) }
            changes.deleted += o.changes.deleted
        }
        return (activeDocument, changes)
    }

    /// Execute a list of commands. With `atomic` (default) the batch is one transaction:
    /// if any command fails, everything is rolled back and one undo step results on success.
    public func executeBatch(_ items: [Invocation], atomic: Bool = true, dryRun: Bool = false) throws -> BatchOutcome {
        let saved = state
        var outcomes: [CommandOutcome] = []
        // A dry-run batch really executes (so later steps can reference entities created by
        // earlier ones) and then restores the saved state.
        let ownsTransaction = atomic && !dryRun && activeTransaction == nil && state.activeDocumentID != nil
        if ownsTransaction {
            try execute("transaction.begin", ["label": .string("batch of \(items.count) commands")])
        }
        for (i, item) in items.enumerated() {
            do {
                var o = try execute(item.command, item.params)
                o.dryRun = dryRun
                outcomes.append(o)
            } catch {
                let fe = ForgeError.wrap(error)
                if atomic || dryRun { state = saved }
                return BatchOutcome(outcomes: outcomes, failedIndex: i, error: fe, committed: !atomic && !dryRun && i > 0)
            }
        }
        if dryRun {
            state = saved
            return BatchOutcome(outcomes: outcomes, failedIndex: nil, error: nil, committed: false)
        }
        if ownsTransaction { try execute("transaction.commit") }
        return BatchOutcome(outcomes: outcomes, failedIndex: nil, error: nil, committed: true)
    }

    var activeTransaction: OpenTransaction? {
        state.activeDocumentID.flatMap { state.documents[$0]?.transaction }
    }

    // MARK: read access for clients (renderer, UI)

    public var activeDocument: Document? { state.activeDocumentID.flatMap { state.documents[$0]?.document } }

    public func document(_ id: String?) -> Document? {
        (id ?? state.activeDocumentID).flatMap { state.documents[$0]?.document }
    }

    public func journal(document id: String? = nil) -> [Invocation] {
        (id ?? state.activeDocumentID).flatMap { state.documents[$0]?.journal } ?? []
    }
}

// MARK: - Session commands operating on SessionState

extension SessionState {
    mutating func undo(documentID: String) throws -> String {
        guard var s = documents[documentID] else { throw ForgeError(.preconditionFailed, "no open document") }
        if s.transaction != nil {
            throw ForgeError(
                .transactionActive, "cannot undo while transaction '\(s.transaction!.label)' is open",
                suggestions: [
                    SuggestedFix(description: "Discard the transaction", command: "transaction.rollback"),
                    SuggestedFix(description: "Commit the transaction", command: "transaction.commit"),
                ])
        }
        guard let entry = s.undoStack.popLast() else { throw ForgeError(.nothingToUndo, "nothing to undo") }
        s.document = entry.before.preservingSelection(of: s.document)
        s.redoStack.append(entry)
        s.journal.append(Invocation("edit.undo"))
        documents[documentID] = s
        return entry.label
    }

    mutating func redo(documentID: String) throws -> String {
        guard var s = documents[documentID] else { throw ForgeError(.preconditionFailed, "no open document") }
        if s.transaction != nil { throw ForgeError(.transactionActive, "cannot redo while a transaction is open") }
        guard let entry = s.redoStack.popLast() else { throw ForgeError(.nothingToRedo, "nothing to redo") }
        s.document = entry.after.preservingSelection(of: s.document)
        s.undoStack.append(entry)
        s.journal.append(Invocation("edit.redo"))
        documents[documentID] = s
        return entry.label
    }

    mutating func beginTransaction(documentID: String, label: String) throws {
        guard var s = documents[documentID] else { throw ForgeError(.preconditionFailed, "no open document") }
        if let t = s.transaction {
            throw ForgeError(.transactionActive, "transaction '\(t.label)' is already open (transactions do not nest)")
        }
        s.transaction = OpenTransaction(label: label, snapshot: s.document, journalCount: s.journal.count)
        documents[documentID] = s
    }

    mutating func commitTransaction(documentID: String) throws -> (label: String, changes: ChangeSet) {
        guard var s = documents[documentID], let t = s.transaction else {
            throw ForgeError(.noTransaction, "no open transaction", suggestions: [SuggestedFix(description: "Start one", command: "transaction.begin")])
        }
        let changes = ChangeSet.diff(t.snapshot, s.document)
        if !changes.isEmpty {
            s.undoStack.append(UndoEntry(label: t.label, before: t.snapshot, after: s.document))
            if s.undoStack.count > SessionState.undoLimit { s.undoStack.removeFirst() }
            s.redoStack.removeAll()
        }
        s.transaction = nil
        documents[documentID] = s
        return (t.label, changes)
    }

    mutating func rollbackTransaction(documentID: String) throws -> (label: String, changes: ChangeSet) {
        guard var s = documents[documentID], let t = s.transaction else {
            throw ForgeError(.noTransaction, "no open transaction")
        }
        let discarded = ChangeSet.diff(t.snapshot, s.document)
        s.document = t.snapshot
        s.journal.removeSubrange(t.journalCount...)
        s.transaction = nil
        documents[documentID] = s
        return (t.label, discarded)
    }
}

extension Document {
    /// Undo/redo restore geometry but keep the current selection, minus entities that no
    /// longer exist.
    func preservingSelection(of current: Document) -> Document {
        var d = self
        d.selection = current.selection.filter { d.referenceExists($0) }
        return d
    }
}

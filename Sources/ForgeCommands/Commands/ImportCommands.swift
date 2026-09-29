import ForgeCore
import ForgeKernel
import Foundation

/// Neutral solid geometry enters the document as immutable base bodies. Downstream
/// features operate on them normally; regeneration never reads the external file.
public enum DocumentImportSTEP: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var path: String
        public var name: String?
        public static let fieldDocs: [String: FieldDoc] = [
            "path": "Path of a STEP (.step or .stp) file containing closed solids",
            "name": FieldDoc("Body name; multiple solids receive numbered suffixes", default: "source filename without extension"),
        ]
        public func validate() throws {
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !path.contains("\0") else {
                throw ForgeError(.invalidParams, "path must name a STEP file")
            }
            if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ForgeError(.invalidParams, "name must not be blank")
            }
        }
    }
    public struct Output: Codable, Sendable {
        public var path: String
        public var bodies: [BodySummary]
    }
    public static let name = "document.import_step"
    public static let summary = "Import STEP solids as independent bodies with persistent downstream editing"
    public static let discussion = "Imports geometry in millimetres using STEP units. Original BREP is embedded on save, so rebuilding and undo/redo do not require the source file. Solids become base bodies before the feature tree. Import into a new part before creating sketches or features; repeated imports are supported until modeling begins. Assembly structure, source names, colors, PMI, design history, surface-only files and automatic healing are not imported. Dry-run reads and validates the file without changing the document."
    public static let category = CommandCategory.document
    public static let undo = UndoBehavior.undoable
    public static let preconditions = ["An open document", "No active sketch, rollback position or existing features"]
    public static let errors: [ErrorCode] = [.preconditionFailed, .ioError, .unsupported, .kernelFailure, .emptyResult]
    public static let examples: [JSONValue] = [["path": "/tmp/Bracket.step", "name": "Bracket"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        guard doc.activeSketch == nil, doc.rollback == nil else {
            throw ForgeError(.preconditionFailed, "Exit sketch editing and move the rollback bar to the end before importing STEP")
        }
        guard doc.features.isEmpty else {
            throw ForgeError(.preconditionFailed, "Import STEP into a new part before adding modeling features",
                suggestions: [SuggestedFix(description: "Create a new part, then import the STEP file", command: "document.new", params: ["name": .string(p.name ?? "Imported Part")])])
        }
        let url = DocumentFiles.url(p.path)
        guard ["step", "stp"].contains(url.pathExtension.lowercased()) else {
            throw ForgeError(.unsupported, "STEP import requires a .step or .stp file", entities: [p.path])
        }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
            FileManager.default.isReadableFile(atPath: url.path)
        else { throw ForgeError(.ioError, "Cannot read STEP file '\(url.path)'", entities: [p.path]) }
        let shape = try Kernel.importSTEP(from: url)
        let solids = try shape.solids()
        guard !solids.isEmpty else { throw ForgeError(.emptyResult, "STEP file contains no solid bodies", entities: [p.path]) }
        let allTopology = try shape.topology()
        var faces = 0, edges = 0, vertices = 0
        for solid in solids {
            let validity = try solid.check()
            let mass = try solid.massProperties()
            guard validity.isValid, validity.isClosed, !validity.isEmpty, mass.volume.isFinite, mass.volume > 0 else {
                throw ForgeError(.kernelFailure, "STEP contains an invalid or non-closed solid; repair it in the source application before importing", entities: [p.path])
            }
            let t = try solid.topology()
            faces += t.faces; edges += t.edges; vertices += t.vertices
        }
        guard allTopology.faces <= faces, allTopology.edges <= edges, allTopology.vertices <= vertices else {
            throw ForgeError(.unsupported, "STEP contains additional surface, wire or point geometry; export only solid bodies before importing", entities: [p.path])
        }
        let stem = p.name ?? url.deletingPathExtension().lastPathComponent
        var summaries: [BodySummary] = []
        for (index, solid) in solids.enumerated() {
            // Base-body names are keyed by their own stable id, never by the next feature.
            let id = "body-\(doc.nextBodyNumber)"
            let bases = Array(repeating: ["\(id):imported"], count: try solid.topology().faces)
            let body = doc.addBody(name: solids.count == 1 ? stem : "\(stem) \(index + 1)",
                                   shape: solid, producedBy: name, faces: bases)
            doc.baseBodies.append(body)
            summaries.append(try BodySummary(body))
        }
        doc.markDirty(from: 0)
        ctx.document = doc
        return Output(path: url.path, bodies: summaries)
    }
}

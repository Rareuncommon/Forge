import ForgeCore
import ForgeData
import ForgeKernel
import ForgeRender
import Foundation

enum DocumentFiles {
    static let appVersion = "forge 0.2.0-m1"

    static func package(for doc: Document) throws -> DocumentPackage {
        var breps: [String: Data] = [:]
        var records: [DocumentPackage.BodyRecord] = []
        for b in doc.orderedBodies {
            breps[b.id] = try b.shape.brepData()
            records.append(DocumentPackage.BodyRecord(id: b.id, name: b.name, producedBy: b.producedBy, brep: "bodies/\(b.id).brep"))
        }
        let model = DocumentPackage.Model(
            name: doc.name, units: doc.units, bodies: records, sketches: doc.orderedSketches,
            nextBody: doc.nextBodyNumber, nextSketch: doc.nextSketchNumber)
        return DocumentPackage(
            manifest: DocumentPackage.Manifest(app: appVersion, kernel: Kernel.version), model: model, breps: breps,
            thumbnailPNG: try thumbnail(doc))
    }

    /// 256 px isometric thumbnail for Finder / Quick Look (deterministic).
    static func thumbnail(_ doc: Document) throws -> Data? {
        guard !doc.bodyOrder.isEmpty || !doc.sketchOrder.isEmpty else { return nil }
        let ds = try DocumentScene(document: doc)
        guard let bounds = ds.scene.bounds else { return nil }
        var cam = Camera()
        cam.setOrientation(.isometric)
        cam.fit(bounds)
        let img = SoftwareRenderer.render(ds.scene, camera: cam, options: RenderOptions(width: 256, height: 256))
        return PNG.encode(rgba: img.rgba, width: 256, height: 256)
    }

    static func document(from pkg: DocumentPackage, id: String) throws -> Document {
        let bodies = try pkg.model.bodies.map { r -> Body in
            guard let data = pkg.breps[r.id] else { throw ForgeError(.ioError, "missing BREP for \(r.id)") }
            return Body(id: r.id, name: r.name, shape: try Shape.fromBREP(data), producedBy: r.producedBy)
        }
        return Document.restore(
            id: id, name: pkg.model.name, units: pkg.model.units, bodies: bodies, sketches: pkg.model.sketches,
            nextBody: pkg.model.nextBody, nextSketch: pkg.model.nextSketch)
    }

    static func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
}

public enum DocumentSave: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var path: String?
        public var overwrite: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "path": FieldDoc("Package path, e.g. \"~/Parts/Bracket.forgepart\"", default: "the path the document was opened from or last saved to"),
            "overwrite": FieldDoc("Replace an existing package (always true when re-saving to the document's own path)", default: false),
        ]
    }
    public struct Output: Codable, Sendable {
        public var path: String
        public var files: [String]
        public var bytes: Int
    }

    public static let name = "document.save"
    public static let summary = "Save the document as a .forgepart package (git-friendly JSON + canonical BREP)"
    public static let discussion = "Saving an unchanged document reproduces identical bytes. The write is atomic (temporary package swapped into place)."
    public static let category = CommandCategory.document
    public static let undo = UndoBehavior.session
    public static let errors: [ErrorCode] = [.ioError, .preconditionFailed]
    public static let examples: [JSONValue] = [["path": "/tmp/Bracket.forgepart"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let current = ctx.session.documents[doc.id]?.path
        guard let path = p.path ?? current else {
            throw ForgeError(.invalidParams, "the document has never been saved; give 'path'")
        }
        let url = DocumentFiles.url(path)
        guard url.pathExtension == "forgepart" else {
            throw ForgeError(.invalidParams, "part documents use the .forgepart extension", entities: [path])
        }
        let pkg = try DocumentFiles.package(for: doc)
        try pkg.write(to: url, overwrite: p.overwrite == true || url.path == current)
        ctx.session.documents[doc.id]?.path = url.path
        let files = try pkg.files()
        return Output(path: url.path, files: files.keys.sorted(), bytes: files.values.reduce(0) { $0 + $1.count })
    }
}

public enum DocumentOpen: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var path: String
        public static let fieldDocs: [String: FieldDoc] = ["path": "Path of a .forgepart package"]
    }
    public struct Output: Codable, Sendable {
        public var document: DocumentSummary
        public var bodies: Int
        public var sketches: Int
    }

    public static let name = "document.open"
    public static let summary = "Open a .forgepart package as a new active document (sketches are re-solved on load)"
    public static let category = CommandCategory.document
    public static let undo = UndoBehavior.session
    public static let errors: [ErrorCode] = [.ioError, .unsupported]
    public static let examples: [JSONValue] = [["path": "/tmp/Bracket.forgepart"]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let url = DocumentFiles.url(p.path)
        let pkg = try DocumentPackage.read(from: url)
        let id = ctx.session.nextDocumentID()
        let doc = try DocumentFiles.document(from: pkg, id: id)
        ctx.session.adopt(doc, path: url.path)
        return Output(document: DocumentSummary(doc, active: true), bodies: doc.bodyOrder.count, sketches: doc.sketchOrder.count)
    }
}

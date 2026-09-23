import ForgeCore
import ForgeKernel
import ForgeRender
import Foundation

/// Shape → display mesh cache keyed by shape identity. Shapes are immutable, so a cached
/// tessellation stays valid for the shape's lifetime.
final class MeshCache: @unchecked Sendable {
    static let shared = MeshCache()
    private let lock = NSLock()
    private var entries: [ObjectIdentifier: (shape: WeakShape, mesh: Mesh)] = [:]

    struct WeakShape { weak var shape: Shape? }

    func mesh(for shape: Shape) throws -> Mesh {
        let key = ObjectIdentifier(shape)
        lock.lock()
        if let e = entries[key], e.shape.shape === shape {
            lock.unlock()
            return e.mesh
        }
        lock.unlock()
        let m = try shape.tessellate()
        lock.lock()
        entries = entries.filter { $0.value.shape.shape != nil }
        entries[key] = (WeakShape(shape: shape), m)
        lock.unlock()
        return m
    }
}

/// Builds the render scene for a document: bodies (object ids 0..<bodies.count) followed by
/// sketches (one item each; edge ids index the sketch's drawn curves).
public struct DocumentScene: Sendable {
    public var scene: RenderScene
    public var bodies: [String]
    public var sketches: [String]
    /// For each sketch item, the curve id per edge index.
    public var sketchCurves: [[String]]

    public init(document: Document, bodies filter: [String]? = nil, highlight: [String] = [], showSketches: Bool = true) throws {
        let selected = try filter.map { try $0.map { try document.body($0).id } }
        let list = document.orderedBodies.filter { selected?.contains($0.id) ?? true }
        let bodyRefs = highlight.filter { !document.sketches.keys.contains(String($0.split(separator: "/").first ?? "")) }
        let refs = bodyRefs.compactMap(EntityRef.init(parsing:))
        var items: [RenderItem] = []
        for (i, b) in list.enumerated() {
            let mine = refs.filter { $0.body == b.id }
            let colorIndex = document.bodyOrder.firstIndex(of: b.id) ?? i
            items.append(
                RenderItem(
                    objectID: UInt32(i), mesh: try MeshCache.shared.mesh(for: b.shape), color: .bodyColor(colorIndex),
                    highlightedFaces: Set(mine.filter { $0.kind == .face }.compactMap { $0.index.map(UInt32.init) }),
                    highlightedEdges: Set(mine.filter { $0.kind == .edge }.compactMap { $0.index.map(UInt32.init) }),
                    highlightAll: mine.contains { $0.kind == .body }))
        }
        bodies = list.map(\.id)
        sketches = []
        sketchCurves = []
        guard showSketches else {
            scene = RenderScene(items: items)
            return
        }
        for sk in document.orderedSketches {
            var points: [Float] = [], offsets: [UInt32] = [0], ids: [UInt32] = []
            var colors: [UInt32: RGBA] = [:], highlighted: Set<UInt32> = []
            var curves: [String] = []
            for e in sk.orderedEntities where e.kind != .point {
                let edge = UInt32(curves.count)
                curves.append(e.id)
                for (u, v) in sk.polyline(e.id) {
                    let p = sk.plane.point(u, v)
                    points += [Float(p.x), Float(p.y), Float(p.z)]
                }
                offsets.append(UInt32(points.count / 3))
                ids.append(edge)
                let state = sk.report?.entityStates[e.id] ?? .underDefined
                colors[edge] = e.construction ? .sketchConstruction : state == .overDefined ? .sketchOver : state == .fullyDefined ? .sketchFully : .sketchUnder
                if highlight.contains("\(sk.id)/\(e.id)") || highlight.contains(sk.id) { highlighted.insert(edge) }
            }
            guard !curves.isEmpty else { continue }
            let mesh = Mesh(positions: [], normals: [], indices: [], triangleFaces: [], edgeOffsets: offsets, edgeIDs: ids, edgePoints: points)
            items.append(RenderItem(objectID: UInt32(list.count + sketches.count), mesh: mesh, color: .sketchUnder, highlightedEdges: highlighted, edgeColors: colors))
            sketches.append(sk.id)
            sketchCurves.append(curves)
        }
        scene = RenderScene(items: items)
    }

    /// Entity reference for a pick hit.
    public func reference(for hit: PickHit) -> String? {
        let o = Int(hit.objectID)
        if o < bodies.count {
            return EntityRef(body: bodies[o], kind: hit.element == .face ? .face : .edge, index: Int(hit.index)).description
        }
        let k = o - bodies.count
        guard k < sketches.count, Int(hit.index) < sketchCurves[k].count else { return nil }
        return "\(sketches[k])/\(sketchCurves[k][Int(hit.index)])"
    }
}

/// Shared view parameters for render/pick so an agent can pick on exactly the image it saw.
public struct ViewSpec: Codable, Sendable, SchemaDocumented, ValidatableParams {
    public var orientation: ViewOrientation?
    public var style: RenderStyle?
    public var projection: ProjectionKind?
    public var width: Int?
    public var height: Int?
    public var bodies: [String]?
    public var highlight: [String]?
    /// Orbit offsets applied after the standard orientation (degrees, turntable).
    public var yaw: Double?
    public var pitch: Double?
    public var sketches: Bool?

    public static let fieldDocs: [String: FieldDoc] = [
        "orientation": FieldDoc("Standard view", default: "isometric"),
        "style": FieldDoc("Display style", default: "shaded_with_edges"),
        "projection": FieldDoc("Projection", default: "orthographic"),
        "width": FieldDoc("Image width in pixels (16–4096)", default: 800),
        "height": FieldDoc("Image height in pixels (16–4096)", default: 600),
        "bodies": FieldDoc("Only show these bodies", default: "all"),
        "highlight": FieldDoc("Entities drawn in the highlight colour (bodies, faces, edges)", default: []),
        "yaw": FieldDoc("Extra rotation about the vertical axis in degrees", default: 0),
        "pitch": FieldDoc("Extra rotation about the horizontal axis in degrees", default: 0),
        "sketches": FieldDoc("Show sketches (curves coloured by constraint state)", default: true),
    ]

    public func validate() throws {
        for (n, v) in [("width", width), ("height", height)] {
            if let v, !(16...4096).contains(v) { throw ForgeError(.invalidParams, "\(n) must be between 16 and 4096") }
        }
    }

    var size: (Int, Int) { (width ?? 800, height ?? 600) }

    func camera(for scene: RenderScene) -> Camera {
        var cam = Camera(projection: projection ?? .orthographic)
        cam.setOrientation(orientation ?? .isometric)
        if yaw != nil || pitch != nil { cam.turntable(dx: (yaw ?? 0) * .pi / 180, dy: (pitch ?? 0) * .pi / 180) }
        let (w, h) = size
        if let b = scene.bounds { cam.fit(b, aspect: Double(w) / Double(h)) }
        return cam
    }

    func render(_ ds: DocumentScene, supersample: Int = 2) -> RenderImage {
        let (w, h) = size
        return SoftwareRenderer.render(
            ds.scene, camera: camera(for: ds.scene),
            options: RenderOptions(width: w, height: h, style: style ?? .shadedWithEdges, supersample: supersample))
    }
}

public enum ViewRender: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var view: ViewSpec?
        public var path: String?
        public var overwrite: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "view": "Camera and display options",
            "path": FieldDoc("Write the PNG here instead of returning it inline", default: "inline base64"),
            "overwrite": FieldDoc("Replace an existing file at 'path'", default: false),
        ]
        public func validate() throws { try view?.validate() }
    }
    public struct Output: Codable, Sendable {
        public var width: Int
        public var height: Int
        public var mimeType: String
        public var pngBase64: String?
        public var path: String?
        public var bodies: [String]

        enum CodingKeys: String, CodingKey {
            case width, height, path, bodies
            case mimeType = "mime_type"
            case pngBase64 = "png_base64"
        }
    }

    public static let name = "view.render"
    public static let summary = "Render the model to a PNG (headless) so agents can visually verify it"
    public static let discussion = "Pass the same 'view' to view.pick to identify what is at a pixel of this image."
    public static let category = CommandCategory.view
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity, .ioError]
    public static let examples: [JSONValue] = [[:], ["view": ["orientation": "front", "style": "hidden_lines_removed", "width": 400, "height": 300]]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let view = p.view ?? ViewSpec()
        let ds = try DocumentScene(document: doc, bodies: view.bodies, highlight: view.highlight ?? doc.selection, showSketches: view.sketches ?? true)
        let img = view.render(ds)
        let png = PNG.encode(rgba: img.rgba, width: img.width, height: img.height)
        if let path = p.path {
            let url = try checkWritable(path, overwrite: p.overwrite)
            do { try png.write(to: url) } catch { throw ForgeError(.ioError, "could not write \(url.path): \(error)") }
            return Output(width: img.width, height: img.height, mimeType: "image/png", pngBase64: nil, path: url.path, bodies: ds.bodies)
        }
        return Output(width: img.width, height: img.height, mimeType: "image/png", pngBase64: png.base64EncodedString(), path: nil, bodies: ds.bodies)
    }
}

public enum ViewRenderMultiview: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var size: Int?
        public var style: RenderStyle?
        public var path: String?
        public var overwrite: Bool?
        public static let fieldDocs: [String: FieldDoc] = [
            "size": FieldDoc("Size of each of the four tiles in pixels (64–2048)", default: 400),
            "style": FieldDoc("Display style", default: "shaded_with_edges"),
            "path": FieldDoc("Write the PNG here instead of returning it inline", default: "inline base64"),
            "overwrite": FieldDoc("Replace an existing file at 'path'", default: false),
        ]
        public func validate() throws {
            if let s = size, !(64...2048).contains(s) { throw ForgeError(.invalidParams, "size must be between 64 and 2048") }
        }
    }
    public typealias Output = ViewRender.Output

    public static let name = "view.render_multiview"
    public static let summary = "Standard 4-view sheet in one image: front, top, right (third-angle layout) and isometric"
    public static let category = CommandCategory.view
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.ioError]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let ds = try DocumentScene(document: doc, highlight: doc.selection)
        let s = p.size ?? 400
        // Third-angle projection: top above front, right to the right of front.
        let layout: [(ViewOrientation, Int, Int)] = [(.top, 0, 0), (.isometric, 1, 0), (.front, 0, 1), (.right, 1, 1)]
        var sheet = [UInt8](repeating: 255, count: 2 * s * 2 * s * 4)
        // One shared scale so the orthographic views line up.
        let bounds = ds.scene.bounds
        for (o, tx, ty) in layout {
            var cam = Camera(projection: .orthographic)
            cam.setOrientation(o)
            if let b = bounds { cam.fit(b) }
            let img = SoftwareRenderer.render(ds.scene, camera: cam, options: RenderOptions(width: s, height: s, style: p.style ?? .shadedWithEdges))
            for y in 0..<s {
                let src = y * s * 4, dst = ((ty * s + y) * 2 * s + tx * s) * 4
                sheet.replaceSubrange(dst..<(dst + s * 4), with: img.rgba[src..<(src + s * 4)])
            }
        }
        let png = PNG.encode(rgba: sheet, width: 2 * s, height: 2 * s)
        if let path = p.path {
            let url = try checkWritable(path, overwrite: p.overwrite)
            do { try png.write(to: url) } catch { throw ForgeError(.ioError, "could not write \(url.path): \(error)") }
            return Output(width: 2 * s, height: 2 * s, mimeType: "image/png", pngBase64: nil, path: url.path, bodies: ds.bodies)
        }
        return Output(width: 2 * s, height: 2 * s, mimeType: "image/png", pngBase64: png.base64EncodedString(), path: nil, bodies: ds.bodies)
    }
}

public enum ViewPick: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var x: Int
        public var y: Int
        public var view: ViewSpec?
        public var radius: Int?
        public static let fieldDocs: [String: FieldDoc] = [
            "x": "Pixel column (0 = left) in the image rendered with the same 'view'",
            "y": "Pixel row (0 = top)",
            "view": "The same view options passed to view.render",
            "radius": FieldDoc("Pick tolerance in pixels; edges win within it", default: 3),
        ]
        public func validate() throws {
            try view?.validate()
            let (w, h) = (view ?? ViewSpec()).size
            guard (0..<w).contains(x), (0..<h).contains(y) else {
                throw ForgeError(.invalidParams, "pixel (\(x), \(y)) is outside the \(w)x\(h) image")
            }
            if let r = radius, !(0...20).contains(r) { throw ForgeError(.invalidParams, "radius must be between 0 and 20") }
        }
    }
    public struct Output: Codable, Sendable {
        public var hit: String?
        public var element: String?
        public var face: FaceDescriptor?
        public var edge: EdgeDescriptor?
    }

    public static let name = "view.pick"
    public static let summary = "Identify the face or edge at a pixel of a rendered view"
    public static let category = CommandCategory.view
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.invalidParams]
    public static let examples: [JSONValue] = [["x": 400, "y": 300]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let view = p.view ?? ViewSpec()
        let ds = try DocumentScene(document: doc, bodies: view.bodies, showSketches: view.sketches ?? true)
        let img = view.render(ds)
        guard let hit = img.pick(x: p.x, y: p.y, radius: p.radius ?? 3), let ref = ds.reference(for: hit) else {
            return Output(hit: nil, element: nil, face: nil, edge: nil)
        }
        guard Int(hit.objectID) < ds.bodies.count else {
            return Output(hit: ref, element: "sketch_curve", face: nil, edge: nil)
        }
        let b = try doc.body(ds.bodies[Int(hit.objectID)])
        switch hit.element {
        case .face:
            return Output(hit: ref, element: "face", face: FaceDescriptor(body: b.id, try b.shape.face(Int(hit.index))), edge: nil)
        case .edge:
            return Output(hit: ref, element: "edge", face: nil, edge: EdgeDescriptor(body: b.id, try b.shape.edge(Int(hit.index))))
        }
    }
}

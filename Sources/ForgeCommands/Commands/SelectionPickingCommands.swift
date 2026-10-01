import ForgeCore
import ForgeRender
import Foundation

/// Viewport filters are session state; explicit selection.set remains unrestricted.
public enum SelectionFilter: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case all, bodies, faces, edges
}

public enum SelectionSetFilter: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var filter: SelectionFilter
        public static let fieldDocs: [String: FieldDoc] = ["filter": "Viewport hit filter: all geometry, bodies, faces or model edges; explicit selection.set is unaffected"]
    }
    public struct Output: Codable, Sendable { public var filter: SelectionFilter }
    public static let name = "selection.set_filter"
    public static let summary = "Set the active document's viewport selection filter"
    public static let category = CommandCategory.selection
    public static let undo = UndoBehavior.session
    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        var doc = try ctx.requireDocument()
        doc.selectionFilter = p.filter
        ctx.document = doc
        return Output(filter: p.filter)
    }
}

extension DocumentScene {
    /// Pick only model/sketch objects. Planes, grids and display overlays never become
    /// candidates, and hidden bodies have already been omitted by DocumentScene.
    public func pickCandidates(origin: Vec3, direction: Vec3, edgeTolerance: Double,
                               filter: SelectionFilter, includeOccluded: Bool, style: RenderStyle = .shadedWithEdges) -> [String] {
        var geometry = scene
        geometry.items.removeAll { Int($0.objectID) >= bodies.count + sketches.count }
        let hits = RayPicker.candidates(geometry, origin: origin, direction: direction,
                                        edgeTolerance: edgeTolerance, includeOccluded: includeOccluded || (filter == .all && style == .wireframe))
        var refs: [String] = [], seen = Set<String>()
        for hit in hits {
            let isBody = Int(hit.objectID) < bodies.count
            let ref: String?
            switch filter {
            case .all:
                if style == .wireframe && hit.element == .face { continue }
                if style == .shaded && isBody && hit.element == .edge { continue }
                ref = reference(for: hit)
            case .bodies: ref = isBody ? bodies[Int(hit.objectID)] : nil
            case .faces: ref = isBody && hit.element == .face ? reference(for: hit) : nil
            case .edges: ref = isBody && hit.element == .edge ? reference(for: hit) : nil
            }
            if let ref, seen.insert(ref).inserted { refs.append(ref) }
        }
        return refs
    }
}

public enum ViewPickCandidates: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var x: Int
        public var y: Int
        public var view: ViewSpec?
        public var radius: Int?
        public var filter: SelectionFilter?
        public var includeOccluded: Bool?
        enum CodingKeys: String, CodingKey { case x, y, view, radius, filter; case includeOccluded = "include_occluded" }
        public static let fieldDocs: [String: FieldDoc] = [
            "x": "Pixel column in the rendered view", "y": "Pixel row from the top",
            "view": "Same view options as view.render", "radius": FieldDoc("Edge tolerance in pixels (0–20)", default: 4),
            "filter": FieldDoc("Candidate type", default: "current document selection filter"),
            "include_occluded": FieldDoc("Include surfaces behind the nearest visible face for Select Other", default: true),
        ]
        public func validate() throws {
            try view?.validate()
            let (w, h) = (view ?? ViewSpec()).size
            guard (0..<w).contains(x), (0..<h).contains(y), (0...20).contains(radius ?? 4) else {
                throw ForgeError(.invalidParams, "pixel must be inside the image and radius must be between 0 and 20")
            }
        }
    }
    public struct Output: Codable, Sendable { public var candidates: [String]; public var filter: SelectionFilter }
    public static let name = "view.pick_candidates"
    public static let summary = "List unique filtered geometry under a pixel, including occluded faces for Select Other"
    public static let category = CommandCategory.view
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.invalidParams, .preconditionFailed]
    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument(), view = p.view ?? ViewSpec()
        let ds = try DocumentScene(document: doc, bodies: view.bodies, showSketches: view.sketches ?? true)
        let camera = view.camera(for: ds.scene), (w, h) = view.size
        let ray = camera.ray(pixelX: Double(p.x), pixelY: Double(p.y), width: Double(w), height: Double(h))
        let filter = p.filter ?? doc.selectionFilter
        return Output(candidates: ds.pickCandidates(origin: ray.origin, direction: ray.direction,
            edgeTolerance: Double(p.radius ?? 4) * 2 * camera.visibleHalfHeight / Double(h),
            filter: filter, includeOccluded: p.includeOccluded ?? true, style: view.style ?? .shadedWithEdges), filter: filter)
    }
}

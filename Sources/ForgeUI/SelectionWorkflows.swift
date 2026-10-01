import ForgeCommands
import ForgeCore
import ForgeRender
import ForgeSketch
import Foundation

package struct ViewportPickContext {
    var view: ViewProjection
    var point: CGPoint
    var current: String?
    var style: RenderStyle
}

extension SelectionFilter {
    package var title: String {
        switch self { case .all: "All Geometry"; case .bodies: "Bodies"; case .faces: "Faces"; case .edges: "Edges" }
    }
}

extension AppModel {
    /// Extrusion pages collect model/contour picks even when opened directly from a
    /// sketch drawing tool. Front ends share this routing decision for press and release.
    package var viewportSketchPlane: SketchPlane? {
        guard operation != .extrude, operation != .cutExtrude else { return nil }
        return sketchState.tool == nil ? nil : sketchState.plane
    }

    package func setSelectionFilter(_ filter: SelectionFilter) async {
        await run("selection.set_filter", ["filter": .string(filter.rawValue)])
    }

    package var canSelectOther: Bool {
        guard viewportSketchPlane == nil, let context = viewportPickContext else { return false }
        return projection == nil || context.view == projection
    }

    /// Shared desktop pick path. Filters apply to viewport geometry only; tree and
    /// explicit command selections remain available regardless of the current filter.
    package func viewportPick(at point: CGPoint, camera: Camera, width: Double, height: Double, extend: Bool, style: RenderStyle = .shadedWithEdges) async {
        guard width > 0, height > 0, viewportSketchPlane == nil, let ds = scene.value else { return }
        let version = sceneVersion
        let view = ViewProjection(camera: camera, width: width, height: height)
        let ray = camera.ray(pixelX: point.x, pixelY: point.y, width: width, height: height)
        if await pickExtrusionContour(origin: ray.origin, direction: ray.direction) { viewportPickContext = nil; return }
        guard sceneVersion == version, viewportSketchPlane == nil else { return }
        let candidates = ds.pickCandidates(origin: ray.origin, direction: ray.direction,
            edgeTolerance: 8 * camera.visibleHalfHeight / height, filter: selectionFilter, includeOccluded: false, style: style)
        let ref = candidates.first
        viewportPickContext = ViewportPickContext(view: view, point: point, current: ref, style: style)
        await select(ref, extend: extend)
        contextToolbarAt = ref == nil ? nil : point
    }

    /// Recompute candidates from the current visible scene, never cached object IDs.
    /// Each step replaces this click's candidate while retaining other selected entities.
    package func selectOther() async {
        guard canSelectOther, var context = viewportPickContext, let ds = scene.value else { return }
        let view = context.view
        let ray = view.camera.ray(pixelX: context.point.x, pixelY: context.point.y, width: view.width, height: view.height)
        let refs = ds.pickCandidates(origin: ray.origin, direction: ray.direction,
            edgeTolerance: 8 * view.camera.visibleHalfHeight / view.height, filter: selectionFilter, includeOccluded: true, style: context.style)
        guard !refs.isEmpty else { viewportPickContext = nil; return }
        let index = context.current.flatMap { refs.firstIndex(of: $0) }.map { ($0 + 1) % refs.count } ?? 0
        let ref = refs[index]
        let preserved = selection.filter { $0 != context.current && $0 != ref }
        context.current = ref
        viewportPickContext = context
        await run("selection.set", ["entities": .array((preserved + [ref]).map(JSONValue.string)), "mode": "replace"])
        contextToolbarAt = context.point
    }
}

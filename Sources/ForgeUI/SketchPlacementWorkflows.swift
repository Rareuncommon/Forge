import ForgeCore

extension AppModel {
    package var sketchStartTitle: String { selectedFace == nil ? "Sketch" : "Sketch on Face" }

    /// A generic Sketch action respects the picked face. An unsuitable model selection must
    /// never silently create a sketch on the origin's Front plane.
    package func startSketchFromSelection() async {
        guard activeSketch == nil else { return }
        if let face = selectedFace {
            await newSketch(onPlaneOrFace: face)
        } else if !selectedBodies.isEmpty {
            lastError = ForgeError(.invalidParams, "Select a planar face to start a sketch, or choose a plane from the Sketch menu.", entities: selection)
        } else {
            await newSketch(on: .front)
        }
    }

    package var selectedModelGeometry: [String] {
        selection.filter { entityKind($0) == .edge || entityKind($0) == .face }
    }

    /// With no sketch drawing tool active, both native viewports pick model faces and edges.
    package func selectModelGeometry() {
        chooseTool(nil)
        contextToolbarAt = nil
    }

    package func convertSelectedModelGeometry() async {
        guard activeSketch != nil, !selectedModelGeometry.isEmpty else { return }
        let refs = selectedModelGeometry
        chooseTool(nil)
        await run("sketch.convert_entities", ["entities": .array(refs.map(JSONValue.string))])
    }
}

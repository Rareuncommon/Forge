import ForgeCommands
import ForgeCore
import ForgeSketch
import Foundation

package struct ExtrudeContourChoice: Identifiable {
    package var selector: [String]
    package var area: Double
    package var id: String { selector.sorted().joined(separator: "|") }
    package var title: String { "Region · \(String(format: "%.3f", area)) mm²" }
}

extension AppModel {
    package func refreshContourChoices() async {
        guard let sketch = operationSketch else {
            contourRequest += 1
            contourChoices = []; contourQueryError = nil
            contourQueryTask = nil; contourQueryKey = nil
            return
        }
        guard let document = await engine.activeDocument, operationSketch == sketch else { return }
        let revision = sceneVersion
        let key = "\(document.id)|\(sketch)|\(revision)"
        // begin(), operationSketch.didSet and explicit callers can all request the same
        // regions in one run-loop turn. Await one task rather than invalidating each other.
        if contourQueryKey == key, let task = contourQueryTask {
            await task.value
            return
        }
        contourRequest += 1
        let request = contourRequest
        contourQueryKey = key
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.execute("sketch.regions", ["sketch": .string(sketch)], document: document.id).result
                guard await engine.activeDocument?.id == document.id, request == contourRequest,
                      operationSketch == sketch, sceneVersion == revision else { return }
                contourChoices = (result["regions"]?.arrayValue ?? []).compactMap { region in
                    guard let selector = region["selector"]?.arrayValue?.compactMap(\.stringValue), !selector.isEmpty,
                          let area = region["area_mm2"]?.doubleValue else { return nil }
                    return ExtrudeContourChoice(selector: selector, area: area)
                }
                contourQueryError = nil
            } catch {
                guard await engine.activeDocument?.id == document.id, request == contourRequest,
                      operationSketch == sketch, sceneVersion == revision else { return }
                contourChoices = []
                contourQueryError = ForgeError.wrap(error).message
            }
        }
        contourQueryTask = task
        await task.value
        if request == contourRequest { contourQueryTask = nil; contourQueryKey = nil }
    }

    private func canonicalContour(_ selector: [String]) -> [String] {
        let prefix = (operationSketch ?? "") + "/"
        return selector.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }.sorted()
    }

    package func contourIsSelected(_ choice: ExtrudeContourChoice) -> Bool {
        form.contours == nil || form.contours!.contains { canonicalContour($0) == canonicalContour(choice.selector) }
    }

    package func setContourSelected(_ choice: ExtrudeContourChoice, _ selected: Bool) {
        var contours = form.contours ?? contourChoices.map(\.selector)
        contours.removeAll { canonicalContour($0) == canonicalContour(choice.selector) }
        if selected { contours.append(choice.selector) }
        form.contours = contours
    }

    package func useSelectedExtrudeSurface(direction2: Bool = false) {
        guard let ref = selectedFace ?? selection.last(where: { $0.hasPrefix("plane-") }) else {
            lastError = ForgeError(.invalidParams, "Select a planar face or plane for the extrusion limit.")
            return
        }
        if direction2 { form.surface2 = ref } else { form.surface = ref }
    }

    /// Contour picking is explicit so an extrusion can still select a limiting face.
    package func pickExtrusionContour(origin: Vec3, direction: Vec3) async -> Bool {
        guard operation == .extrude || operation == .cutExtrude, form.activeBox == "contours" else { return false }
        guard let id = operationSketch, let doc = await engine.activeDocument, let sk = doc.sketches[id] else { return true }
        let requestedOperation = operation, requestedFeature = editingFeature
        let denominator = direction.dot(sk.plane.normal)
        guard abs(denominator) > 1e-10 else { return true }
        let distance = (sk.plane.origin - origin).dot(sk.plane.normal) / denominator
        guard distance >= 0 else { return true }
        let offset = origin + direction * distance - sk.plane.origin
        let point: JSONValue = [.number(offset.dot(sk.plane.xAxis)), .number(offset.dot(sk.plane.yAxis))]
        do {
            let result = try await engine.execute("sketch.regions", ["sketch": .string(id), "at": point], document: doc.id).result
            guard await engine.activeDocument?.id == doc.id, operationSketch == id, form.activeBox == "contours",
                  operation == requestedOperation, editingFeature == requestedFeature else { return true }
            let regions = result["regions"]?.arrayValue ?? []
            guard regions.count == 1, let selector = regions[0]["selector"]?.arrayValue?.compactMap(\.stringValue), !selector.isEmpty else {
                lastError = ForgeError(.invalidParams, regions.isEmpty ? "Click inside a closed sketch region, outside its holes." : "Several regions overlap here; choose one from Selected Contours.")
                return true
            }
            if form.contours == nil { form.contours = [] }
            let choice = ExtrudeContourChoice(selector: selector, area: regions[0]["area_mm2"]?.doubleValue ?? 0)
            setContourSelected(choice, !contourIsSelected(choice))
            lastError = nil
            await updatePreview()
        } catch {
            guard await engine.activeDocument?.id == doc.id, operationSketch == id, form.activeBox == "contours",
                  operation == requestedOperation, editingFeature == requestedFeature else { return true }
            lastError = ForgeError.wrap(error)
        }
        return true
    }
}

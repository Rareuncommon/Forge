import ForgeCommands
import ForgeCore
import Foundation

extension AppModel {
    package func importSTEP() {
        guard let path = platform.chooseImportSTEPPath() else { return }
        Task { await importSTEP(path: path) }
    }

    @discardableResult
    package func importSTEP(path: String) async -> Bool {
        guard await run("document.import_step", ["path": .string(path)]) != nil else { return false }
        zoomToFit()
        return true
    }

    package func moveFeature(_ feature: String, by offset: Int) async {
        guard let index = features.firstIndex(where: { $0.id == feature }), offset == -1 || offset == 1 else { return }
        let destination = index + offset
        guard features.indices.contains(destination) else { return }
        var params: [String: JSONValue] = ["feature": .string(feature)]
        if offset < 0 { params["before"] = .string(features[destination].id) }
        else if destination + 1 < features.count { params["before"] = .string(features[destination + 1].id) }
        await run("feature.reorder", .object(params))
    }

    package func showFeatureDependencies(_ feature: String) async {
        guard let outcome = await run("feature.dependencies", ["feature": .string(feature)]) else { return }
        func names(_ key: String) -> String {
            let ids = outcome.result[key]?.arrayValue?.compactMap(\.stringValue) ?? []
            return ids.isEmpty ? "None" : ids.map { id in features.first { $0.id == id }?.name ?? id }.joined(separator: ", ")
        }
        let name = features.first { $0.id == feature }?.name ?? feature
        platform.showMessage("Parent/Child: \(name)", "Parents: \(names("parents"))\n\nChildren: \(names("children"))\n\nAll upstream features: \(names("ancestors"))\n\nAll downstream features: \(names("descendants"))")
    }

    package func computeInterference() async {
        interferenceRequest += 1
        let request = interferenceRequest
        var params: [String: JSONValue] = [:]
        if !selectedBodies.isEmpty { params["bodies"] = .array(selectedBodies.map(JSONValue.string)) }
        do {
            let outcome = try await engine.execute("query.interference", .object(params))
            guard operation == .interference, request == interferenceRequest else { return }
            form.result = outcome.result
            lastError = nil
        } catch {
            guard operation == .interference, request == interferenceRequest else { return }
            form.result = nil
            lastError = ForgeError.wrap(error)
        }
    }

    package var interferencePairs: [JSONValue] { form.result?["interferences"]?.arrayValue ?? [] }

    package func interferenceLabel(_ pair: JSONValue) -> String {
        let a = pair["body_a"]?.stringValue ?? "", b = pair["body_b"]?.stringValue ?? ""
        let nameA = bodies.first { $0.id == a }?.name ?? a, nameB = bodies.first { $0.id == b }?.name ?? b
        return "\(nameA) / \(nameB): \(String(format: "%.6g", pair["volume_mm3"]?.doubleValue ?? 0)) mm³"
    }

    package func selectInterference(_ pair: JSONValue) async {
        let ids = [pair["body_a"]?.stringValue, pair["body_b"]?.stringValue].compactMap { $0 }
        await select(ids)
    }
}

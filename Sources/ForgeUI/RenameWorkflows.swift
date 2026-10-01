import ForgeCore

extension AppModel {
    /// Rename by stable identity through the same undoable command used by MCP.
    /// Cancelling the native prompt does not submit a command or create an undo entry.
    package func renameBody(_ id: String) async {
        guard let body = bodies.first(where: { $0.id == id }),
              let name = platform.requestName("Rename Body", currentName: body.name) else { return }
        guard name != body.name else { return }
        await run("body.rename", ["body": .string(id), "name": .string(name)])
    }

    package func renameFeature(_ id: String) async {
        guard let feature = features.first(where: { $0.id == id }),
              let name = platform.requestName("Rename Feature", currentName: feature.name) else { return }
        guard name != feature.name else { return }
        await run("feature.rename", ["feature": .string(id), "name": .string(name)])
    }
}

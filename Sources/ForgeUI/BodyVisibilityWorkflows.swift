import ForgeCore

extension AppModel {
    package func setBodiesVisible(_ ids: [String], _ visible: Bool) async {
        guard !ids.isEmpty else { return }
        await run("view.set_visibility", ["bodies": .array(ids.map(JSONValue.string)), "visible": .bool(visible)])
    }

    package func isolateBodies(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        await run("view.isolate", ["bodies": .array(ids.map(JSONValue.string))])
    }

    package func showAllBodies() async { await run("view.show_all") }
    package func exitBodyIsolation() async { await run("view.exit_isolation") }
}

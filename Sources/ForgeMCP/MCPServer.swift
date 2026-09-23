import ForgeCommands
import ForgeCore
import Foundation

/// Model Context Protocol server over the Forge command bus (docs/adr/0006-mcp-server.md).
///
/// Transport-agnostic: `handle(_:)` takes one JSON-RPC message (a line) and returns the
/// response line, if any. Server-initiated notifications go through `notify`.
public actor MCPServer {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverName = "forge"
    public static let serverVersion = "0.1.0-m0"

    public let engine: Engine
    private var negotiatedVersion: String?
    private var subscriptions: Set<String> = []
    private let notify: @Sendable (String) -> Void

    public init(engine: Engine, notify: @escaping @Sendable (String) -> Void = { _ in }) {
        self.engine = engine
        self.notify = notify
    }

    // MARK: JSON-RPC dispatch

    public func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let message: JSONValue
        do {
            message = try JSONCoding.parse(trimmed)
        } catch {
            return Self.errorResponse(id: .null, code: -32700, message: "parse error")
        }
        if let batch = message.arrayValue {
            // JSON-RPC batches (removed from MCP 2025-06-18 but harmless to accept).
            var responses: [JSONValue] = []
            for m in batch {
                if let r = await handleMessage(m) { responses.append(r) }
            }
            return responses.isEmpty ? nil : JSONCoding.string(.array(responses))
        }
        return await handleMessage(message).map { JSONCoding.string($0) }
    }

    func handleMessage(_ m: JSONValue) async -> JSONValue? {
        guard m["jsonrpc"] == "2.0", let method = m["method"]?.stringValue else {
            // Responses to server-initiated requests are ignored (we send none that expect replies).
            if m["result"] != nil || m["error"] != nil { return nil }
            return Self.error(id: m["id"] ?? .null, code: -32600, message: "invalid request")
        }
        let id = m["id"]
        let params = m["params"] ?? [:]
        guard let id else {
            await handleNotification(method, params)
            return nil
        }
        do {
            let result = try await dispatch(method, params)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let e as RPCError {
            return Self.error(id: id, code: e.code, message: e.message, data: e.data)
        } catch {
            return Self.error(id: id, code: -32603, message: String(describing: error))
        }
    }

    struct RPCError: Error {
        var code: Int
        var message: String
        var data: JSONValue?
    }

    func handleNotification(_ method: String, _ params: JSONValue) async {
        // notifications/initialized, notifications/cancelled: nothing to do (commands are short
        // and serial in M0; cancellation lands with background regeneration in M2).
    }

    func dispatch(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize": return initialize(params)
        case "ping": return [:]
        case "tools/list": return ["tools": .array(ToolCatalog.tools(registry: engine.registry).map(\.definition))]
        case "tools/call": return try await callTool(params)
        case "resources/list": return ["resources": .array(ResourceCatalog.resources)]
        case "resources/templates/list": return ["resourceTemplates": []]
        case "resources/read": return try await readResource(params)
        case "resources/subscribe":
            guard let uri = params["uri"]?.stringValue else { throw RPCError(code: -32602, message: "missing uri") }
            subscriptions.insert(uri)
            return [:]
        case "resources/unsubscribe":
            if let uri = params["uri"]?.stringValue { subscriptions.remove(uri) }
            return [:]
        case "prompts/list": return ["prompts": .array(PromptCatalog.prompts.map(\.definition))]
        case "prompts/get": return try PromptCatalog.get(params)
        case "logging/setLevel": return [:]
        case "completion/complete": return ["completion": ["values": [], "hasMore": false]]
        default: throw RPCError(code: -32601, message: "method not found: \(method)")
        }
    }

    func initialize(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? Self.supportedProtocolVersions[0]
        let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
        negotiatedVersion = version
        return [
            "protocolVersion": .string(version),
            "capabilities": [
                "tools": ["listChanged": false],
                "resources": ["subscribe": true, "listChanged": false],
                "prompts": ["listChanged": false],
                "logging": [:],
            ],
            "serverInfo": ["name": .string(Self.serverName), "version": .string(Self.serverVersion), "title": "Forge CAD"],
            "instructions": .string(Self.instructions),
        ]
    }

    static let instructions = """
        Forge is a parametric CAD engine. Every capability is a typed command on one command bus.
        Discover with list_commands / search_commands / describe_command, run with execute (or the \
        convenience tools), and verify with get_document_state, render_view (PNG) and validate_model. \
        Numbers without units use the document units (mm/deg by default); strings like "25 mm" or \
        "1 in" are always accepted. Use dry_run to preview changes, execute_batch or \
        begin/commit_transaction for atomic multi-step edits. Errors are structured: code, message, \
        entities and suggested fixes that are themselves executable commands.
        """

    var supportsStructuredContent: Bool {
        guard let v = negotiatedVersion else { return true }
        return v >= "2025-06-18"
    }

    // MARK: tools

    func callTool(_ params: JSONValue) async throws -> JSONValue {
        guard let name = params["name"]?.stringValue else { throw RPCError(code: -32602, message: "missing tool name") }
        guard let tool = ToolCatalog.tools(registry: engine.registry).first(where: { $0.name == name }) else {
            throw RPCError(code: -32602, message: "unknown tool: \(name)")
        }
        let args = params["arguments"] ?? [:]
        do {
            let output = try await tool.run(engine, args)
            if output.mutated { await notifyStateChanged() }
            return toolResult(output)
        } catch {
            let fe = ForgeError.wrap(error)
            let json = (try? JSONCoding.toJSON(fe)) ?? .string(fe.description)
            var r: [String: JSONValue] = [
                "content": [["type": "text", "text": .string(JSONCoding.string(["error": json], pretty: true))]],
                "isError": true,
            ]
            if supportsStructuredContent { r["structuredContent"] = ["error": json] }
            return .object(r)
        }
    }

    func toolResult(_ output: ToolOutput) -> JSONValue {
        var content: [JSONValue] = []
        if let png = output.imagePNGBase64 {
            content.append(["type": "image", "data": .string(png), "mimeType": "image/png"])
        }
        content.append(["type": "text", "text": .string(JSONCoding.string(output.json, pretty: true))])
        var r: [String: JSONValue] = ["content": .array(content), "isError": false]
        if supportsStructuredContent, case .object = output.json { r["structuredContent"] = output.json }
        return .object(r)
    }

    func notifyStateChanged() async {
        for uri in subscriptions.sorted() where uri.hasPrefix("forge://document") || uri == ResourceCatalog.journalURI {
            notify(JSONCoding.string(["jsonrpc": "2.0", "method": "notifications/resources/updated", "params": ["uri": .string(uri)]]))
        }
    }

    // MARK: resources

    func readResource(_ params: JSONValue) async throws -> JSONValue {
        guard let uri = params["uri"]?.stringValue else { throw RPCError(code: -32602, message: "missing uri") }
        let value: JSONValue
        switch uri {
        case ResourceCatalog.commandsURI:
            value = .array(engine.registry.all.map(\.documentation))
        case ResourceCatalog.stateURI:
            do {
                value = try await engine.execute("document.state").result
            } catch {
                value = ["error": (try? JSONCoding.toJSON(ForgeError.wrap(error))) ?? .null]
            }
        case ResourceCatalog.journalURI:
            value = ["forge_script": 1, "commands": (try? JSONCoding.toJSON(await engine.journal())) ?? []]
        default:
            throw RPCError(code: -32002, message: "resource not found", data: ["uri": .string(uri)])
        }
        return ["contents": [["uri": .string(uri), "mimeType": "application/json", "text": .string(JSONCoding.string(value, pretty: true))]]]
    }

    // MARK: helpers

    static func error(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
        var e: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { e["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": .object(e)]
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> String {
        JSONCoding.string(error(id: id, code: code, message: message))
    }
}

enum ResourceCatalog {
    static let commandsURI = "forge://commands"
    static let stateURI = "forge://document/state"
    static let journalURI = "forge://document/journal"

    static let resources: [JSONValue] = [
        ["uri": .string(commandsURI), "name": "commands", "title": "Command catalog",
         "description": "Every command with parameter/result JSON Schemas, errors and examples", "mimeType": "application/json"],
        ["uri": .string(stateURI), "name": "document-state", "title": "Active document state",
         "description": "Bodies, selection, undo/redo stacks and open transaction of the active document (subscribable)", "mimeType": "application/json"],
        ["uri": .string(journalURI), "name": "journal", "title": "Command journal",
         "description": "Replayable script of every committed command in the active document (forge-cli run)", "mimeType": "application/json"],
    ]
}

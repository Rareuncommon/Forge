import ForgeCommands
import ForgeCore
import Foundation

/// What a tool returns: JSON, optionally an image, and whether the document changed.
public struct ToolOutput: Sendable {
    public var json: JSONValue
    public var imagePNGBase64: String?
    public var mutated: Bool
}

/// An MCP tool. Most tools are thin views over bus commands and reuse the command's
/// generated JSON Schema, so MCP never drifts from the command layer.
public struct Tool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool
    public var run: @Sendable (Engine, JSONValue) async throws -> ToolOutput

    public var definition: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(readOnly),
                "openWorldHint": false,
            ],
        ]
    }
}

public enum ToolCatalog {
    /// Tools in a stable order (discovery, document, query, mutate, vision, verification).
    public static func tools(registry: CommandRegistry) -> [Tool] {
        func schema(_ command: String) -> JSONValue {
            (try? registry.descriptor(command).paramsSchema) ?? ["type": "object"]
        }
        func alias(_ tool: String, _ title: String, _ command: String, extra: String = "") -> Tool {
            let d = try? registry.descriptor(command)
            return Tool(
                name: tool, title: title, description: (d?.summary ?? command) + (extra.isEmpty ? "" : ". " + extra) + " (command: \(command))",
                inputSchema: schema(command), readOnly: d?.undo == UndoBehavior.none, destructive: false,
                run: { engine, args in
                    let o = try await engine.execute(command, args)
                    return ToolOutput(json: o.result, imagePNGBase64: nil, mutated: d?.undo != UndoBehavior.none)
                })
        }
        func imageTool(_ tool: String, _ title: String, _ command: String) -> Tool {
            let d = try? registry.descriptor(command)
            return Tool(
                name: tool, title: title, description: (d?.summary ?? command) + ". Returns the PNG as MCP image content. (command: \(command))",
                inputSchema: schema(command), readOnly: true, destructive: false,
                run: { engine, args in
                    let o = try await engine.execute(command, args)
                    var json = o.result
                    let png = json["png_base64"]?.stringValue
                    if case .object(var obj) = json {
                        obj["png_base64"] = nil
                        json = .object(obj)
                    }
                    return ToolOutput(json: json, imagePNGBase64: png, mutated: false)
                })
        }

        let invocationSchema: JSONValue = [
            "type": "object",
            "properties": [
                "command": ["type": "string", "description": "Command name, e.g. \"body.create_box\""],
                "params": ["type": "object", "description": "Command parameters (see describe_command)"],
            ],
            "required": ["command"],
            "additionalProperties": false,
        ]

        return [
            // ---- discovery
            alias("list_commands", "List commands", "help.list_commands"),
            alias("describe_command", "Describe command", "help.describe_command"),
            alias("search_commands", "Search commands", "help.search_commands"),
            // ---- document
            alias("new_document", "New document", "document.new"),
            alias("list_documents", "List documents", "document.list"),
            alias("activate_document", "Activate document", "document.activate"),
            alias("get_document_state", "Document state", "document.state"),
            // ---- sketch
            alias("create_sketch", "Create sketch", "sketch.create"),
            alias("get_sketch", "Get sketch", "sketch.get"),
            alias("edit_dimension", "Edit dimension", "sketch.set_dimension"),
            alias("check_sketch", "Check sketch", "sketch.check"),
            // ---- query
            alias("list_bodies", "List bodies", "query.bodies"),
            alias("query_faces", "Query faces", "query.faces"),
            alias("query_edges", "Query edges", "query.edges"),
            alias("query_entity", "Query entity", "query.entity"),
            alias("get_mass_properties", "Mass properties", "query.mass_properties"),
            alias("measure", "Measure", "query.measure"),
            // ---- mutate
            Tool(
                name: "execute", title: "Execute command",
                description: "Execute any Forge command by name. Set dry_run to preview the result and the entities it would create/modify/delete without committing. Returns {command, document, dry_run, result, changes}.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string", "description": "Command name (see list_commands)"],
                        "params": ["type": "object", "description": "Command parameters; validated against the command's schema"],
                        "dry_run": ["type": "boolean", "description": "Preview without committing", "default": false],
                        "document": ["type": "string", "description": "Target document id (default: active)"],
                    ],
                    "required": ["command"],
                    "additionalProperties": false,
                ],
                readOnly: false, destructive: true,
                run: { engine, args in
                    guard let command = args["command"]?.stringValue else { throw ForgeError(.invalidParams, "missing 'command'") }
                    let dry = args["dry_run"]?.boolValue ?? false
                    let o = try await engine.execute(command, args["params"] ?? [:], dryRun: dry, document: args["document"]?.stringValue)
                    let mutated = !dry && (engine.registry.descriptors[command]?.undo ?? UndoBehavior.none) != UndoBehavior.none
                    return ToolOutput(json: try JSONCoding.toJSON(o), imagePNGBase64: nil, mutated: mutated)
                }),
            Tool(
                name: "execute_batch", title: "Execute batch",
                description: "Execute a list of commands. atomic (default true): all-or-nothing, one undo step. dry_run: run, report, then restore. On failure returns failed_index and the structured error.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "commands": ["type": "array", "items": invocationSchema, "description": "Commands in order"],
                        "atomic": ["type": "boolean", "default": true, "description": "Roll back everything if any command fails"],
                        "dry_run": ["type": "boolean", "default": false, "description": "Preview without committing"],
                    ],
                    "required": ["commands"],
                    "additionalProperties": false,
                ],
                readOnly: false, destructive: true,
                run: { engine, args in
                    let items = try JSONCoding.fromJSON([Invocation].self, args["commands"] ?? [])
                    let dry = args["dry_run"]?.boolValue ?? false
                    let b = try await engine.executeBatch(items, atomic: args["atomic"]?.boolValue ?? true, dryRun: dry)
                    return ToolOutput(json: try JSONCoding.toJSON(b), imagePNGBase64: nil, mutated: !dry)
                }),
            alias("undo", "Undo", "edit.undo"),
            alias("redo", "Redo", "edit.redo"),
            alias("begin_transaction", "Begin transaction", "transaction.begin"),
            alias("commit_transaction", "Commit transaction", "transaction.commit"),
            alias("rollback_transaction", "Roll back transaction", "transaction.rollback"),
            alias("set_selection", "Set selection", "selection.set"),
            // ---- vision
            imageTool("render_view", "Render view", "view.render"),
            imageTool("render_multiview", "Render 4-view sheet", "view.render_multiview"),
            alias("pick", "Pick", "view.pick", extra: "Pass the same 'view' used for render_view"),
            // ---- verification & export
            alias("validate_model", "Validate model", "query.validate"),
            alias("compare_to_spec", "Compare to spec", "query.compare_to_spec"),
            alias("export_step", "Export STEP", "export.step"),
            alias("export_stl", "Export STL", "export.stl"),
        ]
    }
}

public struct Prompt: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var arguments: [(name: String, description: String, required: Bool)]
    public var render: @Sendable ([String: String]) -> String

    var definition: JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description),
            "arguments": .array(arguments.map { ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)] }),
        ]
    }
}

enum PromptCatalog {
    static let prompts: [Prompt] = [
        Prompt(
            name: "model_from_description", title: "Model a part from a description",
            description: "Build a part from a dimensioned description and verify it",
            arguments: [("description", "Dimensioned description of the part", true)],
            render: { args in
                """
                Build this part in Forge: \(args["description"] ?? "")

                Workflow:
                1. new_document (choose units that match the description).
                2. Plan the geometry; call describe_command for any command you have not used. Profiles are drawn
                   in sketches (create_sketch, sketch.add_* via execute) and fully defined with relations and
                   dimensions — get_sketch reports DOF and conflicts, check_sketch validates closed profiles.
                3. Use execute_batch with dry_run: true to check the plan, then run it for real (atomic).
                4. Verify: get_document_state (volumes, bounding boxes, topology), validate_model, and render_multiview.
                5. If anything is off, undo or fix with targeted commands; errors include executable suggested fixes.
                Report the final bounding box, volume and any assumptions you made.
                """
            }),
        Prompt(
            name: "verify_model", title: "Verify the active model",
            description: "Check the active document against a specification",
            arguments: [("spec", "Expected dimensions/volume/features", true)],
            render: { args in
                """
                Verify the active Forge document against this specification: \(args["spec"] ?? "")
                Use get_document_state, get_mass_properties, query_faces/query_edges, validate_model and render_view.
                List every check with expected vs actual values and a pass/fail verdict.
                """
            }),
    ]

    static func get(_ params: JSONValue) throws -> JSONValue {
        guard let name = params["name"]?.stringValue, let p = prompts.first(where: { $0.name == name }) else {
            throw MCPServer.RPCError(code: -32602, message: "unknown prompt")
        }
        var args: [String: String] = [:]
        for (k, v) in params["arguments"]?.objectValue ?? [:] { args[k] = v.stringValue ?? JSONCoding.string(v) }
        for a in p.arguments where a.required && args[a.name] == nil {
            throw MCPServer.RPCError(code: -32602, message: "missing required argument '\(a.name)'")
        }
        return [
            "description": .string(p.description),
            "messages": [["role": "user", "content": ["type": "text", "text": .string(p.render(args))]]],
        ]
    }
}

import ForgeCommands
import ForgeCore
import Foundation
import Testing

@testable import ForgeMCP

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

struct Client {
    let server: MCPServer
    var nextID = 1

    mutating func request(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let msg: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        let line = await server.handle(JSONCoding.string(msg))
        let response = try JSONCoding.parse(line!)
        #expect(response["id"] == .number(Double(id)))
        return response
    }

    mutating func call(_ tool: String, _ args: JSONValue = [:]) async throws -> JSONValue {
        try await request("tools/call", ["name": .string(tool), "arguments": args])["result"]!
    }
}

@Suite("MCP server")
struct MCPServerTests {
    func client(notify: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Client {
        var c = Client(server: MCPServer(engine: Engine(), notify: notify))
        let r = try await c.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
        #expect(r["result"]?["protocolVersion"] == "2025-11-25")
        #expect(r["result"]?["serverInfo"]?["name"] == "forge")
        #expect(await c.server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        return c
    }

    @Test func versionNegotiationFallsBackToLatest() async throws {
        var c = Client(server: MCPServer(engine: Engine()))
        let r = try await c.request("initialize", ["protocolVersion": "1999-01-01"])
        #expect(r["result"]?["protocolVersion"] == .string(MCPServer.supportedProtocolVersions[0]))
        let old = try await c.request("initialize", ["protocolVersion": "2024-11-05"])
        #expect(old["result"]?["protocolVersion"] == "2024-11-05")
    }

    @Test func toolListHasSchemasFromCommands() async throws {
        var c = try await client()
        let tools = try await c.request("tools/list")["result"]!["tools"]!.arrayValue!
        let names = tools.compactMap { $0["name"]?.stringValue }
        for required in ["list_commands", "describe_command", "search_commands", "execute", "execute_batch", "undo", "redo",
                         "new_document", "get_document_state", "render_view", "render_multiview", "pick", "validate_model",
                         "compare_to_spec", "get_mass_properties", "measure", "get_sketch", "edit_dimension", "create_sketch", "check_sketch", "get_feature_tree", "edit_feature", "rebuild", "repair_reference", "begin_transaction", "commit_transaction", "rollback_transaction"] {
            #expect(names.contains(required), "missing tool \(required)")
        }
        #expect(Set(names).count == names.count, "duplicate tool names")
        for t in tools {
            #expect(t["inputSchema"]?["type"] == "object", "\(t["name"]!) needs an object input schema")
            #expect(t["description"]?.stringValue?.isEmpty == false)
        }
    }

    @Test func buildVerifyAndRenderThroughTools() async throws {
        var c = try await client()
        _ = try await c.call("new_document", ["name": "Bracket"])
        let batch = try await c.call("execute_batch", ["commands": [
            ["command": "body.create_box", "params": ["width": 40, "height": 20, "depth": 10]],
            ["command": "body.create_cylinder", "params": ["radius": 5, "height": 20, "origin": [20, 10, -5]]],
            ["command": "body.boolean", "params": ["operation": "cut", "target": "body-1", "tool": "body-2"]],
        ]])
        #expect(batch["isError"] == false)
        #expect(batch["structuredContent"]?["committed"] == true)

        let spec = try await c.call("compare_to_spec", ["spec": ["body_count": 1, "bodies": [[
            "body": "body-1", "volume_mm3": ["value": .number(8000 - Double.pi * 25 * 10), "tol": 1e-6], "faces": 7,
        ]]]])
        #expect(spec["structuredContent"]?["passed"] == true)

        let img = try await c.call("render_view", ["view": ["orientation": "top", "width": 160, "height": 120]])
        let content = img["content"]!.arrayValue!
        #expect(content.first?["type"] == "image")
        #expect(content.first?["mimeType"] == "image/png")
        let png = Data(base64Encoded: content.first!["data"]!.stringValue!)!
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(img["structuredContent"]?["png_base64"] == nil)

        let undo = try await c.call("undo")
        #expect(undo["structuredContent"]?["undone"] == "batch of 3 commands")
    }

    @Test func toolErrorsAreStructuredResultsNotProtocolErrors() async throws {
        var c = try await client()
        let r = try await c.call("execute", ["command": "body.create_box", "params": ["width": 1, "height": 1, "depth": 1]])
        #expect(r["isError"] == true)
        let err = r["structuredContent"]?["error"]
        #expect(err?["code"] == "precondition_failed")
        #expect(err?["suggestions"]?[0]?["command"] == "document.new")

        let unknown = try await c.request("tools/call", ["name": "no_such_tool", "arguments": [:]])
        #expect(unknown["error"]?["code"] == -32602)
    }

    @Test func dryRunThroughExecute() async throws {
        var c = try await client()
        _ = try await c.call("new_document")
        let r = try await c.call("execute", ["command": "body.create_sphere", "params": ["radius": 2], "dry_run": true])
        #expect(r["structuredContent"]?["dry_run"] == true)
        #expect(r["structuredContent"]?["changes"]?["created"] == ["body-1", "feature-1"])
        let state = try await c.call("get_document_state")
        #expect(state["structuredContent"]?["bodies"] == [])
    }

    @Test func protocolErrors() async throws {
        let s = MCPServer(engine: Engine())
        let parse = try JSONCoding.parse(await s.handle("{not json")!)
        #expect(parse["error"]?["code"] == -32700)
        let missing = try JSONCoding.parse(await s.handle(#"{"jsonrpc":"2.0","id":7,"method":"nope"}"#)!)
        #expect(missing["error"]?["code"] == -32601)
        #expect(missing["id"] == 7)
        let ping = try JSONCoding.parse(await s.handle(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#)!)
        #expect(ping["result"] == [:])
    }

    @Test func parametricFeatureToolsEditUndoRebuildAndPublishTheTree() async throws {
        let notes = Collected()
        var c = try await client(notify: { notes.add($0) })
        _ = try await c.call("new_document")
        _ = try await c.request("resources/subscribe", ["uri": "forge://document/features"])
        _ = try await c.call("execute", ["command": "body.create_box", "params": ["width": 2, "height": 3, "depth": 4]])
        let tree = try await c.call("get_feature_tree")
        #expect(tree["structuredContent"]?["features"]?[0]?["id"] == "feature-1")
        let edit = try await c.call("edit_feature", ["feature": "feature-1", "params": ["width": 5]])
        #expect(edit["isError"] == false)
        let verify = try await c.call("compare_to_spec", ["spec": ["bodies": [["body": "body-1", "volume_mm3": ["value": 60, "tol": 1e-9]]]]])
        #expect(verify["structuredContent"]?["passed"] == true)
        _ = try await c.call("undo")
        #expect(try await c.call("get_feature_tree")["structuredContent"]?["features"]?[0]?["params"]?["width"] == 2)
        _ = try await c.call("redo")
        _ = try await c.call("rename_feature", ["feature": "feature-1", "name": "Block"])
        _ = try await c.call("suppress_feature", ["feature": "Block"])
        #expect(try await c.call("get_document_state")["structuredContent"]?["bodies"] == [])
        _ = try await c.call("suppress_feature", ["feature": "Block", "suppressed": false])
        _ = try await c.call("rollback_features", ["before": "Block"])
        #expect(try await c.call("get_document_state")["structuredContent"]?["bodies"] == [])
        _ = try await c.call("rollback_features")
        let rebuilt = try await c.call("rebuild")
        #expect(rebuilt["isError"] == false)
        let resource = try await c.request("resources/read", ["uri": "forge://document/features"])
        let value = try JSONCoding.parse(try #require(resource["result"]?["contents"]?[0]?["text"]?.stringValue))
        #expect(value["features"]?[0]?["name"] == "Block")
        #expect(value["features"]?[0]?["state"] == "ok")
        #expect(notes.all.contains { $0.contains("forge://document/features") })
    }

    @Test func exportedFilesAreNotAdvertisedAsReadOnly() async throws {
        var c = try await client()
        let list = try await c.request("tools/list")["result"]?["tools"]?.arrayValue ?? []
        for name in ["export_step", "export_stl", "save"] {
            let tool = try #require(list.first { $0["name"]?.stringValue == name })
            #expect(tool["annotations"]?["readOnlyHint"] == false)
            #expect(tool["annotations"]?["destructiveHint"] == true)
        }
    }

    @Test func invalidToolFlagsCannotAccidentallyMutateTheDocument() async throws {
        var c = try await client()
        _ = try await c.call("new_document")
        for args: JSONValue in [
            ["command": "body.create_box", "params": ["width": 2, "height": 3, "depth": 4], "dry_run": "true"],
            ["command": "body.create_box", "params": ["width": 2, "height": 3, "depth": 4], "dry_rnu": true],
            ["commands": [], "atomic": "false"],
        ] {
            let result = try await c.call(args["commands"] == nil ? "execute" : "execute_batch", args)
            #expect(result["isError"] == true)
            #expect(result["structuredContent"]?["error"]?["code"] == "invalid_params")
        }
        #expect(try await c.call("get_document_state")["structuredContent"]?["bodies"] == [])
    }

    @Test func failedBatchesReportToolErrorsAndOnlyNotifyCommittedChanges() async throws {
        let notes = Collected()
        var c = try await client(notify: { notes.add($0) })
        _ = try await c.call("new_document")
        _ = try await c.request("resources/subscribe", ["uri": "forge://document/state"])
        let commands: JSONValue = [
            ["command": "body.create_box", "params": ["width": 2, "height": 3, "depth": 4]],
            ["command": "body.create_sphere", "params": ["radius": -1]],
        ]
        let atomic = try await c.call("execute_batch", ["commands": commands])
        #expect(atomic["isError"] == true)
        #expect(atomic["structuredContent"]?["failed_index"] == 1)
        #expect(atomic["structuredContent"]?["committed"] == false)
        #expect(notes.all.isEmpty)
        #expect(try await c.call("get_document_state")["structuredContent"]?["bodies"] == [])
        let partial = try await c.call("execute_batch", ["commands": commands, "atomic": false])
        #expect(partial["isError"] == true)
        #expect(partial["structuredContent"]?["committed"] == true)
        #expect(notes.all.count == 1)
        let dry = try await c.call("execute_batch", ["commands": commands, "dry_run": true])
        #expect(dry["isError"] == true)
        #expect(notes.all.count == 1)
    }

    @Test func malformedProtocolMessagesAreRejected() async throws {
        let server = MCPServer(engine: Engine())
        for line in ["[]", #"{"jsonrpc":"1.0","id":true,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":{},"method":"ping"}"#] {
            let response = try JSONCoding.parse(try #require(await server.handle(line)))
            #expect(response["error"]?["code"] == -32600)
            #expect(response["id"] == .null)
        }
        let response = try JSONCoding.parse(try #require(await server.handle(
            #"{"jsonrpc":"2.0","id":1,"method":"ping","params":false}"#)))
        #expect(response["error"]?["code"] == -32602)
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"ping","params":false}"#) == nil)
    }

    @Test func resourcesAndSubscriptions() async throws {
        let notes = Collected()
        var c = try await client(notify: { notes.add($0) })
        let list = try await c.request("resources/list")["result"]!["resources"]!.arrayValue!
        #expect(list.compactMap { $0["uri"]?.stringValue } == ["forge://commands", "forge://document/state", "forge://document/journal", "forge://document/features"])
        let catalog = try await c.request("resources/read", ["uri": "forge://commands"])
        let text = catalog["result"]!["contents"]![0]!["text"]!.stringValue!
        #expect(try JSONCoding.parse(text).arrayValue!.count == CommandRegistry.standard.all.count)

        _ = try await c.request("resources/subscribe", ["uri": "forge://document/state"])
        _ = try await c.call("new_document")
        _ = try await c.call("execute", ["command": "body.create_box", "params": ["width": 1, "height": 2, "depth": 3]])
        #expect(notes.all.contains { $0.contains("notifications/resources/updated") && $0.contains("forge://document/state") })

        let journal = try await c.request("resources/read", ["uri": "forge://document/journal"])
        let script = try JSONCoding.parse(journal["result"]!["contents"]![0]!["text"]!.stringValue!)
        #expect(script["commands"]?.arrayValue?.last?["command"] == "body.create_box")
        let bad = try await c.request("resources/read", ["uri": "forge://nope"])
        #expect(bad["error"] != nil)
    }

    @Test func prompts() async throws {
        var c = try await client()
        let list = try await c.request("prompts/list")["result"]!["prompts"]!.arrayValue!
        #expect(list.contains { $0["name"] == "model_from_description" })
        let p = try await c.request("prompts/get", ["name": "model_from_description", "arguments": ["description": "a 10 mm cube"]])
        #expect(p["result"]?["messages"]?[0]?["content"]?["text"]?.stringValue?.contains("a 10 mm cube") == true)
        let missing = try await c.request("prompts/get", ["name": "model_from_description"])
        #expect(missing["error"]?["code"] == -32602)
    }
}

#if !os(Windows)
@Suite("MCP Unix socket transport")
struct SocketTests {
    @Test func socketStartupAndStopPreserveUnownedFiles() throws {
        let path = "/tmp/forge-file-\(UUID().uuidString).sock"
        let original = Data("valuable document".utf8)
        try original.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let transport = UnixSocketTransport(path: path)
        #expect(throws: ForgeError.self) { try transport.start(engine: Engine()) }
        transport.stop()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
    }

    @Test func socketStartupDoesNotReplaceALiveServer() throws {
        let path = "/tmp/forge-live-\(UUID().uuidString).sock"
        let first = UnixSocketTransport(path: path)
        try first.start(engine: Engine())
        defer { first.stop() }
        #expect(throws: ForgeError.self) { try first.start(engine: Engine()) }
        let second = UnixSocketTransport(path: path)
        #expect(throws: ForgeError.self) { try second.start(engine: Engine()) }
        second.stop()
        #expect(FileManager.default.fileExists(atPath: path))
        var metadata = stat()
        #expect(lstat(path, &metadata) == 0)
        #expect(metadata.st_mode & 0o777 == 0o600)
    }

    @Test func stoppedTransportPreservesAReplacementFile() throws {
        let path = "/tmp/forge-replaced-\(UUID().uuidString).sock"
        let transport = UnixSocketTransport(path: path)
        try transport.start(engine: Engine())
        defer {
            transport.stop()
            try? FileManager.default.removeItem(atPath: path)
        }
        try FileManager.default.removeItem(atPath: path)
        let data = Data("replacement".utf8)
        try data.write(to: URL(fileURLWithPath: path))
        transport.stop()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
    }

    @Test func disconnectedSocketDoesNotTerminateTheProcess() throws {
        for configureBeforeDisconnect in [true, false] {
            var fds = [Int32](repeating: -1, count: 2)
            #if canImport(Glibc)
            let type = Int32(SOCK_STREAM.rawValue)
            #else
            let type = SOCK_STREAM
            #endif
            try #require(socketpair(AF_UNIX, type, 0, &fds) == 0)
            defer { close(fds[0]) }
            let writer = configureBeforeDisconnect ? LineWriter(fd: fds[0], socketOutput: true) : nil
            close(fds[1])
            (writer ?? LineWriter(fd: fds[0], socketOutput: true)).write("disconnected")
        }
    }

    @Test func transportCanRestartAndStopDisconnectsClients() async throws {
        let path = "/tmp/forge-restart-\(UUID().uuidString).sock"
        let transport = UnixSocketTransport(path: path)
        defer { transport.stop() }
        for iteration in 0..<5 {
            let engine = Engine()
            _ = try await engine.execute("document.new", ["name": .string("Session\(iteration)")])
            try transport.start(engine: engine)
            #if canImport(Glibc)
            let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
            #else
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            #endif
            try #require(fd >= 0)
            defer { close(fd) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            try #require(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            try #require(rc == 0)
            LineWriter(fd: fd, socketOutput: true).write(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_document_state"}}"#)
            var bytes = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while !bytes.contains(10) {
                let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                try #require(count > 0)
                bytes.append(contentsOf: chunk[..<count])
            }
            #expect(String(decoding: bytes, as: UTF8.self).contains("Session\(iteration)"))
            transport.stop()
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            #expect(count == 0)
        }
    }

    @Test func initializeOverSocket() async throws {
        let path = "/tmp/forge-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        let transport = UnixSocketTransport(path: path)
        try transport.start(engine: Engine())
        defer { transport.stop() }

        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        #expect(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(rc == 0)
        let msg = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"# + "\n"
        _ = msg.withCString { write(fd, $0, strlen($0)) }
        var buf = [UInt8](repeating: 0, count: 65536)
        var received = [UInt8]()
        while !received.contains(0x0A) {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            received += buf[0..<n]
        }
        let response = try JSONCoding.parse(String(decoding: received, as: UTF8.self))
        #expect(response["result"]?["protocolVersion"] == "2025-06-18")
    }
}
#endif

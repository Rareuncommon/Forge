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
                         "compare_to_spec", "get_mass_properties", "measure", "begin_transaction", "commit_transaction", "rollback_transaction"] {
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
        #expect(r["structuredContent"]?["changes"]?["created"] == ["body-1"])
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

    @Test func resourcesAndSubscriptions() async throws {
        let notes = Collected()
        var c = try await client(notify: { notes.add($0) })
        let list = try await c.request("resources/list")["result"]!["resources"]!.arrayValue!
        #expect(list.compactMap { $0["uri"]?.stringValue } == ["forge://commands", "forge://document/state", "forge://document/journal"])
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

@Suite("MCP Unix socket transport")
struct SocketTests {
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

// forge-cli — headless Forge engine: run commands and scripts, serve MCP, batch export.
// Everything the app can build, forge-cli can build (SPEC §3 "Headless first").

import ForgeCommands
import ForgeCore
import ForgeKernel
import ForgeMCP
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif

let usage = """
    forge-cli — headless Forge CAD engine

    USAGE
      forge-cli run <script.json>... [--quiet]   Run forge scripts; check their "expect" specs
      forge-cli exec <command> [params-json]      Run one command in a fresh session (a document is created first)
      forge-cli commands [--json]                 List commands
      forge-cli describe <command>                Command documentation with JSON Schemas
      forge-cli search <query>                    Search commands
      forge-cli mcp [--socket <path>]             Serve MCP on stdio (and optionally a Unix socket)
      forge-cli version                           Engine and kernel versions

    Script format: {"forge_script": 1, "commands": [{"command": "...", "params": {...}}], "expect": {...}}
    Exit status: 0 success, 1 command/spec failure, 2 usage error.
    """

func printJSON(_ v: JSONValue, pretty: Bool = true) {
    print(JSONCoding.string(v, pretty: pretty))
}

func fail(_ e: ForgeError) -> Never {
    let json = (try? JSONCoding.toJSON(e)) ?? .string(e.description)
    FileHandle.standardError.write(Data((JSONCoding.string(["error": json], pretty: true) + "\n").utf8))
    exit(1)
}

func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let sub = args.first else { usageError("missing subcommand") }
args.removeFirst()

let engine = Engine()

do {
    switch sub {
    case "version", "--version":
        printJSON(["forge": .string(MCPServer.serverVersion), "kernel": .string(Kernel.version), "commands": .number(Double(engine.registry.all.count))])

    case "commands":
        if args.contains("--json") {
            printJSON(.array(engine.registry.all.map(\.brief)))
        } else {
            for d in engine.registry.all { print("\(d.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(d.summary)") }
        }

    case "describe":
        guard let name = args.first else { usageError("describe needs a command name") }
        printJSON(try engine.registry.descriptor(name).documentation)

    case "search":
        guard !args.isEmpty else { usageError("search needs a query") }
        for d in engine.registry.search(args.joined(separator: " ")) { print("\(d.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(d.summary)") }

    case "exec":
        guard let command = args.first else { usageError("exec needs a command name") }
        let params = args.count > 1 ? try JSONCoding.parse(args[1]) : [:]
        if !command.hasPrefix("document.") && !command.hasPrefix("help.") { try await engine.execute("document.new") }
        printJSON(try JSONCoding.toJSON(try await engine.execute(command, params)))

    case "run":
        let quiet = args.contains("--quiet")
        let files = args.filter { !$0.hasPrefix("--") }
        guard !files.isEmpty else { usageError("run needs at least one script") }
        var failed = false
        for file in files {
            let script = try ForgeScript.load(URL(fileURLWithPath: file))
            let e = Engine()
            let result = try await e.run(script)
            if !quiet {
                for o in result.outcomes { printJSON(try JSONCoding.toJSON(o), pretty: false) }
            }
            if let r = result.report {
                let status = r.passed ? "PASS" : "FAIL"
                print("\(status) \(script.name ?? file): \(r.checks.count - r.failures)/\(r.checks.count) checks")
                for c in r.checks where !c.passed {
                    print("  ✗ \(c.subject).\(c.property): expected \(c.expected), got \(c.actual)")
                }
                failed = failed || !r.passed
            }
        }
        exit(failed ? 1 : 0)

    case "mcp":
        var socket: UnixSocketTransport?
        if let i = args.firstIndex(of: "--socket") {
            guard i + 1 < args.count else { usageError("--socket needs a path") }
            socket = UnixSocketTransport(path: args[i + 1])
            try socket!.start(engine: engine)
            FileHandle.standardError.write(Data("forge-cli: MCP also listening on \(args[i + 1])\n".utf8))
        }
        await StdioTransport.run(engine: engine)
        socket?.stop()

    case "help", "--help", "-h":
        print(usage)

    default:
        usageError("unknown subcommand '\(sub)'")
    }
} catch {
    fail(ForgeError.wrap(error))
}

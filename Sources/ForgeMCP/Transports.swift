import ForgeCommands
import ForgeCore
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Serialised, newline-delimited writes to a file descriptor.
final class LineWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()

    init(fd: Int32) { self.fd = fd }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { raw in
                #if canImport(Glibc)
                Glibc.write(fd, raw.baseAddress, raw.count)
                #else
                Darwin.write(fd, raw.baseAddress, raw.count)
                #endif
            }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return
            }
            offset += n
        }
    }
}

/// Reads newline-delimited messages from a file descriptor on a dedicated thread.
func lines(from fd: Int32) -> AsyncStream<String> {
    AsyncStream { continuation in
        let thread = Thread {
            var buffer = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = chunk.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress, raw.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
                while let nl = buffer.firstIndex(of: 0x0A) {
                    continuation.yield(String(decoding: buffer[..<nl], as: UTF8.self))
                    buffer.removeSubrange(...nl)
                }
            }
            if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
            continuation.finish()
        }
        thread.stackSize = 1 << 20
        thread.start()
    }
}

/// Serve one connection: each incoming line is handled in order; responses and
/// notifications are written back on the same connection.
public func serveConnection(engine: Engine, input: Int32, output: Int32) async {
    let writer = LineWriter(fd: output)
    let server = MCPServer(engine: engine, notify: { writer.write($0) })
    for await line in lines(from: input) {
        if let response = await server.handle(line) { writer.write(response) }
    }
}

/// MCP over stdio (the standard transport for local MCP servers).
public enum StdioTransport {
    public static func run(engine: Engine) async {
        await serveConnection(engine: engine, input: STDIN_FILENO, output: STDOUT_FILENO)
    }
}

/// MCP over a local Unix-domain socket, so an app instance can be driven by several local
/// agents at once. All connections share one Engine (one command bus).
public final class UnixSocketTransport: @unchecked Sendable {
    public let path: String
    private var listenFD: Int32 = -1

    public init(path: String) { self.path = path }

    public func start(engine: Engine) throws {
        unlink(path)
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw ForgeError(.ioError, "socket() failed: \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else {
            close(fd)
            throw ForgeError(.invalidParams, "socket path longer than \(maxLen) bytes")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8) + [0])
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            close(fd)
            throw ForgeError(.ioError, "bind(\(path)) failed: errno \(errno)")
        }
        chmod(path, 0o600)  // owner-only: the socket grants full control of the session
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw ForgeError(.ioError, "listen failed: errno \(errno)")
        }
        listenFD = fd
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                Task {
                    await serveConnection(engine: engine, input: client, output: client)
                    close(client)
                }
            }
        }
        thread.start()
    }

    public func stop() {
        if listenFD >= 0 {
            shutdown(listenFD, Int32(SHUT_RDWR))
            close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }
}

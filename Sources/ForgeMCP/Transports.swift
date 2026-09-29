import ForgeCommands
import ForgeCore
import Foundation
import Dispatch

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif

/// Serialised, newline-delimited writes to a file descriptor.
final class LineWriter: @unchecked Sendable {
    private let fd: Int32
    private let socketOutput: Bool
    private let lock = NSLock()

    init(fd: Int32, socketOutput: Bool = false) {
        self.fd = fd
        self.socketOutput = socketOutput
        #if canImport(Darwin)
        if socketOutput {
            var enabled: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        }
        #endif
    }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { raw in
                #if canImport(Glibc)
                socketOutput
                    ? Glibc.send(fd, raw.baseAddress, raw.count, Int32(MSG_NOSIGNAL))
                    : Glibc.write(fd, raw.baseAddress, raw.count)
                #elseif os(Windows)
                Int(ucrt._write(fd, raw.baseAddress, UInt32(raw.count)))
                #else
                Darwin.write(fd, raw.baseAddress, raw.count)
                #endif
            }
            if n <= 0 {
                #if !os(Windows)
                if n < 0 && errno == EINTR { continue }
                #endif
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
                #if os(Windows)
                let n = chunk.withUnsafeMutableBytes { raw in Int(_read(fd, raw.baseAddress, UInt32(raw.count))) }
                #else
                let n = chunk.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress, raw.count) }
                if n < 0 && errno == EINTR { continue }
                #endif
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
public func serveConnection(engine: Engine, input: Int32, output: Int32, socketOutput: Bool = false) async {
    let writer = LineWriter(fd: output, socketOutput: socketOutput)
    let server = MCPServer(engine: engine, notify: { writer.write($0) })
    for await line in lines(from: input) {
        if let response = await server.handle(line) { writer.write(response) }
    }
}

/// MCP over stdio (the standard transport for local MCP servers).
public enum StdioTransport {
    public static func run(engine: Engine) async {
        #if os(Windows)
        // Binary mode: no CRLF translation of the newline-delimited JSON.
        _ = _setmode(0, 0x8000)
        _ = _setmode(1, 0x8000)
        await serveConnection(engine: engine, input: 0, output: 1)
        #else
        await serveConnection(engine: engine, input: STDIN_FILENO, output: STDOUT_FILENO)
        #endif
    }
}

#if !os(Windows)
/// MCP over a local Unix-domain socket, so an app instance can be driven by several local
/// agents at once. All connections share one Engine (one command bus).
public final class UnixSocketTransport: @unchecked Sendable {
    public let path: String
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var socketIdentity: (device: UInt64, inode: UInt64)?
    private let acceptGroup = DispatchGroup()
    private let clientLock = NSLock()
    private var clients: Set<Int32> = []
    private var stopping = false

    public init(path: String) { self.path = path }

    public func start(engine: Engine) throws {
        lock.lock()
        defer { lock.unlock() }
        guard listenFD < 0 else { throw ForgeError(.ioError, "socket transport is already running") }
        guard !path.isEmpty, !path.utf8.contains(0) else {
            throw ForgeError(.invalidParams, "socket path must be nonempty and contain no NUL bytes")
        }
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
        // Never unlink an existing path on startup: it may be a file or another live server.
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            close(fd)
            throw ForgeError(.ioError, "cannot inspect bound socket")
        }
        socketIdentity = (UInt64(metadata.st_dev), UInt64(metadata.st_ino))
        guard chmod(path, 0o600) == 0 else {
            close(fd)
            removeOwnedSocket()
            throw ForgeError(.ioError, "cannot restrict socket permissions")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            removeOwnedSocket()
            throw ForgeError(.ioError, "listen failed: errno \(errno)")
        }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd)
            removeOwnedSocket()
            throw ForgeError(.ioError, "cannot make listener nonblocking")
        }
        listenFD = fd
        clientLock.lock()
        stopping = false
        clientLock.unlock()
        acceptGroup.enter()
        let thread = Thread {
            defer { self.acceptGroup.leave() }
            while !self.shouldStop {
                // Darwin cannot shutdown an unconnected listener to wake accept. Polling
                // a nonblocking descriptor bounds stop latency on both Darwin and Linux.
                var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let count = poll(&ready, 1, 100)
                if count == 0 { continue }
                if count < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if self.shouldStop { break }
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    break
                }
                // Darwin may inherit the listener's flags; connection readers are blocking.
                guard fcntl(client, F_SETFL, 0) == 0 else {
                    close(client)
                    continue
                }
                self.registerClient(client)
                Task {
                    await serveConnection(engine: engine, input: client, output: client, socketOutput: true)
                    self.closeClient(client)
                }
            }
        }
        thread.start()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if listenFD >= 0 {
            clientLock.lock()
            stopping = true
            clientLock.unlock()
            // The accept loop must exit before the descriptor can be reused by a restart.
            acceptGroup.wait()
            close(listenFD)
            listenFD = -1
        }
        clientLock.lock()
        for client in clients { shutdown(client, Int32(SHUT_RDWR)) }
        clientLock.unlock()
        removeOwnedSocket()
    }

    private var shouldStop: Bool {
        clientLock.lock()
        defer { clientLock.unlock() }
        return stopping
    }

    private func registerClient(_ fd: Int32) {
        clientLock.lock()
        defer { clientLock.unlock() }
        clients.insert(fd)
    }

    private func closeClient(_ fd: Int32) {
        clientLock.lock()
        defer { clientLock.unlock() }
        clients.remove(fd)
        close(fd)
    }

    private func removeOwnedSocket() {
        guard let identity = socketIdentity else { return }
        var metadata = stat()
        if lstat(path, &metadata) == 0,
            UInt64(metadata.st_dev) == identity.device, UInt64(metadata.st_ino) == identity.inode {
            unlink(path)
        }
        socketIdentity = nil
    }
}
#else
/// MCP over a local socket is not available on Windows yet (named pipes / AF_UNIX via
/// WinSock). Use the stdio transport.
public final class UnixSocketTransport: @unchecked Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    // NOT IMPLEMENTED: Windows local-socket transport (FEATURES.md: 1.x mcp socket on Windows).
    public func start(engine: Engine) throws {
        throw ForgeError(
            .unsupported, "the local socket transport is not available on Windows yet; run forge-cli mcp over stdio",
            suggestions: [SuggestedFix(description: "Serve MCP over stdio", command: "forge-cli mcp")])
    }

    public func stop() {}
}
#endif

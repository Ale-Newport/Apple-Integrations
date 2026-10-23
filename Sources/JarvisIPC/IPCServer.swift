import Darwin
import Foundation
import JarvisCore

/// A local-only control channel: a Unix domain socket in the user's Application Support folder.
///
/// * No network port is opened; the socket file is `0600` inside a `0700` directory, and every connection's peer
///   user id is checked, so only processes of the same macOS user can talk to Jarvis.
/// * Requests are newline-delimited JSON (see ``IPCRequest``); one connection may send many requests in sequence.
/// * A client that disconnects while a request is running cancels it.
/// * Limits: 1 MiB per request line, a bounded number of simultaneous connections, idle connections time out.
public final class IPCServer: @unchecked Sendable {
    public struct Limits: Sendable {
        public var maxConnections = 8
        public var idleTimeout: TimeInterval = 300
        public init() {}
    }

    private let socketURL: URL
    private let handler: any IPCRequestHandling
    private let limits: Limits
    private let queue = DispatchQueue(label: "com.newportdiaz.jarvis.ipc.server")

    // Everything below is confined to `queue`.
    private var listenDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var running = false

    public init(socketURL: URL = JarvisPaths.socketFile(), handler: any IPCRequestHandling, limits: Limits = Limits()) {
        self.socketURL = socketURL
        self.handler = handler
        self.limits = limits
    }

    public var path: String { socketURL.path }

    public var isRunning: Bool { queue.sync { running } }

    // MARK: Lifecycle

    public func start() throws {
        try queue.sync {
            guard !running else { return }
            let directory = socketURL.deletingLastPathComponent()
            if directory.path != "/tmp" { JarvisPaths.ensurePrivateDirectory(directory) }

            try removeStaleSocket()

            var address = try UnixSocket.address(for: socketURL.path)
            let descriptor = try UnixSocket.makeSocket()
            // Create the file as 0600 from the start (no window where it is more permissive).
            let previousMask = umask(0o177)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            let bindError = errno
            umask(previousMask)
            guard bound == 0 else {
                close(descriptor)
                throw IPCError.socketFailed(String(cString: strerror(bindError)))
            }
            chmod(socketURL.path, 0o600)
            guard listen(descriptor, 16) == 0 else {
                let message = String(cString: strerror(errno))
                close(descriptor)
                unlink(socketURL.path)
                throw IPCError.socketFailed(message)
            }
            UnixSocket.setNonBlocking(descriptor)

            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.setCancelHandler { close(descriptor) }
            source.resume()

            listenDescriptor = descriptor
            acceptSource = source
            running = true
            JarvisLog.ipc.info("IPC server listening")
        }
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            acceptSource?.cancel()
            acceptSource = nil
            listenDescriptor = -1
            for connection in connections.values { connection.close() }
            connections.removeAll()
            unlink(socketURL.path)
            JarvisLog.ipc.info("IPC server stopped")
        }
    }

    deinit { stop() }

    /// A leftover socket from a crashed run is removed; a socket with a live server behind it is an error.
    private func removeStaleSocket() throws {
        var info = stat()
        guard lstat(socketURL.path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
            throw IPCError.socketFailed("\(socketURL.path) exists and is not a Jarvis socket")
        }
        if let probe = try? UnixSocket.connect(to: socketURL.path) {
            close(probe)
            throw IPCError.alreadyRunning
        }
        unlink(socketURL.path)
    }

    // MARK: Accepting

    private func acceptPending() {
        while true {
            let descriptor = accept(listenDescriptor, nil, nil)
            if descriptor < 0 { return }   // EAGAIN: nothing more to accept
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            guard UnixSocket.peerUserID(descriptor) == getuid() else {
                JarvisLog.ipc.error("Rejected a connection from another user")
                close(descriptor)
                continue
            }
            guard connections.count < limits.maxConnections else {
                let busy = IPCResponse.failure("busy", "Too many simultaneous connections.")
                if let data = try? IPCCodec.encode(busy) { UnixSocket.writeAll(data, to: descriptor) }
                close(descriptor)
                continue
            }
            UnixSocket.setNonBlocking(descriptor)
            let connection = Connection(descriptor: descriptor, handler: handler, queue: queue, idleTimeout: limits.idleTimeout) { [weak self] finished in
                self?.connections[finished] = nil
            }
            connections[descriptor] = connection
            connection.start()
        }
    }
}

/// One accepted client. Requests on a connection run one at a time, in order.
private final class Connection: @unchecked Sendable {
    private let descriptor: Int32
    private let handler: any IPCRequestHandling
    private let queue: DispatchQueue
    private let idleTimeout: TimeInterval
    private let onClose: (Int32) -> Void
    private let id = "ipc:" + UUID().uuidString.prefix(8).lowercased()

    private var source: DispatchSourceRead?
    private var idleTimer: DispatchSourceTimer?
    private var buffer = Data()
    private var pending: [Data] = []
    private var current: Task<Void, Never>?
    private var closed = false

    init(descriptor: Int32, handler: any IPCRequestHandling, queue: DispatchQueue, idleTimeout: TimeInterval, onClose: @escaping (Int32) -> Void) {
        self.descriptor = descriptor
        self.handler = handler
        self.queue = queue
        self.idleTimeout = idleTimeout
        self.onClose = onClose
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        self.source = source
        armIdleTimer()
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        guard current == nil, idleTimeout > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self] in self?.close() }
        timer.resume()
        idleTimer = timer
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                if buffer.count > IPCCodec.maxLineBytes, !buffer.contains(0x0A) {
                    reply(.failure("request_too_large", "A request line may not exceed \(IPCCodec.maxLineBytes) bytes."), id: nil)
                    close()
                    return
                }
            } else if count == 0 {
                // The client hung up: stop whatever it asked for.
                current?.cancel()
                close()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                if errno == EINTR { continue }
                current?.cancel()
                close()
                return
            }
        }
        extractLines()
        processNext()
    }

    private func extractLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D })
            if !trimmed.isEmpty { pending.append(Data(trimmed)) }
        }
    }

    private func processNext() {
        guard current == nil, !closed, !pending.isEmpty else { return }
        idleTimer?.cancel()
        let line = pending.removeFirst()
        let request: IPCRequest
        do {
            request = try IPCCodec.decodeRequest(line)
        } catch {
            // The wording is fixed English: the system's own parse message would follow the user's locale.
            reply(.failure("invalid_request", "The request is not a valid Jarvis request: send one JSON object per line, for example {\"command\": \"help\"}."), id: nil)
            processNext()
            return
        }
        let connectionID = id
        let handler = self.handler
        current = Task { [weak self] in
            let response = await handler.handle(request, connectionID: connectionID)
            guard let owner = self else { return }
            owner.queue.async {
                var final = response
                if final.id == nil { final.id = request.id }
                owner.reply(final, id: request.id)
                owner.current = nil
                owner.processNext()
                owner.armIdleTimer()
            }
        }
    }

    private func reply(_ response: IPCResponse, id: String?) {
        guard !closed else { return }
        var payload = response
        if payload.id == nil { payload.id = id }
        guard let data = try? IPCCodec.encode(payload) else { return }
        if !UnixSocket.writeAll(data, to: descriptor) { close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        current?.cancel()
        idleTimer?.cancel()
        source?.cancel()
        source = nil
        Darwin.close(descriptor)
        onClose(descriptor)
    }
}

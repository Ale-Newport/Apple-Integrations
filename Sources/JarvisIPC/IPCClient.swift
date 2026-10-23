import Darwin
import Foundation
import JarvisCore

/// Client side of the local control channel. Used by the `jarvisctl` tool and by tests; the broader Jarvis assistant
/// can embed it, or speak the same newline-delimited JSON from any language.
public struct IPCClient: Sendable {
    public let socketPath: String
    public var timeout: TimeInterval

    public init(socketPath: String = JarvisPaths.socketFile().path, timeout: TimeInterval = 120) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func send(_ request: IPCRequest) async throws -> IPCResponse {
        let path = socketPath
        let deadline = timeout
        let line = try IPCCodec.encode(request)
        let holder = DescriptorHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let descriptor = try UnixSocket.connect(to: path)
                        holder.set(descriptor)
                        defer { holder.closeIfOpen() }
                        guard UnixSocket.writeAll(line, to: descriptor) else { throw IPCError.connectionClosed }
                        let data = try Self.readLine(from: descriptor, deadline: deadline)
                        continuation.resume(returning: try IPCCodec.decodeResponse(data))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            holder.shutdown()
        }
    }

    private static func readLine(from descriptor: Int32, deadline: TimeInterval) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let end = Date().addingTimeInterval(deadline)
        while true {
            let remaining = end.timeIntervalSinceNow
            if remaining <= 0 { throw IPCError.timedOut }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(min(remaining, 1.0) * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                throw IPCError.connectionClosed
            }
            if ready == 0 { continue }
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw IPCError.connectionClosed
            }
            if count == 0 { throw IPCError.connectionClosed }
            buffer.append(contentsOf: chunk[0..<count])
            if let newline = buffer.firstIndex(of: 0x0A) { return Data(buffer[buffer.startIndex..<newline]) }
            if buffer.count > IPCCodec.maxLineBytes * 4 { throw IPCError.responseTooLarge }
        }
    }
}

private final class DescriptorHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false

    func set(_ value: Int32) {
        lock.lock(); defer { lock.unlock() }
        descriptor = value
        if cancelled { Darwin.shutdown(value, SHUT_RDWR) }
    }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR) }
    }

    func closeIfOpen() {
        lock.lock(); defer { lock.unlock() }
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
}

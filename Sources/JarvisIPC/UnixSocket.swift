import Darwin
import Foundation

public enum IPCError: Error, Equatable, Sendable {
    case pathTooLong(Int)
    case alreadyRunning
    case socketFailed(String)
    case notConnected(String)
    case timedOut
    case connectionClosed
    case responseTooLarge
    case invalidResponse
}

/// Thin, dependency-free wrappers over the BSD socket calls used for the local control channel.
enum UnixSocket {
    static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathBytes else { throw IPCError.pathTooLong(bytes.count) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IPCError.socketFailed(String(cString: strerror(errno))) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        // Never raise SIGPIPE when the peer vanished; write() just fails with EPIPE.
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    static func connect(to path: String) throws -> Int32 {
        var address = try address(for: path)
        let descriptor = try makeSocket()
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(descriptor)
            throw IPCError.notConnected(message)
        }
        return descriptor
    }

    /// Writes all of `data`, retrying on partial writes and EAGAIN.
    @discardableResult
    static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        var offset = 0
        let total = data.count
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < total {
                let written = Darwin.write(descriptor, base.advanced(by: offset), total - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    if poll(&pollDescriptor, 1, 5_000) <= 0 { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// The effective user id of the process on the other end.
    static func peerUserID(_ descriptor: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 ? uid : nil
    }
}

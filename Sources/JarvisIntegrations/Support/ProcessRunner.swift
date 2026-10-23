import Foundation
import JarvisCore

/// Output of a finished child process.
public struct ProcessOutput: Sendable, Equatable {
    public var status: Int32
    public var standardOutput: String
    public var standardError: String

    public init(status: Int32, standardOutput: String, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum ProcessRunnerError: Error, Sendable, Equatable {
    case launchFailed(String)
    case timedOut
    case outputTooLarge
}

/// Runs a fixed executable with an argument vector — never through a shell.
public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) async throws -> ProcessOutput
}

/// `Process`-based implementation with a hard timeout, cooperative cancellation and an output cap.
///
/// * No shell is involved: the arguments array goes straight to `execve`, so metacharacters in user text are inert.
/// * Cancelling the Swift task (or hitting the deadline) terminates the child (SIGTERM, then SIGKILL).
/// * stdout/stderr are drained concurrently so large outputs cannot deadlock the child.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int = 4 * 1024 * 1024) async throws -> ProcessOutput {
        let controller = ProcessController()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                controller.start(executable: executable, arguments: arguments, timeout: timeout, maxOutputBytes: maxOutputBytes) { result in
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            controller.cancel()
        }
    }
}

private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private(set) var overflowed = false

    /// Appends up to `limit` bytes. Returns `false` once the limit has been exceeded.
    func append(_ chunk: Data, limit: Int) -> Bool {
        lock.withLock {
            if data.count + chunk.count > limit {
                overflowed = true
                return false
            }
            data.append(chunk)
            return true
        }
    }

    var snapshot: Data { lock.withLock { data } }
}

private final class ProcessController: @unchecked Sendable {
    private enum Stop { case none, timeout, cancelled, overflow }

    private let lock = NSLock()
    private var process: Process?
    private var stop: Stop = .none
    private var finished = false
    private var cancelledBeforeStart = false

    private static let environment: [String: String] = {
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        let source = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = source[key] { env[key] = value }
        }
        return env
    }()

    func cancel() {
        let (process, alreadyStarted): (Process?, Bool) = lock.withLock {
            if self.process == nil { cancelledBeforeStart = true }
            return (self.process, self.process != nil)
        }
        if alreadyStarted { terminate(reason: .cancelled, process: process) }
    }

    func start(executable: String, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int, completion: @escaping @Sendable (Result<ProcessOutput, Error>) -> Void) {
        // Foundation raises an Objective-C exception for arguments containing NUL; make that impossible.
        let safeArguments = arguments.map { $0.replacingOccurrences(of: "\u{0000}", with: "") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = safeArguments
        process.environment = Self.environment
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let skipLaunch: Bool = lock.withLock {
            if cancelledBeforeStart { return true }
            self.process = process
            return false
        }
        if skipLaunch {
            completion(.failure(CancellationError()))
            return
        }

        let outBuffer = LockedBuffer()
        let errBuffer = LockedBuffer()
        let group = DispatchGroup()

        group.enter()
        process.terminationHandler = { _ in group.leave() }
        do {
            try process.run()
        } catch {
            group.leave()
            completion(.failure(ProcessRunnerError.launchFailed(error.localizedDescription)))
            return
        }

        for (handle, buffer) in [(outPipe.fileHandleForReading, outBuffer), (errPipe.fileHandleForReading, errBuffer)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if !buffer.append(chunk, limit: maxOutputBytes) {
                        self?.terminate(reason: .overflow, process: process)
                        break
                    }
                }
                group.leave()
            }
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(timeout, 0.1)) { [weak self] in
            guard let self else { return }
            let running = self.lock.withLock { !self.finished }
            if running { self.terminate(reason: .timeout, process: process) }
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            group.wait()
            let reason: Stop = lock.withLock {
                finished = true
                return stop
            }
            switch reason {
            case .timeout: completion(.failure(ProcessRunnerError.timedOut))
            case .cancelled: completion(.failure(CancellationError()))
            case .overflow: completion(.failure(ProcessRunnerError.outputTooLarge))
            case .none:
                completion(.success(ProcessOutput(
                    status: process.terminationStatus,
                    standardOutput: String(decoding: outBuffer.snapshot, as: UTF8.self),
                    standardError: String(decoding: errBuffer.snapshot, as: UTF8.self)
                )))
            }
        }
    }

    private func terminate(reason: Stop, process: Process?) {
        guard let process else { return }
        let shouldTerminate: Bool = lock.withLock {
            guard !finished, stop == .none else { return false }
            stop = reason
            return true
        }
        guard shouldTerminate else { return }
        if process.isRunning { process.terminate() }
        // A well-behaved child exits on SIGTERM; make sure a stuck one cannot linger.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

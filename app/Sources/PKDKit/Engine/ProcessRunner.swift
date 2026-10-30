import Foundation

public struct ProcessRequest: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var currentDirectory: URL?
    public var environment: [String: String]?

    public init(executable: URL,
                arguments: [String],
                currentDirectory: URL? = nil,
                environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.environment = environment
    }
}

public struct ProcessOutput: Sendable {
    public let exitCode: Int32
    public let terminatedBySignal: Bool
    public let stdoutLines: [String]
    public let stderrLines: [String]
    public let wasCancelled: Bool
    public let duration: TimeInterval

    public var stdout: String { stdoutLines.joined(separator: "\n") }
    public var stderr: String { stderrLines.joined(separator: "\n") }
}

public protocol ProcessRunning: AnyObject {
    func run(_ request: ProcessRequest,
             onStdoutLine: @escaping @Sendable (String) -> Void,
             onStderrLine: @escaping @Sendable (String) -> Void) async throws -> ProcessOutput
    func cancel(grace: TimeInterval) async
    /// 退出 App 时同步强杀，不等子进程优雅退出。
    func cancelImmediately()
}

/// 线程安全的行累积器。读循环在 IO 队列上跑，结果在主流程上取。
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer: [String] = []
    private var stderrBuffer: [String] = []

    func append(_ line: String, isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStdout {
            stdoutBuffer.append(line)
        } else {
            stderrBuffer.append(line)
        }
    }

    var stdout: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stdoutBuffer
    }

    var stderr: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stderrBuffer
    }
}

/// 用两个**并发阻塞读循环**消费子进程的 stdout/stderr。
///
/// 不使用 `FileHandle.readabilityHandler`：进程退出后 handler 可能不再触发，
/// 最后几行（含 `Done` 哨兵）会丢失，导致成败判定失效。
public final class RealProcessRunner: ProcessRunning, @unchecked Sendable {
    private let stateLock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public func run(_ request: ProcessRequest,
                    onStdoutLine: @escaping @Sendable (String) -> Void,
                    onStderrLine: @escaping @Sendable (String) -> Void) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.standardInput = FileHandle.nullDevice
        if let dir = request.currentDirectory {
            process.currentDirectoryURL = dir
        }
        if let env = request.environment {
            process.environment = env
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        stateLock.lock()
        self.process = process
        self.cancelled = false
        stateLock.unlock()

        let box = LineBox()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "pkd.repkg.io", qos: .userInitiated, attributes: .concurrent)

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            stateLock.lock()
            self.process = nil
            stateLock.unlock()
            throw error
        }

        // 必须在 run() 之后**立刻**并发起两个读循环，否则子进程写满 pipe 缓冲会死锁
        ioQueue.async(group: group) {
            Self.readLoop(outPipe.fileHandleForReading, isStdout: true, box: box, onLine: onStdoutLine)
        }
        ioQueue.async(group: group) {
            Self.readLoop(errPipe.fileHandleForReading, isStdout: false, box: box, onLine: onStderrLine)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }

        // 两个读循环都读到 EOF 并冲刷完残留行，才认为输出投递完毕
        group.wait()

        let duration = Date().timeIntervalSince(startedAt)

        stateLock.lock()
        let wasCancelled = cancelled
        self.process = nil
        stateLock.unlock()

        return ProcessOutput(
            exitCode: process.terminationStatus,
            terminatedBySignal: process.terminationReason == .uncaughtSignal,
            stdoutLines: box.stdout,
            stderrLines: box.stderr,
            wasCancelled: wasCancelled,
            duration: duration
        )
    }

    /// 三级取消：SIGINT（repkg 在条目边界响应）→ SIGTERM → SIGKILL。
    public func cancel(grace: TimeInterval) async {
        guard let process = takeProcessForCancel(), process.isRunning else { return }

        process.interrupt()
        if await Self.waitForExit(process, timeout: grace) { return }

        if process.isRunning { process.terminate() }
        if await Self.waitForExit(process, timeout: 3) { return }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// 同步读取并置位取消标志（`NSLock.unlock()` 不能出现在 async 上下文里）。
    private func takeProcessForCancel() -> Process? {
        stateLock.lock()
        let current = process
        cancelled = true
        stateLock.unlock()
        return current
    }

    public func cancelImmediately() {
        guard let process = takeProcessForCancel(), process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !process.isRunning
    }

    private static func readLoop(_ handle: FileHandle,
                                 isStdout: Bool,
                                 box: LineBox,
                                 onLine: @escaping @Sendable (String) -> Void) {
        var stream = LineStream()
        defer { try? handle.close() }

        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 65536)
            } catch {
                break
            }
            guard let data = chunk, !data.isEmpty else { break }

            for line in stream.consume(data) {
                box.append(line, isStdout: isStdout)
                onLine(line)
            }
        }

        for line in stream.finish() {
            box.append(line, isStdout: isStdout)
            onLine(line)
        }
    }
}

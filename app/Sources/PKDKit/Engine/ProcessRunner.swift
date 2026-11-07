import Foundation

public struct ProcessRequest: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var currentDirectory: URL?
    public var environment: [String: String]?
    /// Run the executable under a small parent-death supervisor. This prevents a
    /// SIGKILLed app from leaving the engine writing into its output directory:
    /// a monitor process owns the engine, notices when the app-side wrapper is
    /// gone, and terminates only that exact child. See `RealProcessRunner`.
    public var superviseParentDeath: Bool

    public init(executable: URL,
                arguments: [String],
                currentDirectory: URL? = nil,
                environment: [String: String]? = nil,
                superviseParentDeath: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.superviseParentDeath = superviseParentDeath
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
        if request.superviseParentDeath {
            let launch = Self.supervisedLaunch(for: request)
            process.executableURL = launch.executable
            process.arguments = launch.arguments
            process.environment = launch.environment
        } else {
            process.executableURL = request.executable
            process.arguments = request.arguments
            if let env = request.environment {
                process.environment = env
            }
        }
        process.standardInput = FileHandle.nullDevice
        if let dir = request.currentDirectory {
            process.currentDirectoryURL = dir
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        install(process)

        let box = LineBox()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "pkd.repkg.io", qos: .userInitiated, attributes: .concurrent)

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            clearProcess()
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
        Self.waitForReaders(group)

        let duration = Date().timeIntervalSince(startedAt)

        let wasCancelled = clearProcessAndReadCancellation()

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

    private func install(_ process: Process) {
        stateLock.lock()
        self.process = process
        cancelled = false
        stateLock.unlock()
    }

    private func clearProcess() {
        stateLock.lock()
        process = nil
        stateLock.unlock()
    }

    private func clearProcessAndReadCancellation() -> Bool {
        stateLock.lock()
        let wasCancelled = cancelled
        process = nil
        stateLock.unlock()
        return wasCancelled
    }

    private static func waitForReaders(_ group: DispatchGroup) {
        group.wait()
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

    /// Wrapper/monitor scripts. The app's `Process` is the wrapper (`/bin/sh`);
    /// the wrapper starts a monitor in a separate process, and the monitor is the
    /// direct parent of the real engine. If the app is SIGKILLed, the wrapper is
    /// killed too, the monitor is reparented to launchd, sees that its parent is
    /// gone, and terminates only its own engine child. The monitor also forwards
    /// SIGINT/SIGTERM for normal cancellation.
    private static let supervisorMonitorScript = #"""
wrapper="$1"; shift
app="$1"; shift
exe="$1"; shift
child=""
trap 'if [ -z "$child" ]; then /bin/sleep 0.1; fi; if [ -n "$child" ]; then /bin/kill -INT "$child" 2>/dev/null; /bin/sleep 0.1; /bin/kill -KILL "$child" 2>/dev/null; fi; exit 130' INT
trap 'if [ -z "$child" ]; then /bin/sleep 0.1; fi; if [ -n "$child" ]; then /bin/kill -TERM "$child" 2>/dev/null; /bin/sleep 0.2; /bin/kill -KILL "$child" 2>/dev/null; fi; exit 143' TERM
"$exe" "$@" &
child=$!
while :; do
  ppid=$(/bin/ps -o ppid= -p "$wrapper" 2>/dev/null | /usr/bin/tr -d ' ')
  if [ "$ppid" != "$app" ]; then
    /bin/kill -TERM "$child" 2>/dev/null
    /bin/sleep 0.2
    /bin/kill -KILL "$child" 2>/dev/null
    wait "$child" 2>/dev/null
    exit 143
  fi
  state=$(/bin/ps -o stat= -p "$child" 2>/dev/null | /usr/bin/tr -d ' ')
  if [ -z "$state" ] || [ "${state#Z}" != "$state" ]; then
    wait "$child"
    status=$?
    exit $status
  fi
  /bin/sleep 0.05
done
"""#

    private static let supervisorWrapperScript = #"""
monitor="$PKD_SUPERVISOR_MONITOR"
app="$PKD_SUPERVISOR_APP_PID"
unset PKD_SUPERVISOR_MONITOR
unset PKD_SUPERVISOR_APP_PID
wrapper=$$
exe="$1"; shift
/bin/sh -c "$monitor" pkd-monitor "$wrapper" "$app" "$exe" "$@" &
monitor_pid=$!
trap '/bin/kill -INT "$monitor_pid" 2>/dev/null' INT
trap '/bin/kill -TERM "$monitor_pid" 2>/dev/null' TERM
wait "$monitor_pid"
status=$?
exit $status
"""#

    private static func supervisedLaunch(for request: ProcessRequest) -> (executable: URL, arguments: [String], environment: [String: String]) {
        var environment = request.environment ?? ProcessInfo.processInfo.environment
        environment["PKD_SUPERVISOR_MONITOR"] = supervisorMonitorScript
        environment["PKD_SUPERVISOR_APP_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        let arguments = ["-c", supervisorWrapperScript, "pkd-supervisor", request.executable.path] + request.arguments
        return (URL(fileURLWithPath: "/bin/sh"), arguments, environment)
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

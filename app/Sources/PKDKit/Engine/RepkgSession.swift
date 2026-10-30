import Foundation

public enum InfoFailure: Error, Equatable {
    case inputNotFound
    case notAPackage
    case processFailed(String)

    public var message: String {
        switch self {
        case .inputNotFound: return "包文件不存在"
        case .notAPackage: return "无法解析包结构（可能不是有效的 pkg）"
        case .processFailed(let text): return "读取包信息失败：\(text)"
        }
    }
}

/// 逐行消费 repkg 输出，维护解析器与进度状态。
/// 读循环在 IO 队列上回调，因此内部状态必须加锁。
final class ExtractLinePump: @unchecked Sendable {
    struct Snapshot {
        var sawDone: Bool
        var sawTerminating: Bool
        var fatal: RepkgEvent.FatalSignal?
        var entriesStarted: Int
        var entriesSkipped: Int
        var warnings: [String]
        var progress: ExtractProgress
    }

    private let lock = NSLock()
    private var parser = RepkgOutputParser()
    private var tracker: ProgressTracker
    private var warnings: [String] = []
    private let onEvent: @Sendable (RepkgEvent) -> Void
    private let onProgress: @Sendable (ExtractProgress) -> Void

    init(expected: PkgInfo?,
         onEvent: @escaping @Sendable (RepkgEvent) -> Void,
         onProgress: @escaping @Sendable (ExtractProgress) -> Void) {
        self.tracker = ProgressTracker(expected: expected)
        self.onEvent = onEvent
        self.onProgress = onProgress
    }

    func begin() {
        lock.lock()
        tracker.beginExtracting()
        let progress = tracker.progress
        lock.unlock()
        onProgress(progress)
    }

    func consume(_ line: String) {
        lock.lock()
        guard let event = parser.feed(line) else {
            lock.unlock()
            return
        }
        switch event {
        case .textureWarning(let kind):
            warnings.append(kind == .read ? "纹理读取失败" : "纹理写入失败")
        case .projectJSONWarning(let message):
            warnings.append("project.json 读取失败：\(message)")
        case .unrecognizedExtension(let ext):
            warnings.append("无法识别的扩展名：\(ext)")
        default:
            break
        }
        let progress = tracker.handle(event)
        lock.unlock()

        onEvent(event)
        onProgress(progress)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            sawDone: parser.sawDone,
            sawTerminating: parser.sawTerminating,
            fatal: parser.fatal,
            entriesStarted: parser.entriesStarted,
            entriesSkipped: parser.entriesSkipped,
            warnings: warnings,
            progress: tracker.progress
        )
    }
}

/// 一次解包会话。每个任务持有独立实例，取消互不干扰。
public final class RepkgSession: @unchecked Sendable {
    public let executable: URL
    private let runner: ProcessRunning

    public init(executable: URL, runner: ProcessRunning = RealProcessRunner()) {
        self.executable = executable
        self.runner = runner
    }

    /// 探活：返回 `repkg 0.4.0+…` 这样的版本串。
    /// 注意 `repkg version` 的横幅是走 **stderr** 的（CommandLineParser 的行为），两路都要看。
    public func probeVersion() async -> String? {
        let request = ProcessRequest(executable: executable, arguments: ["version"])
        guard let output = try? await runner.run(request, onStdoutLine: { _ in }, onStderrLine: { _ in }) else {
            return nil
        }
        let combined = (output.stdoutLines + output.stderrLines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard combined.contains("repkg") else { return nil }
        return combined.split(separator: "\n").first.map(String.init)
    }

    public func info(for pkg: URL) async -> Result<PkgInfo, InfoFailure> {
        let request = ProcessRequest(executable: executable, arguments: ["info", pkg.path, "-e"])

        let output: ProcessOutput
        do {
            output = try await runner.run(request, onStdoutLine: { _ in }, onStderrLine: { _ in })
        } catch {
            return .failure(.processFailed(error.localizedDescription))
        }

        var parser = PkgInfoParser()
        for line in output.stdoutLines {
            parser.feed(line)
        }

        if let info = parser.result() {
            return .success(info)
        }
        if parser.fatal != nil || output.stdoutLines.contains("Input file not found") {
            return .failure(.inputNotFound)
        }
        let stderrTail = output.stderrLines.suffix(3).joined(separator: " ")
        return .failure(.processFailed(stderrTail.isEmpty ? "无有效输出" : stderrTail))
    }

    public func extract(_ request: ExtractRequest,
                        expected: PkgInfo?,
                        onEvent: @escaping @Sendable (RepkgEvent) -> Void = { _ in },
                        onProgress: @escaping @Sendable (ExtractProgress) -> Void = { _ in }) async -> ExtractReport {
        let pump = ExtractLinePump(expected: expected, onEvent: onEvent, onProgress: onProgress)
        pump.begin()

        // 工作目录必须真实存在，否则 Process 起不来；
        // repkg 自己会创建输出目录，所以这里只在已存在时设置 CWD。
        let existingDirectory = FileManager.default.fileExists(atPath: request.outputDirectory.path)
            ? request.outputDirectory
            : nil

        let processRequest = ProcessRequest(
            executable: executable,
            arguments: request.arguments(),
            currentDirectory: existingDirectory
        )

        let output: ProcessOutput
        do {
            output = try await runner.run(
                processRequest,
                onStdoutLine: { line in pump.consume(line) },
                onStderrLine: { _ in }
            )
        } catch {
            return ExtractReport(
                verdict: .failed(.crashed),
                entriesExtracted: 0,
                entriesSkipped: 0,
                warnings: ["无法启动 repkg：\(error.localizedDescription)"],
                missingEntries: [],
                stderrTail: [],
                exitCode: -1,
                duration: 0,
                outputFileCount: 0
            )
        }

        let state = pump.snapshot()
        let outputFileCount = Self.countFiles(in: request.outputDirectory)
        let missing = Self.missingEntries(expected: expected, in: request.outputDirectory, request: request)

        var facts = ExtractVerdict.Facts()
        facts.sawDone = state.sawDone
        facts.sawTerminating = state.sawTerminating
        facts.fatal = state.fatal
        facts.exitCode = output.exitCode
        facts.stderrLines = output.stderrLines
        facts.warningCount = state.warnings.count
        facts.outputFileCount = outputFileCount
        facts.wasCancelled = output.wasCancelled
        facts.missingEntries = missing
        facts.sawUnrecognizedExtension = output.stdoutLines.contains { $0.hasPrefix("Unrecognized file extension: ") }

        return ExtractReport(
            verdict: ExtractVerdict.decide(facts),
            entriesExtracted: state.entriesStarted,
            entriesSkipped: state.entriesSkipped,
            warnings: state.warnings,
            missingEntries: missing,
            stderrTail: Array(output.stderrLines.suffix(20)),
            exitCode: output.exitCode,
            duration: output.duration,
            outputFileCount: outputFileCount
        )
    }

    public func cancel(grace: TimeInterval = 5) async {
        await runner.cancel(grace: grace)
    }

    /// 退出 App 时调用：同步 SIGKILL，避免残留进程继续写盘。
    public func cancelImmediately() {
        runner.cancelImmediately()
    }

    // MARK: - Helpers

    private static func countFiles(in directory: URL) -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true {
                count += 1
                if count > 50000 { break }
            }
        }
        return count
    }

    private static func missingEntries(expected: PkgInfo?, in directory: URL, request: ExtractRequest) -> [String] {
        guard let expected, !expected.entries.isEmpty else { return [] }
        guard !request.flatten else { return [] }

        var missing: [String] = []
        for entry in expected.entries {
            if let filters = request.onlyExtensions, !filters.isEmpty {
                let matches = filters.contains { entry.path.lowercased().hasSuffix(".\($0.lowercased())") }
                if !matches { continue }
            }
            let path = directory.appendingPathComponent(entry.path).path
            if !FileManager.default.fileExists(atPath: path) {
                missing.append(entry.path)
            }
        }
        return missing
    }
}

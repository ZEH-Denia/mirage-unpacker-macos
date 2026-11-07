import Foundation

public struct ExtractRequest: Sendable {
    public var input: URL
    public var outputDirectory: URL
    public var overwrite: Bool
    public var convertTextures: Bool
    public var copyProjectFiles: Bool
    public var flatten: Bool
    public var onlyExtensions: [String]?

    public init(input: URL,
                outputDirectory: URL,
                overwrite: Bool = false,
                convertTextures: Bool = true,
                copyProjectFiles: Bool = true,
                flatten: Bool = false,
                onlyExtensions: [String]? = nil) {
        self.input = input
        self.outputDirectory = outputDirectory
        self.overwrite = overwrite
        self.convertTextures = convertTextures
        self.copyProjectFiles = copyProjectFiles
        self.flatten = flatten
        self.onlyExtensions = onlyExtensions
    }

    /// 参数数组直传，中文与空格路径天然安全（禁止拼 shell 字符串）。
    public func arguments() -> [String] {
        var args = ["extract", input.path, "-o", outputDirectory.path]
        if copyProjectFiles { args.append("-c") }
        if overwrite { args.append("--overwrite") }
        if !convertTextures { args.append("--no-tex-convert") }
        if flatten { args.append("-s") }
        if let exts = onlyExtensions, !exts.isEmpty {
            args.append("-e")
            args.append(exts.joined(separator: ","))
        }
        return args
    }
}

public struct ExtractProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Codable {
        case idle
        case inspecting
        case extracting
        case converting
        case finishing
    }

    public var phase: Phase = .idle
    public var entriesDone: Int = 0
    public var entriesTotal: Int?
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64?
    public var currentEntry: String?

    public init() {}

    public var fraction: Double? {
        if let total = bytesTotal, total > 0 {
            return min(1, max(0, Double(bytesDone) / Double(total)))
        }
        if let total = entriesTotal, total > 0 {
            return min(1, max(0, Double(entriesDone) / Double(total)))
        }
        return nil
    }

    public var phaseText: String {
        switch phase {
        case .idle: return "等待中"
        case .inspecting: return "读取包结构"
        case .extracting: return "解包中"
        case .converting: return "转换纹理"
        case .finishing: return "收尾"
        }
    }
}

public struct ExtractReport: Sendable {
    public enum Verdict: Sendable, Equatable {
        case success
        case partialSuccess
        case failed(Failure)
        case cancelled

        public var isSuccess: Bool {
            switch self {
            case .success, .partialSuccess: return true
            case .failed, .cancelled: return false
            }
        }
    }

    public enum Failure: Sendable, Equatable {
        case inputNotFound
        case invalidArguments
        case crashed
        case missingDoneSentinel
        case emptyOutput
        case unrecognizedInput
        case unsafePackageEntryPath

        public var message: String {
            switch self {
            case .inputNotFound: return "输入文件不存在"
            case .invalidArguments: return "命令行参数错误（内部错误）"
            case .crashed: return "repkg 异常退出（包可能已损坏）"
            case .missingDoneSentinel: return "解包未正常结束（未收到完成标记）"
            case .emptyOutput: return "未产出任何文件"
            case .unrecognizedInput: return "无法识别的输入文件类型"
            case .unsafePackageEntryPath: return "包内路径越界，已阻止写入"
            }
        }
    }

    public let verdict: Verdict
    public let entriesExtracted: Int
    public let entriesSkipped: Int
    public let warnings: [String]
    public let missingEntries: [String]
    public let stderrTail: [String]
    public let exitCode: Int32
    public let duration: TimeInterval
    public let outputFileCount: Int

    public init(verdict: Verdict,
                entriesExtracted: Int,
                entriesSkipped: Int,
                warnings: [String],
                missingEntries: [String],
                stderrTail: [String],
                exitCode: Int32,
                duration: TimeInterval,
                outputFileCount: Int) {
        self.verdict = verdict
        self.entriesExtracted = entriesExtracted
        self.entriesSkipped = entriesSkipped
        self.warnings = warnings
        self.missingEntries = missingEntries
        self.stderrTail = stderrTail
        self.exitCode = exitCode
        self.duration = duration
        self.outputFileCount = outputFileCount
    }

    /// 面向用户/UI 的失败文案：非 0 退出必须带退出码和可分类原因，
    /// 不把所有非 0 退出都笼统说成“包已损坏”。
    public var failureMessage: String {
        guard case .failed(let failure) = verdict else { return "" }
        switch failure {
        case .crashed:
            return Self.crashedMessage(exitCode: exitCode, stderrTail: stderrTail)
        default:
            return failure.message
        }
    }

    private static func crashedMessage(exitCode: Int32, stderrTail: [String]) -> String {
        let text = stderrTail.joined(separator: "\n").lowercased()
        if exitCode < 0 {
            return "无法启动 repkg（引擎未运行）"
        }
        let code = "（退出码 \(exitCode)）"
        if exitCode == 126 || exitCode == 127
            || (text.contains("no such file or directory") && text.contains("repkg")) {
            return "无法启动 repkg\(code)"
        }
        if text.contains("permission denied") || text.contains("operation not permitted")
            || text.contains("read-only file system") {
            return "权限不足或输出位置只读\(code)；请检查输出目录权限"
        }
        if text.contains("no space left on device") || text.contains("disk full")
            || text.contains("not enough space") {
            return "磁盘空间不足\(code)"
        }
        if text.contains("bad cpu type") || text.contains("not supported")
            || text.contains("library not loaded") || text.contains("dyld") {
            return "repkg 运行环境不兼容\(code)"
        }
        if exitCode == 137 {
            return "repkg 被强制终止\(code)"
        }
        if exitCode == 143 {
            return "repkg 被系统终止\(code)"
        }
        if exitCode == 134 || exitCode == 139 || exitCode == 133 {
            return "repkg 异常终止\(code)，可能由损坏输入或引擎缺陷引起"
        }
        let firstLine = stderrTail.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        if let firstLine {
            return "repkg 异常退出\(code)：\(firstLine.prefix(160))"
        }
        return "repkg 异常退出\(code)；stderr 未给出可分类原因"
    }
}

/// 成败判定表。**这是本项目最核心的正确性逻辑**：
/// repkg 的退出码恒为 0，只能靠输出哨兵判定。
public enum ExtractVerdict {
    public struct Facts: Sendable {
        public var sawDone: Bool = false
        public var sawTerminating: Bool = false
        public var fatal: RepkgEvent.FatalSignal?
        public var exitCode: Int32 = 0
        public var stderrLines: [String] = []
        public var warningCount: Int = 0
        public var outputFileCount: Int = 0
        public var wasCancelled: Bool = false
        public var missingEntries: [String] = []
        public var sawUnrecognizedExtension: Bool = false

        public init() {}
    }

    public static func decide(_ facts: Facts) -> ExtractReport.Verdict {
        // 1. 取消优先于一切（即便已产出部分文件、即便 exitCode == 0）
        if facts.wasCancelled || facts.sawTerminating {
            return .cancelled
        }

        let stderrText = facts.stderrLines.joined(separator: "\n")

        // 2. 参数拼错属于程序 bug，必须暴露
        if stderrText.contains("ERROR(S):") {
            return .failed(.invalidArguments)
        }

        // 3. 非 0 退出码是唯一可信任的 exit code 语义：崩溃
        if facts.exitCode != 0 || stderrText.contains("Unhandled exception") {
            return .failed(.crashed)
        }

        // 4. 输入不存在
        if facts.fatal != nil {
            if facts.fatal == .unsafePackageEntryPath {
                return .failed(.unsafePackageEntryPath)
            }
            return .failed(.inputNotFound)
        }

        // 5. 没有 Done 哨兵 = 没跑完（exit 0 下最主要的失败识别手段）
        if !facts.sawDone {
            return .failed(.missingDoneSentinel)
        }

        // 6. 跑完了但一个文件都没有
        if facts.outputFileCount == 0 {
            return facts.sawUnrecognizedExtension ? .failed(.unrecognizedInput) : .failed(.emptyOutput)
        }

        // 7. 有警告或条目缺失 → 部分成功
        if facts.warningCount > 0 || !facts.missingEntries.isEmpty {
            return .partialSuccess
        }

        return .success
    }
}

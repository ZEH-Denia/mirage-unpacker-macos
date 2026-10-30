import Foundation

/// 把 repkg 的一行输出映射成语义事件。
///
/// 匹配顺序严格按规则表：先精确匹配哨兵，再匹配前缀，
/// `* Failed to read project.json:` 必须排在其它 `* ` 前缀之前。
public struct RepkgOutputParser {
    public private(set) var sawDone = false
    public private(set) var sawTerminating = false
    public private(set) var fatal: RepkgEvent.FatalSignal?
    public private(set) var warningCount = 0
    public private(set) var entriesStarted = 0
    public private(set) var entriesSkipped = 0
    public private(set) var packagesStarted = 0

    private var expectPathAfterFatal = false
    private var stackTraceLines = 0

    public init() {}

    /// 喂一行，返回识别出的事件（空行返回 nil）。
    public mutating func feed(_ line: String) -> RepkgEvent? {
        if line.isEmpty {
            stackTraceLines = 0
            return nil
        }

        // 紧跟 "Input file not found" 的下一行是路径，不产生新事件
        if expectPathAfterFatal {
            expectPathAfterFatal = false
            return .continuation(line)
        }

        if let event = match(line) {
            stackTraceLines = 0
            return event
        }

        // 已知前缀都没命中：若正在异常堆栈里，视为堆栈续行
        if stackTraceLines > 0 && stackTraceLines < 40 {
            stackTraceLines += 1
            return .continuation(line)
        }

        return .unparsed(line)
    }

    private mutating func match(_ line: String) -> RepkgEvent? {
        // 1. 精确哨兵（必须 ==，不能 contains）
        switch line {
        case "Done":
            sawDone = true
            return .done

        case "Terminating...":
            sawTerminating = true
            return .terminating

        case "Input file not found":
            fatal = .inputNotFound
            expectPathAfterFatal = true
            return .fatal(.inputNotFound)

        case "Input file/directory doesn't exist!":
            fatal = .inputPathDoesNotExist
            return .fatal(.inputPathDoesNotExist)

        case "Failed to read texture":
            warningCount += 1
            stackTraceLines = 1
            return .textureWarning(.read)

        case "Failed to write texture":
            warningCount += 1
            stackTraceLines = 1
            return .textureWarning(.write)

        default:
            break
        }

        // 2. 前缀匹配（长前缀在前）
        if let value = Self.value(line, prefix: "* Failed to read project.json: ") {
            warningCount += 1
            return .projectJSONWarning(message: value)
        }
        if let value = Self.value(line, prefix: "### Extracting package: ") {
            packagesStarted += 1
            return .packageStarted(path: value)
        }
        if let value = Self.value(line, prefix: "### Package info: ") {
            packagesStarted += 1
            return .packageStarted(path: value)
        }
        if let value = Self.value(line, prefix: "* Skipping, already exists: ") {
            entriesSkipped += 1
            return .entrySkipped(path: value)
        }
        if let value = Self.value(line, prefix: "* Extracting: ") {
            entriesStarted += 1
            return .entryExtracting(path: value)
        }
        if let value = Self.value(line, prefix: "* Copying: ") {
            return .fileCopied(path: value)
        }
        if let value = Self.value(line, prefix: "* Reading: ") {
            return .textureReading(name: value)
        }
        if let value = Self.value(line, prefix: "Unrecognized file extension: ") {
            warningCount += 1
            return .unrecognizedExtension(ext: value)
        }

        if line == "Package entries:" || line == "Package info:" {
            return .unparsed(line)
        }

        return nil
    }

    private static func value(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }
}

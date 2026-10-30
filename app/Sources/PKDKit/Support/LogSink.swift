import Foundation

/// 日志汇聚：IO 队列写入，UI 以 10Hz 批量取走。
/// 刻意**不**放进 `@Observable` 数组——万行输出会打满主线程。
public final class LogSink: @unchecked Sendable {
    public enum Kind: Sendable {
        case stdout
        case stderr
        case warning
        case marker
    }

    public struct Line: Sendable {
        public let jobID: UUID?
        public let text: String
        public let kind: Kind
    }

    private let lock = NSLock()
    private var pending: [Line] = []
    private var pendingFileText: [UUID: String] = [:]
    private var handles: [UUID: FileHandle] = [:]
    private let logDirectory: URL

    public init(logDirectory: URL? = nil) {
        let base = logDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PKD", isDirectory: true)
        self.logDirectory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public func append(jobID: UUID?, text: String, kind: Kind = .stdout) {
        let line = Line(jobID: jobID, text: text, kind: kind)

        var overflowChunks: [UUID: String] = [:]
        lock.lock()
        pending.append(line)
        if let jobID {
            let chunk = pendingFileText[jobID, default: ""] + text + "\n"
            if chunk.utf8.count > 16 * 1024 {
                overflowChunks[jobID] = chunk
                pendingFileText[jobID] = ""
            } else {
                pendingFileText[jobID] = chunk
            }
        }
        let shouldFlush = pending.count > 4000
        lock.unlock()

        for (id, chunk) in overflowChunks {
            write(chunk, jobID: id)
        }
        if shouldFlush {
            _ = drain()
        }
    }

    /// 把积压的完整日志立即落盘（不消耗显示队列）。
    public func flushFiles() {
        lock.lock()
        let fileChunks = pendingFileText
        pendingFileText.removeAll(keepingCapacity: true)
        lock.unlock()

        for (jobID, chunk) in fileChunks {
            write(chunk, jobID: jobID)
        }
    }

    /// 取走待显示的日志行，同时把积压的完整日志落盘。
    public func drain() -> [Line] {
        lock.lock()
        let lines = pending
        pending.removeAll(keepingCapacity: true)
        let fileChunks = pendingFileText
        pendingFileText.removeAll(keepingCapacity: true)
        lock.unlock()

        for (jobID, chunk) in fileChunks {
            write(chunk, jobID: jobID)
        }

        return lines
    }
    public func logFileURL(for jobID: UUID) -> URL {
        logDirectory.appendingPathComponent("\(jobID.uuidString).log")
    }

    public func close(jobID: UUID) {
        lock.lock()
        let handle = handles.removeValue(forKey: jobID)
        lock.unlock()
        try? handle?.close()
    }

    private func write(_ text: String, jobID: UUID) {
        lock.lock()
        let handle: FileHandle
        if let existing = handles[jobID] {
            handle = existing
        } else {
            let url = logDirectory.appendingPathComponent("\(jobID.uuidString).log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = (try? FileHandle(forWritingTo: url)) ?? FileHandle.nullDevice
            handles[jobID] = handle
        }
        lock.unlock()

        if let data = text.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}

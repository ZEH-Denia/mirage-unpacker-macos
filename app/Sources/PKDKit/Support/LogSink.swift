import Foundation

/// 日志汇聚：IO 队列写入，UI 以 10Hz 批量取走。
/// 刻意**不**放进 `@Observable` 数组——万行输出会打满主线程。
///
/// 生命周期约定（2026-11-07 修复）：
/// - 每个 job 的显示行与文件行在锁内按调用顺序入队，文件写入在单一串行 IO 队列上
///   执行，因此同一 job 的日志不会因并发调用而乱序、丢失或重复。
/// - `close(jobID:)` 先把该 job 尚未落盘的尾块（包括 <16 KiB 的小缓冲）刷入队列，
///   再关闭文件句柄，并等待本 job 之前入队的写入完成；返回后立即读文件即可看到全部尾行。
/// - 文件只以“追加”方式打开：绝不 `createFile(contents:nil)` 截断已有内容。因此
///   close 之后的 `drain()`/`flushFiles()`、甚至晚到的 append，都不会覆盖旧日志。
/// - 重复 `close` 是幂等的；close 之后的 append 会重新以追加模式打开同一文件，
///   不会丢弃旧内容。
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
    private let ioQueue = DispatchQueue(label: "com.zeh.pkd.logsink.file-io", qos: .utility)

    private var pending: [Line] = []
    private var pendingFileText: [UUID: String] = [:]

    /// 只在 `ioQueue` 上访问；锁不保护它。
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

        lock.lock()
        pending.append(line)
        if let jobID {
            let chunk = pendingFileText[jobID, default: ""] + text + "\n"
            if chunk.utf8.count > 16 * 1024 {
                // 在锁内入队，保证与其它 append/drain/close 的文件顺序一致。
                pendingFileText[jobID] = ""
                enqueueWriteLocked(chunk, jobID: jobID)
            } else {
                pendingFileText[jobID] = chunk
            }
        }
        let shouldFlush = pending.count > 4000
        lock.unlock()

        if shouldFlush {
            _ = drain()
        }
    }

    /// 把积压的完整日志立即落盘（不消耗显示队列）。返回前会等待已入队的写入完成。
    public func flushFiles() {
        lock.lock()
        let fileChunks = pendingFileText
        pendingFileText.removeAll(keepingCapacity: true)
        for (jobID, chunk) in fileChunks {
            enqueueWriteLocked(chunk, jobID: jobID)
        }
        lock.unlock()

        ioQueue.sync {}
    }

    /// 取走待显示的日志行，同时把积压的完整日志按序入队。
    ///
    /// 不等待磁盘写入完成（10Hz UI 路径）；需要“调用返回即已写出”的调用方
    /// 请使用 `flushFiles()` 或 `close(jobID:)`。
    public func drain() -> [Line] {
        lock.lock()
        let lines = pending
        pending.removeAll(keepingCapacity: true)
        let fileChunks = pendingFileText
        pendingFileText.removeAll(keepingCapacity: true)
        for (jobID, chunk) in fileChunks {
            enqueueWriteLocked(chunk, jobID: jobID)
        }
        lock.unlock()

        return lines
    }

    public func logFileURL(for jobID: UUID) -> URL {
        logDirectory.appendingPathComponent("\(jobID.uuidString).log")
    }

    /// 冲刷该 job 的尾部缓冲、关闭句柄，并等待该 job 已入队的写入完成。
    /// 返回后文件包含 close 之前 append 的全部内容，可被立即读取或再次 append。
    public func close(jobID: UUID) {
        lock.lock()
        let tail = pendingFileText.removeValue(forKey: jobID)
        if let tail, !tail.isEmpty {
            enqueueWriteLocked(tail, jobID: jobID)
        }
        ioQueue.async { [weak self] in
            self?.closeHandleLocked(jobID)
        }
        lock.unlock()

        ioQueue.sync {}
    }

    // MARK: - IO 队列内部

    /// 必须在 `lock` 内调用；只投递，不阻塞调用线程。
    private func enqueueWriteLocked(_ text: String, jobID: UUID) {
        guard !text.isEmpty else { return }
        ioQueue.async { [weak self] in
            self?.writeNow(text, jobID: jobID)
        }
    }

    /// 只在 IO 队列上执行。
    private func writeNow(_ text: String, jobID: UUID) {
        let url = logFileURL(for: jobID)
        let handle: FileHandle
        if let existing = handles[jobID] {
            handle = existing
        } else {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let opened = try? FileHandle(forWritingTo: url) else { return }
            // 追加而不是从头写：晚到的日志绝不能截断之前已写出的内容。
            _ = try? opened.seekToEnd()
            handles[jobID] = opened
            handle = opened
        }

        if let data = text.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    /// 只在 IO 队列上执行。
    private func closeHandleLocked(_ jobID: UUID) {
        guard let handle = handles.removeValue(forKey: jobID) else { return }
        try? handle.synchronize()
        try? handle.close()
    }
}

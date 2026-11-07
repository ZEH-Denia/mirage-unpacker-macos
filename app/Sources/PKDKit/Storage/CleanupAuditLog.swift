import Foundation

/// 清理操作专用审计日志。
///
/// 设计目标：
/// - 只记录**清理相关的目录路径、分类、大小、结果**；不记录任何图片/文件内容，不上传，不进入 Git。
/// - 明确区分「取消」「确认」「逐项结果」「完成」，以便将来定位「谁在什么时候把哪个目录移到了哪里」。
/// - 权限 0600，目录 0700；超过 4 MB 轮转一次（保留 `.1`），不做无界增长。
///
/// 默认位置：`~/Library/Application Support/PKD/CleanupAudit/cleanup-audit.jsonl`。
/// 开发副本使用隔离根目录下的同名子路径，避免测试写进真实用户目录。
public final class CleanupAuditLog: @unchecked Sendable {
    public enum Event: String, Codable, Sendable {
        case request        // 生成清理计划（用户点了「移到废纸篓」并看到确认界面）
        case cancelled      // 用户在确认界面取消 / 关闭
        case confirmed      // 用户确认执行
        case itemResult = "item_result"  // 单个目录的执行结果
        case completed      // 本次计划执行完毕（含部分失败）
    }

    public struct Item: Codable, Sendable, Equatable {
        public var path: String
        public var kind: String
        public var ownership: String
        public var sizeBytes: Int64
        public var device: UInt64?
        public var inode: UInt64?
        /// trashed / failed / skipped
        public var result: String?
        public var error: String?

        public init(path: String,
                    kind: String,
                    ownership: String,
                    sizeBytes: Int64,
                    device: UInt64? = nil,
                    inode: UInt64? = nil,
                    result: String? = nil,
                    error: String? = nil) {
            self.path = path
            self.kind = kind
            self.ownership = ownership
            self.sizeBytes = sizeBytes
            self.device = device
            self.inode = inode
            self.result = result
            self.error = error
        }
    }

    public struct Entry: Codable, Sendable {
        public var timestamp: String
        public var event: String
        public var planID: String?
        public var appVersion: String
        public var pid: Int32
        public var roots: [String: String]?
        public var itemCount: Int?
        public var totalBytes: Int64?
        public var items: [Item]?
        public var note: String?
    }

    /// 单文件上限；超过后轮转到 `.1`。
    public static let maxBytes = 4 * 1024 * 1024

    public let fileURL: URL
    public let appVersion: String
    private let lock = NSLock()

    public init(fileURL: URL, appVersion: String = CleanupAuditLog.currentAppVersion()) {
        self.fileURL = fileURL
        self.appVersion = appVersion
    }

    /// 默认路径；传入 `baseDirectory` 可覆盖（开发副本 / 测试使用隔离目录）。
    public static func defaultURL(baseDirectory: URL? = nil) -> URL {
        let base = baseDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PKD", isDirectory: true)
        return base.appendingPathComponent("CleanupAudit", isDirectory: true)
            .appendingPathComponent("cleanup-audit.jsonl")
    }

    public static func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// 追加一条记录。失败时静默（审计日志绝不能影响清理流程本身），但会保留内存中的错误计数供测试读取。
    @discardableResult
    public func record(_ event: Event,
                       planID: UUID?,
                       items: [Item] = [],
                       roots: [String: String] = [:],
                       note: String? = nil) -> Bool {
        let entry = Entry(
            timestamp: Self.timestampFormatter().string(from: Date()),
            event: event.rawValue,
            planID: planID?.uuidString,
            appVersion: appVersion,
            pid: ProcessInfo.processInfo.processIdentifier,
            roots: roots.isEmpty ? nil : roots,
            itemCount: items.isEmpty ? nil : items.count,
            totalBytes: items.isEmpty ? nil : items.reduce(Int64(0)) { $0 + $1.sizeBytes },
            items: items.isEmpty ? nil : items,
            note: note
        )
        return append(entry)
    }

    @discardableResult
    public func append(_ entry: Entry) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber,
               size.intValue > Self.maxBytes {
                rotateLocked()
            }
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path,
                                                     contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    return false
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var line = try encoder.encode(entry)
            line.append(0x0A)
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            // 尽量在返回前把尾部刷到磁盘：日志是同步追加 + 关闭，不依赖异步缓冲。
            try? handle.synchronize()
            return true
        } catch {
            return false
        }
    }

    public func readAllEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }

    private func rotateLocked() {
        let backup = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

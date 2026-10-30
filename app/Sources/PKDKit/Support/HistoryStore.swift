import Foundation
import Combine

public struct HistoryEntry: Codable, Sendable, Equatable {
    public var outputPath: String
    public var date: Date
    public var verdict: String
    public var fileCount: Int
    /// X-Ray 正常层图片文件名（解包时自动识别）
    public var xrayCleanFile: String?
    /// X-Ray 层图片文件名
    public var xrayLayerFile: String?
}

/// 已解包索引：列表上的「已解包」标记与快捷入口。
@MainActor
public final class HistoryStore: ObservableObject {
    @Published public private(set) var entries: [String: HistoryEntry] = [:]

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    public init(fileURL: URL? = nil) {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PKD", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? base.appendingPathComponent("history.json")
        load()
    }

    /// 纯字典查询（无 IO），用于列表过滤的高频路径。
    public func entry(for id: String) -> HistoryEntry? {
        entries[id]
    }

    /// 带磁盘校验的查询（目录被删则清除标记）。
    public func validatedEntry(for id: String) -> HistoryEntry? {
        guard let entry = entries[id] else { return nil }
        if !FileManager.default.fileExists(atPath: entry.outputPath) {
            entries.removeValue(forKey: id)
            scheduleSave()
            return nil
        }
        return entry
    }

    public func record(id: String,
                       outputPath: URL,
                       verdict: String,
                       fileCount: Int,
                       xrayCleanFile: String? = nil,
                       xrayLayerFile: String? = nil) {
        entries[id] = HistoryEntry(
            outputPath: outputPath.path,
            date: Date(),
            verdict: verdict,
            fileCount: fileCount,
            xrayCleanFile: xrayCleanFile,
            xrayLayerFile: xrayLayerFile
        )
        scheduleSave()
    }

    public func remove(id: String) {
        entries.removeValue(forKey: id)
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([String: HistoryEntry].self, from: data)) ?? [:]
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    private func saveNow() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

import Foundation

/// 清理确认界面的**纯数据**组装（可离屏单元测试，不依赖 SwiftUI/窗口）。
///
/// 目的：把「确认时到底展示什么」从 View 里拆出来，保证以下不变量可以被静态/后台测试覆盖：
/// - 必须展示每个将被移动目录的完整路径、数量与总大小；
/// - 只读（unknown）条目永远不出现在清单里；
/// - 被跳过的条目要单独列出原因；
/// - 全选/选中集合只包含可清理条目。
public struct StorageCleanupSummary: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        public var path: String
        public var meta: String
        public var sizeBytes: Int64

        public init(id: String, path: String, meta: String, sizeBytes: Int64) {
            self.id = id
            self.path = path
            self.meta = meta
            self.sizeBytes = sizeBytes
        }
    }

    public var itemCount: Int
    public var totalBytes: Int64
    public var totalFiles: Int
    /// 例如「将把 2 个目录移到废纸篓，共 12 KB（5 个文件）。」
    public var headline: String
    /// 固定安全说明。
    public var safetyNote: String
    public var rows: [Row]
    public var rejectedCount: Int
    public var rejectedRows: [Row]

    public init(itemCount: Int,
                totalBytes: Int64,
                totalFiles: Int,
                headline: String,
                safetyNote: String,
                rows: [Row],
                rejectedCount: Int,
                rejectedRows: [Row]) {
        self.itemCount = itemCount
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        self.headline = headline
        self.safetyNote = safetyNote
        self.rows = rows
        self.rejectedCount = rejectedCount
        self.rejectedRows = rejectedRows
    }

    public static let note = "文件会进入访达「废纸篓」，可手动恢复；本操作不会直接抹除数据。"

    /// 确认面板文案与清单。`plan.items` 已经是通过归属/边界/快照校验的条目。
    public static func make(plan: CleanupPlan) -> StorageCleanupSummary {
        let rows = plan.items.map { item in
            Row(id: item.id,
                path: item.url.path,
                meta: "\(item.kind.sectionTitle) · \(item.ownership.label) · \(item.sizeText) · \(item.fileCount) 个文件",
                sizeBytes: item.sizeBytes)
        }
        let rejectedRows = plan.rejections.map { rejection in
            Row(id: rejection.path, path: rejection.path, meta: rejection.reason, sizeBytes: 0)
        }
        let sizeText = ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)
        let headline = "将把 \(plan.items.count) 个目录移到废纸篓，共 \(sizeText)（\(plan.totalFiles) 个文件）。"
        return StorageCleanupSummary(itemCount: plan.items.count,
                                     totalBytes: plan.totalBytes,
                                     totalFiles: plan.totalFiles,
                                     headline: headline,
                                     safetyNote: note,
                                     rows: rows,
                                     rejectedCount: plan.rejections.count,
                                     rejectedRows: rejectedRows)
    }

    /// 只保留「可清理」条目的选中集合。用于 List 选择绑定与「全选」。
    public static func trashableSelection(_ selection: Set<String>,
                                          items: [StorageItem]) -> Set<String> {
        let trashable = Set(items.filter(\.isTrashable).map(\.id))
        return selection.intersection(trashable)
    }

    /// 是否所有可清理条目都已选中（只读条目不计入）。
    public static func allTrashableSelected(_ selection: Set<String>,
                                            items: [StorageItem]) -> Bool {
        let trashable = Set(items.filter(\.isTrashable).map(\.id))
        return !trashable.isEmpty && trashable.isSubset(of: selection)
    }

    /// 页头摘要：共 N 项 · 总大小 · 可清理 M 项（K 项只读）· 已选 S 项（大小）。
    public static func headerLine(items: [StorageItem],
                                  selection: Set<String>) -> String {
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        var line = "共 \(items.count) 项 · \(total)"
        let trashable = items.filter(\.isTrashable)
        if trashable.count != items.count {
            line += " · 可清理 \(trashable.count) 项，\(items.count - trashable.count) 项只读"
        }
        let selectedIDs = trashableSelection(selection, items: items)
        if !selectedIDs.isEmpty {
            let selectedBytes = items
                .filter { selectedIDs.contains($0.id) }
                .reduce(Int64(0)) { $0 + $1.sizeBytes }
            let selected = ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)
            line += " · 已选 \(selectedIDs.count) 项（\(selected)）"
        }
        return line
    }
}

import Foundation

/// 一处可清理的存储占用。
public struct StorageItem: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case extracted   // 完整解包产物
        case images      // 导出的图片
        case temporary   // 残留的临时解包目录

        public var label: String {
            switch self {
            case .extracted: return "完整解包产物"
            case .images: return "导出图片"
            case .temporary: return "临时文件"
            }
        }

        public var sectionTitle: String {
            switch self {
            case .extracted: return "完整解包产物"
            case .images: return "导出图片"
            case .temporary: return "残留临时文件"
            }
        }
    }

    public let id: String        // 绝对路径
    public let url: URL
    public let kind: Kind
    public let displayName: String
    public let sizeBytes: Int64
    public let fileCount: Int
    public let modified: Date?

    public init(url: URL,
                kind: Kind,
                displayName: String,
                sizeBytes: Int64,
                fileCount: Int,
                modified: Date?) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.kind = kind
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.modified = modified
    }

    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public enum StorageScanner {
    public static let tempPrefix = "PKD-extract-"

    /// 扫描两个根目录下的子文件夹 + 残留临时目录。
    /// 只取**一层**子目录，避免把用户自己放进来的深层结构误当成可删项。
    public static func scan(extractRoot: URL,
                            imageRoot: URL,
                            includeTemporary: Bool = true,
                            fileManager: FileManager = .default) -> [StorageItem] {
        var items: [StorageItem] = []

        if let children = subdirectories(of: extractRoot, fileManager: fileManager) {
            for url in children {
                items.append(makeItem(url: url, kind: .extracted, fileManager: fileManager))
            }
        }

        if let children = subdirectories(of: imageRoot, fileManager: fileManager) {
            for url in children {
                items.append(makeItem(url: url, kind: .images, fileManager: fileManager))
            }
        }

        if includeTemporary {
            let temp = fileManager.temporaryDirectory
            if let children = subdirectories(of: temp, fileManager: fileManager) {
                for url in children where url.lastPathComponent.hasPrefix(tempPrefix) {
                    items.append(makeItem(url: url, kind: .temporary, fileManager: fileManager))
                }
            }
        }

        return items.sorted {
            if $0.kind != $1.kind {
                return kindOrder($0.kind) < kindOrder($1.kind)
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static func kindOrder(_ kind: StorageItem.Kind) -> Int {
        switch kind {
        case .extracted: return 0
        case .images: return 1
        case .temporary: return 2
        }
    }

    private static func subdirectories(of root: URL, fileManager: FileManager) -> [URL]? {
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private static func makeItem(url: URL, kind: StorageItem.Kind, fileManager: FileManager) -> StorageItem {
        let measured = size(of: url, fileManager: fileManager)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        return StorageItem(
            url: url,
            kind: kind,
            displayName: url.lastPathComponent,
            sizeBytes: measured.bytes,
            fileCount: measured.files,
            modified: modified
        )
    }

    /// 递归统计占用（按分配大小，与 Finder 显示一致）。
    public static func size(of url: URL, fileManager: FileManager = .default) -> (bytes: Int64, files: Int) {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        var bytes: Int64 = 0
        var files = 0

        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: keys) else { continue }
            guard values.isRegularFile == true else { continue }

            bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            files += 1
        }

        return (bytes, files)
    }

    /// 只允许删除两个根目录的**直接子项**，以及带固定前缀的临时目录。
    /// 防止历史数据被篡改后误删到根目录以外的东西。
    public static func isSafeToTrash(_ url: URL,
                                     extractRoot: URL,
                                     imageRoot: URL,
                                     fileManager: FileManager = .default) -> Bool {
        let path = url.standardizedFileURL.path

        for root in [extractRoot, imageRoot] {
            let rootPath = root.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            // 必须是直接子项，且不能是 ".." 之类的相对路径
            guard !relative.isEmpty, !relative.contains("/") else { continue }
            return true
        }

        let tempPath = fileManager.temporaryDirectory.standardizedFileURL.path
        if path.hasPrefix(tempPath + "/") {
            let relative = String(path.dropFirst(tempPath.count + 1))
            if !relative.isEmpty, !relative.contains("/"), relative.hasPrefix(tempPrefix) {
                return true
            }
        }

        return false
    }

    /// 移到废纸篓（可恢复），而不是直接删除。
    public static func trash(_ items: [StorageItem],
                             extractRoot: URL,
                             imageRoot: URL,
                             fileManager: FileManager = .default) -> (trashed: [StorageItem], failed: [String]) {
        var trashed: [StorageItem] = []
        var failed: [String] = []

        for item in items {
            guard isSafeToTrash(item.url, extractRoot: extractRoot, imageRoot: imageRoot, fileManager: fileManager) else {
                failed.append("\(item.displayName)（路径不在允许范围内，已跳过）")
                continue
            }

            do {
                try fileManager.trashItem(at: item.url, resultingItemURL: nil)
                trashed.append(item)
            } catch {
                failed.append("\(item.displayName)：\(error.localizedDescription)")
            }
        }

        return (trashed, failed)
    }
}

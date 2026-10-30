import Foundation

/// 一处可清理的存储占用。
public struct StorageItem: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case extracted   // 完整解包产物
        case images      // 导出的图片
        case temporary   // 残留的临时解包目录
        case orphan      // 历史记录里指向的其他位置（输出目录被改过）

        public var label: String {
            switch self {
            case .extracted: return "完整解包产物"
            case .images: return "导出图片"
            case .temporary: return "临时文件"
            case .orphan: return "其他位置"
            }
        }

        public var sectionTitle: String {
            switch self {
            case .extracted: return "完整解包产物"
            case .images: return "导出图片"
            case .temporary: return "残留临时文件"
            case .orphan: return "历史记录中的其他位置"
            }
        }
    }

    public let id: String        // 规范化后的绝对路径
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
        self.id = StorageScanner.canonicalPath(url)
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

    /// 解析符号链接后的真实路径。
    ///
    /// `/tmp` 是 `/private/tmp` 的符号链接，而 `contentsOfDirectory` 返回的子项路径
    /// 会被 Foundation 解析成 `/private/tmp/...`。若直接拿字符串前缀与配置里的
    /// `/tmp/...` 比较，会误判为「越界」而拒绝删除——曾导致 `/tmp` 下的解包产物
    /// 在存储页里看得到、却删不掉。
    public static func canonicalPath(_ url: URL) -> String {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }

        // 路径还不存在时，解析父目录再拼回最后一段，
        // 否则「已存在的父目录 + 不存在的子项」两边规范化形式不一致
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path, let resolvedParent = realpath(parent.path, nil) {
            defer { free(resolvedParent) }
            let name = url.lastPathComponent
            return name.isEmpty ? String(cString: resolvedParent)
                                : String(cString: resolvedParent) + "/" + name
        }

        return url.standardizedFileURL.path
    }

    /// 扫描可清理项。
    /// - Parameter historyPaths: 历史记录里记录过的输出路径；用于把「改过输出目录后留下的旧产物」
    ///   也纳入清理范围（否则它们在界面上完全不可见）。
    public static func scan(extractRoot: URL,
                            imageRoot: URL,
                            historyPaths: [String] = [],
                            includeTemporary: Bool = true,
                            fileManager: FileManager = .default) -> [StorageItem] {
        var items: [StorageItem] = []
        var seen: Set<String> = []

        func append(_ url: URL, kind: StorageItem.Kind) {
            guard seen.insert(canonicalPath(url)).inserted else { return }
            items.append(makeItem(url: url, kind: kind, fileManager: fileManager))
        }

        if let children = subdirectories(of: extractRoot, fileManager: fileManager) {
            for url in children { append(url, kind: .extracted) }
        }

        if let children = subdirectories(of: imageRoot, fileManager: fileManager) {
            for url in children { append(url, kind: .images) }
        }

        if includeTemporary {
            if let children = subdirectories(of: fileManager.temporaryDirectory, fileManager: fileManager) {
                for url in children where url.lastPathComponent.hasPrefix(tempPrefix) {
                    append(url, kind: .temporary)
                }
            }
        }

        for path in historyPaths where !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            append(url, kind: .orphan)
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
        case .orphan: return 3
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

    /// 只允许删除两个根目录的**直接子项**、带固定前缀的临时目录，以及历史记录里显式记录过的路径。
    /// 比较时统一走 `canonicalPath`，避免 `/tmp` → `/private/tmp` 这类符号链接造成的误判。
    public static func isSafeToTrash(_ url: URL,
                                     extractRoot: URL,
                                     imageRoot: URL,
                                     extraAllowed: Set<String> = [],
                                     fileManager: FileManager = .default) -> Bool {
        let path = canonicalPath(url)

        // 绝不允许删根目录、家目录或文件系统根
        let protected = [extractRoot, imageRoot, fileManager.homeDirectoryForCurrentUser]
            .map { canonicalPath($0) } + ["/"]
        if protected.contains(path) { return false }

        // 历史记录里显式记录过的路径（输出目录被改过之后的旧产物）
        if extraAllowed.contains(path) || extraAllowed.contains(url.standardizedFileURL.path) {
            return true
        }

        for root in [extractRoot, imageRoot] {
            let rootPath = canonicalPath(root)
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            if !relative.isEmpty, !relative.contains("/") { return true }
        }

        let tempPath = canonicalPath(fileManager.temporaryDirectory)
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
                             extraAllowed: Set<String> = [],
                             fileManager: FileManager = .default) -> (trashed: [StorageItem], failed: [String]) {
        var trashed: [StorageItem] = []
        var failed: [String] = []

        for item in items {
            guard isSafeToTrash(item.url,
                                extractRoot: extractRoot,
                                imageRoot: imageRoot,
                                extraAllowed: extraAllowed,
                                fileManager: fileManager) else {
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

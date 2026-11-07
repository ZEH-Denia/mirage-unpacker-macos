import CryptoKit
import Foundation

// MARK: - 输出根角色

/// 输出根的用途。不同角色使用不同的边界规则。
public enum StorageRootRole: String, Sendable, CaseIterable {
    case extract   // 完整解包产物根
    case image     // 导出图片根
    case temporary // 系统临时目录（只清理固定前缀）
    case orphan    // 历史记录里出现过、但不在当前根下的位置
}

// MARK: - 根边界判定

public struct StorageRootVerdict: Sendable, Equatable {
    public var isSafe: Bool
    public var reason: String?

    public init(isSafe: Bool, reason: String? = nil) {
        self.isSafe = isSafe
        self.reason = reason
    }

    public static let safe = StorageRootVerdict(isSafe: true)
    public static func unsafe(_ reason: String) -> StorageRootVerdict {
        StorageRootVerdict(isSafe: false, reason: reason)
    }
}

/// 判定「输出根」是否可以被当作清理范围。
///
/// 目标是：即使用户把输出目录改成家目录、`~/Pictures`、`~/Documents` 这类宽范围目录，
/// 也不能让其中的**所有子目录**自动变成可清理产物。判定不通过时扫描仍会展示条目，
/// 但条目一律降级为「未知（只读）」，不会进入清理计划。
public enum StorageRootPolicy {
    /// 家目录下不允许直接当作输出根的常见用户目录（只比较目录本身）。
    public static let protectedHomeChildren: [String] = [
        "Applications", "Desktop", "Documents", "Downloads", "Library",
        "Movies", "Music", "Pictures", "Public", "Sites", "Templates",
    ]

    /// 系统级目录：不允许作为输出根。
    public static let protectedAbsoluteRoots: [String] = [
        "/", "/Users", "/Applications", "/Library", "/System", "/private",
        "/Volumes", "/cores", "/dev", "/bin", "/sbin", "/usr",
    ]

    public static func assess(root: URL,
                              role: StorageRootRole,
                              fs: StorageFileSystem = .live) -> StorageRootVerdict {
        let canonical = fs.canonicalPath(root)
        let home = fs.canonicalPath(fs.homeDirectory())
        let temporary = fs.canonicalPath(fs.temporaryDirectory())

        if role == .temporary {
            return canonical == temporary
                ? .safe
                : .unsafe("临时文件根必须是系统临时目录")
        }

        if protectedAbsoluteRoots.contains(canonical) {
            return .unsafe("「\(canonical)」不能作为输出根")
        }
        if canonical == home {
            return .unsafe("家目录不能作为输出根")
        }
        if canonical == temporary {
            return .unsafe("系统临时目录不能作为输出根")
        }
        // 输出根是家目录的上级（例如 /Users、/Users/xxx 的父级）时同样拒绝
        if home.hasPrefix(canonical.hasSuffix("/") ? canonical : canonical + "/") {
            return .unsafe("输出根不能是家目录的上级目录")
        }
        for name in protectedHomeChildren {
            if canonical == home + "/" + name {
                return .unsafe("「\(name)」整个目录不能作为输出根，请选择其下专用子目录")
            }
        }
        // 根不能与已解析的真实路径层级过浅（至少两段，例如 /Volumes/MyDrive）
        let depth = canonical.split(separator: "/", omittingEmptySubsequences: true).count
        if depth < 2 {
            return .unsafe("输出根层级过浅，不能作为清理范围")
        }
        return .safe
    }
}

// MARK: - 文件系统抽象（可注入，便于隔离测试）

/// 清理流程用到的文件系统操作。测试可注入故障（权限拒绝、部分失败）而不触碰真实废纸篓。
public struct StorageFileSystem: Sendable {
    public var canonicalPath: @Sendable (URL) -> String
    public var identity: @Sendable (URL) -> StorageItemIdentity?
    /// 完整身份：在 `identity` 之外再计算内容指纹（用于确认前快照）。
    public var identityFull: @Sendable (URL) -> StorageItemIdentity?
    public var isSymbolicLink: @Sendable (URL) -> Bool
    public var homeDirectory: @Sendable () -> URL
    public var temporaryDirectory: @Sendable () -> URL
    public var subdirectories: @Sendable (URL) -> [URL]
    public var trash: @Sendable (URL) throws -> Void

    public init(canonicalPath: @escaping @Sendable (URL) -> String,
                identity: @escaping @Sendable (URL) -> StorageItemIdentity?,
                identityFull: @escaping @Sendable (URL) -> StorageItemIdentity?,
                isSymbolicLink: @escaping @Sendable (URL) -> Bool,
                homeDirectory: @escaping @Sendable () -> URL,
                temporaryDirectory: @escaping @Sendable () -> URL,
                subdirectories: @escaping @Sendable (URL) -> [URL],
                trash: @escaping @Sendable (URL) throws -> Void) {
        self.canonicalPath = canonicalPath
        self.identity = identity
        self.identityFull = identityFull
        self.isSymbolicLink = isSymbolicLink
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
        self.subdirectories = subdirectories
        self.trash = trash
    }

    public static let live: StorageFileSystem = StorageFileSystem(
        canonicalPath: { StorageScanner.canonicalPath($0) },
        identity: { StorageItemIdentity.read(from: $0) },
        identityFull: { StorageItemIdentity.readFull(from: $0) },
        isSymbolicLink: { url in
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        },
        homeDirectory: { FileManager.default.homeDirectoryForCurrentUser },
        temporaryDirectory: { FileManager.default.temporaryDirectory },
        subdirectories: { url in
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return children.filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                // 符号链接也列出来（只读展示），避免「看不见但占空间」的目录完全隐身。
                return values?.isDirectory == true || values?.isSymbolicLink == true
            }
        },
        trash: { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    )
}

// MARK: - 条目身份（用于确认前快照 / 确认后重校验）

public struct StorageItemIdentity: Sendable, Equatable, Hashable, Codable {
    public var canonicalPath: String
    public var device: UInt64
    public var inode: UInt64
    public var isDirectory: Bool
    public var sizeBytes: Int64
    public var modifiedSeconds: Double
    /// 目录内容指纹（相对路径/大小/修改时间/类型的有序哈希）。`nil` 表示未计算。
    public var contentFingerprint: String?
    /// 指纹是否覆盖了全部条目（超过上限时为 false，不能作为清理依据）。
    public var fingerprintComplete: Bool
    /// 参与指纹的条目数（不含 `.DS_Store` / `._*`）。
    public var entryCount: Int

    public init(canonicalPath: String,
                device: UInt64,
                inode: UInt64,
                isDirectory: Bool,
                sizeBytes: Int64,
                modifiedSeconds: Double,
                contentFingerprint: String? = nil,
                fingerprintComplete: Bool = false,
                entryCount: Int = 0) {
        self.canonicalPath = canonicalPath
        self.device = device
        self.inode = inode
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.modifiedSeconds = modifiedSeconds
        self.contentFingerprint = contentFingerprint
        self.fingerprintComplete = fingerprintComplete
        self.entryCount = entryCount
    }

    /// 位置（路径 + 设备 + inode + 类型）是否与快照一致。用于确认前后比对。
    public func matchesLocation(_ other: StorageItemIdentity) -> Bool {
        canonicalPath == other.canonicalPath
            && device == other.device
            && inode == other.inode
            && isDirectory == other.isDirectory
    }

    /// 完全相同（位置 + 目录项 + 完整内容指纹）。任一侧指纹缺失或未覆盖全部条目都视为不一致（fail closed）。
    public func matchesExactly(_ other: StorageItemIdentity) -> Bool {
        matchesLocation(other)
            && sizeBytes == other.sizeBytes
            && modifiedSeconds == other.modifiedSeconds
            && entryCount == other.entryCount
            && fingerprintComplete && other.fingerprintComplete
            && contentFingerprint != nil
            && contentFingerprint == other.contentFingerprint
    }

    /// 只读元数据（不计算内容指纹）。用于展示/构造，不用于清理决策。
    public static func read(from url: URL) -> StorageItemIdentity? {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let type = attributes[.type] as? FileAttributeType
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return StorageItemIdentity(
            canonicalPath: StorageScanner.canonicalPath(url),
            device: device,
            inode: inode,
            isDirectory: type == .typeDirectory,
            sizeBytes: size,
            modifiedSeconds: modified
        )
    }

    /// 完整身份：元数据 + 目录内容指纹。清理决策必须用这个。
    public static func readFull(from url: URL) -> StorageItemIdentity? {
        guard var identity = read(from: url) else { return nil }
        guard identity.isDirectory else { return identity }
        guard let fingerprint = StorageContentFingerprint.compute(for: url) else {
            return nil
        }
        identity.contentFingerprint = fingerprint.hash
        identity.fingerprintComplete = fingerprint.complete
        identity.entryCount = fingerprint.entryCount
        return identity
    }
}

// MARK: - 目录内容指纹

/// 目录内容指纹：按相对路径排序后，对「相对路径|大小|修改时间(ms)|类型」做 SHA-256。
///
/// 边界：
/// - 能检测：条目增删/改名、文件大小变化、文件修改时间变化、文件↔目录↔符号链接的类型变化。
/// - 不检测：文件内容在**大小与 mtime 都保持不变**的情况下被改写（例如手工回填 mtime）、
///   xattr/ACL 变化、以及超过 `entryLimit` 的大目录（此时 `complete=false`，条目一律只读）。
/// - `.DS_Store` 与 `._*` 不计入（Finder 浏览会生成，无法作为内容依据）。
public enum StorageContentFingerprint {
    public static let entryLimit = 20_000
    public static let ignoredNames: Set<String> = [".DS_Store", OutputMarker.fileName]

    public struct Result: Sendable, Equatable {
        public var hash: String
        public var complete: Bool
        public var entryCount: Int

        public init(hash: String, complete: Bool, entryCount: Int) {
            self.hash = hash
            self.complete = complete
            self.entryCount = entryCount
        }
    }

    public static func isIgnored(_ name: String) -> Bool {
        ignoredNames.contains(name) || name.hasPrefix("._")
    }

    public static func compute(for url: URL,
                               entryLimit: Int = entryLimit,
                               fileManager: FileManager = .default) -> Result? {
        let rootPath = url.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey,
                                         .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return nil
        }

        var entries: [String] = []
        entries.reserveCapacity(256)
        var complete = true
        var seen = 0

        for case let child as URL in enumerator {
            let name = child.lastPathComponent
            if isIgnored(name) { continue }
            seen += 1
            if seen > entryLimit {
                complete = false
                break
            }
            let path = child.standardizedFileURL.path
            let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : name
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey,
                                                             .isDirectoryKey, .isSymbolicLinkKey])
            let size = Int64(values?.fileSize ?? 0)
            let millis = Int64(((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970) * 1000.0)
            let kind = values?.isSymbolicLink == true ? "l" : (values?.isDirectory == true ? "d" : "f")
            entries.append("\(relative)|\(size)|\(millis)|\(kind)")
        }

        entries.sort()
        var hasher = SHA256()
        hasher.update(data: Data("pkd-content-v1|\(entries.count)|\(complete ? 1 : 0)\n".utf8))
        for entry in entries {
            hasher.update(data: Data(entry.utf8))
            hasher.update(data: Data([0x0A]))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Result(hash: digest, complete: complete, entryCount: entries.count)
    }
}

// MARK: - 路径安全工具

public enum StoragePathSafety {
    /// child 是否为 root 的**直接**子项（比较规范化后的路径）。
    public static func isDirectChild(canonicalChild: String, canonicalRoot: String) -> Bool {
        guard !canonicalRoot.isEmpty, !canonicalChild.isEmpty else { return false }
        let prefix = canonicalRoot == "/" ? "/" : canonicalRoot + "/"
        guard canonicalChild.hasPrefix(prefix) else { return false }
        let relative = canonicalChild.dropFirst(prefix.count)
        return !relative.isEmpty && !relative.contains("/")
    }

    /// ancestor 是否等于 path 或是其上级。
    public static func isSameOrAncestor(_ ancestor: String, of path: String) -> Bool {
        if ancestor == path { return true }
        let prefix = ancestor == "/" ? "/" : ancestor + "/"
        return path.hasPrefix(prefix)
    }

    /// 是否是不允许清理的目标（根、家目录、任何受保护根、以及它们的上级）。
    public static func forbiddenTargetReason(_ canonicalTarget: String,
                                             roots: [String],
                                             fs: StorageFileSystem = .live) -> String? {
        let home = fs.canonicalPath(fs.homeDirectory())
        let temporary = fs.canonicalPath(fs.temporaryDirectory())

        if canonicalTarget == "/" { return "文件系统根目录不可清理" }
        if canonicalTarget == home { return "家目录不可清理" }
        if home.hasPrefix(canonicalTarget + "/") { return "家目录的上级不可清理" }
        if canonicalTarget == temporary { return "系统临时目录本身不可清理" }
        for root in roots where !root.isEmpty {
            if canonicalTarget == root { return "输出根目录本身不可清理" }
            // 目标包含某个根（例如目标是根的上级）也不允许，避免一次删掉整棵根
            if root.hasPrefix(canonicalTarget + "/") { return "目标包含输出根，拒绝清理" }
        }
        return nil
    }
}

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
    /// 归属可信等级：只有 `owned` / `legacy` 允许进入清理计划。
    public let ownership: OutputOwnershipLevel
    /// 是否允许被选中清理（根边界、归属、符号链接、重复项都通过才为 true）。
    public let isTrashable: Bool
    /// 只读原因 / 识别依据，用于界面提示。
    public let note: String?
    /// 该条目所属输出根（规范化路径）；`orphan` 为其父目录。
    public let rootCanonicalPath: String
    /// 扫描时记录的设备/inode/大小/修改时间，作为确认前快照。
    public let identity: StorageItemIdentity?

    public init(url: URL,
                kind: Kind,
                displayName: String,
                sizeBytes: Int64,
                fileCount: Int,
                modified: Date?,
                ownership: OutputOwnershipLevel = .unknown,
                isTrashable: Bool = true,
                note: String? = nil,
                rootCanonicalPath: String = "",
                identity: StorageItemIdentity? = nil) {
        self.id = StorageScanner.canonicalPath(url)
        self.url = url
        self.kind = kind
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.modified = modified
        self.ownership = ownership
        self.isTrashable = isTrashable
        self.note = note
        self.rootCanonicalPath = rootCanonicalPath
        self.identity = identity
    }

    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// MARK: - 一次清理计划

/// 确认界面上展示的清理计划：确认前后都用它做状态比对。
public struct CleanupPlan: Identifiable, Sendable {
    public struct Rejection: Sendable, Equatable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public let id: UUID
    public let createdAt: Date
    public let items: [StorageItem]
    public let rejections: [Rejection]
    /// 计划涉及的输出根（规范化路径），执行时再次用于边界校验。
    public let roots: [String]

    public var totalBytes: Int64 { items.reduce(Int64(0)) { $0 + $1.sizeBytes } }
    public var totalFiles: Int { items.reduce(0) { $0 + $1.fileCount } }
    public var isEmpty: Bool { items.isEmpty }
}

// MARK: - 扫描结果

public struct StorageScanResult: Sendable {
    public var items: [StorageItem]
    public var rootWarnings: [String]
    public var rootVerdicts: [StorageRootRole: StorageRootVerdict]

    public init(items: [StorageItem],
                rootWarnings: [String],
                rootVerdicts: [StorageRootRole: StorageRootVerdict]) {
        self.items = items
        self.rootWarnings = rootWarnings
        self.rootVerdicts = rootVerdicts
    }
}

// MARK: - 执行结果

public struct CleanupOutcome: Sendable {
    public struct Failure: Sendable, Equatable {
        public let path: String
        public let reason: String
    }

    public var trashed: [StorageItem]
    public var failed: [Failure]
    public var skipped: [Failure]

    public var isEmpty: Bool { trashed.isEmpty && failed.isEmpty && skipped.isEmpty }
}

// MARK: - 扫描与清理

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

    /// 扫描可清理项（兼容旧调用：只返回条目）。
    public static func scan(extractRoot: URL,
                            imageRoot: URL,
                            historyPaths: [String] = [],
                            includeTemporary: Bool = true,
                            fileManager: FileManager = .default) -> [StorageItem] {
        scanDetailed(extractRoot: extractRoot,
                     imageRoot: imageRoot,
                     historyPaths: historyPaths,
                     includeTemporary: includeTemporary,
                     fileManager: fileManager).items
    }

    /// 扫描可清理项，并带上输出根判定与只读原因。
    ///
    /// - 输出根判定不通过（例如根被设成家目录 / `~/Pictures`）时，条目仍会列出，
    ///   但一律降级为「未知（只读）」，不会进入清理计划。
    /// - 归属只认两种证据：应用私有归属记录（路径+设备+inode 一致），或历史记录
    ///   （应用自己写的记录）。仅凭目录名相同不算归属。
    public static func scanDetailed(extractRoot: URL,
                                    imageRoot: URL,
                                    historyPaths: [String] = [],
                                    includeTemporary: Bool = true,
                                    fileManager: FileManager = .default,
                                    ownership: OutputOwnershipSnapshot = .empty,
                                    fs: StorageFileSystem = .live) -> StorageScanResult {
        var warnings: [String] = []
        var verdicts: [StorageRootRole: StorageRootVerdict] = [:]

        let extractCanonical = fs.canonicalPath(extractRoot)
        let imageCanonical = fs.canonicalPath(imageRoot)

        var extractVerdict = StorageRootPolicy.assess(root: extractRoot, role: .extract, fs: fs)
        var imageVerdict = StorageRootPolicy.assess(root: imageRoot, role: .image, fs: fs)

        // 两个根相同或互相嵌套时，无法判断条目属于谁：都降级为不安全。
        if extractVerdict.isSafe && imageVerdict.isSafe {
            if extractCanonical == imageCanonical {
                extractVerdict = .unsafe("解包根与图片根相同")
                imageVerdict = .unsafe("解包根与图片根相同")
            } else if StoragePathSafety.isSameOrAncestor(extractCanonical, of: imageCanonical) {
                imageVerdict = .unsafe("图片根位于解包根内部")
            } else if StoragePathSafety.isSameOrAncestor(imageCanonical, of: extractCanonical) {
                extractVerdict = .unsafe("解包根位于图片根内部")
            }
        }
        verdicts[.extract] = extractVerdict
        verdicts[.image] = imageVerdict
        if let reason = extractVerdict.reason { warnings.append("解包目录：\(reason)") }
        if let reason = imageVerdict.reason { warnings.append("图片目录：\(reason)") }
        if let warning = ownership.loadWarning { warnings.append(warning) }

        let temporaryURL = fs.temporaryDirectory()
        let temporaryCanonical = fs.canonicalPath(temporaryURL)
        var temporaryVerdict = StorageRootVerdict.safe
        if includeTemporary {
            temporaryVerdict = StorageRootPolicy.assess(root: temporaryURL, role: .temporary, fs: fs)
            verdicts[.temporary] = temporaryVerdict
            if let reason = temporaryVerdict.reason { warnings.append("临时目录：\(reason)") }
        }

        var items: [StorageItem] = []
        var seenCanonical: Set<String> = []
        var seenPartitions: Set<String> = []

        func register(_ canonical: String, device: UInt64?, inode: UInt64?) -> String? {
            if seenCanonical.contains(canonical) { return "重复条目（路径重复）" }
            seenCanonical.insert(canonical)
            guard let device, let inode, inode != 0 else { return nil }
            let key = "\(device):\(inode)"
            if seenPartitions.contains(key) { return "重复条目（同一 inode 出现多次）" }
            seenPartitions.insert(key)
            return nil
        }

        func readOnlyItem(url: URL,
                          kind: StorageItem.Kind,
                          rootCanonical: String,
                          identity: StorageItemIdentity?,
                          note: String,
                          measure: Bool) -> StorageItem {
            let measured: (bytes: Int64, files: Int) = measure ? size(of: url, fileManager: fileManager) : (0, 0)
            return StorageItem(url: url,
                               kind: kind,
                               displayName: url.lastPathComponent,
                               sizeBytes: measured.bytes,
                               fileCount: measured.files,
                               modified: identityDate(url),
                               ownership: .unknown,
                               isTrashable: false,
                               note: note,
                               rootCanonicalPath: rootCanonical,
                               identity: identity)
        }

        func makeItem(url: URL,
                      kind: StorageItem.Kind,
                      rootCanonical: String,
                      rootVerdict: StorageRootVerdict,
                      allowOrphanRange: Bool,
                      ownershipHint: OutputOwnershipLevel? = nil,
                      ownershipNote: String? = nil,
                      measure: Bool) -> StorageItem? {
            let canonical = fs.canonicalPath(url)
            guard !canonical.isEmpty else { return nil }

            // 根自身永远不是清理条目
            let rootsInPlay = [extractCanonical, imageCanonical, temporaryCanonical]
            if rootsInPlay.contains(canonical) { return nil }

            let isSymlink = fs.isSymbolicLink(url)
            let cheapIdentity = fs.identity(url)
            if !isSymlink {
                guard let cheapIdentity, cheapIdentity.isDirectory else { return nil }
            }

            // 符号链接一律只读：不跟随、不统计、不允许清理（避免逃逸到输出目录之外）。
            if isSymlink {
                return readOnlyItem(url: url,
                                    kind: kind,
                                    rootCanonical: rootCanonical,
                                    identity: cheapIdentity,
                                    note: "符号链接，已设为只读（避免逃逸到输出目录之外）",
                                    measure: false)
            }

            guard let cheapIdentity else { return nil }
            if let duplicateReason = register(canonical, device: cheapIdentity.device, inode: cheapIdentity.inode) {
                return readOnlyItem(url: url,
                                    kind: kind,
                                    rootCanonical: rootCanonical,
                                    identity: cheapIdentity,
                                    note: duplicateReason,
                                    measure: measure)
            }

            var ownershipLevel: OutputOwnershipLevel = .unknown
            var note: String?
            var boundaryOK: Bool
            if kind == .orphan {
                boundaryOK = allowOrphanRange
                if let issue = StoragePathSafety.forbiddenTargetReason(canonical,
                                                                       roots: [extractCanonical, imageCanonical],
                                                                       fs: fs) {
                    boundaryOK = false
                    note = issue
                }
            } else {
                boundaryOK = StoragePathSafety.isDirectChild(canonicalChild: canonical,
                                                             canonicalRoot: rootCanonical)
                if !boundaryOK { note = "已不在输出目录的直接子项位置（可能被移动或替换）" }
            }

            // 第一步：只看「归属候选」（路径 + inode + 标记），不算内容指纹（大目录也便宜）。
            var candidate: OwnershipCandidate = .none(reason: "无法证明是本应用产物")
            if boundaryOK, rootVerdict.isSafe || kind == .orphan {
                if let enforced = ownershipHint {
                    ownershipLevel = enforced
                    if let ownershipNote { note = ownershipNote }
                } else {
                    candidate = classifyLocation(canonical: canonical,
                                                 directory: url,
                                                 snapshot: ownership,
                                                 identity: cheapIdentity)
                    switch candidate {
                    case .none(let reason):
                        ownershipLevel = .unknown
                        if let reason { note = reason }
                    case .owned:
                        ownershipLevel = .unknown // 待内容指纹确认
                    case .legacy(let binding):
                        // legacy 仅用于展示，不参与整目录清理。
                        ownershipLevel = .legacy
                        note = "旧记录目录（只读）：导出时身份绑定 \(binding.itemID)"
                    }
                }
            } else if !rootVerdict.isSafe, kind != .orphan {
                note = rootVerdict.reason ?? "输出根范围过大，条目已设为只读"
            }

            // 第二步：只有候选（或命名约定识别的临时目录）才计算完整内容指纹。
            var fullIdentity: StorageItemIdentity?
            var fingerprintReady = false
            let wantsFingerprint = boundaryOK
                && (rootVerdict.isSafe || kind == .orphan)
                && (ownershipHint == .temporary || isOwnedCandidate(candidate))
            if wantsFingerprint {
                if let full = fs.identityFull(url),
                   full.isDirectory, full.fingerprintComplete, full.contentFingerprint != nil {
                    fullIdentity = full
                    fingerprintReady = true
                    if ownershipHint == nil {
                        let confirmed = confirm(candidate: candidate, full: full)
                        ownershipLevel = confirmed.level
                        if let confirmedNote = confirmed.note { note = confirmedNote }
                    }
                } else {
                    ownershipLevel = .unknown
                    note = "无法建立完整内容指纹（目录过大或读取失败），已设为只读"
                }
            }

            let trashable = boundaryOK
                && rootVerdict.isSafe
                && ownershipLevel.isTrashable
                && fingerprintReady
                && (kind != .orphan || allowOrphanRange)

            let measured: (bytes: Int64, files: Int) = measure ? size(of: url, fileManager: fileManager) : (0, 0)
            return StorageItem(url: url,
                               kind: kind,
                               displayName: url.lastPathComponent,
                               sizeBytes: measured.bytes,
                               fileCount: measured.files,
                               modified: identityDate(url),
                               ownership: ownershipLevel,
                               isTrashable: trashable,
                               note: note,
                               rootCanonicalPath: rootCanonical,
                               identity: fullIdentity ?? cheapIdentity)
        }

        // 1) 完整解包产物根
        let shouldMeasure = extractVerdict.isSafe
        for url in fs.subdirectories(URL(fileURLWithPath: extractCanonical, isDirectory: true)) {
            if let item = makeItem(url: url,
                                   kind: .extracted,
                                   rootCanonical: extractCanonical,
                                   rootVerdict: extractVerdict,
                                   allowOrphanRange: false,
                                   measure: shouldMeasure) {
                items.append(item)
            }
        }

        // 2) 导出图片根
        let shouldMeasureImages = imageVerdict.isSafe
        for url in fs.subdirectories(URL(fileURLWithPath: imageCanonical, isDirectory: true)) {
            if let item = makeItem(url: url,
                                   kind: .images,
                                   rootCanonical: imageCanonical,
                                   rootVerdict: imageVerdict,
                                   allowOrphanRange: false,
                                   measure: shouldMeasureImages) {
                items.append(item)
            }
        }

        // 3) 固定前缀的临时解包目录（仅在系统临时目录根下）
        if includeTemporary, temporaryVerdict.isSafe {
            for url in fs.subdirectories(URL(fileURLWithPath: temporaryCanonical, isDirectory: true)) where url.lastPathComponent.hasPrefix(tempPrefix) {
                if let item = makeItem(url: url,
                                       kind: .temporary,
                                       rootCanonical: temporaryCanonical,
                                       rootVerdict: temporaryVerdict,
                                       allowOrphanRange: false,
                                       ownershipHint: .temporary,
                                       ownershipNote: "按应用固定临时目录前缀识别",
                                       measure: true) {
                    items.append(item)
                }
            }
        }

        // 4) 历史记录里出现过、但不在当前根下的旧位置
        var seenOrphanParents: Set<String> = []
        for path in historyPaths where !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            guard let identity = fs.identity(url), identity.isDirectory else { continue }
            let canonical = fs.canonicalPath(url)
            if canonical == extractCanonical || canonical == imageCanonical { continue }
            guard seenOrphanParents.insert(canonical).inserted else { continue }
            // 已经作为当前根的条目列出过时，不再重复展示
            guard !seenCanonical.contains(canonical) else { continue }
            let parent = (canonical as NSString).deletingLastPathComponent
            if let item = makeItem(url: url,
                                   kind: .orphan,
                                   rootCanonical: parent,
                                   rootVerdict: .safe,
                                   allowOrphanRange: true,
                                   measure: true) {
                items.append(item)
            } else {
                items.append(StorageItem(url: url,
                                         kind: .orphan,
                                         displayName: url.lastPathComponent,
                                         sizeBytes: 0,
                                         fileCount: 0,
                                         modified: identityDate(url),
                                         ownership: .unknown,
                                         isTrashable: false,
                                         note: "历史路径已不可用或位于受保护位置",
                                         rootCanonicalPath: parent,
                                         identity: identity))
            }
        }

        return StorageScanResult(
            items: items.sorted {
                if $0.kind != $1.kind { return kindOrder($0.kind) < kindOrder($1.kind) }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            },
            rootWarnings: warnings,
            rootVerdicts: verdicts
        )
    }

    private static func kindOrder(_ kind: StorageItem.Kind) -> Int {
        switch kind {
        case .extracted: return 0
        case .images: return 1
        case .temporary: return 2
        case .orphan: return 3
        }
    }

    private static func identityDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// 归属判定：应用私有记录（路径+设备+inode）优先，其次历史记录。
    /// 归属候选（只看路径 + inode + 标记，不做内容指纹计算）。
    private enum OwnershipCandidate {
        case owned(OwnedOutputRecord)
        case legacy(LegacyOutputBinding)
        case none(reason: String?)
    }

    private static func isOwnedCandidate(_ candidate: OwnershipCandidate) -> Bool {
        if case .owned = candidate { return true }
        return false
    }

    private static func classifyLocation(canonical: String,
                                         directory: URL,
                                         snapshot: OutputOwnershipSnapshot,
                                         identity: StorageItemIdentity) -> OwnershipCandidate {
        if let record = snapshot.recordsByCanonicalPath[canonical] {
            guard identity.device == record.device, identity.inode == record.inode else {
                return .none(reason: "归属记录的 inode 与当前目录不一致，已设为只读")
            }
            if let marker = OutputOwnershipStore.readMarker(in: directory), marker.token != record.token {
                return .none(reason: "目录内标记与归属记录不一致，已设为只读")
            }
            return .owned(record)
        }
        if let binding = snapshot.legacyBindings[canonical] {
            // legacy 只用于展示与解释来源，永不授权整目录清理，因此不需要 inode 授权校验。
            return .legacy(binding)
        }
        if snapshot.legacyCanonicalPaths.contains(canonical) {
            return .none(reason: "历史记录缺少身份绑定（旧产物请重新导出一次以恢复清理能力）")
        }
        return .none(reason: nil)
    }

    /// 用完整内容指纹确认候选：任何不一致都 fail closed。
    private static func confirm(candidate: OwnershipCandidate,
                                full: StorageItemIdentity) -> (level: OutputOwnershipLevel, note: String?) {
        switch candidate {
        case .owned(let record):
            guard record.fingerprintComplete, !record.contentFingerprint.isEmpty else {
                return (.unknown, "归属记录缺少内容指纹（旧格式），已设为只读")
            }
            guard let currentFingerprint = full.contentFingerprint,
                  full.fingerprintComplete,
                  currentFingerprint == record.contentFingerprint else {
                return (.unknown, "目录内容自上次导出后发生变化，已设为只读")
            }
            return (.owned, "应用归属记录（\(record.itemID)）")
        case .legacy(let binding):
            return (.legacy, "旧记录目录（只读）：导出时身份绑定 \(binding.itemID)")
        case .none(let reason):
            return (.unknown, reason ?? "无法证明是本应用产物")
        }
    }

    // MARK: - 大小统计

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

    // MARK: - 边界判定（路径白名单）

    /// 只允许删除两个根目录的**直接子项**、带固定前缀的临时目录，以及历史记录里显式记录过的路径。
    /// 比较时统一走 `canonicalPath`，避免 `/tmp` → `/private/tmp` 这类符号链接造成的误判。
    ///
    /// 注意：这是**路径边界**判定，不包含归属判定。界面路径使用 `makePlan`（会额外校验归属、
    /// 符号链接和确认前后状态），本函数只给底层工具/自测使用。
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

    /// 底层路径白名单删除（兼容自测 `--trash`；界面流程请用 `makePlan` + `execute`）。
    public static func trash(_ items: [StorageItem],
                             extractRoot: URL,
                             imageRoot: URL,
                             extraAllowed: Set<String> = [],
                             fileManager: FileManager = .default,
                             fs: StorageFileSystem = .live) -> (trashed: [StorageItem], failed: [String]) {
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
                try fs.trash(item.url)
                trashed.append(item)
            } catch {
                failed.append("\(item.displayName)：\(error.localizedDescription)")
            }
        }

        return (trashed, failed)
    }

    // MARK: - 确认流程：计划与执行

    /// 生成清理计划：逐项校验边界、归属、符号链接、重复项，并保存确认前快照。
    public static func makePlan(items: [StorageItem],
                                roots: [String],
                                fs: StorageFileSystem = .live) -> CleanupPlan {
        var accepted: [StorageItem] = []
        var rejections: [CleanupPlan.Rejection] = []
        var seenCanonical: Set<String> = []
        var seenInodes: Set<UInt64> = []

        for item in items {
            let canonical = fs.canonicalPath(item.url)
            if !item.isTrashable {
                rejections.append(.init(path: canonical, reason: "该条目不可清理（\(item.note ?? "未通过安全校验")）"))
                continue
            }
            guard let snapshot = item.identity else {
                rejections.append(.init(path: canonical, reason: "缺少确认前状态快照"))
                continue
            }
            guard snapshot.fingerprintComplete, snapshot.contentFingerprint != nil else {
                rejections.append(.init(path: canonical, reason: "扫描时缺少完整内容指纹，请重新扫描"))
                continue
            }
            guard let current = fs.identityFull(item.url), current.isDirectory else {
                rejections.append(.init(path: canonical, reason: "目录已不存在或无法读取"))
                continue
            }
            if fs.isSymbolicLink(item.url) {
                rejections.append(.init(path: canonical, reason: "目标已变成符号链接"))
                continue
            }
            if let reason = StoragePathSafety.forbiddenTargetReason(canonical, roots: roots, fs: fs) {
                rejections.append(.init(path: canonical, reason: reason))
                continue
            }
            if !seenCanonical.insert(canonical).inserted {
                rejections.append(.init(path: canonical, reason: "重复选择（路径重复）"))
                continue
            }
            if current.inode != 0, !seenInodes.insert(current.inode).inserted {
                rejections.append(.init(path: canonical, reason: "重复选择（同一 inode）"))
                continue
            }
            guard current.matchesExactly(snapshot) else {
                rejections.append(.init(path: canonical, reason: "扫描后目录状态已变化（内容指纹/大小/修改时间不一致），请重新扫描"))
                continue
            }
            accepted.append(item)
        }

        return CleanupPlan(id: UUID(),
                           createdAt: Date(),
                           items: accepted,
                           rejections: rejections,
                           roots: roots)
    }

    /// 执行清理计划：再次校验确认前快照，逐项移入废纸篓并记录审计日志。
    public static func execute(plan: CleanupPlan,
                               fs: StorageFileSystem = .live,
                               audit: CleanupAuditLog? = nil,
                               currentRoots: [String]? = nil) -> CleanupOutcome {
        var outcome = CleanupOutcome(trashed: [], failed: [], skipped: [])

        for item in plan.items {
            let canonical = fs.canonicalPath(item.url)

            func skip(_ reason: String) {
                outcome.skipped.append(.init(path: canonical, reason: reason))
                audit?.record(.itemResult,
                              planID: plan.id,
                              items: [auditItem(item, result: "skipped", error: reason)])
            }

            guard let snapshot = item.identity else {
                skip("缺少确认前状态快照")
                continue
            }
            guard snapshot.fingerprintComplete, snapshot.contentFingerprint != nil else {
                skip("缺少完整内容指纹")
                continue
            }
            // 先做「不可变边界」检查：即使确认期间路径被重定向，也不会把受保护目标移走。
            if let reason = StoragePathSafety.forbiddenTargetReason(canonical, roots: plan.roots, fs: fs) {
                skip(reason)
                continue
            }
            if fs.isSymbolicLink(item.url) {
                skip("确认时目标已变成符号链接")
                continue
            }
            if let currentRoots, item.kind != .orphan {
                let inside = currentRoots.contains {
                    StoragePathSafety.isDirectChild(canonicalChild: canonical, canonicalRoot: $0)
                }
                guard inside else {
                    skip("当前输出根已变化（不再是该根的直接子项）")
                    continue
                }
            }
            guard let current = fs.identityFull(item.url), current.isDirectory else {
                skip("确认时目录已不存在或无法读取")
                continue
            }
            guard current.matchesExactly(snapshot) else {
                skip("确认前后目录状态不一致（可能被替换、重定向或内容已变化）")
                continue
            }
            do {
                try fs.trash(item.url)
                outcome.trashed.append(item)
                audit?.record(.itemResult,
                              planID: plan.id,
                              items: [auditItem(item, result: "trashed", error: nil)])
            } catch {
                let reason = "移入废纸篓失败：\(error.localizedDescription)"
                outcome.failed.append(.init(path: canonical, reason: reason))
                audit?.record(.itemResult,
                              planID: plan.id,
                              items: [auditItem(item, result: "failed", error: error.localizedDescription)])
            }
        }

        audit?.record(.completed,
                      planID: plan.id,
                      items: plan.items.map { auditItem($0) },
                      note: "trashed=\(outcome.trashed.count) failed=\(outcome.failed.count) skipped=\(outcome.skipped.count)")
        return outcome
    }

    /// 把条目转换成审计日志条目（只含路径/分类/归属/大小/身份，不含任何文件内容）。
    public static func auditItem(_ item: StorageItem,
                                 result: String? = nil,
                                 error: String? = nil) -> CleanupAuditLog.Item {
        CleanupAuditLog.Item(path: item.identity?.canonicalPath ?? item.url.path,
                             kind: item.kind.rawValue,
                             ownership: item.ownership.rawValue,
                             sizeBytes: item.sizeBytes,
                             device: item.identity?.device,
                             inode: item.identity?.inode,
                             result: result,
                             error: error)
    }
}

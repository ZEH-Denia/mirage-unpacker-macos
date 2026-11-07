import Foundation

// MARK: - 归属可信等级

/// 一个目录「是不是本应用写出来的」的可信等级。
///
/// 只有 `owned` / `legacy` 允许进入清理流程；`unknown` 一律只读展示。
public enum OutputOwnershipLevel: String, Codable, Sendable, CaseIterable {
    /// 本应用创建的目录，且有应用私有记录（路径 + 设备 + inode + 内容指纹）。
    case owned
    /// 旧记录/历史候选：**只读展示**，不参与整目录清理。
    case legacy
    /// 系统临时目录下、带应用固定前缀的残留解包目录（内容指纹完整才可清理）。
    case temporary
    /// 无法证明来源，默认只读，不允许自动清理。
    case unknown

    public var label: String {
        switch self {
        case .owned: return "本应用产物"
        case .legacy: return "旧记录（只读）"
        case .temporary: return "残留临时目录"
        case .unknown: return "未知（只读）"
        }
    }

    /// 只有「应用新建/可信续写」的产物与固定前缀临时目录允许整目录清理；
    /// legacy 仅用于展示，标签不同不再等于删除权限不同。
    public var isTrashable: Bool { self == .owned || self == .temporary }
}

// MARK: - 导出前的可信快照

/// 导出任务入队时对目标目录的归属判定结果。决定导出成功后能否把目录登记为可清理产物。
public enum ExportEligibility: String, Sendable, Equatable, Codable {
    /// 导出前目录不存在（应用新建）。
    case newDirectory
    /// 导出前已存在，且是应用私有 owned 记录 + inode 一致 + 内容指纹完全一致（纯应用产物）。
    case trustedOwned
    /// 导出前已存在但没有可信证明（含用户预存目录、被替换、导出后被改动、仅历史记录）。
    /// 这类目录**永远保持只读**；重新导出不会自动授权清理。
    case untrusted
}

// MARK: - 目录内标记（owned 的第二重证据）

public struct OutputMarker: Codable, Sendable, Equatable {
    public static let fileName = ".pkd-output.json"
    public var version: Int
    public var token: String
    public var itemID: String
    public var recordedAt: Date

    public init(version: Int = 1, token: String, itemID: String, recordedAt: Date) {
        self.version = version
        self.token = token
        self.itemID = itemID
        self.recordedAt = recordedAt
    }
}

// MARK: - 归属记录

/// 应用创建的产物目录（owned）。
public struct OwnedOutputRecord: Codable, Sendable, Equatable {
    public var canonicalPath: String
    public var token: String
    public var itemID: String
    public var recordedAt: Date
    public var device: UInt64
    public var inode: UInt64
    /// 导出完成时的目录内容指纹；之后内容变化则降级为只读。
    public var contentFingerprint: String
    public var fingerprintComplete: Bool
    public var entryCount: Int

    public init(canonicalPath: String,
                token: String,
                itemID: String,
                recordedAt: Date,
                device: UInt64,
                inode: UInt64,
                contentFingerprint: String,
                fingerprintComplete: Bool,
                entryCount: Int) {
        self.canonicalPath = canonicalPath
        self.token = token
        self.itemID = itemID
        self.recordedAt = recordedAt
        self.device = device
        self.inode = inode
        self.contentFingerprint = contentFingerprint
        self.fingerprintComplete = fingerprintComplete
        self.entryCount = entryCount
    }
}

/// 导出前已存在、但应用写入过内容的目录（legacy）。
///
/// 只有「同一 inode + 同一份内容指纹」才允许清理：目录被替换、重建、内容被改动都 fail closed。
public struct LegacyOutputBinding: Codable, Sendable, Equatable {
    public var canonicalPath: String
    public var itemID: String
    public var recordedAt: Date
    public var device: UInt64
    public var inode: UInt64
    public var contentFingerprint: String
    public var fingerprintComplete: Bool
    public var entryCount: Int

    public init(canonicalPath: String,
                itemID: String,
                recordedAt: Date,
                device: UInt64,
                inode: UInt64,
                contentFingerprint: String,
                fingerprintComplete: Bool,
                entryCount: Int) {
        self.canonicalPath = canonicalPath
        self.itemID = itemID
        self.recordedAt = recordedAt
        self.device = device
        self.inode = inode
        self.contentFingerprint = contentFingerprint
        self.fingerprintComplete = fingerprintComplete
        self.entryCount = entryCount
    }
}

/// 扫描时使用的只读归属快照。
public struct OutputOwnershipSnapshot: Sendable {
    public var recordsByCanonicalPath: [String: OwnedOutputRecord]
    /// 历史记录（应用写的 `history.json`）里出现过的路径。仅作「候选」，不单独授权清理。
    public var legacyCanonicalPaths: Set<String>
    /// 导出完成时写下的 legacy 身份绑定。
    public var legacyBindings: [String: LegacyOutputBinding]
    public var loadWarning: String?

    public init(recordsByCanonicalPath: [String: OwnedOutputRecord] = [:],
                legacyCanonicalPaths: Set<String> = [],
                legacyBindings: [String: LegacyOutputBinding] = [:],
                loadWarning: String? = nil) {
        self.recordsByCanonicalPath = recordsByCanonicalPath
        self.legacyCanonicalPaths = legacyCanonicalPaths
        self.legacyBindings = legacyBindings
        self.loadWarning = loadWarning
    }

    public static let empty = OutputOwnershipSnapshot()
}

// MARK: - 持久化注入（测试故障用）

/// 归属数据的落盘操作，可注入以测试「写入失败不得默默标 owned」。
public struct OwnershipPersistence: Sendable {
    public var writeStore: @Sendable (Data, URL) throws -> Void
    public var writeMarker: @Sendable (URL, OutputMarker) throws -> Void

    public init(writeStore: @escaping @Sendable (Data, URL) throws -> Void,
                writeMarker: @escaping @Sendable (URL, OutputMarker) throws -> Void) {
        self.writeStore = writeStore
        self.writeMarker = writeMarker
    }

    public static let live = OwnershipPersistence(
        writeStore: { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        },
        writeMarker: { directory, marker in
            try OutputOwnershipStore.writeMarkerFile(in: directory, marker: marker)
        }
    )
}

// MARK: - 归属持久化

/// 应用私有的产物归属记录。
///
/// 文件内容：`{version:2, owned:{...}, legacy:{...}}`，0600，位于
/// `~/Library/Application Support/PKD/output-ownership.json`（开发副本在隔离根目录），不进 Git、不上传。
/// 兼容读取上一版（`[path: record]` 且无指纹）——那类记录缺少内容指纹，一律按 `unknown` 处理。
public final class OutputOwnershipStore: @unchecked Sendable {
    public static let defaultFileName = "output-ownership.json"

    public enum RecordOutcome: Sendable, Equatable {
        case owned(OwnedOutputRecord)
        case legacy(LegacyOutputBinding)
        case rejected(String)
    }

    public let fileURL: URL
    private let persistence: OwnershipPersistence
    private let lock = NSLock()
    private var owned: [String: OwnedOutputRecord]
    private var legacy: [String: LegacyOutputBinding]
    private var loadWarning: String?

    public init(fileURL: URL, persistence: OwnershipPersistence = .live) {
        self.fileURL = fileURL
        self.persistence = persistence
        self.owned = [:]
        self.legacy = [:]
        self.loadWarning = nil
        loadIfPresent()
    }

    public var warning: String? {
        lock.lock()
        defer { lock.unlock() }
        return loadWarning
    }

    public func ownedRecord(forCanonicalPath: String) -> OwnedOutputRecord? {
        lock.lock()
        defer { lock.unlock() }
        return owned[forCanonicalPath]
    }

    public func legacyBinding(forCanonicalPath: String) -> LegacyOutputBinding? {
        lock.lock()
        defer { lock.unlock() }
        return legacy[forCanonicalPath]
    }

    /// 生成扫描用快照。`legacyPaths` 是历史记录里的输出路径（仅候选，需 binding 才可清理）。
    public func snapshot(legacyPaths: [String],
                         fs: StorageFileSystem = .live) -> OutputOwnershipSnapshot {
        lock.lock()
        let currentOwned = owned
        let currentLegacy = legacy
        let warning = loadWarning
        lock.unlock()

        var legacySet = Set<String>()
        for path in legacyPaths where !path.isEmpty {
            legacySet.insert(fs.canonicalPath(URL(fileURLWithPath: path)))
        }
        return OutputOwnershipSnapshot(recordsByCanonicalPath: currentOwned,
                                       legacyCanonicalPaths: legacySet,
                                       legacyBindings: currentLegacy,
                                       loadWarning: warning)
    }

    /// 入队时判定目标目录的可信度（必须在导出**之前**调用并保存结果）。
    ///
    /// 只有「不存在」或「既有 owned 记录 + inode 一致 + 完整内容指纹一致」两种情形算可信；
    /// 其余（用户预存目录、被替换、被用户改动、仅历史记录）一律 `untrusted`，重新导出也不能自动授权清理。
    public static func exportEligibility(directory: URL,
                                         existingRecord: OwnedOutputRecord?,
                                         fs: StorageFileSystem = .live) -> ExportEligibility {
        guard FileManager.default.fileExists(atPath: directory.path) else { return .newDirectory }
        guard let record = existingRecord else { return .untrusted }
        guard record.fingerprintComplete, !record.contentFingerprint.isEmpty else { return .untrusted }
        guard let identity = fs.identityFull(directory),
              identity.isDirectory,
              identity.fingerprintComplete,
              identity.device == record.device,
              identity.inode == record.inode,
              identity.contentFingerprint == record.contentFingerprint else {
            return .untrusted
        }
        return .trustedOwned
    }

    /// 记录一次成功导出后的产物目录。
    ///
    /// - `newDirectory`：本次导出前目录不存在（由应用创建）→ 记录为 `owned`。
    /// - `trustedOwned`：导出前已验证「既有 owned 记录 + 同 inode + 内容指纹完全一致」→ 刷新为 `owned`。
    /// - `untrusted`：导出前已存在但没有可信证明（用户预存/被替换/被改动/仅历史）→ **拒绝登记并保持只读**。
    /// - `owned` 需要目录内标记写入成功 **且** 归属文件写入并回读校验成功；任一失败都返回 `.rejected`，
    ///   不会在内存里留下一条「看起来 owned」的记录。
    @discardableResult
    public func recordAfterExport(directory: URL,
                                  itemID: String,
                                  allowedCanonicalRoots: [String],
                                  eligibility: ExportEligibility,
                                  fs: StorageFileSystem = .live) -> RecordOutcome {
        let canonical = fs.canonicalPath(directory)
        guard !canonical.isEmpty, canonical != "/" else {
            return .rejected("目录路径无效")
        }
        guard allowedCanonicalRoots.contains(where: {
            StoragePathSafety.isDirectChild(canonicalChild: canonical, canonicalRoot: $0)
        }) else {
            return .rejected("目录不在允许的输出根之下")
        }
        guard !fs.isSymbolicLink(directory) else {
            return .rejected("目录是符号链接")
        }
        guard let identity = fs.identityFull(directory), identity.isDirectory else {
            return .rejected("目录不存在或无法读取身份")
        }
        guard identity.fingerprintComplete,
              let fingerprint = identity.contentFingerprint else {
            return .rejected("无法建立完整内容指纹（目录过大或读取失败）")
        }

        // 不可信目录：导出成功也不登记任何可清理归属，保持只读（legacy 仅展示）。
        guard eligibility != .untrusted else {
            return .rejected("目录在导出前已存在且没有可信归属证明（可能含非本应用文件），保持只读")
        }

        lock.lock()
        let existing = owned[canonical]
        lock.unlock()

        // trustedOwned：入队时验证过的记录必须仍然匹配；newDirectory：不允许同路径已有别的 inode 记录。
        if let existing {
            guard existing.device == identity.device, existing.inode == identity.inode else {
                return .rejected("同名目录已被替换（inode 不一致），保持只读")
            }
        }
        if eligibility == .trustedOwned, existing == nil {
            return .rejected("可信归属记录在入队后消失，保持只读")
        }

        let now = Date()
        let token = existing?.token ?? Self.makeToken()
        let marker = OutputMarker(token: token, itemID: itemID, recordedAt: now)
        do {
            try persistence.writeMarker(directory, marker)
        } catch {
            return .rejected("目录标记写入失败：\(error.localizedDescription)")
        }
        let record = OwnedOutputRecord(canonicalPath: canonical,
                                       token: token,
                                       itemID: itemID,
                                       recordedAt: now,
                                       device: identity.device,
                                       inode: identity.inode,
                                       contentFingerprint: fingerprint,
                                       fingerprintComplete: true,
                                       entryCount: identity.entryCount)
        lock.lock()
        let previousOwned = owned[canonical]
        owned[canonical] = record
        lock.unlock()
        if persistAndVerify(expectedOwned: record, expectedLegacy: nil) {
            return .owned(record)
        }
        lock.lock()
        if let previousOwned { owned[canonical] = previousOwned } else { owned.removeValue(forKey: canonical) }
        lock.unlock()
        return .rejected("归属记录写入失败（已回滚，不会标记为 owned）")
    }

    /// 清理成功后忘掉这些路径的记录。
    public func forget(canonicalPaths: [String]) {
        guard !canonicalPaths.isEmpty else { return }
        lock.lock()
        for path in canonicalPaths {
            owned.removeValue(forKey: path)
            legacy.removeValue(forKey: path)
        }
        lock.unlock()
        _ = persistAndVerify(expectedOwned: nil, expectedLegacy: nil)
    }

    // MARK: - 磁盘

    private struct StoreFile: Codable {
        var version: Int
        var owned: [String: OwnedOutputRecord]
        var legacy: [String: LegacyOutputBinding]
    }

    private func loadIfPresent() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else {
            lock.lock(); loadWarning = "归属记录不可读"; lock.unlock()
            return
        }
        let decoder = JSONDecoder()
        if let store = try? decoder.decode(StoreFile.self, from: data) {
            lock.lock()
            owned = store.owned
            legacy = store.legacy
            lock.unlock()
            return
        }
        // 上一版格式（无内容指纹）：保留但按 unknown 处理（fingerprint 为空 → 必然 fail closed）。
        if let legacyV1 = try? decoder.decode([String: OwnedOutputRecordLegacyV1].self, from: data) {
            var converted: [String: OwnedOutputRecord] = [:]
            for (path, value) in legacyV1 {
                converted[path] = OwnedOutputRecord(canonicalPath: value.canonicalPath,
                                                    token: value.token,
                                                    itemID: value.itemID,
                                                    recordedAt: value.recordedAt,
                                                    device: value.device,
                                                    inode: value.inode,
                                                    contentFingerprint: "",
                                                    fingerprintComplete: false,
                                                    entryCount: 0)
            }
            lock.lock()
            owned = converted
            loadWarning = "归属记录为旧格式（缺少内容指纹），旧记录按只读处理"
            lock.unlock()
            return
        }
        // 损坏：不崩溃、不清空证据，挪到 .corrupt 后按空记录工作。
        let corrupt = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: corrupt)
        try? FileManager.default.moveItem(at: fileURL, to: corrupt)
        lock.lock()
        loadWarning = "归属记录损坏，已隔离为 \(corrupt.lastPathComponent)；本次按无记录处理"
        lock.unlock()
    }

    /// 写入后回读校验；失败返回 false（调用方必须回滚）。
    private func persistAndVerify(expectedOwned: OwnedOutputRecord?,
                                  expectedLegacy: LegacyOutputBinding?) -> Bool {
        lock.lock()
        let payload = StoreFile(version: 2, owned: owned, legacy: legacy)
        lock.unlock()

        do {
            let data = try JSONEncoder().encode(payload)
            try persistence.writeStore(data, fileURL)
            // 回读校验：必须真的能看到刚写的记录（防止「写入静默失败」仍被当成已记录）
            let readBack = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(StoreFile.self, from: readBack)
            guard decoded.version == 2 else { return false }
            if let expectedOwned {
                guard decoded.owned[expectedOwned.canonicalPath]?.token == expectedOwned.token else { return false }
            }
            if let expectedLegacy {
                guard decoded.legacy[expectedLegacy.canonicalPath]?.recordedAt == expectedLegacy.recordedAt else { return false }
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - 标记文件

    public static func readMarker(in directory: URL) -> OutputMarker? {
        let url = directory.appendingPathComponent(OutputMarker.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OutputMarker.self, from: data)
    }

    public static func writeMarkerFile(in directory: URL, marker: OutputMarker) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(OutputMarker.fileName)
        let data = try JSONEncoder().encode(marker)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func makeToken() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// 兼容读取上一版记录结构。
    private struct OwnedOutputRecordLegacyV1: Codable {
        var canonicalPath: String
        var token: String
        var itemID: String
        var recordedAt: Date
        var device: UInt64
        var inode: UInt64
    }
}

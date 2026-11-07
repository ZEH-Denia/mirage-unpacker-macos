import Foundation
#if canImport(PKDKit)
import PKDKit
#endif

/// 存储清理与输出数据保护的隔离回归测试（归属可信度 + 攻击面 + 数据保护）。
///
/// 只使用自建 fixture 目录（默认系统临时目录，或 `PKD_STORAGE_SAFETY_ROOT` 指定），
/// 不触碰真实用户目录、真实废纸篓；`trash` 被替换为「移动到 fixture 内的 sink 目录」，
/// 权限拒绝、写入失败等故障由注入接口模拟。
///
/// 该文件不依赖 `main.swift` 的断言框架：既可编进 `pkd-selftest`（由主代理接线），
/// 也可用 `tools/dev/verify-storage-safety.sh` 独立编译运行。
enum StorageSafetyTests {
    // MARK: - 可注入的 trash

    private final class TrashRecorder: @unchecked Sendable {
        let sink: URL
        private let lock = NSLock()
        private var _attempts: [String] = []
        private var _trashed: [String] = []
        private var _failingSuffixes: [String] = []

        init(sink: URL) {
            self.sink = sink
        }

        var attempts: [String] {
            lock.lock(); defer { lock.unlock() }
            return _attempts
        }

        func failOn(suffixes: [String]) {
            lock.lock(); defer { lock.unlock() }
            _failingSuffixes = suffixes
        }

        func trash(_ url: URL) throws {
            let name = url.lastPathComponent
            lock.lock()
            _attempts.append(name)
            let shouldFail = _failingSuffixes.contains { name.hasSuffix($0) }
            lock.unlock()

            if shouldFail {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteNoPermissionError,
                              userInfo: [NSLocalizedDescriptionKey: "模拟权限拒绝（隔离测试）"])
            }
            try FileManager.default.createDirectory(at: sink, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: sink.appendingPathComponent(name))
            lock.lock()
            _trashed.append(name)
            lock.unlock()
        }
    }

    private static func makeFileSystem(home: URL,
                                       temporary: URL,
                                       recorder: TrashRecorder) -> StorageFileSystem {
        StorageFileSystem(
            canonicalPath: { StorageScanner.canonicalPath($0) },
            identity: { StorageItemIdentity.read(from: $0) },
            identityFull: { StorageItemIdentity.readFull(from: $0) },
            isSymbolicLink: { url in
                (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            },
            homeDirectory: { home },
            temporaryDirectory: { temporary },
            subdirectories: { url in
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ) else { return [] }
                return children.filter { url in
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    return values?.isDirectory == true || values?.isSymbolicLink == true
                }
            },
            trash: { try recorder.trash($0) }
        )
    }

    // MARK: - 运行

    static func run(verbose: Bool = true) -> Bool {
        var failures = 0
        var checks = 0

        func check(_ condition: Bool, _ message: String, line: Int = #line) {
            checks += 1
            if !condition {
                failures += 1
                FileHandle.standardError.write(Data("FAIL StorageSafetyTests:\(line) — \(message)\n".utf8))
            }
        }

        func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String, line: Int = #line) {
            checks += 1
            if lhs != rhs {
                failures += 1
                FileHandle.standardError.write(Data("FAIL StorageSafetyTests:\(line) — \(message)\n  实际: \(lhs)\n  期望: \(rhs)\n".utf8))
            }
        }

        func section(_ name: String) {
            if verbose { print("· \(name)") }
        }

        let fm = FileManager.default
        let base: URL = {
            if let raw = ProcessInfo.processInfo.environment["PKD_STORAGE_SAFETY_ROOT"], raw.hasPrefix("/") {
                return URL(fileURLWithPath: raw, isDirectory: true)
            }
            return fm.temporaryDirectory.appendingPathComponent("pkd-storage-safety-\(UUID().uuidString)",
                                                                isDirectory: true)
        }()
        let home = base.appendingPathComponent("Home", isDirectory: true)
        let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let extracted = base.appendingPathComponent("Extracted", isDirectory: true)
        let images = base.appendingPathComponent("Images", isDirectory: true)
        let temporary = base.appendingPathComponent("Temp", isDirectory: true)
        let outside = base.appendingPathComponent("Outside", isDirectory: true)
        let sink = base.appendingPathComponent("TrashSink", isDirectory: true)
        let attacker = base.appendingPathComponent("Attacker", isDirectory: true)
        let auditURL = base.appendingPathComponent("Audit/cleanup-audit.jsonl")
        let ownershipURL = base.appendingPathComponent("Ownership/output-ownership.json")

        for dir in [home, pictures, documents, extracted, images, temporary, outside, attacker] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        func makeFolder(_ url: URL, files: Int = 2) throws {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            for index in 0..<files {
                try Data(repeating: 0x41, count: 256)
                    .write(to: url.appendingPathComponent("f\(index).bin"))
            }
        }

        // MARK: fixture

        let ownedDir = extracted.appendingPathComponent("owned_2001", isDirectory: true)
        let ownedSecond = extracted.appendingPathComponent("owned_2002", isDirectory: true)
        let ownedRefresh = extracted.appendingPathComponent("owned_refresh_2003", isDirectory: true)
        let ownedCancelA = extracted.appendingPathComponent("owned_cancel_a_2004", isDirectory: true)
        let ownedCancelB = extracted.appendingPathComponent("owned_cancel_b_2005", isDirectory: true)
        let ownedExecA = extracted.appendingPathComponent("owned_exec_a_2006", isDirectory: true)
        let ownedExecB = extracted.appendingPathComponent("owned_exec_b_2007", isDirectory: true)
        let ownedChange = extracted.appendingPathComponent("owned_change_2008", isDirectory: true)
        let ownedReplace = extracted.appendingPathComponent("owned_replace_2009", isDirectory: true)
        let ownedPartialA = extracted.appendingPathComponent("owned_partial_a_2010", isDirectory: true)
        let ownedPartialB = extracted.appendingPathComponent("owned_partial_b_2011", isDirectory: true)
        let ownedMissing = extracted.appendingPathComponent("owned_missing_2012", isDirectory: true)
        let ownedIntruded = extracted.appendingPathComponent("owned_intruded_2013", isDirectory: true)
        let ownedReplaced = extracted.appendingPathComponent("owned_replaced_2014", isDirectory: true)
        let sentinelDir = extracted.appendingPathComponent("sentinel_preexisting_2020", isDirectory: true)
        let historyOnlyDir = extracted.appendingPathComponent("history_only_2021", isDirectory: true)
        let legacyDisplayDir = extracted.appendingPathComponent("legacy_display_2022", isDirectory: true)
        let unknownDir = extracted.appendingPathComponent("unknown_2030", isDirectory: true)
        let namedOnly = extracted.appendingPathComponent("看起来像产物_2031", isDirectory: true)
        let linkedDir = extracted.appendingPathComponent("linked_2032", isDirectory: true)
        let ownedImage = images.appendingPathComponent("owned_3001", isDirectory: true)
        let tempItem = temporary.appendingPathComponent("\(StorageScanner.tempPrefix)abc", isDirectory: true)

        let ownedDirs = [ownedDir, ownedSecond, ownedRefresh, ownedCancelA, ownedCancelB,
                         ownedExecA, ownedExecB, ownedChange, ownedReplace,
                         ownedPartialA, ownedPartialB, ownedMissing, ownedIntruded, ownedReplaced,
                         ownedImage]
        do {
            for dir in ownedDirs { try makeFolder(dir) }
            // 预存目录：用户自己创建并放了文件
            try makeFolder(sentinelDir, files: 1)
            try Data(repeating: 0x55, count: 64)
                .write(to: sentinelDir.appendingPathComponent("user-sentinel.bin"))
            try makeFolder(historyOnlyDir, files: 1)
            try makeFolder(legacyDisplayDir, files: 1)
            try makeFolder(unknownDir)
            try makeFolder(namedOnly)
            try makeFolder(tempItem, files: 1)
            try makeFolder(outside, files: 1)
            try makeFolder(unknownDir.appendingPathComponent("nested_9999", isDirectory: true), files: 1)
            try fm.createSymbolicLink(at: linkedDir, withDestinationURL: outside)
        } catch {
            FileHandle.standardError.write(Data("FAIL 无法创建 fixture：\(error)\n".utf8))
            return false
        }

        let recorder = TrashRecorder(sink: sink)
        let fs = makeFileSystem(home: home, temporary: temporary, recorder: recorder)
        let extractCanonical = fs.canonicalPath(extracted)
        let imageCanonical = fs.canonicalPath(images)
        let store = OutputOwnershipStore(fileURL: ownershipURL)
        let audit = CleanupAuditLog(fileURL: auditURL, appVersion: "test")

        func recordNew(_ dir: URL, id: String, roots: [String]) -> OutputOwnershipStore.RecordOutcome {
            store.recordAfterExport(directory: dir, itemID: id,
                                    allowedCanonicalRoots: roots,
                                    eligibility: .newDirectory, fs: fs)
        }

        for (dir, id) in [(ownedDir, "2001"), (ownedSecond, "2002"), (ownedRefresh, "2003"),
                          (ownedCancelA, "2004"), (ownedCancelB, "2005"), (ownedExecA, "2006"),
                          (ownedExecB, "2007"), (ownedChange, "2008"), (ownedReplace, "2009"),
                          (ownedPartialA, "2010"), (ownedPartialB, "2011"), (ownedMissing, "2012"),
                          (ownedIntruded, "2013"), (ownedReplaced, "2014")] {
            _ = recordNew(dir, id: id, roots: [extractCanonical])
        }
        _ = recordNew(ownedImage, id: "3001", roots: [imageCanonical])

        let historyPaths = [sentinelDir.path, historyOnlyDir.path, legacyDisplayDir.path]

        func scan(_ store: OutputOwnershipStore,
                  history: [String] = historyPaths,
                  includeTemporary: Bool = true,
                  extractRoot: URL? = nil,
                  imageRoot: URL? = nil) -> StorageScanResult {
            StorageScanner.scanDetailed(extractRoot: extractRoot ?? extracted,
                                        imageRoot: imageRoot ?? images,
                                        historyPaths: history,
                                        includeTemporary: includeTemporary,
                                        ownership: store.snapshot(legacyPaths: history, fs: fs),
                                        fs: fs)
        }

        func item(_ name: String, in result: StorageScanResult) -> StorageItem? {
            result.items.first { $0.displayName == name }
        }

        // MARK: 归属可信度（反例核心）

        section("归属可信度：新建 / 可信续写 / 预存 / 混入用户文件 / 替换")
        // 1) 新建目录 → owned，可清理
        checkEqual(item("owned_2001", in: scan(store))?.ownership, OutputOwnershipLevel.owned, "新建目录 → owned")
        checkEqual(item("owned_2001", in: scan(store))?.isTrashable, true, "新建目录可清理")

        // 2) 纯应用目录重复导出 → 仍可清理（不能误禁）
        let refreshEligibility = OutputOwnershipStore.exportEligibility(
            directory: ownedRefresh,
            existingRecord: store.ownedRecord(forCanonicalPath: fs.canonicalPath(ownedRefresh)),
            fs: fs)
        checkEqual(refreshEligibility, .trustedOwned, "纯应用目录重复导出判定为可信")
        let refreshOutcome = store.recordAfterExport(directory: ownedRefresh, itemID: "2003",
                                                     allowedCanonicalRoots: [extractCanonical],
                                                     eligibility: .trustedOwned, fs: fs)
        if case .owned = refreshOutcome { check(true, "可信续写刷新 owned") } else { check(false, "可信续写应保持 owned") }
        checkEqual(item("owned_refresh_2003", in: scan(store))?.isTrashable, true, "纯应用重复导出仍可清理")

        // 3) 预存目录（含用户哨兵文件）→ untrusted，导出也不得授权清理
        let sentinelEligibility = OutputOwnershipStore.exportEligibility(
            directory: sentinelDir, existingRecord: nil, fs: fs)
        checkEqual(sentinelEligibility, .untrusted, "预存目录判定为 untrusted")
        let sentinelRecord = store.recordAfterExport(directory: sentinelDir, itemID: "2020",
                                                     allowedCanonicalRoots: [extractCanonical],
                                                     eligibility: sentinelEligibility, fs: fs)
        if case .rejected = sentinelRecord { check(true, "预存目录导出后拒绝登记") } else { check(false, "预存目录不得登记") }
        let sentinelScan = scan(store)
        checkEqual(item("sentinel_preexisting_2020", in: sentinelScan)?.ownership,
                   OutputOwnershipLevel.unknown, "预存目录保持 unknown（含用户文件）")
        checkEqual(item("sentinel_preexisting_2020", in: sentinelScan)?.isTrashable, false,
                   "预存目录不可清理")
        if let sentinelItem = item("sentinel_preexisting_2020", in: sentinelScan) {
            let sentinelPlan = StorageScanner.makePlan(items: [sentinelItem], roots: [extractCanonical], fs: fs)
            checkEqual(sentinelPlan.items.count, 0, "预存目录不得进入清理计划")
            let allSelection = StorageCleanupSummary.trashableSelection(
                Set(sentinelScan.items.map(\.id)), items: sentinelScan.items)
            check(!allSelection.contains(sentinelItem.id), "全选不得包含预存目录")
        }

        // 4) owned 目录混入用户文件 → untrusted，重新导出也不得刷新接管
        try? Data(repeating: 0x66, count: 64)
            .write(to: ownedIntruded.appendingPathComponent("user-intruded.bin"))
        let intrudedEligibility = OutputOwnershipStore.exportEligibility(
            directory: ownedIntruded,
            existingRecord: store.ownedRecord(forCanonicalPath: fs.canonicalPath(ownedIntruded)),
            fs: fs)
        checkEqual(intrudedEligibility, .untrusted, "混入用户文件的 owned 目录判定为 untrusted")
        let intrudedRecord = store.recordAfterExport(directory: ownedIntruded, itemID: "2013",
                                                     allowedCanonicalRoots: [extractCanonical],
                                                     eligibility: intrudedEligibility, fs: fs)
        if case .rejected = intrudedRecord { check(true, "混入用户文件后重新导出拒绝登记") } else { check(false, "不得刷新接管") }
        checkEqual(item("owned_intruded_2013", in: scan(store))?.ownership,
                   OutputOwnershipLevel.unknown, "混入用户文件的目录只读")
        checkEqual(item("owned_intruded_2013", in: scan(store))?.isTrashable, false,
                   "混入用户文件的目录不可清理")

        // 5) 目录被替换 → untrusted，重新导出也不接管
        try? fm.removeItem(at: ownedReplaced)
        try? makeFolder(ownedReplaced)
        let replacedEligibility = OutputOwnershipStore.exportEligibility(
            directory: ownedReplaced,
            existingRecord: store.ownedRecord(forCanonicalPath: fs.canonicalPath(ownedReplaced)),
            fs: fs)
        checkEqual(replacedEligibility, .untrusted, "被替换目录判定为 untrusted")
        let replacedRecord = store.recordAfterExport(directory: ownedReplaced, itemID: "2014",
                                                     allowedCanonicalRoots: [extractCanonical],
                                                     eligibility: replacedEligibility, fs: fs)
        if case .rejected = replacedRecord { check(true, "被替换目录重新导出拒绝登记") } else { check(false, "被替换目录不得接管") }
        checkEqual(item("owned_replaced_2014", in: scan(store))?.isTrashable, false, "被替换目录不可清理")

        // 6) 只有历史路径、仅名字相似、符号链接 → 只读
        checkEqual(item("history_only_2021", in: sentinelScan)?.ownership,
                   OutputOwnershipLevel.unknown, "仅历史路径 → 只读")
        checkEqual(item("看起来像产物_2031", in: sentinelScan)?.isTrashable, false, "仅名字相似 → 只读")
        checkEqual(item("linked_2032", in: sentinelScan)?.isTrashable, false, "符号链接 → 只读")
        check(sentinelScan.items.contains { $0.displayName == "nested_9999" } == false,
              "嵌套目录不得作为独立条目")
        checkEqual(item("owned_3001", in: sentinelScan)?.ownership, OutputOwnershipLevel.owned, "图片根 owned")
        checkEqual(item("\(StorageScanner.tempPrefix)abc", in: sentinelScan)?.ownership,
                   OutputOwnershipLevel.temporary, "固定前缀临时目录为 temporary")
        checkEqual(item("\(StorageScanner.tempPrefix)abc", in: sentinelScan)?.isTrashable, true,
                   "临时目录可清理（完整指纹）")

        // 7) 旧版 v2 文件里的 legacy 绑定：展示但只读
        let legacyStoreURL = base.appendingPathComponent("Ownership/legacy-display.json")
        try? fm.createDirectory(at: legacyStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyPayload: [String: Any] = [
            "version": 2,
            "owned": [:],
            "legacy": [
                fs.canonicalPath(legacyDisplayDir): [
                    "canonicalPath": fs.canonicalPath(legacyDisplayDir),
                    "itemID": "2022",
                    "recordedAt": 0,
                    "device": 0,
                    "inode": 0,
                    "contentFingerprint": "legacy-fingerprint",
                    "fingerprintComplete": true,
                    "entryCount": 1,
                ],
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: legacyPayload) {
            try? data.write(to: legacyStoreURL)
        }
        let legacyStore = OutputOwnershipStore(fileURL: legacyStoreURL)
        let legacyScan = scan(legacyStore)
        checkEqual(item("legacy_display_2022", in: legacyScan)?.ownership,
                   OutputOwnershipLevel.legacy, "legacy 绑定可展示")
        checkEqual(item("legacy_display_2022", in: legacyScan)?.isTrashable, false,
                   "legacy 仅展示、不可清理")

        // MARK: 根边界

        section("输出根边界")
        check(StorageRootPolicy.assess(root: home, role: .image, fs: fs).isSafe == false, "家目录不安全")
        check(StorageRootPolicy.assess(root: pictures, role: .image, fs: fs).isSafe == false, "~/Pictures 不安全")
        check(StorageRootPolicy.assess(root: documents, role: .extract, fs: fs).isSafe == false, "~/Documents 不安全")
        check(StorageRootPolicy.assess(root: URL(fileURLWithPath: "/"), role: .image, fs: fs).isSafe == false, "根目录不安全")
        check(StorageRootPolicy.assess(root: extracted, role: .extract, fs: fs).isSafe, "专用输出目录安全")
        check(StorageRootPolicy.assess(root: images, role: .image, fs: fs).isSafe, "图片根安全")
        check(StorageRootPolicy.assess(root: temporary, role: .temporary, fs: fs).isSafe, "注入临时根安全")

        let badRootScan = scan(store, history: [], includeTemporary: false, extractRoot: home)
        checkEqual(badRootScan.rootVerdicts[.extract]?.isSafe, false, "家目录根判定")
        check(badRootScan.rootWarnings.isEmpty == false, "根范围过大必须告警")
        let badRootItems = badRootScan.items.filter {
            $0.kind == .extracted || $0.rootCanonicalPath == fs.canonicalPath(home)
        }
        check(!badRootItems.isEmpty && badRootItems.allSatisfy { !$0.isTrashable },
              "根范围过大时该根下条目全部只读")

        let sameRootScan = StorageScanner.scanDetailed(extractRoot: extracted, imageRoot: extracted,
                                                       includeTemporary: false,
                                                       ownership: store.snapshot(legacyPaths: [], fs: fs), fs: fs)
        check(sameRootScan.rootWarnings.contains { $0.contains("相同") }, "相同根必须告警")
        check(sameRootScan.items.allSatisfy { !$0.isTrashable }, "相同根下全部只读")

        let nestedRootScan = StorageScanner.scanDetailed(
            extractRoot: extracted,
            imageRoot: extracted.appendingPathComponent("nested_9999"),
            includeTemporary: false,
            ownership: store.snapshot(legacyPaths: [], fs: fs), fs: fs)
        check(nestedRootScan.rootWarnings.contains { $0.contains("内部") }, "嵌套根必须告警")

        // 根 symlink 按真实路径工作
        let aliasRoot = base.appendingPathComponent("Alias", isDirectory: true)
        try? fm.removeItem(at: aliasRoot)
        try? fm.createSymbolicLink(at: aliasRoot, withDestinationURL: extracted)
        let aliasScan = StorageScanner.scanDetailed(extractRoot: aliasRoot, imageRoot: images,
                                                    includeTemporary: false,
                                                    ownership: store.snapshot(legacyPaths: [], fs: fs), fs: fs)
        checkEqual(item("owned_2001", in: aliasScan)?.ownership, OutputOwnershipLevel.owned,
                   "符号链接根按真实路径归属")
        try? fm.removeItem(at: aliasRoot)

        // MARK: 损坏 / 篡改 / 写入失败

        section("归属数据损坏、标记篡改、写入失败")
        let corruptURL = base.appendingPathComponent("Ownership/corrupt.json")
        try? "not json".write(to: corruptURL, atomically: true, encoding: .utf8)
        let corruptStore = OutputOwnershipStore(fileURL: corruptURL)
        check(corruptStore.warning != nil, "损坏归属文件必须告警且不崩溃")
        check(!fm.fileExists(atPath: corruptURL.path), "损坏文件应被移走")
        check(fm.fileExists(atPath: corruptURL.appendingPathExtension("corrupt").path), "损坏证据保留")
        let corruptScan = scan(corruptStore)
        check(corruptScan.items.allSatisfy { !$0.isTrashable || $0.kind == .temporary },
              "归属文件损坏后除临时目录外全部只读")

        let markerURL = ownedDir.appendingPathComponent(OutputMarker.fileName)
        try? OutputOwnershipStore.writeMarkerFile(
            in: ownedDir,
            marker: OutputMarker(token: "tampered-token", itemID: "2001", recordedAt: Date()))
        checkEqual(item("owned_2001", in: scan(store))?.ownership,
                   OutputOwnershipLevel.unknown, "标记与记录不一致 → 只读")
        try? fm.removeItem(at: markerURL)
        _ = store.recordAfterExport(directory: ownedDir, itemID: "2001",
                                    allowedCanonicalRoots: [extractCanonical],
                                    eligibility: .trustedOwned, fs: fs)

        let markerFailDir = extracted.appendingPathComponent("marker_fail_2100", isDirectory: true)
        try? makeFolder(markerFailDir)
        let markerFailStore = OutputOwnershipStore(
            fileURL: base.appendingPathComponent("Ownership/marker-fail.json"),
            persistence: OwnershipPersistence(
                writeStore: { data, url in try data.write(to: url, options: .atomic) },
                writeMarker: { _, _ in throw NSError(domain: "test", code: 1) }))
        if case .rejected = markerFailStore.recordAfterExport(directory: markerFailDir, itemID: "2100",
                                                              allowedCanonicalRoots: [extractCanonical],
                                                              eligibility: .newDirectory, fs: fs) {
            check(true, "标记写入失败必须拒绝登记")
        } else { check(false, "标记写入失败不得登记") }
        check(markerFailStore.snapshot(legacyPaths: [], fs: fs).recordsByCanonicalPath.isEmpty,
              "标记失败后无 owned 残留")

        let storeFailDir = extracted.appendingPathComponent("store_fail_2101", isDirectory: true)
        try? makeFolder(storeFailDir)
        let storeFailStore = OutputOwnershipStore(
            fileURL: base.appendingPathComponent("Ownership/store-fail.json"),
            persistence: OwnershipPersistence(
                writeStore: { _, _ in throw NSError(domain: "test", code: 2) },
                writeMarker: { directory, marker in
                    try OutputOwnershipStore.writeMarkerFile(in: directory, marker: marker)
                }))
        if case .rejected = storeFailStore.recordAfterExport(directory: storeFailDir, itemID: "2101",
                                                             allowedCanonicalRoots: [extractCanonical],
                                                             eligibility: .newDirectory, fs: fs) {
            check(true, "归属记录写入失败必须拒绝登记")
        } else { check(false, "写入失败不得登记") }
        check(storeFailStore.snapshot(legacyPaths: [], fs: fs).recordsByCanonicalPath.isEmpty,
              "写入失败后无 owned 残留")

        let silentURL = base.appendingPathComponent("Ownership/silent.json")
        try? fm.createDirectory(at: silentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "{\"version\":2,\"owned\":{},\"legacy\":{}}".write(to: silentURL, atomically: true, encoding: .utf8)
        let silentStore = OutputOwnershipStore(
            fileURL: silentURL,
            persistence: OwnershipPersistence(
                writeStore: { _, _ in /* 静默失败 */ },
                writeMarker: { directory, marker in
                    try OutputOwnershipStore.writeMarkerFile(in: directory, marker: marker)
                }))
        let silentDir = extracted.appendingPathComponent("silent_fail_2102", isDirectory: true)
        try? makeFolder(silentDir)
        if case .rejected = silentStore.recordAfterExport(directory: silentDir, itemID: "2102",
                                                          allowedCanonicalRoots: [extractCanonical],
                                                          eligibility: .newDirectory, fs: fs) {
            check(true, "静默写入失败必须拒绝登记（回读校验）")
        } else { check(false, "静默写入失败不得登记") }

        let reloaded = OutputOwnershipStore(fileURL: ownershipURL)
        check(reloaded.ownedRecord(forCanonicalPath: fs.canonicalPath(ownedDir)) != nil,
              "成功登记后重新加载仍存在")

        // MARK: 指纹完整性

        section("内容指纹完整性边界")
        let fpDir = base.appendingPathComponent("Fingerprint/limited", isDirectory: true)
        try? makeFolder(fpDir, files: 5)
        let partialFP = StorageContentFingerprint.compute(for: fpDir, entryLimit: 2)
        checkEqual(partialFP?.complete, false, "超过上限的指纹标记不完整")
        let partialIdentity = StorageItemIdentity(canonicalPath: fs.canonicalPath(fpDir),
                                                  device: 1, inode: 1, isDirectory: true,
                                                  sizeBytes: 0, modifiedSeconds: 0,
                                                  contentFingerprint: partialFP?.hash,
                                                  fingerprintComplete: false,
                                                  entryCount: partialFP?.entryCount ?? 0)
        let partialItem = StorageItem(url: fpDir, kind: .extracted, displayName: fpDir.lastPathComponent,
                                      sizeBytes: 0, fileCount: 0, modified: nil,
                                      ownership: .owned, isTrashable: true,
                                      identity: partialIdentity)
        let partialPlan = StorageScanner.makePlan(items: [partialItem], roots: [extractCanonical], fs: fs)
        checkEqual(partialPlan.items.count, 0, "指纹不完整不得进入计划")

        // MARK: 计划 / 执行攻击面

        section("计划与执行：根变化 / 父路径重定向 / 重复 / 根自身")
        let roots = [extractCanonical, imageCanonical, fs.canonicalPath(temporary)]
        let planScan = scan(store)
        guard let planOwned = item("owned_2001", in: planScan),
              let planUnknown = item("sentinel_preexisting_2020", in: planScan) else {
            FileHandle.standardError.write(Data("FAIL 计划用例缺少条目\n".utf8))
            return false
        }
        let plan = StorageScanner.makePlan(items: [planOwned, planUnknown], roots: roots, fs: fs)
        checkEqual(plan.items.count, 1, "只接受 owned")
        checkEqual(plan.rejections.count, 1, "unknown 必须被拒绝")

        let rootItem = StorageItem(url: extracted, kind: .extracted,
                                   displayName: extracted.lastPathComponent,
                                   sizeBytes: 0, fileCount: 0, modified: nil,
                                   ownership: .owned, isTrashable: true,
                                   identity: StorageItemIdentity.readFull(from: extracted))
        checkEqual(StorageScanner.makePlan(items: [rootItem], roots: roots, fs: fs).items.count, 0,
                   "输出根自身不得进入计划")

        let parentItem = StorageItem(url: extracted.appendingPathComponent(".."),
                                     kind: .extracted, displayName: "..",
                                     sizeBytes: 0, fileCount: 0, modified: nil,
                                     ownership: .owned, isTrashable: true,
                                     identity: StorageItemIdentity.readFull(from: extracted.appendingPathComponent("..")))
        let parentPlan = StorageScanner.makePlan(items: [parentItem], roots: roots, fs: fs)
        checkEqual(parentPlan.items.count, 0, "根上级不得进入计划")

        let duplicatePlan = StorageScanner.makePlan(items: [planOwned, planOwned], roots: roots, fs: fs)
        checkEqual(duplicatePlan.items.count, 1, "重复条目只保留一个")
        checkEqual(duplicatePlan.rejections.count, 1, "重复条目记录拒绝")

        let changedRootsOutcome = StorageScanner.execute(plan: plan, fs: fs, audit: audit,
                                                         currentRoots: [imageCanonical])
        checkEqual(changedRootsOutcome.trashed.count, 0, "输出根变化后不得执行")
        check(changedRootsOutcome.skipped.count >= 1, "根变化记录跳过")

        let redirectPlan = StorageScanner.makePlan(items: [planOwned], roots: roots, fs: fs)
        let movedRoot = base.appendingPathComponent("Extracted-moved", isDirectory: true)
        try? fm.moveItem(at: extracted, to: movedRoot)
        try? fm.createSymbolicLink(at: extracted, withDestinationURL: attacker)
        let attackerOwned = attacker.appendingPathComponent("owned_2001", isDirectory: true)
        try? makeFolder(attackerOwned)
        let redirectOutcome = StorageScanner.execute(plan: redirectPlan, fs: fs, audit: audit,
                                                     currentRoots: roots)
        checkEqual(redirectOutcome.trashed.count, 0, "父路径重定向后不得执行")
        check(fm.fileExists(atPath: attackerOwned.path), "重定向目标不被移动")
        try? fm.removeItem(at: extracted)
        try? fm.moveItem(at: movedRoot, to: extracted)

        // case-insensitive
        let caseDir = extracted.appendingPathComponent("CaseDir_9001", isDirectory: true)
        try? makeFolder(caseDir)
        _ = store.recordAfterExport(directory: caseDir, itemID: "9001",
                                    allowedCanonicalRoots: [extractCanonical],
                                    eligibility: .newDirectory, fs: fs)
        let caseVariant = extracted.appendingPathComponent("casedir_9001", isDirectory: true)
        let caseInsensitive = fm.fileExists(atPath: caseVariant.path)
        let caseA = StorageItem(url: caseDir, kind: .extracted, displayName: "CaseDir_9001",
                                sizeBytes: 0, fileCount: 0, modified: nil,
                                ownership: .owned, isTrashable: true,
                                identity: StorageItemIdentity.readFull(from: caseDir))
        let caseB = StorageItem(url: caseVariant, kind: .extracted, displayName: "casedir_9001",
                                sizeBytes: 0, fileCount: 0, modified: nil,
                                ownership: .owned, isTrashable: true,
                                identity: caseInsensitive ? StorageItemIdentity.readFull(from: caseVariant) : nil)
        let casePlan = StorageScanner.makePlan(items: [caseA, caseB], roots: roots, fs: fs)
        if caseInsensitive {
            check(casePlan.items.count <= 1, "大小写变体最多一个进入计划")
            checkEqual(casePlan.items.count + casePlan.rejections.count, 2, "两个写法都有结论")
        } else {
            checkEqual(casePlan.items.count, 0, "大小写敏感时错误写法不得进入计划")
        }

        // MARK: 取消 / 成功 / 状态变化

        section("取消确认：不移动任何文件")
        let cancelScan = scan(store)
        guard let cancelA = item("owned_cancel_a_2004", in: cancelScan),
              let cancelB = item("owned_cancel_b_2005", in: cancelScan) else {
            FileHandle.standardError.write(Data("FAIL 取消用例缺少条目\n".utf8))
            return false
        }
        let cancelPlan = StorageScanner.makePlan(items: [cancelA, cancelB], roots: roots, fs: fs)
        checkEqual(cancelPlan.items.count, 2, "取消用例计划就绪")
        audit.record(.request, planID: cancelPlan.id,
                     items: cancelPlan.items.map { StorageScanner.auditItem($0) })
        audit.record(.cancelled, planID: cancelPlan.id,
                     items: cancelPlan.items.map { StorageScanner.auditItem($0) })
        checkEqual(recorder.attempts.count, 0, "取消后不得调用 trash")
        check(fm.fileExists(atPath: ownedCancelA.path), "取消后目录保留")
        check(!audit.readAllEntries().contains { $0.event == "completed" && $0.planID == cancelPlan.id.uuidString },
              "取消不产生该计划的完成记录")

        section("确认执行：移入 sink 并写审计")
        let execPlan = StorageScanner.makePlan(items: [cancelA, cancelB], roots: roots, fs: fs)
        audit.record(.request, planID: execPlan.id,
                     items: execPlan.items.map { StorageScanner.auditItem($0) })
        audit.record(.confirmed, planID: execPlan.id,
                     items: execPlan.items.map { StorageScanner.auditItem($0) })
        let execOutcome = StorageScanner.execute(plan: execPlan, fs: fs, audit: audit, currentRoots: roots)
        checkEqual(execOutcome.trashed.count, 2, "两项移入 sink")
        check(fm.fileExists(atPath: sink.appendingPathComponent("owned_cancel_a_2004").path), "A 进入 sink")
        check(fm.fileExists(atPath: sink.appendingPathComponent("owned_cancel_b_2005").path), "B 进入 sink")
        let execEvents = audit.readAllEntries()
        check(execEvents.contains { $0.event == "completed" && ($0.note ?? "").contains("trashed=2") },
              "完成记录计数")
        try? fm.removeItem(at: sink)

        section("确认前后变化 / 替换 / 缺失")
        let changeScan = scan(store)
        guard let changeItem = item("owned_change_2008", in: changeScan) else {
            FileHandle.standardError.write(Data("FAIL 变化用例缺少条目\n".utf8))
            return false
        }
        let changePlan2 = StorageScanner.makePlan(items: [changeItem], roots: roots, fs: fs)
        try? Data(repeating: 0x43, count: 64).write(to: ownedChange.appendingPathComponent("late.bin"))
        let changeOutcome = StorageScanner.execute(plan: changePlan2, fs: fs, audit: audit, currentRoots: roots)
        checkEqual(changeOutcome.trashed.count, 0, "确认前内容变化不得执行")
        checkEqual(changeOutcome.skipped.count, 1, "内容变化记为跳过")
        check(fm.fileExists(atPath: ownedChange.path), "内容变化时目录保留")

        let replaceScan = scan(store)
        guard let replaceItem = item("owned_replace_2009", in: replaceScan) else {
            FileHandle.standardError.write(Data("FAIL 替换用例缺少条目\n".utf8))
            return false
        }
        let replacePlan = StorageScanner.makePlan(items: [replaceItem], roots: roots, fs: fs)
        try? fm.removeItem(at: ownedReplace)
        try? fm.createSymbolicLink(at: ownedReplace, withDestinationURL: outside)
        let replaceOutcome = StorageScanner.execute(plan: replacePlan, fs: fs, audit: audit, currentRoots: roots)
        checkEqual(replaceOutcome.trashed.count, 0, "被替换为符号链接不得执行")
        check(fm.fileExists(atPath: outside.path), "符号链接目标不被移动")
        try? fm.removeItem(at: ownedReplace)

        section("部分失败与权限拒绝（注入故障）")
        let partialScan = scan(store)
        guard let partialA = item("owned_partial_a_2010", in: partialScan),
              let partialB = item("owned_partial_b_2011", in: partialScan) else {
            FileHandle.standardError.write(Data("FAIL 部分失败用例缺少条目\n".utf8))
            return false
        }
        let partialPlan2 = StorageScanner.makePlan(items: [partialA, partialB], roots: roots, fs: fs)
        recorder.failOn(suffixes: ["owned_partial_b_2011"])
        let partialOutcome = StorageScanner.execute(plan: partialPlan2, fs: fs, audit: audit, currentRoots: roots)
        recorder.failOn(suffixes: [])
        checkEqual(partialOutcome.trashed.count, 1, "一项成功")
        checkEqual(partialOutcome.failed.count, 1, "一项权限失败")
        check(partialOutcome.failed.first?.reason.contains("权限") == true, "失败原因说明权限")
        check(fm.fileExists(atPath: ownedPartialB.path), "失败项保留")
        check(audit.readAllEntries().contains { $0.items?.first?.result == "failed" }, "审计记录失败")

        section("确认前目录缺失")
        let missingScan = scan(store)
        guard let missingItem = item("owned_missing_2012", in: missingScan) else {
            FileHandle.standardError.write(Data("FAIL 缺失用例缺少条目\n".utf8))
            return false
        }
        let missingPlan = StorageScanner.makePlan(items: [missingItem], roots: roots, fs: fs)
        try? fm.moveItem(at: ownedMissing, to: base.appendingPathComponent("moved-away"))
        let missingOutcome = StorageScanner.execute(plan: missingPlan, fs: fs, audit: audit, currentRoots: roots)
        checkEqual(missingOutcome.trashed.count, 0, "缺失目录不得执行")
        checkEqual(missingOutcome.skipped.count, 1, "缺失目录记为跳过")
        try? fm.moveItem(at: base.appendingPathComponent("moved-away"), to: ownedMissing)

        // MARK: 审计日志

        section("审计日志：权限、轮转、并发尾写、无图片内容")
        let attributes = try? fm.attributesOfItem(atPath: auditURL.path)
        checkEqual((attributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600, "审计日志权限 0600")
        let logText = (try? String(contentsOf: auditURL, encoding: .utf8)) ?? ""
        check(logText.contains("\"cancelled\""), "含取消事件")
        check(logText.contains("\"completed\""), "含完成事件")
        check(!logText.lowercased().contains(".png")
              && !logText.lowercased().contains(".gif")
              && !logText.lowercased().contains(".jpg"), "不含图片文件名")

        let rotateURL = base.appendingPathComponent("Audit/rotate.jsonl")
        try? fm.createDirectory(at: rotateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(repeating: 0x0A, count: CleanupAuditLog.maxBytes + 1024).write(to: rotateURL)
        let rotateLog = CleanupAuditLog(fileURL: rotateURL, appVersion: "test")
        check(rotateLog.record(.cancelled, planID: UUID()), "轮转后仍可写")
        check(fm.fileExists(atPath: rotateURL.appendingPathExtension("1").path), "超限轮转到 .1")
        checkEqual(rotateLog.readAllEntries().count, 1, "轮转后新文件只有新记录")

        let concurrentURL = base.appendingPathComponent("Audit/concurrent.jsonl")
        let concurrentLog = CleanupAuditLog(fileURL: concurrentURL, appVersion: "test")
        DispatchQueue.concurrentPerform(iterations: 80) { index in
            _ = concurrentLog.record(.itemResult, planID: nil,
                                     items: [CleanupAuditLog.Item(path: "/isolated/entry-\(index)",
                                                                  kind: "extracted",
                                                                  ownership: "owned",
                                                                  sizeBytes: Int64(index))])
        }
        let concurrentEntries = concurrentLog.readAllEntries()
        checkEqual(concurrentEntries.count, 80, "并发追加不丢尾")
        check(concurrentEntries.contains { $0.items?.first?.path == "/isolated/entry-79" },
              "尾记录可读回")

        // MARK: 确认展示

        section("确认界面数据：路径/数量/大小/只读排除")
        let presentationScan = scan(store)
        guard let pOwned = item("owned_2001", in: presentationScan),
              let pSecond = item("owned_2002", in: presentationScan),
              let pSentinel = item("sentinel_preexisting_2020", in: presentationScan) else {
            FileHandle.standardError.write(Data("FAIL 展示用例缺少条目\n".utf8))
            return false
        }
        let presentationPlan = StorageScanner.makePlan(items: [pOwned, pSecond], roots: roots, fs: fs)
        let presentation = StorageCleanupSummary.make(plan: presentationPlan)
        checkEqual(presentation.itemCount, presentationPlan.items.count, "清单数量")
        check(presentation.rows.allSatisfy { $0.path.hasPrefix("/") }, "每行完整路径")
        check(presentation.headline.contains("个目录"), "标题含目录数量")
        check(presentation.headline.contains("个文件"), "标题含文件数量")
        check(presentation.safetyNote.contains("废纸篓"), "含可恢复说明")
        let mixedSelection = Set(presentationScan.items.map(\.id))
        let filtered = StorageCleanupSummary.trashableSelection(mixedSelection, items: presentationScan.items)
        check(!filtered.contains(pSentinel.id), "全选不含预存目录")
        check(filtered.contains(pOwned.id), "全选包含 owned 目录")
        check(StorageCleanupSummary.allTrashableSelected(filtered, items: presentationScan.items),
              "全部可清理项选中时 allSelected 为真")
        check(!StorageCleanupSummary.allTrashableSelected([], items: presentationScan.items),
              "空选择时 allSelected 为假")
        let emptyPlan = StorageScanner.makePlan(items: [], roots: roots, fs: fs)
        checkEqual(StorageCleanupSummary.make(plan: emptyPlan).itemCount, 0, "空计划数量 0")

        // MARK: 测试环境隔离

        section("冒烟导出 imageExportRoot 隔离")
        let noIsolation = TestEnvironmentIsolation.decision(
            exportImagesOnly: true, environment: [:], developmentRoot: nil,
            configuredImageRoot: URL(fileURLWithPath: "/Users/example/Pictures/MirageImages"))
        if case .refused = noIsolation { check(true, "缺隔离目录必须拒绝") } else { check(false, "缺隔离目录必须拒绝") }
        let withEnv = TestEnvironmentIsolation.decision(
            exportImagesOnly: true,
            environment: [TestEnvironmentIsolation.imageRootKey: base.appendingPathComponent("SmokeImages").path],
            developmentRoot: nil,
            configuredImageRoot: URL(fileURLWithPath: "/Users/example/Pictures/MirageImages"))
        if case .allowed(let url) = withEnv {
            checkEqual(url?.lastPathComponent, "SmokeImages", "使用显式隔离目录")
        } else { check(false, "提供隔离目录应允许") }
        let development = TestEnvironmentIsolation.decision(
            exportImagesOnly: true,
            environment: [PKDKitEnvironment.developmentRootKey: base.path],
            developmentRoot: base, configuredImageRoot: nil)
        if case .allowed(let url) = development {
            checkEqual(url?.lastPathComponent, "Images", "开发副本使用 <DEV_ROOT>/Images")
        } else { check(false, "开发副本应允许") }

        // MARK: 静态契约

        section("静态契约：接线点与确认面板")
        if let repoRoot = repoRootURL() {
            if let view = readSource(repoRoot.appendingPathComponent("app/Sources/PKDApp/Storage/StorageView.swift")) {
                check(view.contains("keyboardShortcut(.cancelAction)"), "取消绑定 Esc")
                check(view.contains("ScrollView"), "确认清单可滚动")
                check(view.contains("summary.rows"), "清单来自可测试展示数据")
                check(view.contains("role: .destructive"), "仅破坏性按钮执行清理")
                check(view.contains("disabled(plan.items.isEmpty)"), "空计划禁用破坏性按钮")
                check(!view.contains("storageConfirmCount"), "旧确认逻辑已移除")
            }
            if let model = readSource(repoRoot.appendingPathComponent("app/Sources/PKDApp/AppModel.swift")) {
                check(model.contains("exportEligibility("), "入队时计算可信快照")
                check(model.contains("pendingExportTargets"), "保存导出前快照")
                check(model.contains("eligibility: preState.eligibility"), "导出后按快照登记")
                check(!model.contains("wasCreated:"), "不再使用 wasCreated 简化判定")
                check(model.contains("cleanupAudit.record(.request"), "记录请求")
                check(model.contains("cleanupAudit.record(.cancelled"), "记录取消")
                check(model.contains("cleanupAudit.record(.confirmed"), "记录确认")
                check(model.contains("StorageScanner.execute(plan:"), "执行走计划")
                check(model.contains("currentRoots: storageRoots()"), "执行按当前根再校验")
                check(model.contains("TestEnvironmentIsolation.decision("), "冒烟隔离决策")
            }
            if let scanner = readSource(repoRoot.appendingPathComponent("app/Sources/PKDKit/Storage/StorageScanner.swift")) {
                check(scanner.contains("fingerprintComplete") || scanner.contains("identityFull"), "扫描使用完整内容指纹")
                check(scanner.contains("forbiddenTargetReason"), "执行前保护目标校验")
                check(scanner.contains("matchesExactly"), "确认前后快照比对")
                check(scanner.contains("isDirectChild"), "直接子项边界校验")
                check(scanner.contains("case .legacy"), "legacy 仅展示分支存在")
            }
        } else {
            print("· 静态契约：源码不可达（独立运行环境），已跳过")
        }

        if failures == 0, verbose {
            print("✅ 存储安全回归通过（\(checks) 项断言）")
            print("   fixture: \(base.path)")
        }
        return failures == 0
    }
}

// MARK: - 静态契约所需的最小文件读取

private func repoRootURL() -> URL? {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { url.deleteLastPathComponent() }
    return FileManager.default.fileExists(atPath: url.appendingPathComponent("app/Package.swift").path)
        ? url : nil
}

private func readSource(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

private enum PKDKitEnvironment {
    static let developmentRootKey = "PKD_DEVELOPMENT_ROOT"
}

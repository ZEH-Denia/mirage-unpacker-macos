import Foundation
import Combine
import AppKit
import SwiftUI
import PKDKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    /// 检查器的两个页面：详情与日志共用一个右栏
    enum InspectorTab: String, Hashable {
        case detail, logs
        var title: String { self == .detail ? "详情" : "日志" }
    }

    enum EngineStatus: Equatable {
        case unknown
        case ok(String)
        case missing([String])
        case broken(String)
    }

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all
        case extractable
        case notExtracted
        case extracted
        case favorites
        case recent

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "全部"
            case .extractable: return "可解包"
            case .notExtracted: return "未解包"
            case .extracted: return "已解包"
            case .favorites: return "收藏"
            case .recent: return "最近使用"
            }
        }
    }

    struct ConfirmRequest: Identifiable {
        let id = UUID()
        let items: [WallpaperItem]
        let estimateBytes: Int64
        let availableBytes: Int64?
    }

    // MARK: - 状态

    @Published var items: [WallpaperItem] = [] {
        didSet { filteredItemsCache = nil }
    }
    @Published var selection: Set<String> = []
    @Published var searchText: String = "" {
        didSet {
            if oldValue != searchText { filteredItemsCache = nil }
        }
    }
    /// 当前导航位置。筛选档位本身就是导航的一档，不再与页签分离。
    @Published var nav: NavItem = .library(.all) {
        didSet {
            guard nav != oldValue else { return }
            filteredItemsCache = nil
            // 离开素材库时清掉多选：否则工具栏的「解包所选」会在队列页仍然亮着
            if !nav.isLibrary { selection = [] }
        }
    }
    /// 检查器当前页
    @Published var inspectorTab: InspectorTab = .detail
    /// ⇧ 区间选择的锚点
    @Published var selectionAnchor: String?
    /// 窄窗放不下检查器时，用这个弹详情
    @Published var isDetailSheetPresented = false
    @Published var infoCache: [String: PkgInfo] = [:]
    @Published var loadingInfo: Set<String> = []
    @Published var engineStatus: EngineStatus = .unknown
    @Published var isScanning = false
    /// 侧栏可见性（@State 在本工具链不可用，状态一律放这里）
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    /// 日志检查器是否展开
    @Published var isInspectorPresented: Bool = false
    @Published var pendingConfirm: ConfirmRequest?
    @Published var alertMessage: String?
    @Published var exportGallery: ExportGalleryRequest?
    @Published var isImporting = false
    @Published var isDropTargeted = false
    private var importedItems: [WallpaperItem] = []
    let collections = LibraryCollections(fileURL: DevelopmentEnvironment.root?.appendingPathComponent("History/collections.json"))

    // MARK: 素材库查询

    /// 排序偏好写进 defaults，下次启动沿用
    @Published var sort: LibrarySort = AppModel.loadSort() {
        didSet {
            guard sort != oldValue else { return }
            UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey)
            filteredItemsCache = nil
        }
    }

    /// 卡片和详情中显示的 X-Ray 读取状态。
    @Published private(set) var xrayStatus: [String: XRayStatus] = [:]

    private static let sortKey = "pkd.library.sort"

    private static func loadSort() -> LibrarySort {
        LibrarySort(rawValue: UserDefaults.standard.string(forKey: sortKey) ?? "") ?? .titleAsc
    }

    // 存储清理
    @Published var storageItems: [StorageItem] = []
    @Published var storageSelection: Set<String> = []
    @Published var isScanningStorage = false
    /// 输出根范围告警（例如根被设成家目录 / 图片目录时给出）
    @Published var storageRootWarnings: [String] = []
    /// 确认面板对应的清理计划；非空时界面必须显示完整路径清单
    @Published var pendingStoragePlan: CleanupPlan?
    @Published var storageResultMessage: String?

    let settings: SettingsStore
    let history: HistoryStore
    let log: LogSink
    let queue: JobQueue
    /// 产物归属记录（应用私有，0600，不进入 Git）
    let ownershipStore: OutputOwnershipStore
    /// 清理审计日志（只含目录路径/大小/结果，不含任何图片内容）
    let cleanupAudit: CleanupAuditLog
    /// 本次导出目标目录的「导出前是否已存在」快照：只有导出前不存在的目录才登记为 owned，
    /// 已存在的目录只登记 legacy 身份绑定（避免把用户预存目录接管为可清理产物）。
    private var pendingExportTargets: [UUID: (url: URL, eligibility: ExportEligibility)] = [:]
    /// 日志检查器的控制器放在这里，菜单栏「清空日志」才能拿到它
    let logController = LogController()

    private var filteredItemsCache: [WallpaperItem]?
    private let packageInfoCache = PackageInfoCache(directory: DevelopmentEnvironment.root?.appendingPathComponent("Cache"))

    // MARK: - 窗口布局

    enum WindowLayout: String {
        case wide, medium, narrow
    }

    /// 由窗口宽度推导的布局档位，驱动工具栏降级与页面自适应
    @Published private(set) var layout: WindowLayout = .wide

    /// 窗口窄到放不下右侧检查器：此时详情改用弹出面板
    @Published private(set) var compactDetailMode = false

    /// 自动折叠前的用户意图，用于放大后恢复
    private var savedInspectorIntent = false
    private var autoCollapsedInspector = false
    private var savedColumnVisibility: NavigationSplitViewVisibility = .all
    private var autoCollapsedSidebar = false

    /// 供 AppDelegate 在退出时取用
    static weak var current: AppModel?

    private var cancellables: Set<AnyCancellable> = []
    private var prefetchTask: Task<Void, Never>?

    init() {
        let settings = SettingsStore()
        if let root = DevelopmentEnvironment.root {
            settings.libraryRoot = root.appendingPathComponent("Library")
            settings.outputRoot = root.appendingPathComponent("Extracted")
            settings.imageExportRoot = root.appendingPathComponent("Images")
            settings.exportImagesOnly = true
            settings.openFinderWhenDone = false
        }
        let history = HistoryStore(fileURL: DevelopmentEnvironment.root?.appendingPathComponent("History/history.json"))
        let log = LogSink(logDirectory: DevelopmentEnvironment.root?.appendingPathComponent("Logs"))
        self.settings = settings
        self.history = history
        self.log = log
        self.queue = JobQueue(engineURL: nil, log: log)
        // Only lifecycle wiring: remove abandoned PKD-temp directories from a
        // previous crashed/KILLed instance. Unknown/recent/active dirs are kept.
        queue.cleanupAbandonedTemporaryOutputs()

        // 支持目录：正式版为 ~/Library/Application Support/PKD；开发副本落在隔离根目录。
        let supportBase = DevelopmentEnvironment.root
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/PKD", isDirectory: true)
        self.ownershipStore = OutputOwnershipStore(
            fileURL: supportBase.appendingPathComponent(OutputOwnershipStore.defaultFileName)
        )
        self.cleanupAudit = CleanupAuditLog(
            fileURL: supportBase.appendingPathComponent("CleanupAudit", isDirectory: true)
                .appendingPathComponent("cleanup-audit.jsonl")
        )

        queue.concurrency = max(1, settings.maxConcurrentJobs)
        queue.onFinished = { [weak self] job in
            self?.handleFinished(job)
        }

        AppModel.current = self
        collections.objectWillChange.sink { [weak self] _ in
            self?.filteredItemsCache = nil
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // 把嵌套对象的变更转发给本对象，视图只需观察 AppModel
        history.objectWillChange
            .sink { [weak self] _ in
                self?.filteredItemsCache = nil
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        for publisher in [settings.objectWillChange.eraseToAnyPublisher(),
                          queue.objectWillChange.eraseToAnyPublisher(),
                          logController.objectWillChange.eraseToAnyPublisher()] {
            publisher
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        }

        bootstrapEngine()
        refresh()
        if !DevelopmentEnvironment.isDevelopment { runSmokeExtractionIfRequested() }
        runDevelopmentScenarioIfRequested()

        // 冒烟钩子：pkd.debug.tab=storage/queue/extracted/... 时直接落到对应导航
        let debugDefaults = UserDefaults.standard
        let debugTab = ProcessInfo.processInfo.environment["PKD_SMOKE_TAB"]
            ?? debugDefaults.string(forKey: "pkd.debug.tab")
        switch debugTab {
        case "storage":
            nav = .storage
            refreshStorage()
        case "queue":
            nav = .queue
        case "extracted":
            nav = .library(.extracted)
        case "notExtracted":
            nav = .library(.notExtracted)
        case "extractable":
            nav = .library(.extractable)
        default:
            break
        }
        // 冒烟钩子：pkd.debug.fakeLogs=1 时灌入 300 行日志，用于检查滚动条外观
        if debugDefaults.bool(forKey: "pkd.debug.fakeLogs") {
            for index in 0..<300 {
                log.append(jobID: nil, text: "测试日志行 \(index) — Lorem ipsum dolor sit amet, consectetur adipiscing elit.", kind: .stdout)
            }
        }

        // 冒烟钩子：pkd.debug.stress=1 时每 0.8s 轮换导航，用于验证切换是否卡顿
        if debugDefaults.bool(forKey: "pkd.debug.stress") {
            Task { [weak self] in
                var index = 0
                let destinations: [NavItem] = [.library(.all), .library(.extractable), .queue, .storage]
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard let self else { return }
                    self.nav = destinations[index % destinations.count]
                    index += 1
                }
            }
        }

        // 冒烟钩子：pkd.debug.sheet=1 时选中首项并弹出详情面板（窄窗兜底验证）
        if debugDefaults.bool(forKey: "pkd.debug.sheet") {
            Task { [weak self] in
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self else { return }
                    if let item = self.items.first(where: { $0.isExtractable }) {
                        self.selection = [item.id]
                        self.isDetailSheetPresented = true
                        return
                    }
                }
            }
        }

        // 冒烟钩子：pkd.debug.inspectorTab=logs 时检查器直接停在日志页
        if debugDefaults.string(forKey: "pkd.debug.inspectorTab") == "logs" {
            inspectorTab = .logs
        }

        // 冒烟钩子：PKD_SMOKE_INSPECTOR=1 展开日志检查器；PKD_SMOKE_SELECT=1 选中首项
        if ProcessInfo.processInfo.environment["PKD_SMOKE_INSPECTOR"] != nil
            || debugDefaults.bool(forKey: "pkd.debug.inspector") {
            isInspectorPresented = true
        }
        if ProcessInfo.processInfo.environment["PKD_SMOKE_SELECT"] != nil
            || debugDefaults.bool(forKey: "pkd.debug.select") {
            Task { [weak self] in
                // 素材库是异步扫描的，固定延时可能早于 items 就绪；
                // 轮询等待，最多 15 秒，供截图回归稳定选中首项。
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self else { return }
                    if let item = self.items.first(where: { $0.isExtractable }) {
                        self.selection = [item.id]
                        return
                    }
                }
            }
        }
    }

    /// 冒烟测试钩子：`PKD_SMOKE_PKG=<pkg 绝对路径>` 启动时自动解包该包。
    /// 仅用于无 UI 自动化权限时的端到端验证，不影响正常使用。
    ///
    /// 数据安全：仅导出图片模式必须提供隔离的图片目录
    /// （`PKD_SMOKE_IMAGE_ROOT` 或 `PKD_DEVELOPMENT_ROOT`），否则拒绝执行，
    /// 避免自动化把测试产物写进正式用户的默认图片目录。
    private func runSmokeExtractionIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment[TestEnvironmentIsolation.pkgKey], !path.isEmpty else {
            return
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }

            let originalOutputRoot = self.settings.outputRoot
            let originalImageRoot = self.settings.imageExportRoot
            defer {
                self.settings.outputRoot = originalOutputRoot
                self.settings.imageExportRoot = originalImageRoot
            }

            let decision = TestEnvironmentIsolation.decision(
                exportImagesOnly: self.settings.exportImagesOnly,
                environment: environment,
                developmentRoot: DevelopmentEnvironment.root,
                configuredImageRoot: originalImageRoot
            )
            switch decision {
            case .refused(let reason):
                let message = "冒烟导出已拒绝：\(reason)"
                self.log.append(jobID: nil, text: message, kind: .warning)
                self.alertMessage = message
                return
            case .allowed(let isolatedImageRoot):
                if let isolatedImageRoot {
                    self.settings.imageExportRoot = isolatedImageRoot
                }
                if !self.settings.exportImagesOnly,
                   let output = environment[TestEnvironmentIsolation.outputRootKey], !output.isEmpty {
                    self.settings.outputRoot = URL(fileURLWithPath: output)
                }
            }

            guard let item = self.items.first(where: { $0.pkgURL?.path == path }) else {
                self.alertMessage = "冒烟测试：素材库中未找到 \(path)"
                return
            }

            self.settings.confirmBeforeStart = false
            self.selection = [item.id]
            self.performExtraction([item])
        }
    }

    /// 可重复的占位场景验收入口，不接受用户素材路径。
    private func runDevelopmentScenarioIfRequested() {
        if runLibraryDevelopmentScenarioIfRequested() { return }
        guard let root = DevelopmentEnvironment.root,
              ProcessInfo.processInfo.environment["PKD_DEVELOPMENT_SCENARIO"] == "layers" else { return }
        Task {
            for _ in 0..<300 {
                if !isScanning && queue.engineURL != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let item = items.first(where: { $0.id == "800011" }) else { return }
            settings.imageConflictPolicy = .overwrite
            performExtraction([item])
            for _ in 0..<600 {
                if queue.activeCount == 0 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let job = queue.jobs.last, let result = job.exportedImages else { return }
            exportGallery = ExportGalleryRequest(title: item.title, directory: result.directory)
            let report: [String: Any] = ["state": job.state.label, "files": result.files, "skipped": result.skippedFiles,
                                       "hasPreview": FileManager.default.fileExists(atPath: result.directory.appendingPathComponent(ExperimentalPuppetPreview.outputName).path)]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("layers-validation.json"), options: .atomic)
            }
        }
    }

    // MARK: - 派生数据

    /// 兼容旧调用点的读写入口：筛选就是 `.library(filter)` 这一档导航
    var filter: LibraryFilter {
        get {
            if case .library(let filter) = nav { return filter }
            return .all
        }
        set { nav = .library(newValue) }
    }

    var filteredItems: [WallpaperItem] {
        if let cached = filteredItemsCache { return cached }

        let result = items.filter { item in
            if !searchText.isEmpty {
                let matches = item.title.localizedCaseInsensitiveContains(searchText)
                    || item.id.contains(searchText)
                    || (item.id.hasPrefix("local-") && item.folderURL.lastPathComponent.localizedCaseInsensitiveContains(searchText))
                if !matches { return false }
            }
            switch filter {
            case .all: return true
            case .extractable: return item.isExtractable
            case .notExtracted: return history.entry(for: item.id) == nil
            case .extracted: return history.entry(for: item.id) != nil
            case .favorites: return collections.favoriteIDs.contains(item.id)
            case .recent: return collections.visits[item.id] != nil
            }
        }

        let sorted = filter == .recent ? result.sorted {
            let lhs = collections.visits[$0.id] ?? .distantPast, rhs = collections.visits[$1.id] ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        } : sort.apply(to: result)
        filteredItemsCache = sorted
        return sorted
    }

    /// 某个素材的 X-Ray 状态，未记录即「尚未读取」
    func xrayState(for id: String) -> XRayStatus {
        xrayStatus[id] ?? .unknown
    }

    var selectedItems: [WallpaperItem] {
        items.filter { selection.contains($0.id) }
    }

    func clearHiddenSelection() {
        selection.formIntersection(filteredItems.map(\.id))
    }

    var extractableSelection: [WallpaperItem] {
        selectedItems.filter { $0.isExtractable }
    }

    var focusedItem: WallpaperItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return items.first { $0.id == id }
    }

    var totalPkgSize: String {
        let total = items.filter { $0.isExtractable }.reduce(Int64(0)) { $0 + $1.pkgSize }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var extractableCount: Int {
        items.filter { $0.isExtractable }.count
    }

    /// 「队列」页签角标：未结束的任务数（排队中 + 进行中）
    var queueBadgeCount: Int {
        queue.jobs.filter { !$0.state.isTerminal }.count
    }

    var extractedCount: Int {
        items.filter { history.entry(for: $0.id) != nil }.count
    }

    var notExtractedCount: Int {
        max(0, items.count - extractedCount)
    }

    /// 侧栏某个导航项右侧的计数；队列用未完成任务数
    func badgeCount(for item: NavItem) -> Int? {
        switch item {
        case .library(.all): return items.count
        case .library(.extractable): return extractableCount
        case .library(.notExtracted): return notExtractedCount
        case .library(.extracted): return extractedCount
        case .library(.favorites): return items.filter { collections.favoriteIDs.contains($0.id) }.count
        case .library(.recent): return items.filter { collections.visits[$0.id] != nil }.count
        case .queue: return queueBadgeCount > 0 ? queueBadgeCount : nil
        case .storage: return nil
        }
    }

    // MARK: - 窗口布局与面板折叠

    /// 按导航位置分派刷新：存储页重新统计，其余重扫素材库
    func refreshCurrentContext() {
        switch nav {
        case .storage:
            refreshStorage()
        case .queue, .library:
            refresh()
        }
    }

    func selectAllInCurrentContext() {
        if case .storage = nav {
            selectAllStorage(nil)
        } else {
            selection = Set(filteredItems.filter(\.isExtractable).map(\.id))
        }
    }

    /// 窗口宽度变化时调用。只在跨断点时写状态，避免每帧刷新整棵视图树。
    func noteWindowWidth(_ width: CGFloat) {
        let next: WindowLayout
        if width >= PKD.Breakpoint.tabIcons {
            next = .wide
        } else if width >= PKD.Breakpoint.tabMenu {
            next = .medium
        } else {
            next = .narrow
        }
        if next != layout {
            layout = next
        }

        // 窄窗放不下三栏：详情改用弹出面板（只在跨断点时写状态，避免拖动时每帧刷新）
        let compact = width <= PKD.Breakpoint.inspectorCollapse
        if compact != compactDetailMode {
            compactDetailMode = compact
        }

        // 检查器：窄了自动收起，宽回来按用户原意恢复
        if width <= PKD.Breakpoint.inspectorCollapse,
           !autoCollapsedInspector,
           isInspectorPresented {
            savedInspectorIntent = isInspectorPresented
            autoCollapsedInspector = true
            isInspectorPresented = false
        } else if width >= PKD.Breakpoint.inspectorRestore, autoCollapsedInspector {
            autoCollapsedInspector = false
            isInspectorPresented = savedInspectorIntent
        }

        // 侧栏：再窄才收
        if width <= PKD.Breakpoint.sidebarCollapse,
           !autoCollapsedSidebar,
           columnVisibility != .detailOnly {
            savedColumnVisibility = columnVisibility
            autoCollapsedSidebar = true
            columnVisibility = .detailOnly
        } else if width >= PKD.Breakpoint.sidebarRestore, autoCollapsedSidebar {
            autoCollapsedSidebar = false
            columnVisibility = savedColumnVisibility
        }
    }

    /// 用户主动切换检查器：清掉自动折叠标记，避免放大时被「恢复」覆盖
    func toggleInspector() {
        autoCollapsedInspector = false
        isInspectorPresented.toggle()
    }

    func setInspectorPresented(_ value: Bool) {
        guard value != isInspectorPresented else { return }
        autoCollapsedInspector = false
        isInspectorPresented = value
    }

    func setColumnVisibility(_ value: NavigationSplitViewVisibility) {
        guard value != columnVisibility else { return }
        autoCollapsedSidebar = false
        columnVisibility = value
    }

    // MARK: - 素材库

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let root = DevelopmentEnvironment.root?.appendingPathComponent("Library") ?? settings.libraryRoot

        Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                LibraryScanner().scan(root: root).filter { LibraryTypeFilter.scene.matches($0) }
            }.value

            guard let self else { return }
            let scannedPaths = Set(scanned.compactMap { $0.pkgURL?.standardizedFileURL.resolvingSymlinksInPath().path })
            let combined = scanned + self.importedItems.filter { !scannedPaths.contains($0.pkgURL?.standardizedFileURL.resolvingSymlinksInPath().path ?? "") }
            self.items = combined
            self.isScanning = false
            let scannedIDs = Set(combined.map(\.id))
            let scannedPackagePaths = Set(combined.compactMap { $0.pkgURL?.path })
            self.selection = self.selection.filter { scannedIDs.contains($0) }
            self.infoCache = self.infoCache.filter { key, _ in
                scannedPackagePaths.contains(key)
            }
            // 清理指向已删除目录的「已解包」标记
            for item in scanned where self.history.entry(for: item.id) != nil {
                _ = self.history.validatedEntry(for: item.id)
            }

            self.prefetchInfo()
        }
    }

    /// 后台逐个预读包条目：填充详情缓存，并给出每个素材的 X-Ray 状态。
    ///
    /// 保留读取状态，以便卡片与详情正确显示 X-Ray 信息。
    private func prefetchInfo() {
        prefetchTask?.cancel()

        var statuses: [String: XRayStatus] = [:]
        var targets: [WallpaperItem] = []
        for item in items {
            if item.pkgURL == nil {
                statuses[item.id] = .unavailable
            } else {
                statuses[item.id] = .unknown
                targets.append(item)
            }
        }
        xrayStatus = statuses
        guard let engineURL = queue.engineURL else { return }
        guard !targets.isEmpty else { return }

        prefetchTask = Task { [weak self] in
            for item in targets {
                guard !Task.isCancelled else { return }
                guard let pkg = item.pkgURL else { continue }

                let key = pkg.path
                self?.xrayStatus[item.id] = .scanning

                var resolved: Bool?
                if let info = self?.infoCache[key] {
                    resolved = Self.containsXRay(info)
                } else if let cached = await self?.packageInfoCache.load(for: pkg) {
                    self?.infoCache[key] = cached
                    resolved = Self.containsXRay(cached)
                } else if self?.loadingInfo.contains(key) != true {
                    self?.loadingInfo.insert(key)
                    let session = RepkgSession(executable: engineURL)
                    let result = await session.info(for: pkg)
                    self?.loadingInfo.remove(key)
                    guard !Task.isCancelled else { return }
                    if case .success(let info) = result {
                        self?.infoCache[key] = info
                        resolved = Self.containsXRay(info)
                    }
                }

                self?.xrayStatus[item.id] = resolved.map(XRayStatus.loaded) ?? .failed
            }
        }
    }

    private static func containsXRay(_ info: PkgInfo) -> Bool {
        info.entries.contains { $0.path.lowercased().contains("xray") }
    }

    func loadInfo(for item: WallpaperItem) {
        guard let pkg = item.pkgURL else { return }
        let key = pkg.path
        guard infoCache[key] == nil, !loadingInfo.contains(key) else { return }
        guard let engineURL = queue.engineURL else { return }

        loadingInfo.insert(key)
        Task { [weak self] in
            let session = RepkgSession(executable: engineURL)
            let result = await session.info(for: pkg)
            guard let self else { return }
            self.loadingInfo.remove(key)
            switch result {
            case .success(let info):
                self.infoCache[key] = info
                self.xrayStatus[item.id] = .loaded(Self.containsXRay(info))
            case .failure:
                // 预读阶段失败过就保留 failed，这里只把「尚未读取」标成失败
                if self.xrayState(for: item.id) == .unknown {
                    self.xrayStatus[item.id] = .failed
                }
            }
        }
    }

    // MARK: - 解包

    func requestExtraction() {
        requestExtraction(for: extractableSelection)
    }

    /// 指定目标解包（详情页底栏用它解包当前单个，不必先改选区）
    func requestExtraction(for items: [WallpaperItem]) {
        let targets = items.filter(\.isExtractable)
        guard !targets.isEmpty else { return }

        let estimate = targets.reduce(Int64(0)) {
            $0 + DiskSpace.estimateOutputBytes(pkgSize: $1.pkgSize, convertsTextures: settings.convertTextures)
        }

        if settings.confirmBeforeStart {
            pendingConfirm = ConfirmRequest(
                items: targets,
                estimateBytes: estimate,
                availableBytes: DiskSpace.availableBytes(
                    at: settings.exportImagesOnly
                        ? FileManager.default.temporaryDirectory
                        : settings.outputRoot
                )
            )
        } else {
            performExtraction(targets)
        }
    }

    func performExtraction(_ targets: [WallpaperItem]) {
        let imageOnly = settings.exportImagesOnly
        let root = imageOnly ? settings.imageExportRoot : settings.outputRoot

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            alertMessage = "无法创建输出目录：\(error.localizedDescription)"
            return
        }

        let created = queue.enqueue(
            items: targets,
            settings: settings,
            imageExportDestination: imageOnly ? settings.imageExportRoot : nil
        )
        // 记录导出前可信快照：只有「新建目录」或「之前确实可信且未混入未知内容」的目录，
        // 导出成功后才可以继续整目录可清理；其余保持只读。
        for job in created {
            let folder = OutputLayout.folderName(for: job.item)
            let target = job.imageExportDestination?.appendingPathComponent(folder, isDirectory: true)
                ?? OutputLayout.outputDirectory(for: job.item, root: settings.outputRoot)
            let canonical = StorageScanner.canonicalPath(target)
            let existingRecord = ownershipStore.ownedRecord(forCanonicalPath: canonical)
            let eligibility = OutputOwnershipStore.exportEligibility(directory: target,
                                                                     existingRecord: existingRecord)
            pendingExportTargets[job.id] = (target, eligibility)
        }
        if created.isEmpty {
            alertMessage = "所选项目都无法解包（缺少 pkg 或类型为视频）"
        }
        // 刻意不切换页签：解包时保持当前视图，只在「队列」上显示角标
    }

    private func handleFinished(_ job: ExtractJob) {
        // 无论成功/失败/取消都消费掉导出前快照，避免字典泄漏。
        let preState = pendingExportTargets.removeValue(forKey: job.id)
        guard job.report != nil else { return }
        if case .cancelled = job.state { return }

        let verdictText: String
        switch job.state {
        case .succeeded: verdictText = "成功"
        case .partial(let count): verdictText = "部分成功（\(count)）"
        case .failed(let message): verdictText = "失败：\(message)"
        default: verdictText = job.state.label
        }

        if job.report?.verdict.isSuccess == true {
            markVisited(job.item)
            // 仅导出图片时，历史记录指向图片目录（临时解包目录已被删除）
            let recordPath = job.exportedImages?.directory ?? job.outputDirectory

            history.record(
                id: job.item.id,
                outputPath: recordPath,
                verdict: verdictText,
                fileCount: job.report?.outputFileCount ?? 0,
                xrayCleanFile: job.xray.cleanFiles.first,
                xrayLayerFile: job.xray.xrayFiles.first
            )
            // 数据安全：记录本应用产物归属（只在当前输出根之下登记；失败不影响导出）。
            // 只有导出前不存在的目录才登记 owned；已存在的目录只登记 legacy 身份绑定。
            let allowedRoot = settings.exportImagesOnly
                ? StorageScanner.canonicalPath(settings.imageExportRoot)
                : StorageScanner.canonicalPath(settings.outputRoot)
            if let preState {
                let outcome = ownershipStore.recordAfterExport(
                    directory: recordPath,
                    itemID: job.item.id,
                    allowedCanonicalRoots: [allowedRoot],
                    eligibility: preState.eligibility
                )
                if case .rejected(let reason) = outcome {
                    log.append(jobID: job.id,
                               text: "警告：产物归属未登记（\(reason)），该目录将保持只读",
                               kind: .warning)
                }
            }
            if settings.openFinderWhenDone {
                NSWorkspace.shared.activateFileViewerSelecting([recordPath])
            }
        }
    }

    // MARK: - 引擎

    private func bootstrapEngine() {
        switch RepkgLocator.locate() {
        case .success(let location):
            queue.engineURL = location.url
            engineStatus = .ok(location.source)

            Task { [weak self] in
                let session = RepkgSession(executable: location.url)
                let version = await session.probeVersion()
                guard let self else { return }
                if let version {
                    self.engineStatus = .ok(version)
                } else {
                    self.engineStatus = .broken("repkg 存在但无法运行：\(location.url.path)")
                }
            }

        case .failure(let error):
            engineStatus = .missing(error.attemptedPaths)
        }
    }

    // MARK: - 辅助

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func chooseLocalPackages() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "pkg") ?? .data, .folder]
        panel.message = "选择壁纸包或所在文件夹，临时导入后可选择导出。"
        panel.directoryURL = DevelopmentEnvironment.root?.appendingPathComponent("Library")
        if panel.runModal() == .OK { importWallpapers(panel.urls) }
    }

    func importWallpapers(_ urls: [URL]) {
        if let root = DevelopmentEnvironment.root?.resolvingSymlinksInPath(), urls.contains(where: { !$0.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") }) {
            alertMessage = "开发副本仅接受占位数据目录中的文件。"
            return
        }
        guard !isImporting else { alertMessage = "正在导入，请稍候再添加。"; return }
        isImporting = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { WallpaperImporter.resolve(urls) }.value
            var selected: Set<String> = []
            for item in result.items {
                if let root = DevelopmentEnvironment.root?.resolvingSymlinksInPath(), item.pkgURL?.path.hasPrefix(root.path + "/") != true {
                    alertMessage = "开发副本不能导入指向占位目录以外的包。"
                    continue
                }
                if let existing = items.first(where: { $0.pkgURL?.standardizedFileURL.resolvingSymlinksInPath().path == item.pkgURL?.path }) {
                    selected.insert(existing.id)
                } else {
                    importedItems.append(item)
                    items.append(item)
                    selected.insert(item.id)
                }
            }
            isImporting = false
            if !selected.isEmpty {
                nav = .library(.all)
                searchText = ""
                selection = selected
                if selected.count == 1, let item = items.first(where: { selected.contains($0.id) }) { markVisited(item) }
                prefetchInfo()
            }
            if !result.failures.isEmpty { alertMessage = result.failures.joined(separator: "\n") }
        }
    }

    func removeImported(_ item: WallpaperItem) {
        guard item.id.hasPrefix("local-") else { return }
        importedItems.removeAll { $0.id == item.id }
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
    }

    func showResults(for item: WallpaperItem) {
        markVisited(item)
        guard let entry = history.validatedEntry(for: item.id) else {
            alertMessage = "导出目录不存在，请重新导出后查看。"
            return
        }
        exportGallery = ExportGalleryRequest(title: item.title, directory: URL(fileURLWithPath: entry.outputPath))
    }

    func toggleFavorite(_ item: WallpaperItem) {
        do { try collections.toggleFavorite(item.id) }
        catch { alertMessage = error.localizedDescription }
    }

    func markVisited(_ item: WallpaperItem) {
        do { try collections.recordVisit(item.id) }
        catch { alertMessage = error.localizedDescription }
    }

    func clearRecent() {
        do { try collections.clearRecent() }
        catch { alertMessage = error.localizedDescription }
    }

    func openOutput(for item: WallpaperItem) {
        if let entry = history.entry(for: item.id),
           FileManager.default.fileExists(atPath: entry.outputPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: entry.outputPath))
            return
        }

        let dir = OutputLayout.outputDirectory(for: item, root: settings.outputRoot)
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.open(dir)
        } else {
            alertMessage = "输出目录不存在，可能尚未解包。"
        }
    }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    // MARK: - 存储清理

    var selectedStorageItems: [StorageItem] {
        storageItems.filter { storageSelection.contains($0.id) && $0.isTrashable }
    }

    /// 可进入清理计划的条目（未知/只读条目永远不在其中）。
    var storageTrashableItems: [StorageItem] {
        storageItems.filter(\.isTrashable)
    }

    var selectedStorageBytes: Int64 {
        selectedStorageItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var storageTotalBytes: Int64 {
        storageItems.reduce(0) { $0 + $1.sizeBytes }
    }

    func storageItems(of kind: StorageItem.Kind) -> [StorageItem] {
        storageItems.filter { $0.kind == kind }
    }

    /// 输出根（规范化路径）。执行清理计划时会再次用于边界校验。
    private func storageRoots() -> [String] {
        [
            StorageScanner.canonicalPath(settings.outputRoot),
            StorageScanner.canonicalPath(settings.imageExportRoot),
            StorageScanner.canonicalPath(FileManager.default.temporaryDirectory),
        ]
    }

    private func storageRootMap() -> [String: String] {
        [
            "extract": StorageScanner.canonicalPath(settings.outputRoot),
            "image": StorageScanner.canonicalPath(settings.imageExportRoot),
        ]
    }

    private func auditItems(_ items: [StorageItem]) -> [CleanupAuditLog.Item] {
        items.map { StorageScanner.auditItem($0) }
    }

    func refreshStorage() {
        guard !isScanningStorage else { return }
        isScanningStorage = true

        let extractRoot = settings.outputRoot
        let imageRoot = settings.imageExportRoot
        // 输出目录被改过时，旧产物不在当前根目录下，靠历史记录把它们捞出来
        let historyPaths = history.entries.values.map { $0.outputPath }
        let ownership = ownershipStore.snapshot(legacyPaths: historyPaths)

        Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                StorageScanner.scanDetailed(
                    extractRoot: extractRoot,
                    imageRoot: imageRoot,
                    historyPaths: historyPaths,
                    ownership: ownership
                )
            }.value

            guard let self else { return }
            self.storageItems = scanned.items
            self.storageRootWarnings = scanned.rootWarnings
            // 只保留仍然可清理的选中项；未知/只读条目不会被带入确认流程
            self.storageSelection = self.storageSelection.filter { id in
                scanned.items.first(where: { $0.id == id })?.isTrashable == true
            }
            self.isScanningStorage = false
        }
    }

    /// 生成清理计划并展示确认面板（面板列出完整路径、数量与总大小）。
    func requestTrashSelection() {
        let items = selectedStorageItems
        guard !items.isEmpty else { return }

        let plan = StorageScanner.makePlan(items: items, roots: storageRoots())
        cleanupAudit.record(.request,
                            planID: plan.id,
                            items: auditItems(plan.items),
                            roots: storageRootMap(),
                            note: plan.rejections.isEmpty ? nil : "rejected=\(plan.rejections.count)")

        guard !plan.items.isEmpty else {
            pendingStoragePlan = nil
            let reasons = plan.rejections.prefix(3)
                .map { "\($0.path)：\($0.reason)" }
                .joined(separator: "\n")
            storageResultMessage = "所选目录的状态已变化，未生成清理计划。\n" + reasons
            refreshStorage()
            return
        }
        pendingStoragePlan = plan
    }

    /// 用户在确认面板取消（含直接关闭面板）。
    func cancelStorageTrash() {
        if let plan = pendingStoragePlan {
            cleanupAudit.record(.cancelled,
                                planID: plan.id,
                                items: auditItems(plan.items),
                                roots: storageRootMap())
            storageResultMessage = "已取消，未移动任何文件"
        }
        pendingStoragePlan = nil
    }

    /// 面板关闭回调：计划还在就说明是取消，而不是确认。
    func storagePlanDismissed() {
        if pendingStoragePlan != nil {
            cancelStorageTrash()
        }
    }

    /// 用户确认后执行：再次校验确认前快照（防替换/符号链接/状态变化），逐项移入废纸篓并记审计日志。
    func performTrashSelection() {
        guard let plan = pendingStoragePlan else { return }
        pendingStoragePlan = nil

        cleanupAudit.record(.confirmed,
                            planID: plan.id,
                            items: auditItems(plan.items),
                            roots: storageRootMap())

        let outcome = StorageScanner.execute(plan: plan,
                                              audit: cleanupAudit,
                                              currentRoots: storageRoots())

        let trashedPaths = Set(outcome.trashed.map {
            $0.identity?.canonicalPath ?? StorageScanner.canonicalPath($0.url)
        })
        // 目录没了，历史记录里的「已解包」标记也要跟着失效
        let staleIDs = history.entries
            .filter { trashedPaths.contains(StorageScanner.canonicalPath(URL(fileURLWithPath: $0.value.outputPath))) }
            .map { $0.key }
        for id in staleIDs { history.remove(id: id) }
        ownershipStore.forget(canonicalPaths: Array(trashedPaths))

        storageSelection = []
        refreshStorage()

        var lines: [String] = ["已移入废纸篓 \(outcome.trashed.count) 项"]
        if !outcome.skipped.isEmpty {
            lines.append("跳过 \(outcome.skipped.count) 项（确认前后状态变化或已不存在）")
        }
        if !outcome.failed.isEmpty {
            lines.append("失败 \(outcome.failed.count) 项：")
            lines.append(contentsOf: outcome.failed.prefix(3).map { "· \($0.path)：\($0.reason)" })
        }
        storageResultMessage = lines.joined(separator: "\n")
    }

    func selectAllStorage(_ kind: StorageItem.Kind?) {
        let targets = kind.map { storageItems(of: $0).filter(\.isTrashable) } ?? storageTrashableItems
        storageSelection = Set(targets.map { $0.id })
    }
}

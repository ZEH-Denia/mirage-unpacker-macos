import Foundation
import Combine
import AppKit
import SwiftUI
import PKDKit

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

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "全部"
            case .extractable: return "可解包"
            case .notExtracted: return "未解包"
            case .extracted: return "已解包"
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

    // MARK: 素材库查询（排序持久化，两个筛选不跨启动保存）

    /// 排序偏好写进 defaults，下次启动沿用
    @Published var sort: LibrarySort = AppModel.loadSort() {
        didSet {
            guard sort != oldValue else { return }
            UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey)
            filteredItemsCache = nil
        }
    }

    @Published var typeFilter: LibraryTypeFilter = .all {
        didSet {
            guard typeFilter != oldValue else { return }
            filteredItemsCache = nil
        }
    }

    @Published var xrayFilter: XRayFilter = .all {
        didSet {
            guard xrayFilter != oldValue else { return }
            filteredItemsCache = nil
        }
    }

    /// 每个素材的 X-Ray 读取状态。区分「尚未读取 / 读取中 / 成功 / 失败 / 无包」，
    /// 不能把未知当成「不含 X-Ray」。
    @Published private(set) var xrayStatus: [String: XRayStatus] = [:] {
        didSet {
            // 只有按 X-Ray 筛选时结果才会变，其余情况不必让网格重算
            if xrayFilter != .all { filteredItemsCache = nil }
        }
    }

    /// X-Ray 预读进度
    @Published private(set) var xrayScanDone = 0
    @Published private(set) var xrayScanTotal = 0
    @Published private(set) var isScanningXRay = false
    /// 引擎不可用时无法判定 X-Ray，界面上要解释并禁用该筛选
    @Published private(set) var xrayEngineAvailable = true

    private static let sortKey = "pkd.library.sort"

    private static func loadSort() -> LibrarySort {
        LibrarySort(rawValue: UserDefaults.standard.string(forKey: sortKey) ?? "") ?? .titleAsc
    }

    // 存储清理
    @Published var storageItems: [StorageItem] = []
    @Published var storageSelection: Set<String> = []
    @Published var isScanningStorage = false
    @Published var storageConfirmCount: Int?
    @Published var storageResultMessage: String?

    let settings: SettingsStore
    let history: HistoryStore
    let log: LogSink
    let queue: JobQueue
    /// 日志检查器的控制器放在这里，菜单栏「清空日志」才能拿到它
    let logController = LogController()

    private var filteredItemsCache: [WallpaperItem]?
    private let packageInfoCache = PackageInfoCache()

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
        let history = HistoryStore()
        let log = LogSink()
        self.settings = settings
        self.history = history
        self.log = log
        self.queue = JobQueue(engineURL: nil, log: log)

        queue.concurrency = max(1, settings.maxConcurrentJobs)
        queue.onFinished = { [weak self] job in
            self?.handleFinished(job)
        }

        AppModel.current = self

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
        runSmokeExtractionIfRequested()

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
        // 冒烟钩子：pkd.debug.type=video / pkd.debug.xray=hasXRay 预设附加筛选，用于截图验收
        let debugType = debugDefaults.string(forKey: "pkd.debug.type")
            ?? ProcessInfo.processInfo.environment["PKD_SMOKE_TYPE"]
        if let debugType, let filter = LibraryTypeFilter(rawValue: debugType) {
            typeFilter = filter
        }
        let debugXRay = debugDefaults.string(forKey: "pkd.debug.xray")
            ?? ProcessInfo.processInfo.environment["PKD_SMOKE_XRAY"]
        if let debugXRay, let filter = XRayFilter(rawValue: debugXRay) {
            xrayFilter = filter
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
    private func runSmokeExtractionIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["PKD_SMOKE_PKG"], !path.isEmpty else {
            return
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }

            let originalOutputRoot = self.settings.outputRoot
            if let output = ProcessInfo.processInfo.environment["PKD_SMOKE_OUT"], !output.isEmpty {
                self.settings.outputRoot = URL(fileURLWithPath: output)
            }

            guard let item = self.items.first(where: { $0.pkgURL?.path == path }) else {
                self.settings.outputRoot = originalOutputRoot
                self.alertMessage = "冒烟测试：素材库中未找到 \(path)"
                return
            }

            self.settings.confirmBeforeStart = false
            self.selection = [item.id]
            self.performExtraction([item])

            // 冒烟钩子不应把临时输出目录写进用户设置
            self.settings.outputRoot = originalOutputRoot
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
                if !matches { return false }
            }
            guard typeFilter.matches(item) else { return false }
            guard xrayFilter.matches(xrayState(for: item.id)) else { return false }
            switch filter {
            case .all: return true
            case .extractable: return item.isExtractable
            case .notExtracted: return history.entry(for: item.id) == nil
            case .extracted: return history.entry(for: item.id) != nil
            }
        }

        let sorted = sort.apply(to: result)
        filteredItemsCache = sorted
        return sorted
    }

    /// 某个素材的 X-Ray 状态，未记录即「尚未读取」
    func xrayState(for id: String) -> XRayStatus {
        xrayStatus[id] ?? .unknown
    }

    /// 是否有「类型 / X-Ray」这类附加筛选在生效（不含搜索、侧栏导航、排序）
    var hasExtraFilters: Bool {
        typeFilter != .all || xrayFilter != .all
    }

    /// 只清除附加筛选，不动搜索、侧栏导航与排序，也不清多选
    func clearExtraFilters() {
        typeFilter = .all
        xrayFilter = .all
    }

    /// X-Ray 分类下各项的计数，用于菜单里显示数量
    func xrayCount(_ filter: XRayFilter) -> Int {
        items.filter { item in
            guard typeFilter.matches(item) else { return false }
            return filter.matches(xrayState(for: item.id))
        }.count
    }

    var selectedItems: [WallpaperItem] {
        items.filter { selection.contains($0.id) }
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
        let root = settings.libraryRoot

        Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                LibraryScanner().scan(root: root)
            }.value

            guard let self else { return }
            self.items = scanned
            self.isScanning = false
            let scannedIDs = Set(scanned.map(\.id))
            let scannedPackagePaths = Set(scanned.compactMap { $0.pkgURL?.path })
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
    /// 状态要能区分「尚未读取 / 读取中 / 成功 / 失败 / 无包」——
    /// 把未知当成「不含 X-Ray」会让按 X-Ray 筛选时整批素材被误判。
    private func prefetchInfo() {
        prefetchTask?.cancel()

        var statuses: [String: XRayStatus] = [:]
        var targets: [WallpaperItem] = []
        for item in items {
            if item.pkgURL == nil {
                statuses[item.id] = .unavailable   // 视频类没有 pkg，不进入 X-Ray 分类
            } else {
                statuses[item.id] = .unknown
                targets.append(item)
            }
        }
        xrayStatus = statuses
        xrayScanTotal = targets.count
        xrayScanDone = 0
        isScanningXRay = false

        guard let engineURL = queue.engineURL else {
            // 引擎不可用：无法判定，界面上要说明原因并禁用 X-Ray 筛选
            xrayEngineAvailable = false
            return
        }
        xrayEngineAvailable = true
        guard !targets.isEmpty else { return }
        isScanningXRay = true

        prefetchTask = Task { [weak self] in
            var done = 0
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

                done += 1
                self?.xrayStatus[item.id] = resolved.map(XRayStatus.loaded) ?? .failed
                self?.xrayScanDone = done
            }
            self?.isScanningXRay = false
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
        if created.isEmpty {
            alertMessage = "所选项目都无法解包（缺少 pkg 或类型为视频）"
        }
        // 刻意不切换页签：解包时保持当前视图，只在「队列」上显示角标
    }

    private func handleFinished(_ job: ExtractJob) {
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
        storageItems.filter { storageSelection.contains($0.id) }
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

    func refreshStorage() {
        guard !isScanningStorage else { return }
        isScanningStorage = true

        let extractRoot = settings.outputRoot
        let imageRoot = settings.imageExportRoot
        // 输出目录被改过时，旧产物不在当前根目录下，靠历史记录把它们捞出来
        let historyPaths = history.entries.values.map { $0.outputPath }

        Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                StorageScanner.scan(
                    extractRoot: extractRoot,
                    imageRoot: imageRoot,
                    historyPaths: historyPaths
                )
            }.value

            guard let self else { return }
            self.storageItems = scanned
            self.storageSelection = self.storageSelection.filter { id in
                scanned.contains { $0.id == id }
            }
            self.isScanningStorage = false
        }
    }

    func requestTrashSelection() {
        let items = selectedStorageItems
        guard !items.isEmpty else { return }
        storageConfirmCount = items.count
    }

    func performTrashSelection() {
        let items = selectedStorageItems
        guard !items.isEmpty else { return }

        let extractRoot = settings.outputRoot
        let imageRoot = settings.imageExportRoot
        let extraAllowed = Set(history.entries.values.map { $0.outputPath })

        let outcome = StorageScanner.trash(
            items,
            extractRoot: extractRoot,
            imageRoot: imageRoot,
            extraAllowed: extraAllowed
        )

        // 目录没了，历史记录里的「已解包」标记也要跟着失效
        let trashedPaths = Set(outcome.trashed.map { $0.url.path })
        let staleIDs = history.entries
            .filter { trashedPaths.contains($0.value.outputPath) }
            .map { $0.key }
        for id in staleIDs {
            history.remove(id: id)
        }

        storageSelection = []
        refreshStorage()

        if outcome.failed.isEmpty {
            storageResultMessage = "已把 \(outcome.trashed.count) 项移到废纸篓"
        } else {
            storageResultMessage = "已移入废纸篓 \(outcome.trashed.count) 项，"
                + "\(outcome.failed.count) 项失败：\n" + outcome.failed.prefix(3).joined(separator: "\n")
        }
    }

    func selectAllStorage(_ kind: StorageItem.Kind?) {
        let targets = kind.map { storageItems(of: $0) } ?? storageItems
        storageSelection = Set(targets.map { $0.id })
    }
}

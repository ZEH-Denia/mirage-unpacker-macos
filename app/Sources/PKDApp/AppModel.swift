import Foundation
import Combine
import AppKit
import PKDKit

@MainActor
final class AppModel: ObservableObject {
    enum Tab: Hashable {
        case detail
        case queue
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

    @Published var items: [WallpaperItem] = []
    @Published var selection: Set<String> = []
    @Published var searchText: String = ""
    @Published var filter: LibraryFilter = .all
    @Published var infoCache: [String: PkgInfo] = [:]
    @Published var loadingInfo: Set<String> = []
    @Published var engineStatus: EngineStatus = .unknown
    @Published var isScanning = false
    @Published var selectedTab: Tab = .detail
    @Published var pendingConfirm: ConfirmRequest?
    @Published var alertMessage: String?
    /// 壁纸是否含 X-Ray 效果（由后台预读包条目得出）
    @Published var xrayFlags: [String: Bool] = [:]

    let settings: SettingsStore
    let history: HistoryStore
    let log: LogSink
    let queue: JobQueue

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
        for publisher in [settings.objectWillChange.eraseToAnyPublisher(),
                          history.objectWillChange.eraseToAnyPublisher(),
                          queue.objectWillChange.eraseToAnyPublisher()] {
            publisher
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        }

        bootstrapEngine()
        refresh()
        runSmokeExtractionIfRequested()
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

            if let output = ProcessInfo.processInfo.environment["PKD_SMOKE_OUT"], !output.isEmpty {
                self.settings.outputRoot = URL(fileURLWithPath: output)
            }

            guard let item = self.items.first(where: { $0.pkgURL?.path == path }) else {
                self.alertMessage = "冒烟测试：素材库中未找到 \(path)"
                return
            }

            self.settings.confirmBeforeStart = false
            self.selection = [item.id]
            self.performExtraction([item])
            self.selectedTab = .queue
        }
    }

    // MARK: - 派生数据

    var filteredItems: [WallpaperItem] {
        items.filter { item in
            if !searchText.isEmpty {
                let matches = item.title.localizedCaseInsensitiveContains(searchText)
                    || item.id.contains(searchText)
                if !matches { return false }
            }
            switch filter {
            case .all: return true
            case .extractable: return item.isExtractable
            case .notExtracted: return history.entry(for: item.id) == nil
            case .extracted: return history.entry(for: item.id) != nil
            }
        }
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
            self.selection = self.selection.filter { id in scanned.contains { $0.id == id } }
            self.infoCache = self.infoCache.filter { key, _ in
                scanned.contains { $0.pkgURL?.path == key }
            }
            // 清理指向已删除目录的「已解包」标记
            for item in scanned where self.history.entry(for: item.id) != nil {
                _ = self.history.validatedEntry(for: item.id)
            }

            self.prefetchInfo()
        }
    }

    /// 后台逐个预读包条目：填充详情页缓存，并标记哪些壁纸含 X-Ray。
    private func prefetchInfo() {
        prefetchTask?.cancel()
        guard let engineURL = queue.engineURL else { return }

        let snapshot = items
        prefetchTask = Task { [weak self] in
            for item in snapshot {
                guard !Task.isCancelled else { return }
                guard let pkg = item.pkgURL else { continue }

                let key = pkg.path
                if self?.infoCache[key] != nil {
                    self?.xrayFlags[item.id] = self?.infoCache[key]?.entries.contains {
                        $0.path.lowercased().contains("xray")
                    }
                    continue
                }

                let session = RepkgSession(executable: engineURL)
                let result = await session.info(for: pkg)
                guard !Task.isCancelled else { return }

                if case .success(let info) = result {
                    self?.infoCache[key] = info
                    self?.xrayFlags[item.id] = info.entries.contains {
                        $0.path.lowercased().contains("xray")
                    }
                }
            }
        }
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
            if case .success(let info) = result {
                self.infoCache[key] = info
            }
        }
    }

    // MARK: - 解包

    func requestExtraction() {
        let targets = extractableSelection
        guard !targets.isEmpty else { return }

        let estimate = targets.reduce(Int64(0)) {
            $0 + DiskSpace.estimateOutputBytes(pkgSize: $1.pkgSize, convertsTextures: settings.convertTextures)
        }

        if settings.confirmBeforeStart {
            pendingConfirm = ConfirmRequest(
                items: targets,
                estimateBytes: estimate,
                availableBytes: DiskSpace.availableBytes(at: settings.outputRoot)
            )
        } else {
            performExtraction(targets)
        }
    }

    func performExtraction(_ targets: [WallpaperItem]) {
        do {
            try FileManager.default.createDirectory(at: settings.outputRoot, withIntermediateDirectories: true)
        } catch {
            alertMessage = "无法创建输出目录：\(error.localizedDescription)"
            return
        }

        let created = queue.enqueue(items: targets, settings: settings)
        if created.isEmpty {
            alertMessage = "所选项目都无法解包（缺少 pkg 或类型为视频）"
        } else {
            selectedTab = .queue
        }
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
            history.record(
                id: job.item.id,
                outputPath: job.outputDirectory,
                verdict: verdictText,
                fileCount: job.report?.outputFileCount ?? 0,
                xrayCleanFile: job.xray.cleanFiles.first,
                xrayLayerFile: job.xray.xrayFiles.first
            )
            if settings.openFinderWhenDone {
                NSWorkspace.shared.activateFileViewerSelecting([job.outputDirectory])
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
}

import Foundation
import Combine

public enum JobState: Equatable, Sendable {
    case queued
    case inspecting
    case running
    case cancelling
    case succeeded
    case partial(warningCount: Int)
    case failed(String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .queued, .inspecting, .running, .cancelling: return false
        case .succeeded, .partial, .failed, .cancelled: return true
        }
    }

    public var isRunning: Bool {
        switch self {
        case .inspecting, .running, .cancelling: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .queued: return "排队中"
        case .inspecting: return "读取包结构"
        case .running: return "解包中"
        case .cancelling: return "正在停止…"
        case .succeeded: return "成功"
        case .partial(let count): return "部分成功（\(count) 条警告）"
        case .failed(let message): return "失败：\(message)"
        case .cancelled: return "已取消"
        }
    }
}

/// 进度回调来自 IO 线程，先写进这个盒子，再由主线程 10Hz 拉取。
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ExtractProgress()
    private var dirty = false

    func update(_ progress: ExtractProgress) {
        lock.lock()
        storage = progress
        dirty = true
        lock.unlock()
    }

    /// 仅在变化时返回，避免无意义的 UI 刷新
    func takeIfChanged() -> ExtractProgress? {
        lock.lock()
        defer { lock.unlock() }
        guard dirty else { return nil }
        dirty = false
        return storage
    }

    var latest: ExtractProgress {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
public final class ExtractJob: ObservableObject, Identifiable {
    public let id = UUID()
    public let item: WallpaperItem
    public let request: ExtractRequest

    @Published public var state: JobState = .queued
    @Published public var progress = ExtractProgress()
    @Published public var report: ExtractReport?
    @Published public var warnings: [String] = []
    /// 解包后识别出的 X-Ray 图层（正常层 / X-Ray 层各是哪张图）
    @Published public var xray = XRayLabelSummary()
    /// 「仅导出图片」模式：非空表示解包产物是临时的，导出后要删除
    public var temporaryOutput: URL?
    /// 「仅导出图片」模式的图片目标目录
    public var imageExportDestination: URL?
    @Published public var exportedImages: ImageExportResult?
    public var startedAt: Date?
    public var endedAt: Date?
    public var session: RepkgSession?

    let progressBox = ProgressBox()

    public init(item: WallpaperItem, request: ExtractRequest) {
        self.item = item
        self.request = request
    }

    public var outputDirectory: URL { request.outputDirectory }

    public var durationText: String {
        guard let start = startedAt else { return "—" }
        let end = endedAt ?? Date()
        let seconds = Int(end.timeIntervalSince(start))
        if seconds < 60 { return "\(seconds) 秒" }
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
}

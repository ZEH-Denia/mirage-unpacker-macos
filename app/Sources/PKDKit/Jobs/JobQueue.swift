import Foundation
import Combine

/// 解包任务队列。默认串行：repkg 单线程解码，单条目可达 857MB，并行只增内存不减时间。
@MainActor
public final class JobQueue: ObservableObject {
    @Published public private(set) var jobs: [ExtractJob] = []
    @Published public private(set) var activeCount = 0

    public var concurrency: Int = 1 {
        didSet {
            if concurrency < 1 { concurrency = 1 }
            pump()
        }
    }

    public var engineURL: URL?
    public var onFinished: ((ExtractJob) -> Void)?

    public let log: LogSink
    private var ticker: Timer?

    public init(engineURL: URL?, log: LogSink) {
        self.engineURL = engineURL
        self.log = log
    }

    // MARK: - 队列操作

    @discardableResult
    public func enqueue(items: [WallpaperItem],
                        settings: SettingsStore,
                        imageExportDestination: URL? = nil) -> [ExtractJob] {
        var created: [ExtractJob] = []

        for item in items where item.isExtractable {
            guard var request = settings.makeRequest(for: item) else { continue }

            if let destination = imageExportDestination {
                // 仅导出图片：解包到临时目录，导出后清理
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PKD-extract-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                request.outputDirectory = temp

                let job = ExtractJob(item: item, request: request)
                job.temporaryOutput = temp
                job.imageExportDestination = destination
                jobs.append(job)
                created.append(job)
            } else {
                let job = ExtractJob(item: item, request: request)
                jobs.append(job)
                created.append(job)
            }
        }

        pump()
        return created
    }

    public func cancel(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), !job.state.isTerminal else { return }
        job.state = .cancelling
        let session = job.session
        Task {
            await session?.cancel()
        }
    }

    public func cancelAll() {
        for job in jobs where !job.state.isTerminal {
            cancel(job.id)
        }
    }

    public func retry(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        job.state = .queued
        job.progress = ExtractProgress()
        job.report = nil
        job.warnings = []
        job.endedAt = nil
        pump()
    }

    public func retryAllFailed() {
        for job in jobs {
            if case .failed = job.state { retry(job.id) }
        }
    }

    public func removeFinished() {
        jobs.removeAll { $0.state.isTerminal }
    }

    public var failedCount: Int {
        jobs.filter { if case .failed = $0.state { return true } else { return false } }.count
    }

    // MARK: - 调度

    private func pump() {
        while activeCount < concurrency,
              let next = jobs.first(where: { $0.state == .queued }) {
            run(next)
        }
    }

    private func run(_ job: ExtractJob) {
        activeCount += 1
        job.state = .inspecting
        job.startedAt = Date()
        startTicker()

        Task { [weak self] in
            guard let self else { return }
            await self.execute(job)
            self.activeCount -= 1
            self.stopTickerIfIdle()
            self.pump()
        }
    }

    private func execute(_ job: ExtractJob) async {
        guard let engineURL else {
            job.state = .failed("未找到 repkg 引擎")
            job.endedAt = Date()
            log.append(jobID: job.id, text: "错误：未找到 repkg 引擎", kind: .stderr)
            return
        }

        let logSink = log
        let jobID = job.id
        let box = job.progressBox

        logSink.append(jobID: jobID, text: "", kind: .marker)
        logSink.append(
            jobID: jobID,
            text: "=== \(job.item.title)  [\(job.item.id)]  \(job.item.sizeText) ===",
            kind: .marker
        )

        // 磁盘预检（不足只警告，不中止）
        let estimate = DiskSpace.estimateOutputBytes(
            pkgSize: job.item.pkgSize,
            convertsTextures: job.request.convertTextures
        )
        if let available = DiskSpace.availableBytes(at: job.request.outputDirectory), available < estimate {
            let text = "警告：预计需要 \(ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file))，"
                + "剩余 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))"
            job.warnings.append(text)
            logSink.append(jobID: jobID, text: text, kind: .warning)
        }

        let session = RepkgSession(executable: engineURL)
        job.session = session

        var expected: PkgInfo?
        if let pkg = job.item.pkgURL {
            switch await session.info(for: pkg) {
            case .success(let info):
                expected = info
                logSink.append(
                    jobID: jobID,
                    text: "包内 \(info.entries.count) 个条目，"
                        + ByteCountFormatter.string(fromByteCount: info.totalBytes, countStyle: .file),
                    kind: .stdout
                )
            case .failure(let error):
                logSink.append(jobID: jobID, text: "读取包信息失败：\(error.message)", kind: .warning)
            }
        }

        job.state = .running

        var attempt = 0
        while true {
            let report = await session.extract(
                job.request,
                expected: expected,
                onEvent: { event in
                    logSink.append(jobID: jobID, text: JobQueue.describe(event), kind: JobQueue.kind(for: event))
                },
                onProgress: { progress in
                    box.update(progress)
                }
            )

            // 崩溃类失败自动重试一次
            if attempt == 0, case .failed(let failure) = report.verdict,
               failure == .crashed || failure == .missingDoneSentinel {
                attempt += 1
                logSink.append(jobID: jobID, text: "首次失败（\(failure.message)），自动重试一次…", kind: .warning)
                continue
            }

            job.report = report
            job.progress = box.latest
            job.warnings.append(contentsOf: report.warnings)
            job.endedAt = Date()

            // X-Ray 图层分离：识别正常层 / X-Ray 层并给导出的图片加上可读后缀
            if report.verdict.isSuccess {
                let layers = XRayAnalyzer.analyze(outputDirectory: job.request.outputDirectory)
                if !layers.isEmpty {
                    let summary = XRayLabeler.label(layers, in: job.request.outputDirectory)
                    job.xray = summary
                    logSink.append(
                        jobID: jobID,
                        text: "X-Ray 图层已分离：\(summary.shortDescription ?? "已识别 \(layers.count) 处")",
                        kind: .marker
                    )
                }
            }

            // 仅导出图片模式：把图片复制到目标目录，随后删除临时解包目录
            if let destination = job.imageExportDestination {
                if report.verdict.isSuccess {
                    let result = ImageExporter.export(
                        from: job.request.outputDirectory,
                        to: destination,
                        title: job.item.title,
                        xray: job.xray
                    )
                    job.exportedImages = result

                    if result.isEmpty {
                        job.warnings.append("未找到可导出的图片")
                        logSink.append(jobID: jobID, text: "警告：未找到可导出的图片", kind: .warning)
                    } else {
                        logSink.append(
                            jobID: jobID,
                            text: "已导出 \(result.files.count) 张图片 → \(destination.path)：\(result.summary)",
                            kind: .marker
                        )
                    }
                }

                if let temp = job.temporaryOutput {
                    try? FileManager.default.removeItem(at: temp)
                }
            }

            switch report.verdict {
            case .success:
                job.state = .succeeded
            case .partialSuccess:
                job.state = .partial(warningCount: report.warnings.count + report.missingEntries.count)
            case .cancelled:
                job.state = .cancelled
            case .failed(let failure):
                job.state = .failed(failure.message)
            }

            logSink.append(
                jobID: jobID,
                text: "结束：\(job.state.label) · 产物 \(report.outputFileCount) 个文件 · \(job.durationText)",
                kind: report.verdict.isSuccess ? .marker : .stderr
            )
            logSink.close(jobID: jobID)
            onFinished?(job)
            return
        }
    }

    nonisolated private static func describe(_ event: RepkgEvent) -> String {
        switch event {
        case .packageStarted(let path): return "解包：\(path)"
        case .entryExtracting(let path): return "  + \(path)"
        case .entrySkipped(let path): return "  = 跳过已存在：\(path)"
        case .fileCopied(let path): return "  > 复制：\(path)"
        case .textureReading(let name): return "  ~ 转换纹理：\(name)"
        case .projectJSONWarning(let message): return "警告：project.json — \(message)"
        case .textureWarning(let kind): return "警告：纹理\(kind == .read ? "读取" : "写入")失败"
        case .unrecognizedExtension(let ext): return "警告：无法识别的扩展名 \(ext)"
        case .fatal(let signal):
            return signal == .inputNotFound ? "错误：输入文件不存在" : "错误：输入路径不存在"
        case .terminating: return "收到中断信号，正在停止…"
        case .done: return "完成标记"
        case .continuation(let text): return "  \(text)"
        case .unparsed(let text): return text
        }
    }

    nonisolated private static func kind(for event: RepkgEvent) -> LogSink.Kind {
        switch event {
        case .textureWarning, .projectJSONWarning, .unrecognizedExtension, .fatal:
            return .warning
        case .packageStarted, .done, .terminating:
            return .marker
        default:
            return .stdout
        }
    }

    // MARK: - 进度节流

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        for job in jobs where job.state.isRunning {
            if let progress = job.progressBox.takeIfChanged() {
                job.progress = progress
            }
        }
    }

    private func stopTickerIfIdle() {
        guard activeCount == 0 else { return }
        ticker?.invalidate()
        ticker = nil
    }

    /// 退出时同步终止所有子进程（否则残留 repkg 会继续写 GB 级文件）。
    public func terminateAllChildren() {
        for job in jobs where job.state.isRunning {
            job.session?.cancelImmediately()
        }
    }
}

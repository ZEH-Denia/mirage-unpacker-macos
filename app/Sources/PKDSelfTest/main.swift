import Foundation
import PKDKit

// 轻量断言框架：不依赖 XCTest（CLT 环境里没有 XCTest.framework）
var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL \(file):\(line) — \(message)\n".utf8))
    }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if lhs != rhs {
        failures += 1
        FileHandle.standardError.write(Data("FAIL \(file):\(line) — \(message)\n  实际: \(lhs)\n  期望: \(rhs)\n".utf8))
    }
}

func section(_ name: String) {
    print("· \(name)")
}

// MARK: - 手动清理入口（pkd-selftest --trash <目标> <解包根> <图片根>）

if let flagIndex = CommandLine.arguments.firstIndex(of: "--trash"),
   flagIndex + 3 < CommandLine.arguments.count {
    let target = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let extractRoot = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 2])
    let imageRoot = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 3])

    let item = StorageItem(url: target,
                           kind: .extracted,
                           displayName: target.lastPathComponent,
                           sizeBytes: 0,
                           fileCount: 0,
                           modified: nil)

    // 刻意不传 extraAllowed：走的就是界面上「按根目录白名单判定」的真实路径
    let result = StorageScanner.trash([item], extractRoot: extractRoot, imageRoot: imageRoot)
    print("已移入废纸篓：\(result.trashed.count) 项，失败：\(result.failed.count) 项")
    for message in result.failed {
        print("  - \(message)")
    }
    exit(result.failed.isEmpty ? 0 : 1)
}

// MARK: - 队列集成测试入口（pkd-selftest --queue <pkg>）

if let flagIndex = CommandLine.arguments.firstIndex(of: "--queue"),
   flagIndex + 1 < CommandLine.arguments.count {
    let pkgURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    await runQueueIntegrationTest(pkg: pkgURL)
    print("")
    print(failures == 0
        ? "✅ 队列集成测试通过（\(checks) 项断言）"
        : "❌ \(failures) 项失败 / 共 \(checks) 项断言")
    exit(failures == 0 ? 0 : 1)
}

@MainActor
func runQueueIntegrationTest(pkg: URL) async {
    section("JobQueue 全链路（info → extract → 进度 → 日志 → 历史）")

    guard case .success(let location) = RepkgLocator.locate() else {
        check(false, "未找到 repkg 引擎")
        return
    }

    let suiteName = "pkd.selftest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    let settings = SettingsStore(defaults: defaults)

    let outputRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("pkd-queue-\(UUID().uuidString)")
    settings.outputRoot = outputRoot
    settings.confirmBeforeStart = false
    settings.openFinderWhenDone = false

    let logDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pkd-queue-logs-\(UUID().uuidString)")
    let log = LogSink(logDirectory: logDirectory)
    let queue = JobQueue(engineURL: location.url, log: log)
    queue.concurrency = 1

    let pkgSize = (try? pkg.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    let item = WallpaperItem(
        id: "selftest",
        folderURL: pkg.deletingLastPathComponent(),
        title: "自测包",
        type: "scene",
        previewURL: nil,
        pkgURL: pkg,
        contentRating: "",
        tags: [],
        pkgSize: pkgSize,
        issue: nil
    )

    let created = queue.enqueue(items: [item], settings: settings)
    checkEqual(created.count, 1, "应创建 1 个任务")
    checkEqual(created.first?.request.outputDirectory.lastPathComponent,
               "自测包_selftest", "输出子目录应为 <标题>_<id>")

    var waited = 0.0
    while queue.jobs.contains(where: { !$0.state.isTerminal }), waited < 120 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        waited += 0.1
    }

    guard let job = queue.jobs.first else {
        check(false, "任务丢失")
        return
    }

    checkEqual(job.state, .succeeded, "任务应成功，实际：\(job.state.label)")
    check((job.report?.outputFileCount ?? 0) >= 5, "产物文件数应 ≥ 5，实际 \(job.report?.outputFileCount ?? 0)")
    check((job.progress.fraction ?? 0) >= 0.99, "进度应到 100%，实际 \(job.progress.fraction ?? -1)")
    checkEqual(job.progress.entriesDone, job.progress.entriesTotal ?? -1, "完成条目数应等于总条目数")
    check(FileManager.default.fileExists(atPath: outputRoot.path), "输出目录应存在")

    let logFile = log.logFileURL(for: job.id)
    log.flushFiles()
    check(FileManager.default.fileExists(atPath: logFile.path), "日志文件应已落盘")
    if let content = try? String(contentsOf: logFile, encoding: .utf8) {
        check(content.contains("自测包"), "日志应包含任务标题")
        check(content.contains("结束："), "日志应包含结束行")
    }

    try? FileManager.default.removeItem(at: outputRoot)
    try? FileManager.default.removeItem(at: logDirectory)
    defaults.removePersistentDomain(forName: suiteName)
}


/// 线程安全的进度采样收集器（进度回调来自 IO 队列）。
final class FractionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    private var callCount = 0
    private var lastProgress = ExtractProgress()

    func record(_ progress: ExtractProgress) {
        lock.lock()
        callCount += 1
        lastProgress = progress
        if let value = progress.fraction {
            storage.append(value)
        }
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    var last: ExtractProgress {
        lock.lock()
        defer { lock.unlock() }
        return lastProgress
    }
}

// MARK: - LineStream

section("LineStream 基本切行")
do {
    var stream = LineStream()
    checkEqual(stream.consume(Data("a\nb\n".utf8)), ["a", "b"], "两行完整输入")
    checkEqual(stream.finish(), [], "无残留")

    var crlf = LineStream()
    checkEqual(crlf.consume(Data("\r\n### Extracting package: x\r\n".utf8)),
               ["", "### Extracting package: x"], "CRLF 与行首空行")
}

section("LineStream 跨 chunk 与 UTF-8 切断")
do {
    let text = "未标题-1 拷贝.tex\n第二行\n"
    let data = Data(text.utf8)

    // 在每一个字节位置切成两块，结果必须一致
    var mismatches = 0
    for split in 0...data.count {
        var stream = LineStream()
        let head = data.prefix(split)
        let tail = data.suffix(from: split)
        var lines = stream.consume(Data(head))
        lines += stream.consume(Data(tail))
        lines += stream.finish()
        if lines != ["未标题-1 拷贝.tex", "第二行"] {
            mismatches += 1
        }
    }
    checkEqual(mismatches, 0, "任意字节位置切分都不应产生乱码")
}

section("LineStream 无结尾换行")
do {
    var stream = LineStream()
    checkEqual(stream.consume(Data("Done".utf8)), [], "未闭合的行先不吐")
    checkEqual(stream.finish(), ["Done"], "finish() 必须冲刷残留")
}

// MARK: - RepkgOutputParser

section("RepkgOutputParser 哨兵与规则")
do {
    var parser = RepkgOutputParser()
    checkEqual(parser.feed("Done"), .done, "Done 精确匹配")
    check(parser.sawDone, "sawDone 置位")

    var notDone = RepkgOutputParser()
    checkEqual(notDone.feed("Done!"), .unparsed("Done!"), "Done! 不应命中")
    check(!notDone.sawDone, "Done! 不置位")

    var fatalParser = RepkgOutputParser()
    checkEqual(fatalParser.feed("Input file not found"), .fatal(.inputNotFound), "extract 失败哨兵")
    checkEqual(fatalParser.feed("/tmp/不存在.pkg"), .continuation("/tmp/不存在.pkg"), "失败后的路径行被吞掉")

    var infoFatal = RepkgOutputParser()
    checkEqual(infoFatal.feed("Input file/directory doesn't exist!"),
               .fatal(.inputPathDoesNotExist), "info 的失败哨兵文案不同")

    var extractParser = RepkgOutputParser()
    checkEqual(extractParser.feed("* Extracting: materials/未标题-1 拷贝.tex"),
               .entryExtracting(path: "materials/未标题-1 拷贝.tex"), "条目事件")
    checkEqual(extractParser.feed("* Skipping, already exists: a/b.tex"),
               .entrySkipped(path: "a/b.tex"), "跳过事件")
    checkEqual(extractParser.feed("* Failed to read project.json: bad"),
               .projectJSONWarning(message: "bad"), "project.json 警告优先于其它 * 前缀")
    checkEqual(extractParser.feed("Terminating..."), .terminating, "取消哨兵")
    check(extractParser.sawTerminating, "sawTerminating 置位")
    checkEqual(extractParser.feed("Failed to write texture"), .textureWarning(.write), "纹理写入失败")
    checkEqual(extractParser.warningCount, 2, "警告计数")
}

// MARK: - PkgInfoParser

section("PkgInfoParser 真实输出")
do {
    let sample = """
    ### Package info: /tmp/test_scene.pkg
    Package entries:
    * scene.json - 94 bytes
    * materials/test_quad.tex - 16467 bytes
    * materials/a - b.tex - 123 bytes
    Done
    """
    var parser = PkgInfoParser()
    for line in sample.split(separator: "\n", omittingEmptySubsequences: false) {
        parser.feed(String(line))
    }
    let info = parser.result()
    check(info != nil, "应解析成功")
    checkEqual(info?.entries.count ?? -1, 3, "条目数")
    checkEqual(info?.entries[0].path ?? "", "scene.json", "首个条目路径")
    checkEqual(info?.entries[2].path ?? "", "materials/a - b.tex", "路径含 ' - ' 时取最后一个分隔符")
    checkEqual(info?.entries[2].size ?? -1, 123, "路径含 ' - ' 时大小正确")
    checkEqual(info?.totalBytes ?? -1, 16684, "总字节数")
}

// MARK: - ExtractVerdict 判定表

section("ExtractVerdict 判定表")
do {
    func verdict(_ configure: (inout ExtractVerdict.Facts) -> Void) -> ExtractReport.Verdict {
        var facts = ExtractVerdict.Facts()
        configure(&facts)
        return ExtractVerdict.decide(facts)
    }

    checkEqual(verdict { f in f.sawDone = true; f.outputFileCount = 3 }, .success, "正常成功")
    checkEqual(verdict { f in f.sawDone = true; f.outputFileCount = 3; f.warningCount = 1 },
               .partialSuccess, "有警告 → 部分成功")
    checkEqual(verdict { f in f.sawDone = true; f.outputFileCount = 3; f.missingEntries = ["a"] },
               .partialSuccess, "条目缺失 → 部分成功")
    checkEqual(verdict { f in f.sawDone = true; f.outputFileCount = 0 }, .failed(.emptyOutput), "无产物")
    checkEqual(verdict { f in }, .failed(.missingDoneSentinel), "无 Done → 失败（exit 0 也一样）")
    checkEqual(verdict { f in f.fatal = .inputNotFound }, .failed(.inputNotFound), "输入不存在")
    checkEqual(verdict { f in f.stderrLines = ["ERROR(S):"] }, .failed(.invalidArguments), "参数错误")
    checkEqual(verdict { f in f.exitCode = 139 }, .failed(.crashed), "非 0 退出码 → 崩溃")
    checkEqual(verdict { f in f.wasCancelled = true; f.sawDone = true; f.outputFileCount = 9 },
               .cancelled, "取消优先于一切")
    checkEqual(verdict { f in f.sawTerminating = true; f.sawDone = true; f.outputFileCount = 9 },
               .cancelled, "Terminating 也算取消")
}

// MARK: - X-Ray 图层识别

section("XRayAnalyzer / XRayLabeler")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pkd-xray-\(UUID().uuidString)")
    let fm = FileManager.default
    try? fm.createDirectory(at: dir.appendingPathComponent("models"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: dir.appendingPathComponent("materials"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: dir.appendingPathComponent("effects/xray"), withIntermediateDirectories: true)

    func write(_ relative: String, _ text: String) {
        try? Data(text.utf8).write(to: dir.appendingPathComponent(relative))
    }

    write("scene.json", """
    {"objects":[
      {"name":"图层A","image":"models/base.json",
       "effects":[{"file":"effects/xray/effect.json",
                   "visible":{"user":"xray","value":true},
                   "passes":[{"textures":[null,"xraytex",null]}]}]},
      {"name":"图层B","image":"models/plain.json"}
    ]}
    """)
    write("models/base.json", #"{"material":"materials/base.json"}"#)
    write("models/plain.json", #"{"material":"materials/plain.json"}"#)
    write("materials/base.json", #"{"passes":[{"textures":["basetex"]}]}"#)
    write("materials/plain.json", #"{"passes":[{"textures":["plaintex"]}]}"#)
    write("materials/basetex.jpg", "clean")
    write("materials/xraytex.jpg", "xray")
    write("materials/plaintex.jpg", "plain")

    let layers = XRayAnalyzer.analyze(outputDirectory: dir)
    checkEqual(layers.count, 1, "应识别出 1 处 X-Ray 效果")
    checkEqual(layers.first?.baseTexture ?? "", "basetex", "正常层纹理解析（models → materials 链路）")
    checkEqual(layers.first?.xrayTextures ?? [], ["xraytex"], "X-Ray 层纹理")
    checkEqual(layers.first?.objectName ?? "", "图层A", "对象名")

    let summary = XRayLabeler.label(layers, in: dir)
    checkEqual(summary.cleanFiles, ["basetex [正常].jpg"], "正常层文件改名")
    checkEqual(summary.xrayFiles, ["xraytex [X-Ray].jpg"], "X-Ray 层文件改名")
    check(fm.fileExists(atPath: dir.appendingPathComponent("materials/basetex [正常].jpg").path),
          "改名后文件存在")
    check(fm.fileExists(atPath: dir.appendingPathComponent("materials/xraytex [X-Ray].jpg").path),
          "X-Ray 文件存在")
    check(fm.fileExists(atPath: dir.appendingPathComponent("materials/plaintex.jpg").path),
          "无关纹理不应被改名")
    check(fm.fileExists(atPath: dir.appendingPathComponent("materials/basetex.tex").path) == false,
          "tex 原始文件不参与改名（此处本来就没有）")

    // 幂等：再跑一次不应崩，也不应产生重复后缀
    _ = XRayLabeler.label(XRayAnalyzer.analyze(outputDirectory: dir), in: dir)
    check(fm.fileExists(atPath: dir.appendingPathComponent("materials/basetex [正常].jpg").path),
          "重复执行保持幂等")

    try? fm.removeItem(at: dir)
}


// MARK: - 仅导出图片

section("ImageExporter 导出与命名")
do {
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("pkd-export-work-\(UUID().uuidString)")
    let dest = fm.temporaryDirectory.appendingPathComponent("pkd-export-dest-\(UUID().uuidString)")
    try? fm.createDirectory(at: work.appendingPathComponent("materials"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: dest, withIntermediateDirectories: true)

    func write(_ relative: String, _ text: String) {
        try? Data(text.utf8).write(to: work.appendingPathComponent(relative))
    }

    write("materials/未标题-1 拷贝 [正常].jpg", "clean")
    write("materials/未标题-2 拷贝 [X-Ray].jpg", "xray")
    write("preview.jpg", "preview")
    write("scene.json", "{}")

    var xray = XRayLabelSummary()
    xray.cleanFiles = ["未标题-1 拷贝 [正常].jpg"]
    xray.xrayFiles = ["未标题-2 拷贝 [X-Ray].jpg"]

    let first = ImageExporter.export(from: work, to: dest, folderName: "测试壁纸_123", xray: xray)
    let subdir = dest.appendingPathComponent("测试壁纸_123")
    checkEqual(first.directory.lastPathComponent, "测试壁纸_123", "按壁纸名建子文件夹")
    checkEqual(first.files, ["正常.jpg", "X-Ray.jpg"], "子文件夹内按图层角色命名")
    check(fm.fileExists(atPath: subdir.appendingPathComponent("正常.jpg").path), "正常层已写入子文件夹")
    check(fm.fileExists(atPath: subdir.appendingPathComponent("X-Ray.jpg").path), "X-Ray 层已写入子文件夹")
    check(!fm.fileExists(atPath: dest.appendingPathComponent("preview.jpg").path), "预览图不应被导出")

    // 同一壁纸重复导出：覆盖，不产生 (2)
    let second = ImageExporter.export(from: work, to: dest, folderName: "测试壁纸_123", xray: xray)
    checkEqual(second.files, ["正常.jpg", "X-Ray.jpg"], "重复导出覆盖同名文件")
    let entries = (try? fm.contentsOfDirectory(atPath: subdir.path)) ?? []
    checkEqual(entries.sorted(), ["X-Ray.jpg", "正常.jpg"], "子文件夹内不应出现 (2) 副本")

    // 没有 X-Ray：导出全部图片，保留原文件名
    let plainWork = fm.temporaryDirectory.appendingPathComponent("pkd-export-plain-\(UUID().uuidString)")
    try? fm.createDirectory(at: plainWork.appendingPathComponent("materials"), withIntermediateDirectories: true)
    try? Data("a".utf8).write(to: plainWork.appendingPathComponent("materials/贴图.png"))
    try? Data("p".utf8).write(to: plainWork.appendingPathComponent("preview.jpg"))

    let plainDest = fm.temporaryDirectory.appendingPathComponent("pkd-export-plain-dest-\(UUID().uuidString)")
    let plain = ImageExporter.export(from: plainWork, to: plainDest, folderName: "无Xray_9", xray: XRayLabelSummary())
    checkEqual(plain.files, ["贴图.png"], "无 X-Ray 时导出全部图片且排除预览图")

    for dir in [work, dest, plainWork, plainDest] {
        try? fm.removeItem(at: dir)
    }
}

// MARK: - 存储清理

section("StorageScanner 扫描与安全校验")
do {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("pkd-storage-\(UUID().uuidString)")
    let extractRoot = base.appendingPathComponent("Extracted")
    let imageRoot = base.appendingPathComponent("Images")

    func makeFolder(_ url: URL, files: Int) {
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        for i in 0..<files {
            try? Data(repeating: 0x41, count: 1024).write(to: url.appendingPathComponent("f\(i).bin"))
        }
    }

    makeFolder(extractRoot.appendingPathComponent("鸣潮_1"), files: 3)
    makeFolder(extractRoot.appendingPathComponent("鸣潮_2"), files: 2)
    makeFolder(imageRoot.appendingPathComponent("鸣潮_1"), files: 2)

    let items = StorageScanner.scan(extractRoot: extractRoot, imageRoot: imageRoot, includeTemporary: false)
    checkEqual(items.count, 3, "应扫描出 3 个子目录")
    checkEqual(items.filter { $0.kind == .extracted }.count, 2, "解包产物 2 项")
    checkEqual(items.filter { $0.kind == .images }.count, 1, "导出图片 1 项")

    let first = items.first { $0.displayName == "鸣潮_1" && $0.kind == .extracted }
    checkEqual(first?.fileCount ?? -1, 3, "文件计数")
    check((first?.sizeBytes ?? 0) >= 3 * 1024, "占用按分配大小统计")

    // 安全校验：只允许删根目录的直接子项
    check(StorageScanner.isSafeToTrash(extractRoot.appendingPathComponent("鸣潮_1"),
                                       extractRoot: extractRoot, imageRoot: imageRoot),
          "根目录直接子项可删")
    check(!StorageScanner.isSafeToTrash(extractRoot.appendingPathComponent("鸣潮_1/f0.bin"),
                                        extractRoot: extractRoot, imageRoot: imageRoot),
          "子文件不可删")
    check(!StorageScanner.isSafeToTrash(extractRoot, extractRoot: extractRoot, imageRoot: imageRoot),
          "根目录本身不可删")
    check(!StorageScanner.isSafeToTrash(base.appendingPathComponent("别处"),
                                        extractRoot: extractRoot, imageRoot: imageRoot),
          "根目录之外不可删")

    // 临时目录只认固定前缀
    let tempDir = fm.temporaryDirectory
    check(StorageScanner.isSafeToTrash(tempDir.appendingPathComponent("PKD-extract-abc"),
                                       extractRoot: extractRoot, imageRoot: imageRoot),
          "带前缀的临时目录可删")
    check(!StorageScanner.isSafeToTrash(tempDir.appendingPathComponent("其他临时目录"),
                                        extractRoot: extractRoot, imageRoot: imageRoot),
          "无前缀的临时目录不可删")

    // 不安全路径必须被拒绝，且不执行删除
    let unsafeItem = StorageItem(
        url: base.appendingPathComponent("别处"),
        kind: .extracted,
        displayName: "别处",
        sizeBytes: 0,
        fileCount: 0,
        modified: nil
    )
    let outcome = StorageScanner.trash([unsafeItem], extractRoot: extractRoot, imageRoot: imageRoot)
    checkEqual(outcome.trashed.count, 0, "越界路径不应被删除")
    checkEqual(outcome.failed.count, 1, "越界路径应记录为失败")

    // 回归：/tmp 是 /private/tmp 的符号链接，contentsOfDirectory 会返回解析后的路径。
    // 早期版本用字符串前缀比对，导致 /tmp 下的产物「看得到却删不掉」。
    let symlinkRoot = URL(fileURLWithPath: "/tmp").appendingPathComponent("pkd-symlink-\(UUID().uuidString)")
    makeFolder(symlinkRoot.appendingPathComponent("产物"), files: 1)
    let symlinkItems = StorageScanner.scan(extractRoot: symlinkRoot,
                                           imageRoot: base.appendingPathComponent("无"),
                                           includeTemporary: false)
    checkEqual(symlinkItems.count, 1, "应扫描到 /tmp 下的产物")
    if let item = symlinkItems.first {
        check(StorageScanner.isSafeToTrash(item.url,
                                           extractRoot: symlinkRoot,
                                           imageRoot: base.appendingPathComponent("无")),
              "符号链接下的产物必须允许删除（曾因 /private/tmp 前缀不匹配而失败）")
    }
    try? fm.removeItem(at: symlinkRoot)

    // 历史记录里的旧产物：默认不可见，显式记录后才出现且可删
    let orphanDir = base.appendingPathComponent("旧输出目录/产物")
    makeFolder(orphanDir, files: 1)
    let orphanScan = StorageScanner.scan(extractRoot: extractRoot,
                                         imageRoot: imageRoot,
                                         historyPaths: [orphanDir.path],
                                         includeTemporary: false)
    check(orphanScan.contains { $0.kind == .orphan && $0.url.path.hasSuffix("产物") }, "历史路径应作为「其他位置」出现")
    check(!StorageScanner.isSafeToTrash(orphanDir, extractRoot: extractRoot, imageRoot: imageRoot),
          "未被记录的越界路径仍然拒绝")
    check(StorageScanner.isSafeToTrash(orphanDir,
                                       extractRoot: extractRoot,
                                       imageRoot: imageRoot,
                                       extraAllowed: [StorageScanner.canonicalPath(orphanDir)]),
          "历史记录里显式记录的路径允许删除")

    try? fm.removeItem(at: base)
}

// MARK: - 集成：真实 repkg

section("PackageInfoCache 命中与失效")
do {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("pkd-info-cache-\(UUID().uuidString)", isDirectory: true)
    let package = base.appendingPathComponent("scene.pkg")
    let cache = PackageInfoCache(directory: base.appendingPathComponent("cache", isDirectory: true))
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try? Data([1, 2, 3]).write(to: package)

    let info = PkgInfo(packagePath: package.path, entries: [PkgEntryInfo(path: "scene.json", size: 3)])
    await cache.store(info, for: package)
    let cached = await cache.load(for: package)
    checkEqual(cached, info, "同一包文件应命中磁盘缓存")

    try? Data([1, 2, 3, 4]).write(to: package)
    let stale = await cache.load(for: package)
    check(stale == nil, "包文件变化后应忽略旧缓存")
    try? FileManager.default.removeItem(at: base)
}

section("集成测试：真实 repkg")
do {
    switch RepkgLocator.locate() {
    case .success(let location):
        let pkg = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/PKDSelfTest
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo
            .appendingPathComponent("tools/testdata/test_scene.pkg")

        if !FileManager.default.fileExists(atPath: pkg.path) {
            print("  （跳过：未找到 \(pkg.path)）")
        } else {
            let session = RepkgSession(executable: location.url)

            let version = await session.probeVersion()
            check(version?.hasPrefix("repkg") == true, "探活返回版本号，实际: \(version ?? "nil")")

            let infoResult = await session.info(for: pkg)
            var knownInfo: PkgInfo?
            switch infoResult {
            case .success(let info):
                knownInfo = info
                checkEqual(info.entries.count, 4, "合成包应有 4 个条目")
                check(info.entries.contains { $0.path == "materials/test_dxt5.tex" }, "包含 DXT5 纹理")
            case .failure(let error):
                check(false, "info 失败：\(error.message)")
            }

            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("pkd-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            let request = ExtractRequest(input: pkg, outputDirectory: out, overwrite: true)
            let collector = FractionCollector()
            let report = await session.extract(
                request,
                expected: knownInfo,
                onEvent: { _ in },
                onProgress: { progress in
                    collector.record(progress)
                }
            )

            checkEqual(report.verdict, .success, "解包应成功")
            check(report.outputFileCount >= 5, "产物文件数 ≥ 5，实际 \(report.outputFileCount)")
            check(collector.calls > 0, "应有进度回调，实际 \(collector.calls) 次")

            // 提供了 expected 时，进度必须能算出来并且跑到 100%
            let fractions = collector.values
            check(!fractions.isEmpty, "有 expected 时 fraction 不应为空")
            checkEqual(fractions.max() ?? -1, 1.0, "最终进度应为 100%")
            checkEqual(collector.last.entriesDone, 4, "完成条目数应为 4")
            check(fractions == fractions.sorted(), "进度必须单调不回退")

            try? FileManager.default.removeItem(at: out)

            // 失败路径：不存在的输入 → 必须判失败（不能因为 exit code 是 0 就当成功）
            let ghost = URL(fileURLWithPath: "/tmp/pkd-does-not-exist-\(UUID().uuidString).pkg")
            let ghostOut = FileManager.default.temporaryDirectory
                .appendingPathComponent("pkd-ghost-\(UUID().uuidString)")
            let ghostReport = await session.extract(
                ExtractRequest(input: ghost, outputDirectory: ghostOut, overwrite: true),
                expected: nil
            )
            checkEqual(ghostReport.verdict, .failed(.inputNotFound), "不存在的输入应判失败")
            check(!FileManager.default.fileExists(atPath: ghostOut.path), "失败时不应创建输出目录")
        }

    case .failure(let error):
        print("  （跳过：\(error.message)）")
        for path in error.attemptedPaths {
            print("    - \(path)")
        }
    }
}

// MARK: - 结果

print("")
if failures == 0 {
    print("✅ 全部通过（\(checks) 项断言）")
    exit(0)
} else {
    print("❌ \(failures) 项失败 / 共 \(checks) 项断言")
    exit(1)
}

import Foundation
import PKDKit

/// 在独立开发副本中验证真实 AppModel 的跨启动状态与导入生命周期。
/// 只使用显式开发根目录内生成的占位包；不将这些检查记作 UI/辅助功能验收。
extension AppModel {
    func runLibraryDevelopmentScenarioIfRequested() -> Bool {
        guard let root = DevelopmentEnvironment.root,
              let scenario = ProcessInfo.processInfo.environment["PKD_DEVELOPMENT_SCENARIO"],
              ["library-seed", "library-verify", "library-inspect"].contains(scenario) else { return false }
        Task {
            var checks: [String] = []
            var failure: String?
            do {
                try await waitForLibrary { !self.isScanning }
                guard let first = items.first(where: { $0.id == "800000" }),
                      let second = items.first(where: { $0.id == "800001" }) else {
                    throw validationError("缺少占位素材")
                }
                if scenario == "library-inspect" {
                    let source = root.appendingPathComponent("Incoming/ValidationPlaceholder")
                    guard FileManager.default.fileExists(atPath: source.appendingPathComponent("scene.pkg").path) else {
                        throw validationError("请先运行 library-verify 生成交互占位包")
                    }
                    importWallpapers([source])
                    try await waitForLibrary { !self.isImporting }
                    try requireLibrary(items.contains { $0.folderURL == source }, "交互占位素材已导入", &checks)
                } else if scenario == "library-seed" {
                    if !collections.favoriteIDs.contains(first.id) { toggleFavorite(first) }
                    markVisited(second)
                    try requireLibrary(collections.favoriteIDs.contains(first.id), "收藏写入", &checks)
                    try requireLibrary(collections.visits[second.id] != nil, "最近使用写入", &checks)
                } else {
                    filter = .favorites
                    try requireLibrary(filteredItems.contains { $0.id == first.id }, "重启后收藏页面数据恢复", &checks)
                    filter = .recent
                    try requireLibrary(filteredItems.contains { $0.id == second.id }, "重启后最近使用页面数据恢复", &checks)
                    filter = .all
                    selection = [first.id, second.id]
                    sort = .sizeDesc
                    try requireLibrary(selection == [first.id, second.id], "排序保留选择", &checks)
                    searchText = first.title
                    try requireLibrary(!filteredItems.contains { $0.id == second.id }, "搜索隐藏另一选中项", &checks)
                    clearHiddenSelection()
                    try requireLibrary(selection == [first.id], "仅清除隐藏选择", &checks)
                    searchText = ""

                    let fm = FileManager.default
                    let source = root.appendingPathComponent("Incoming/ValidationPlaceholder")
                    try fm.createDirectory(at: source, withIntermediateDirectories: true)
                    for name in ["scene.pkg", "project.json", "preview.png"] {
                        let data = try Data(contentsOf: first.folderURL.appendingPathComponent(name))
                        try data.write(to: source.appendingPathComponent(name), options: .atomic)
                    }
                    let names = try fm.contentsOfDirectory(atPath: source.path).sorted()
                    let original = try names.map { try Data(contentsOf: source.appendingPathComponent($0)) }
                    let originalCount = items.count
                    importWallpapers([source])
                    try await waitForLibrary { !self.isImporting }
                    guard let imported = items.first(where: { $0.folderURL == source }) else {
                        throw validationError("导入项未出现")
                    }
                    try requireLibrary(items.count == originalCount + 1 && selection == [imported.id], "导入并选中新素材", &checks)
                    importWallpapers([source.appendingPathComponent("scene.pkg")])
                    try await waitForLibrary { !self.isImporting }
                    try requireLibrary(items.count == originalCount + 1, "重复导入不增加卡片", &checks)
                    refresh()
                    try await waitForLibrary { !self.isScanning }
                    try requireLibrary(items.contains { $0.id == imported.id } && selection.contains(imported.id), "刷新保留临时素材及选择", &checks)
                    removeImported(imported)
                    try requireLibrary(items.count == originalCount && !selection.contains(imported.id), "移出临时素材及选择", &checks)
                    let finalNames = try fm.contentsOfDirectory(atPath: source.path).sorted()
                    let finalData = try finalNames.map { try Data(contentsOf: source.appendingPathComponent($0)) }
                    try requireLibrary(names == finalNames && original == finalData, "导入刷新移出不修改来源", &checks)
                    clearRecent()
                    try requireLibrary(collections.visits.isEmpty && collections.favoriteIDs.contains(first.id), "清空最近使用保留收藏", &checks)
                    filter = .favorites
                    selection = [first.id]
                }
                if let message = alertMessage { throw validationError(message) }
            } catch { failure = error.localizedDescription }
            let report: [String: Any] = ["scenario": scenario, "checks": checks,
                                       "passed": failure == nil, "error": failure ?? "",
                                       "pid": ProcessInfo.processInfo.processIdentifier]
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: root.appendingPathComponent("\(scenario).json"), options: .atomic)
            } catch { NSLog("占位素材验收报告写入失败：%@", error.localizedDescription) }
        }
        return true
    }

    private func waitForLibrary(_ ready: () -> Bool) async throws {
        for _ in 0..<200 {
            if ready() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw validationError("等待素材状态超时")
    }

    private func requireLibrary(_ condition: Bool, _ label: String, _ checks: inout [String]) throws {
        guard condition else { throw validationError(label) }
        checks.append(label)
    }

    private func validationError(_ message: String) -> NSError {
        NSError(domain: "PKD.DevelopmentValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

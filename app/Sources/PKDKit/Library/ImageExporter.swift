import Foundation

public struct ImageExportResult: Sendable, Equatable {
    /// 该壁纸专属的子目录（root/<壁纸名_id>）
    public var directory: URL
    /// 实际写入的文件名（按「正常层 → X-Ray 层」顺序）
    public var files: [String] = []
    /// 未能复制的图片及原因。
    public var failures: [String] = []

    public var isEmpty: Bool { files.isEmpty }

    public var summary: String {
        guard !files.isEmpty else { return "未找到可导出的图片" }
        return files.joined(separator: "、")
    }
}

/// 把解包产物里的图片挑出来，复制到「以壁纸命名的子文件夹」里。
///
/// 目录结构：
/// ```
/// <导出根目录>/
/// └── 鸣潮_3608924541/        ← 壁纸名 + workshopID，保证同名壁纸不混在一起
///     ├── 正常.jpg
///     └── X-Ray.jpg
/// ```
/// 没有 X-Ray 的壁纸会保留原文件名（如 `贴图.png`）。
/// 同一壁纸重复导出时覆盖同名文件，不产生 ` (2)` 副本。
public enum ImageExporter {
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]

    public static func export(from workDirectory: URL,
                              to root: URL,
                              folderName: String,
                              xray: XRayLabelSummary,
                              fileManager: FileManager = .default) -> ImageExportResult {
        let directory = root.appendingPathComponent(folderName, isDirectory: true)
        var result = ImageExportResult(directory: directory)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            result.failures.append("无法创建导出目录：\(error.localizedDescription)")
            return result
        }

        let sources = collectSources(in: workDirectory, xray: xray, fileManager: fileManager)
        guard !sources.isEmpty else { return result }

        var reservedNames: Set<String> = []
        for source in sources {
            let ext = source.url.pathExtension.lowercased()
            let baseName = "\(source.role).\(ext)"
            var fileName = baseName
            var duplicate = 2
            while reservedNames.contains(fileName) {
                fileName = "\(source.role) (\(duplicate)).\(ext)"
                duplicate += 1
            }
            reservedNames.insert(fileName)
            let target = directory.appendingPathComponent(fileName)
            let staging = directory.appendingPathComponent(".pkd-export-\(UUID().uuidString)")

            do {
                try fileManager.copyItem(at: source.url, to: staging)
            } catch {
                result.failures.append("\(source.url.lastPathComponent)：\(error.localizedDescription)")
                continue
            }

            var backup: URL?
            if fileManager.fileExists(atPath: target.path) {
                let backupURL = directory.appendingPathComponent(".pkd-backup-\(UUID().uuidString)")
                do {
                    try fileManager.moveItem(at: target, to: backupURL)
                    backup = backupURL
                } catch {
                    try? fileManager.removeItem(at: staging)
                    result.failures.append("无法替换 \(target.lastPathComponent)：\(error.localizedDescription)")
                    continue
                }
            }

            do {
                try fileManager.moveItem(at: staging, to: target)
                if let backup { try? fileManager.removeItem(at: backup) }
                result.files.append(target.lastPathComponent)
            } catch {
                if let backup { try? fileManager.moveItem(at: backup, to: target) }
                try? fileManager.removeItem(at: staging)
                result.failures.append("无法写入 \(target.lastPathComponent)：\(error.localizedDescription)")
                continue
            }
        }

        return result
    }

    private struct Source {
        let url: URL
        let role: String
    }

    private static func collectSources(in workDirectory: URL,
                                       xray: XRayLabelSummary,
                                       fileManager: FileManager) -> [Source] {
        let materials = workDirectory.appendingPathComponent("materials", isDirectory: true)

        // 1. 有 X-Ray：只取那两层
        if !xray.cleanFiles.isEmpty || !xray.xrayFiles.isEmpty {
            var sources: [Source] = []
            for name in xray.cleanFiles {
                let url = materials.appendingPathComponent(name)
                if fileManager.fileExists(atPath: url.path) {
                    sources.append(Source(url: url, role: "正常"))
                }
            }
            for name in xray.xrayFiles {
                let url = materials.appendingPathComponent(name)
                if fileManager.fileExists(atPath: url.path) {
                    sources.append(Source(url: url, role: "X-Ray"))
                }
            }
            if !sources.isEmpty { return sources }
        }

        // 2. 没有 X-Ray：取全部转换后的图片（排除预览图），保留原文件名
        let enumerator = fileManager.enumerator(
            at: workDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var sources: [Source] = []
        while let url = enumerator?.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            guard url.lastPathComponent.lowercased() != "preview.jpg" else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }

            sources.append(Source(url: url, role: url.deletingPathExtension().lastPathComponent))
        }

        return sources.sorted { $0.url.path < $1.url.path }
    }
}

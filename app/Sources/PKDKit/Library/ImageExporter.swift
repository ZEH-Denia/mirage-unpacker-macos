import Foundation

public struct ImageExportResult: Sendable, Equatable {
    public var directory: URL
    /// 实际写入的文件名（按「正常层 → X-Ray 层」顺序）
    public var files: [String] = []

    public var isEmpty: Bool { files.isEmpty }

    public var summary: String {
        guard !files.isEmpty else { return "未找到可导出的图片" }
        return files.joined(separator: "、")
    }
}

/// 把解包产物里的图片挑出来，复制到用户指定目录，并按壁纸名重命名。
///
/// 命名规则：
/// - 识别到 X-Ray → `<标题>_正常.<ext>`、`<标题>_X-Ray.<ext>`
/// - 没有 X-Ray  → `<标题>_<原文件名>.<ext>`
/// 同名文件自动追加 ` (2)`、` (3)`，不覆盖已有文件。
public enum ImageExporter {
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]

    public static func export(from workDirectory: URL,
                              to destination: URL,
                              title: String,
                              xray: XRayLabelSummary,
                              fileManager: FileManager = .default) -> ImageExportResult {
        var result = ImageExportResult(directory: destination)

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return result
        }

        let sources = collectSources(in: workDirectory, xray: xray, fileManager: fileManager)
        guard !sources.isEmpty else { return result }

        let safeTitle = OutputLayout.sanitize(title)

        for source in sources {
            let ext = source.url.pathExtension.lowercased()
            let baseName = safeTitle.isEmpty ? "image" : safeTitle
            let stem = "\(baseName)_\(source.role)"

            let target = uniqueURL(in: destination, stem: stem, ext: ext, fileManager: fileManager)
            do {
                try fileManager.copyItem(at: source.url, to: target)
                result.files.append(target.lastPathComponent)
            } catch {
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

        // 2. 没有 X-Ray：取全部转换后的图片（排除预览图）
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

    private static func uniqueURL(in directory: URL,
                                  stem: String,
                                  ext: String,
                                  fileManager: FileManager) -> URL {
        var candidate = directory.appendingPathComponent("\(stem).\(ext)")
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(index)).\(ext)")
            index += 1
        }
        return candidate
    }
}

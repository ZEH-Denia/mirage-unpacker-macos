import Foundation

public struct LibraryScanner: Sendable {
    public static let defaultRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Mirage/Workshop/content/431960")

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// 扫描素材库根目录（只取一层子目录，与 repkg 的目录模式一致）。
    public func scan(root: URL) -> [WallpaperItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var items: [WallpaperItem] = []
        for folder in children {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            items.append(makeItem(folder: folder))
        }

        return items.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func makeItem(folder: URL) -> WallpaperItem {
        let id = folder.lastPathComponent
        var issues: [ProjectIssue] = []

        var project: ProjectJSON?
        let projectURL = folder.appendingPathComponent("project.json")
        if let data = try? Data(contentsOf: projectURL) {
            do {
                project = try ProjectJSON.decode(data)
            } catch {
                issues.append(.unreadable("project.json 解析失败"))
            }
        } else {
            issues.append(.missing)
        }

        let title = project?.title ?? id
        let type = project?.type ?? ""

        // 优先 scene.pkg，否则目录内第一个 *.pkg
        let pkgURL = findPackage(in: folder)
        if pkgURL == nil {
            issues.append(.noPackage)
        }
        if type == "video" {
            issues.append(.unsupportedType(type))
        }

        let previewURL = resolvePreview(in: folder, declared: project?.preview)
        if previewURL == nil, let declared = project?.preview {
            issues.append(.previewMissing(declared))
        }

        let pkgSize = pkgURL
            .flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .map(Int64.init) ?? 0

        return WallpaperItem(
            id: id,
            folderURL: folder,
            title: title,
            type: type,
            previewURL: previewURL,
            pkgURL: pkgURL,
            contentRating: project?.contentRating ?? "",
            tags: project?.tags ?? [],
            pkgSize: pkgSize,
            issue: issues.first
        )
    }

    private func findPackage(in folder: URL) -> URL? {
        let scenePkg = folder.appendingPathComponent("scene.pkg")
        if fileManager.fileExists(atPath: scenePkg.path) {
            return scenePkg
        }

        let contents = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension.lowercased() == "pkg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private func resolvePreview(in folder: URL, declared: String?) -> URL? {
        if let declared, !declared.isEmpty {
            let url = folder.appendingPathComponent(declared)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        for name in ["preview.jpg", "preview.jpeg", "preview.png", "preview.gif", "preview.webp"] {
            let url = folder.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

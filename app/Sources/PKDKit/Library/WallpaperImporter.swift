import Foundation
import CryptoKit

public struct WallpaperImportResult: Sendable {
    public var items: [WallpaperItem] = []
    public var failures: [String] = []
}

/// 只检查明确指定的文件或文件夹，不扫描相邻目录、不复制或改写来源文件。
public enum WallpaperImporter {
    public static func resolve(_ urls: [URL]) -> WallpaperImportResult {
        var result = WallpaperImportResult()
        var seen: Set<String> = []
        for supplied in urls {
            let url = supplied.standardizedFileURL.resolvingSymlinksInPath()
            do {
                guard url.isFileURL else { throw ImportError.unsupported }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                let folder: URL
                let pkg: URL
                if values.isDirectory == true {
                    folder = url
                    let item = LibraryScanner().makeItem(folder: folder)
                    guard let package = item.pkgURL else { throw ImportError.noPackage }
                    pkg = package
                } else {
                    guard values.isRegularFile == true, url.pathExtension.lowercased() == "pkg" else { throw ImportError.unsupported }
                    folder = url.deletingLastPathComponent()
                    pkg = url
                }
                let package = pkg.standardizedFileURL.resolvingSymlinksInPath()
                guard (try package.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw ImportError.noPackage }
                guard seen.insert(package.path).inserted else { continue }
                let base = LibraryScanner().makeItem(folder: folder)
                guard base.type.isEmpty || base.type == "scene" else { throw ImportError.unsupported }
                let hash = SHA256.hash(data: Data(package.path.utf8)).map { String(format: "%02x", $0) }.joined()
                let preview = base.previewURL.flatMap { candidate -> URL? in
                    let resolved = candidate.resolvingSymlinksInPath()
                    return resolved.path.hasPrefix(folder.path + "/") ? resolved : nil
                }
                let title = base.issue == .missing ? pkg.deletingPathExtension().lastPathComponent : base.title
                result.items.append(WallpaperItem(id: "local-" + hash, folderURL: folder, title: title, type: base.type.isEmpty ? "scene" : base.type, previewURL: preview, pkgURL: package, contentRating: base.contentRating, tags: base.tags, pkgSize: Int64(try package.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), issue: base.issue))
            } catch { result.failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        return result
    }
    private enum ImportError: LocalizedError {
        case unsupported, noPackage
        var errorDescription: String? {
            switch self {
            case .unsupported: return "请选择场景壁纸的 .pkg 文件或所在文件夹"
            case .noPackage: return "文件夹内没有可读取的 .pkg"
            }
        }
    }
}

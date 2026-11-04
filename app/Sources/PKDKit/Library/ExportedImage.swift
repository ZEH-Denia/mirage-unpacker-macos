import Foundation
import ImageIO

public struct ExportedImage: Identifiable, Sendable, Equatable {
    public let url: URL
    public let width: Int
    public let height: Int
    public let bytes: Int64
    public var id: URL { url }
    public var role: String {
        let name = url.deletingPathExtension().lastPathComponent
        if name == "场景预览-实验" { return "实验性场景预览" }
        if name == "正常" || name.hasPrefix("正常 (") || name.contains("[正常]") { return "正常层" }
        if name == "X-Ray" || name.hasPrefix("X-Ray (") || name.contains("[X-Ray]") { return "X-Ray 层" }
        if name.lowercased().contains("mask") { return "疑似效果遮罩" }
        return "素材图片"
    }
    public var detail: String {
        "\(width) × \(height) · \(url.pathExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    /// Read metadata only; image pixels are decoded lazily by the gallery.
    public static func scan(directory: URL) throws -> [ExportedImage] {
        let fm = FileManager.default
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let values = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]
        var images: [ExportedImage] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard extensions.contains(url.pathExtension.lowercased()), url.lastPathComponent.lowercased() != "preview.jpg",
                  url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                  let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), info.isRegularFile == true,
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = metadata[kCGImagePropertyPixelWidth] as? Int,
                  let height = metadata[kCGImagePropertyPixelHeight] as? Int else { continue }
            images.append(ExportedImage(url: url, width: width, height: height, bytes: Int64(info.fileSize ?? 0)))
        }
        return images.sorted {
            let lhsPreview = $0.url.lastPathComponent == ExperimentalPuppetPreview.outputName
            let rhsPreview = $1.url.lastPathComponent == ExperimentalPuppetPreview.outputName
            if lhsPreview != rhsPreview { return lhsPreview }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }
}

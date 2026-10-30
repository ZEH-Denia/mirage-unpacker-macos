import Foundation

public enum OutputLayout {
    /// 输出子目录名：`<标题>_<workshopID>`。
    /// 标题可能重复（素材库里有两个都叫「鸣潮」），也可能含 `/`，因此必须清洗并拼上 id。
    public static func folderName(for item: WallpaperItem) -> String {
        let sanitized = sanitize(item.title)
        if sanitized.isEmpty {
            return item.id
        }
        return "\(sanitized)_\(item.id)"
    }

    public static func outputDirectory(for item: WallpaperItem, root: URL) -> URL {
        root.appendingPathComponent(folderName(for: item), isDirectory: true)
    }

    /// 清洗文件名：替换路径分隔符与冒号，去掉首尾的点与空格，限长。
    public static func sanitize(_ raw: String) -> String {
        var text = raw
        for bad in ["/", ":", "\\", "\u{0}"] {
            text = text.replacingOccurrences(of: bad, with: "_")
        }
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        if text.count > 80 {
            text = String(text.prefix(80))
        }
        return text
    }
}

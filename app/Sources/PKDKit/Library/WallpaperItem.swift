import Foundation

public enum ProjectIssue: Sendable, Equatable, Hashable {
    case missing
    case unreadable(String)
    case noPackage
    case unsupportedType(String)
    case previewMissing(String)
}

public struct WallpaperItem: Identifiable, Hashable, Sendable {
    /// 素材库中的文件夹名，即 workshop id
    public let id: String
    public let folderURL: URL
    public let title: String
    /// 已转小写：scene / video / …
    public let type: String
    public let previewURL: URL?
    public let pkgURL: URL?
    public let contentRating: String
    public let tags: [String]
    public let pkgSize: Int64
    public let issue: ProjectIssue?

    public init(id: String,
                folderURL: URL,
                title: String,
                type: String,
                previewURL: URL?,
                pkgURL: URL?,
                contentRating: String,
                tags: [String],
                pkgSize: Int64,
                issue: ProjectIssue?) {
        self.id = id
        self.folderURL = folderURL
        self.title = title
        self.type = type
        self.previewURL = previewURL
        self.pkgURL = pkgURL
        self.contentRating = contentRating
        self.tags = tags
        self.pkgSize = pkgSize
        self.issue = issue
    }

    /// video 类型没有 pkg，不可解包；其余只要有 pkg 就允许（有些包 type 标注不规范）
    public var isExtractable: Bool {
        pkgURL != nil && type != "video"
    }

    public var typeLabel: String {
        switch type {
        case "scene": return "场景"
        case "video": return "视频"
        case "": return "未知"
        default: return type
        }
    }

    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: pkgSize, countStyle: .file)
    }

    public static func == (lhs: WallpaperItem, rhs: WallpaperItem) -> Bool {
        lhs.id == rhs.id && lhs.pkgSize == rhs.pkgSize && lhs.title == rhs.title
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

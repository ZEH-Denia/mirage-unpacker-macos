import Foundation
import PKDKit

/// 素材库排序方式。
///
/// 主键相同时依次按标题、ID 比较，保证结果稳定（`sorted(by:)` 本身不保证稳定）。
public enum LibrarySort: String, CaseIterable, Identifiable {
    case titleAsc
    case titleDesc
    case sizeDesc
    case sizeAsc
    case idAsc
    case idDesc

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .titleAsc: return "标题 A–Z"
        case .titleDesc: return "标题 Z–A"
        case .sizeDesc: return "体积从大到小"
        case .sizeAsc: return "体积从小到大"
        case .idAsc: return "Workshop ID 升序"
        case .idDesc: return "Workshop ID 降序"
        }
    }

    /// 菜单里用的短标签
    public var shortLabel: String {
        switch self {
        case .titleAsc: return "标题 A–Z"
        case .titleDesc: return "标题 Z–A"
        case .sizeDesc: return "体积 ↓"
        case .sizeAsc: return "体积 ↑"
        case .idAsc: return "ID ↑"
        case .idDesc: return "ID ↓"
        }
    }

    public func apply(to items: [WallpaperItem]) -> [WallpaperItem] {
        items.sorted { lhs, rhs in
            switch self {
            case .titleAsc, .titleDesc:
                let result = lhs.title.localizedStandardCompare(rhs.title)
                if result != .orderedSame {
                    return self == .titleAsc ? result == .orderedAscending : result == .orderedDescending
                }
            case .sizeDesc, .sizeAsc:
                if lhs.pkgSize != rhs.pkgSize {
                    return self == .sizeDesc ? lhs.pkgSize > rhs.pkgSize : lhs.pkgSize < rhs.pkgSize
                }
            case .idAsc, .idDesc:
                // workshop id 是数字串，按数值比较才符合直觉
                let left = Int64(lhs.id) ?? 0
                let right = Int64(rhs.id) ?? 0
                if left != right {
                    return self == .idAsc ? left < right : left > right
                }
            }

            // 稳定 tie-breaker：标题 → ID
            let byTitle = lhs.title.localizedStandardCompare(rhs.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

/// 素材类型筛选（默认「全部」，不跨启动保存）
public enum LibraryTypeFilter: String, CaseIterable, Identifiable {
    case all
    case scene
    case video
    case other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "全部"
        case .scene: return "场景"
        case .video: return "视频"
        case .other: return "其他/未知"
        }
    }

    public func matches(_ item: WallpaperItem) -> Bool {
        switch self {
        case .all: return true
        case .scene: return item.type == "scene"
        case .video: return item.type == "video"
        case .other: return item.type != "scene" && item.type != "video"
        }
    }
}

/// X-Ray 状态。
///
/// 「尚未读取」与「读取失败」必须分开：把未知当成「不含 X-Ray」会误筛掉整批素材。
public enum XRayStatus: Equatable, Sendable {
    case unknown      // 尚未读取
    case scanning     // 读取中
    case loaded(Bool) // 读取成功，值表示是否含 X-Ray
    case failed       // 读取失败
    case unavailable  // 没有 pkg，不进入 X-Ray 分类
}

/// X-Ray 筛选（默认「全部」，不跨启动保存）
public enum XRayFilter: String, CaseIterable, Identifiable {
    case all
    case hasXRay
    case noXRay
    case pending
    case failed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "全部"
        case .hasXRay: return "含 X-Ray"
        case .noXRay: return "不含 X-Ray"
        case .pending: return "尚未读取"
        case .failed: return "读取失败"
        }
    }

    /// 无 pkg 的素材不进入任何具体 X-Ray 分类
    public func matches(_ status: XRayStatus) -> Bool {
        switch self {
        case .all:
            return true
        case .hasXRay:
            if case .loaded(true) = status { return true }
            return false
        case .noXRay:
            if case .loaded(false) = status { return true }
            return false
        case .pending:
            return status == .unknown || status == .scanning
        case .failed:
            return status == .failed
        }
    }
}

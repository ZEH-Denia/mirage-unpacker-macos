import SwiftUI

/// 侧栏导航目的地。
///
/// 取代原来的 `Tab` + `LibraryFilter` 两个独立状态：筛选本身就是导航的一档，
/// 这样侧栏只有一套高亮，不会出现「筛选高亮 A、页签高亮 B」的错位。
enum NavItem: Hashable, Identifiable {
    case library(AppModel.LibraryFilter)
    case queue
    case storage

    var id: String {
        switch self {
        case .library(let filter): return "library.\(filter.rawValue)"
        case .queue: return "queue"
        case .storage: return "storage"
        }
    }

    var title: String {
        switch self {
        case .library(let filter): return filter.label
        case .queue: return "队列"
        case .storage: return "存储"
        }
    }

    var icon: String {
        switch self {
        case .library(.all): return "square.grid.2x2"
        case .library(.extractable): return "shippingbox"
        case .library(.notExtracted): return "circle.dashed"
        case .library(.extracted): return "checkmark.circle"
        case .queue: return "tray.full"
        case .storage: return "externaldrive"
        }
    }

    /// 侧栏顺序：四个筛选档
    static let libraryItems: [NavItem] = [
        .library(.all),
        .library(.extractable),
        .library(.notExtracted),
        .library(.extracted),
    ]

    /// 是否为素材库页（主区显示网格）
    var isLibrary: Bool {
        if case .library = self { return true }
        return false
    }
}

import SwiftUI
import AppKit

/// 全局视觉令牌：所有尺寸、间距、颜色、字体的唯一来源。
///
/// 字体映射（重构前 → 现在），作为 review 依据：
/// | 旧写法                          | 位置                  | 现在                          |
/// |---------------------------------|-----------------------|-------------------------------|
/// | `.system(size: 12)`             | TabBar.swift:54       | 已删除（改用系统 Picker）      |
/// | `.system(size: 9, .bold)`       | TabBar.swift:59       | 已删除（低于 HIG 10pt 下限）   |
/// | `.caption2` ×26                 | 列表/队列/存储        | 正文 `.subheadline`，次要 `.caption` |
/// | `.title3.weight(.semibold)`     | 详情页标题            | `.largeTitle.bold()`          |
/// | `.callout.weight(.medium)` 行标题 | 队列行              | `.body` + medium 字重         |
/// | 等宽 11pt                       | 日志                  | 保留（11pt ≥ 10pt，合理例外）  |
enum PKD {
    /// 圆角只有两档：控件 6、卡片 10。替代原先 4/7/8/10/14 并存。
    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 10
    }

    /// 4pt 基准的间距阶梯。
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Size {
        static let thumb: CGFloat = 40
        static let heroWide: CGFloat = 300
        static let heroMedium: CGFloat = 240
        static let heroNarrow: CGFloat = 180
        static let sidebarMin: CGFloat = 240
        static let sidebarIdeal: CGFloat = 280
        static let sidebarMax: CGFloat = 360
        static let contentMin: CGFloat = 520
        static let inspectorMin: CGFloat = 260
        static let inspectorIdeal: CGFloat = 340
        static let inspectorMax: CGFloat = 560
        static let windowMinWidth: CGFloat = 640
        static let windowMinHeight: CGFloat = 520
    }

    /// 窗口宽度断点。全部由列最小宽推导：240 + 520 + 260 = 1020。
    ///
    /// 折叠阈值用 `<=` 而不是 `<`：`.windowResizability(.contentMinSize)` 下三列全开时
    /// 窗口下限就是 1020，用 `<=` 才能在拖到边界时触发折叠、把下限降到 760。
    /// 恢复阈值比折叠阈值高 40pt，避免在边界来回抖动。
    enum Breakpoint {
        static let tabIcons: CGFloat = 1100
        static let tabMenu: CGFloat = 900
        static let inspectorCollapse: CGFloat = 1020
        static let inspectorRestore: CGFloat = 1060
        static let sidebarCollapse: CGFloat = 780
        static let sidebarRestore: CGFloat = 820
    }

    /// 全部走语义色，深浅色自动适配；不再出现 `.white.opacity()` / `Color(white:)`。
    enum Palette {
        static let canvas = Color(nsColor: .windowBackgroundColor)
        static let card = Color(nsColor: .controlBackgroundColor)
        static let hairline = Color(nsColor: .separatorColor)
        static let secondary = Color(nsColor: .secondaryLabelColor)
        static let tertiary = Color(nsColor: .tertiaryLabelColor)
    }
}

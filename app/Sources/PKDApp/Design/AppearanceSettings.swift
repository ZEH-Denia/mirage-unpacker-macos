import SwiftUI
import AppKit
import Combine

/// 外观偏好：只保留有实际意义的个性化项，不再暴露色相/高光/流速这类皮肤参数。
final class AppearanceSettings: ObservableObject {
    // MARK: - 选项

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }
    }

    enum Accent: String, CaseIterable, Identifiable {
        case system, blue, purple, pink, red, orange, green, graphite
        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "系统默认"
            case .blue: return "蓝色"
            case .purple: return "紫色"
            case .pink: return "粉色"
            case .red: return "红色"
            case .orange: return "橙色"
            case .green: return "绿色"
            case .graphite: return "石墨"
            }
        }

        /// nil 表示交回系统强调色
        var color: Color? {
            switch self {
            case .system: return nil
            case .blue: return .blue
            case .purple: return .purple
            case .pink: return .pink
            case .red: return .red
            case .orange: return .orange
            case .green: return .green
            case .graphite: return Color(nsColor: .systemGray)
            }
        }
    }

    enum GlassMode: String, CaseIterable, Identifiable {
        case native, standard, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .native: return "系统原生"
            case .standard: return "标准材质"
            case .off: return "关闭"
            }
        }
    }

    enum Density: String, CaseIterable, Identifiable {
        case compact, standard, comfortable
        var id: String { rawValue }
        var label: String {
            switch self {
            case .compact: return "紧凑"
            case .standard: return "标准"
            case .comfortable: return "宽松"
            }
        }
    }

    enum FontScale: String, CaseIterable, Identifiable {
        case small, standard, large
        var id: String { rawValue }
        var label: String {
            switch self {
            case .small: return "小"
            case .standard: return "标准"
            case .large: return "大"
            }
        }
    }

    enum MotionMode: String, CaseIterable, Identifiable {
        case system, reduced, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "跟随系统"
            case .reduced: return "减弱"
            case .off: return "关闭"
            }
        }
    }

    // MARK: - 持久化

    private enum Keys {
        static let theme = "pkd.appearance.theme"
        static let accent = "pkd.appearance.accent"
        static let glass = "pkd.appearance.glass"
        static let density = "pkd.appearance.density"
        static let font = "pkd.appearance.font"
        static let motion = "pkd.appearance.motion"
        static let thumbnails = "pkd.appearance.thumbnails"
    }

    private let defaults: UserDefaults

    @Published var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme); applyTheme() }
    }

    @Published var accent: Accent {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }

    @Published var glassMode: GlassMode {
        didSet { defaults.set(glassMode.rawValue, forKey: Keys.glass) }
    }

    @Published var density: Density {
        didSet { defaults.set(density.rawValue, forKey: Keys.density) }
    }

    @Published var fontScale: FontScale {
        didSet { defaults.set(fontScale.rawValue, forKey: Keys.font) }
    }

    @Published var motionMode: MotionMode {
        didSet { defaults.set(motionMode.rawValue, forKey: Keys.motion) }
    }

    @Published var showThumbnails: Bool {
        didSet { defaults.set(showThumbnails, forKey: Keys.thumbnails) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        theme = Theme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        accent = Accent(rawValue: defaults.string(forKey: Keys.accent) ?? "") ?? .system
        glassMode = GlassMode(rawValue: defaults.string(forKey: Keys.glass) ?? "") ?? .native
        density = Density(rawValue: defaults.string(forKey: Keys.density) ?? "") ?? .standard
        fontScale = FontScale(rawValue: defaults.string(forKey: Keys.font) ?? "") ?? .standard
        motionMode = MotionMode(rawValue: defaults.string(forKey: Keys.motion) ?? "") ?? .system
        showThumbnails = defaults.object(forKey: Keys.thumbnails) as? Bool ?? true
    }

    // MARK: - 派生值

    static var nativeGlassSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 实际使用的玻璃模式（系统不支持时自动降级为标准材质）
    var effectiveGlassMode: GlassMode {
        glassMode == .native && !Self.nativeGlassSupported ? .standard : glassMode
    }

    var accentColor: Color? { accent.color }

    var nsAppearance: NSAppearance? {
        switch theme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// 列表行垂直内边距
    var rowPadding: CGFloat {
        switch density {
        case .compact: return 2
        case .standard: return 6
        case .comfortable: return 10
        }
    }

    /// 卡片内边距
    var cardPadding: CGFloat {
        switch density {
        case .compact: return 12
        case .standard: return 16
        case .comfortable: return 20
        }
    }

    /// 页面主标题（每屏唯一一处）
    var titleFont: Font {
        switch fontScale {
        case .small: return .title
        case .standard: return .largeTitle
        case .large: return .largeTitle
        }
    }

    /// 正文
    var bodyFont: Font {
        switch fontScale {
        case .small: return .callout
        case .standard: return .body
        case .large: return .title3
        }
    }

    /// 次要信息
    var secondaryFont: Font {
        switch fontScale {
        case .small: return .caption
        case .standard: return .subheadline
        case .large: return .body
        }
    }

    /// 动效是否应当减弱
    func reducesMotion(system: Bool) -> Bool {
        switch motionMode {
        case .system: return system
        case .reduced, .off: return true
        }
    }

    /// 动效是否完全关闭
    var motionDisabled: Bool { motionMode == .off }

    func applyTheme() {
        NSApp.appearance = nsAppearance
    }

    func reset() {
        theme = .system
        accent = .system
        glassMode = .native
        density = .standard
        fontScale = .standard
        motionMode = .system
        showThumbnails = true
    }

    /// 清理 1.3.0 及更早版本留下的皮肤参数
    static func purgeLegacyKeys(defaults: UserDefaults = .standard) {
        let legacy = [
            "pkd.glass.enabled", "pkd.glass.blur", "pkd.glass.tintHue", "pkd.glass.tintStrength",
            "pkd.glass.corner", "pkd.glass.highlight", "pkd.glass.motion", "pkd.glass.speed",
            "pkd.glass.shadow", "pkd.glass.backdrop", "pkd.glass.native", "pkd.glass.tintSaturation",
        ]
        for key in legacy {
            defaults.removeObject(forKey: key)
        }
    }
}

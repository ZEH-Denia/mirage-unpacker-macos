import SwiftUI
import AppKit
import Combine

/// 外观参数：全部持久化，改动即时生效。
final class AppearanceSettings: ObservableObject {
    private enum Keys {
        static let enabled = "pkd.glass.enabled"
        static let blur = "pkd.glass.blur"
        static let tintHue = "pkd.glass.tintHue"
        static let tintStrength = "pkd.glass.tintStrength"
        static let corner = "pkd.glass.corner"
        static let highlight = "pkd.glass.highlight"
        static let motion = "pkd.glass.motion"
        static let speed = "pkd.glass.speed"
        static let shadow = "pkd.glass.shadow"
        static let backdrop = "pkd.glass.backdrop"
        static let native = "pkd.glass.native"
        static let tintSaturation = "pkd.glass.tintSaturation"
    }

    private let defaults: UserDefaults

    /// 总开关：关闭后回退到系统原生材质
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }

    /// 玻璃磨砂强度 0…1（越高越模糊、越不透明）
    @Published var blurStrength: Double {
        didSet { defaults.set(blurStrength, forKey: Keys.blur) }
    }

    /// 色调（0…1 对应色相环）
    @Published var tintHue: Double {
        didSet { defaults.set(tintHue, forKey: Keys.tintHue) }
    }

    /// 色调浓度 0…1
    @Published var tintStrength: Double {
        didSet { defaults.set(tintStrength, forKey: Keys.tintStrength) }
    }

    /// 圆角 8…26
    @Published var cornerRadius: Double {
        didSet { defaults.set(cornerRadius, forKey: Keys.corner) }
    }

    /// 边缘高光强度 0…1（液态玻璃的标志性特征）
    @Published var highlight: Double {
        didSet { defaults.set(highlight, forKey: Keys.highlight) }
    }

    /// 背景流光是否流动
    @Published var liquidMotion: Bool {
        didSet { defaults.set(liquidMotion, forKey: Keys.motion) }
    }

    /// 流动速度 0.2…2.0
    @Published var motionSpeed: Double {
        didSet { defaults.set(motionSpeed, forKey: Keys.speed) }
    }

    /// 面板投影
    @Published var shadow: Bool {
        didSet { defaults.set(shadow, forKey: Keys.shadow) }
    }

    /// 背景流光强度 0…1（0 即纯色背景）
    @Published var backdropStrength: Double {
        didSet { defaults.set(backdropStrength, forKey: Keys.backdrop) }
    }

    /// 色调饱和度 0…1（0 即黑白灰，与「简约」观感一致）
    @Published var tintSaturation: Double {
        didSet { defaults.set(tintSaturation, forKey: Keys.tintSaturation) }
    }

    /// 优先使用系统原生液态玻璃（macOS 26+）；关闭或系统不支持时回退到自绘实现
    @Published var useNativeGlass: Bool {
        didSet { defaults.set(useNativeGlass, forKey: Keys.native) }
    }

    /// 当前系统是否支持原生液态玻璃
    static var nativeGlassSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 实际是否走原生路径
    var nativeActive: Bool {
        useNativeGlass && Self.nativeGlassSupported
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        blurStrength = defaults.object(forKey: Keys.blur) as? Double ?? 0.55
        tintHue = defaults.object(forKey: Keys.tintHue) as? Double ?? 0.60
        tintStrength = defaults.object(forKey: Keys.tintStrength) as? Double ?? 0.12
        cornerRadius = defaults.object(forKey: Keys.corner) as? Double ?? 14
        highlight = defaults.object(forKey: Keys.highlight) as? Double ?? 0.55
        liquidMotion = defaults.object(forKey: Keys.motion) as? Bool ?? true
        motionSpeed = defaults.object(forKey: Keys.speed) as? Double ?? 0.8
        shadow = defaults.object(forKey: Keys.shadow) as? Bool ?? true
        backdropStrength = defaults.object(forKey: Keys.backdrop) as? Double ?? 0.70
        useNativeGlass = defaults.object(forKey: Keys.native) as? Bool ?? true
        tintSaturation = defaults.object(forKey: Keys.tintSaturation) as? Double ?? 0.0
    }

    // MARK: - 派生值

    /// 玻璃色调
    var tintColor: Color {
        Color(hue: tintHue, saturation: tintSaturation * 0.9, brightness: 0.95)
    }

    /// 磨砂对应的 NSVisualEffectView 材质
    var material: NSVisualEffectView.Material {
        if blurStrength < 0.34 { return .hudWindow }
        if blurStrength < 0.68 { return .underWindowBackground }
        return .popover
    }

    /// 磨砂层不透明度：强度越低越透
    var glassOpacity: Double {
        0.35 + blurStrength * 0.5
    }

    func reset() {
        enabled = true
        blurStrength = 0.55
        tintHue = 0.60
        tintStrength = 0.12
        cornerRadius = 14
        highlight = 0.55
        liquidMotion = true
        motionSpeed = 0.8
        shadow = true
        backdropStrength = 0.70
        useNativeGlass = true
        tintSaturation = 0.0
    }
}

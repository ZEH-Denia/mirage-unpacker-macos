import SwiftUI
import AppKit

// MARK: - 真实毛玻璃

/// 包装 NSVisualEffectView。用 `.withinWindow` 而不是 `.behindWindow`：
/// 前者模糊同一窗口内它身后的内容（我们的流光背景），这才是液态玻璃的观感。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode
    var opacity: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.blendingMode = blending
        view.material = material
        view.alphaValue = opacity
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.alphaValue = opacity
        view.state = .active
    }
}

// MARK: - 流光背景

/// 缓慢漂移的色块，被上层玻璃折射后形成「液态」观感。
struct LiquidBackdrop: View {
    @ObservedObject var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var scheme

    private struct Blob {
        let hueOffset: Double
        let scale: Double
        let speedX: Double
        let speedY: Double
        let phase: Double
        let driftX: Double
        let driftY: Double
    }

    private let blobs: [Blob] = [
        Blob(hueOffset: 0.00, scale: 0.55, speedX: 0.11, speedY: 0.08, phase: 0.0, driftX: 0.22, driftY: 0.18),
        Blob(hueOffset: 0.14, scale: 0.48, speedX: -0.08, speedY: 0.12, phase: 1.7, driftX: 0.26, driftY: 0.22),
        Blob(hueOffset: -0.18, scale: 0.62, speedX: 0.07, speedY: -0.10, phase: 3.1, driftX: 0.20, driftY: 0.24),
        Blob(hueOffset: 0.32, scale: 0.40, speedX: -0.13, speedY: -0.07, phase: 4.6, driftX: 0.24, driftY: 0.16),
    ]

    var body: some View {
        let base: [Color] = scheme == .dark
            ? [Color(white: 0.085), Color(white: 0.035)]
            : [Color(white: 0.970), Color(white: 0.900)]

        ZStack {
            LinearGradient(colors: base, startPoint: .top, endPoint: .bottom)

            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !appearance.liquidMotion)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate * appearance.motionSpeed
                Canvas { context, size in
                    guard appearance.backdropStrength > 0.01 else { return }
                    context.addFilter(.blur(radius: 60 + 45 * appearance.blurStrength))

                    // 黑白简约：默认饱和度为 0，色块只是不同明度的灰，形成柔和的云状层次
                    let lightWhites: [Double] = [0.72, 0.94, 0.66, 0.97]
                    let darkWhites: [Double] = [0.30, 0.10, 0.38, 0.06]

                    for (index, blob) in blobs.enumerated() {
                        let cx = size.width * (0.5 + blob.driftX * sin(time * blob.speedX + blob.phase))
                        let cy = size.height * (0.5 + blob.driftY * cos(time * blob.speedY + blob.phase * 1.3))
                        let radius = min(size.width, size.height) * blob.scale

                        let hue = (appearance.tintHue + blob.hueOffset).truncatingRemainder(dividingBy: 1)
                        let tone = scheme == .dark
                            ? darkWhites[index % darkWhites.count]
                            : lightWhites[index % lightWhites.count]
                        let color = Color(hue: hue < 0 ? hue + 1 : hue,
                                          saturation: appearance.tintSaturation,
                                          brightness: tone)

                        let rect = CGRect(x: cx - radius, y: cy - radius,
                                          width: radius * 2, height: radius * 2)
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .radialGradient(
                                Gradient(colors: [
                                    color.opacity(0.65 * appearance.backdropStrength),
                                    color.opacity(0.0)
                                ]),
                                center: CGPoint(x: cx, y: cy),
                                startRadius: 0,
                                endRadius: radius
                            )
                        )
                    }
                }
            }

            // 边缘压暗，让中间的玻璃面板浮起来
            if scheme == .light {
                RadialGradient(
                    colors: [.clear, .black.opacity(0.07)],
                    center: .center,
                    startRadius: 200,
                    endRadius: 900
                )
                .blendMode(.multiply)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 玻璃面板

struct GlassPanel: ViewModifier {
    @ObservedObject var appearance: AppearanceSettings
    var cornerRadius: CGFloat?

    func body(content: Content) -> some View {
        let radius = cornerRadius ?? appearance.cornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .background {
                if appearance.enabled {
                    ZStack {
                        VisualEffectBackground(
                            material: appearance.material,
                            blending: .withinWindow,
                            opacity: appearance.glassOpacity
                        )
                        appearance.tintColor.opacity(appearance.tintStrength * 0.45)
                    }
                } else {
                    Rectangle().fill(.background)
                }
            }
            .clipShape(shape)
            .overlay {
                if appearance.enabled {
                    // 高光描边：左上亮、右下暗，模拟玻璃边缘的折射
                    shape.strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.55 * appearance.highlight), location: 0.0),
                                .init(color: .white.opacity(0.05), location: 0.45),
                                .init(color: .white.opacity(0.28 * appearance.highlight), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
            }
            .overlay(alignment: .top) {
                if appearance.enabled, appearance.highlight > 0.01 {
                    // 顶部内高光
                    shape
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.18 * appearance.highlight), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: max(radius * 1.4, 18))
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(appearance.shadow ? 0.26 : 0), radius: 16, y: 7)
    }
}

/// 玻璃面板的边缘定义：一条细描边 + 投影，让面板从背景里「浮」出来。
/// 原生 glassEffect 不提供这两项，需要自己补。
struct GlassEdge: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .overlay {
                shape.strokeBorder(
                    scheme == .light
                        ? Color.black.opacity(0.10)
                        : Color.white.opacity(0.14),
                    lineWidth: 0.8
                )
            }
            .shadow(
                color: .black.opacity(scheme == .light ? 0.13 : 0.45),
                radius: 18,
                y: 8
            )
    }
}

extension View {
    func glassPanel(_ appearance: AppearanceSettings, cornerRadius: CGFloat? = nil) -> some View {
        modifier(GlassPanel(appearance: appearance, cornerRadius: cornerRadius))
    }

    /// 玻璃之上的「凸起表面」：用于卡片，避免玻璃套玻璃导致糊成一片
    func cardSurface(cornerRadius: CGFloat = 14) -> some View {
        self
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }

    /// 统一入口：macOS 26+ 优先使用系统原生液态玻璃，否则回退到自绘实现。
    ///
    /// 原生 API 只暴露有限的调节项（色调、圆角、是否响应指针），
    /// 模糊强度由系统决定；自绘实现保留完整的强度控制。
    @ViewBuilder
    func pkdGlass(_ appearance: AppearanceSettings,
                  cornerRadius: CGFloat? = nil,
                  interactive: Bool = false) -> some View {
        let radius = cornerRadius ?? appearance.cornerRadius

        if appearance.nativeActive {
            if #available(macOS 26.0, *) {
                self.glassEffect(
                    .regular
                        .tint(appearance.tintColor.opacity(appearance.tintStrength * 0.45))
                        .interactive(interactive),
                    in: .rect(cornerRadius: radius)
                )
                .modifier(GlassEdge(radius: radius))
            } else {
                self.glassPanel(appearance, cornerRadius: cornerRadius)
            }
        } else {
            self.glassPanel(appearance, cornerRadius: cornerRadius)
        }
    }
}

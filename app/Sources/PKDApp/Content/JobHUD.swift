import SwiftUI

/// 浮动任务胶囊：对应 Apple Music 的迷你播放条。
/// 全应用唯一一处自绘玻璃，只承载「正在解包」这一状态，并指向日志。
struct JobHUD: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var accessibility: AccessibilitySettings

    var body: some View {
        Group {
            if model.queue.activeCount > 0 {
                Button {
                    model.setInspectorPresented(true)
                } label: {
                    HStack(spacing: PKD.Space.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在解包 \(model.queue.activeCount) 项")
                            .font(.callout)
                    }
                    .padding(.horizontal, PKD.Space.s)
                    .padding(.vertical, PKD.Space.xs)
                    .pkdFloatingCapsule(
                        mode: appearance.effectiveGlassMode,
                        reduceTransparency: accessibility.reduceTransparency
                    )
                }
                .buttonStyle(.plain)
                .help("点击查看日志")
                .transition(.opacity)
            }
        }
        .animation(animation, value: model.queue.activeCount)
    }

    private var animation: Animation? {
        appearance.reducesMotion(system: accessibility.reduceMotion) ? nil : .easeInOut(duration: 0.2)
    }
}

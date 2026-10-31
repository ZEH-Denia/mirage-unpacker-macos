import SwiftUI

extension View {
    /// 内容层卡片：语义色填充 + 圆角，无描边、无投影、无模糊。
    /// 层级靠对齐、留白和分隔线表达（HIG：相关项分组）。
    func pkdCard(padding: CGFloat = PKD.Space.m, radius: CGFloat = PKD.Radius.card) -> some View {
        self
            .padding(padding)
            .background(
                PKD.Palette.card,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
    }

    /// 全应用唯一一处自绘玻璃：悬浮在内容之上的任务条（对应 Music 的迷你播放条）。
    ///
    /// HIG 只允许 Liquid Glass 出现在控制层，且「仅用于最重要的功能元素」；
    /// 侧栏、工具栏、检查器的玻璃由系统绘制，不在这里处理。
    @ViewBuilder
    func pkdFloatingBar(
        radius: CGFloat = PKD.Radius.bar,
        mode: AppearanceSettings.GlassMode,
        reduceTransparency: Bool
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || mode == .off {
            self
                .background(PKD.Palette.card, in: shape)
                .overlay(shape.strokeBorder(PKD.Palette.hairline, lineWidth: 1))
        } else if mode == .native, #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: radius))
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(PKD.Palette.hairline, lineWidth: 1))
        }
    }
}

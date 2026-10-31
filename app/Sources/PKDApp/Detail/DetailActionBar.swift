import SwiftUI
import PKDKit

/// 详情页底部操作条。
///
/// 由 `ContentColumn` 摆放在内容列最底部，而不是详情页内部——
/// 这样「页面内容 → 任务胶囊 → 底栏」的上下顺序是固定的，
/// 胶囊不会盖住底栏右侧的按钮。
struct DetailActionBar: View {
    let item: WallpaperItem

    @EnvironmentObject private var model: AppModel

    var body: some View {
        // 窄窗口下按钮文字降级为图标；作用域是「当前这一个」，与工具栏的「所选」区分
        let showTitle = model.layout != .narrow

        HStack(spacing: PKD.Space.xs) {
            Button {
                model.requestExtraction(for: [item])
            } label: {
                Label(
                    model.settings.exportImagesOnly ? "导出此壁纸图片" : "解包此壁纸",
                    systemImage: model.settings.exportImagesOnly
                        ? "photo.on.rectangle.angled"
                        : "shippingbox.and.arrow.backward"
                )
                .labelStyle(AdaptiveLabelStyle(showTitle: showTitle))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!item.isExtractable)

            if model.history.entry(for: item.id) != nil {
                Button {
                    model.openOutput(for: item)
                } label: {
                    Label("打开输出", systemImage: "folder")
                        .labelStyle(AdaptiveLabelStyle(showTitle: showTitle))
                }
            }

            Spacer(minLength: PKD.Space.xs)

            Button {
                model.revealInFinder(item.pkgURL ?? item.folderURL)
            } label: {
                Label("在 Finder 中显示", systemImage: "magnifyingglass")
                    .labelStyle(AdaptiveLabelStyle(showTitle: showTitle))
            }
        }
        // 与详情内容同一条左右准线（原来用 16，比内容缩进少 8pt，按钮左缘是歪的）
        .padding(.horizontal, PKD.Layout.pageInset)
        .padding(.vertical, PKD.Space.xs)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

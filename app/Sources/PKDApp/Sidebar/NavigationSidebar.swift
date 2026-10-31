import SwiftUI
import PKDKit

/// 纯导航侧栏：只放目的地，不再放素材清单。
///
/// 素材改为在右侧主区用网格浏览（参考 Apple Music 的信息架构：
/// 左边导航、右边内容）。筛选档位本身也是导航的一档，所以侧栏只有一套高亮。
struct NavigationSidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Section 必须无条件直接挂在 List 下：包 if/ForEach 会让 List(selection:)
        // 认不出行的 tag，选中不高亮也点不中（存储页踩过同样的坑）。
        List(selection: navBinding) {
            Section {
                ForEach(NavItem.libraryItems) { item in
                    navRow(item)
                }
            } header: {
                Text("素材库")
            }

            Section {
                navRow(.queue)
                navRow(.storage)
            } header: {
                Text("任务")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private func navRow(_ item: NavItem) -> some View {
        HStack(spacing: PKD.Space.xs) {
            Label(item.title, systemImage: item.icon)

            Spacer(minLength: PKD.Space.xxs)

            if let count = model.badgeCount(for: item) {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .tag(item)
    }

    /// 取消选择时保持当前页，避免内容区变空白
    private var navBinding: Binding<NavItem?> {
        Binding(
            get: { model.nav },
            set: { if let value = $0 { model.nav = value } }
        )
    }

    private var footer: some View {
        SidebarStatus(
            text: "\(model.extractableCount) 个可解包 · \(model.totalPkgSize)",
            detail: model.selection.isEmpty ? nil : "已选 \(model.selection.count)",
            isBusy: model.isScanning
        )
    }
}

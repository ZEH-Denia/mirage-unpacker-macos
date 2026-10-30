import SwiftUI

/// 自绘分段控件：系统 Picker 的分段标签挂不了角标，
/// 而「队列」需要在有任务时提示，所以这里自己画一个。
struct SegmentedTabs: View {
    @Binding var selection: AppModel.Tab
    /// 每个页签右上角的数字角标（0 表示不显示）
    var badges: [AppModel.Tab: Int] = [:]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppModel.Tab.allCases) { tab in
                segment(tab)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                }
        }
    }

    private func segment(_ tab: AppModel.Tab) -> some View {
        let isSelected = selection == tab
        let badge = badges[tab] ?? 0

        return Button {
            selection = tab
        } label: {
            HStack(spacing: 4) {
                Text(tab.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(.red))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: badge)
    }
}

import SwiftUI

/// 悬停状态。CLT 环境缺 SwiftUIMacros，`@State` 不可用，只能用 ObservableObject。
final class HoverState: ObservableObject {
    @Published var isHovering = false
}

/// 自绘分段控件：系统 Picker 的分段标签挂不了角标，
/// 且需要跟随液态玻璃的质感，所以自己画。
struct SegmentedTabs: View {
    @Binding var selection: AppModel.Tab
    /// 每个页签的角标（0 表示不显示）
    var badges: [AppModel.Tab: Int] = [:]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppModel.Tab.allCases) { tab in
                TabSegment(
                    tab: tab,
                    isSelected: selection == tab,
                    badge: badges[tab] ?? 0
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        selection = tab
                    }
                }
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
                }
        }
    }
}

private struct TabSegment: View {
    let tab: AppModel.Tab
    let isSelected: Bool
    let badge: Int
    let action: () -> Void

    @StateObject private var hover = HoverState()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
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
                        .shadow(color: .red.opacity(0.5), radius: 4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: scheme == .light
                                ? [.white, Color(white: 0.97)]
                                : [.white.opacity(0.26), .white.opacity(0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                scheme == .light ? Color.black.opacity(0.07) : Color.white.opacity(0.30),
                                lineWidth: 0.5
                            )
                    }
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            } else if hover.isHovering {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            }
        }
        .onHover { hover.isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: hover.isHovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: badge)
    }
}

import SwiftUI
import PKDKit

// MARK: - 引擎告警条

/// 内容区顶部的告警条（原来是贴在窗口顶部的 safeAreaInset）。
struct NoticeBar: View {
    let color: Color
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: PKD.Space.xs) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PKD.Space.s)
        .padding(.vertical, PKD.Space.xs)
        .background(color.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - 侧栏状态行

/// 被动信息，不是控制：纯文字，不加材质、不加发丝线。
struct SidebarStatus: View {
    let text: String
    let detail: String?
    let isBusy: Bool

    var body: some View {
        HStack(spacing: PKD.Space.xxs) {
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, PKD.Space.s)
        .padding(.vertical, PKD.Space.xs)
    }
}

// MARK: - 键值行

/// 元数据键值对，用对齐 + 分隔线表达层级，不再用卡片描边。
struct KeyValueRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PKD.Space.s) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 状态标签

/// 符号 + 文字，不单独依赖颜色表意（色觉障碍可用）。
struct StatusTag: View {
    let symbol: String?
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(tint)
    }
}

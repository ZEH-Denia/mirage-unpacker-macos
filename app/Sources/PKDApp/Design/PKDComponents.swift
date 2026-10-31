import SwiftUI
import AppKit
import PKDKit

// MARK: - 文字/图标自适应标签

/// 空间不足时把按钮文字降级为图标。
///
/// 不能写成 `.labelStyle(cond ? .titleAndIcon : .iconOnly)`——三元两侧类型不同，
/// `labelStyle` 是泛型，编译不过。这里用一个具体类型包住分支。
struct AdaptiveLabelStyle: LabelStyle {
    var showTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            if showTitle {
                configuration.title
            }
        }
    }
}

// MARK: - 窗口配置

/// 设置窗口内容最小尺寸；若 `pkd.debug.windowWidth` 存在则按该宽度启动（用于截图回归）。
///
/// 直接设 `contentMinSize` 而不是只依赖 `.windowResizability(.contentMinSize)`：
/// NavigationSplitView 会把列最小宽并入下限（240+520+260=1020），
/// 那样窗口永远到不了 780 的折叠阈值。
struct WindowConfigurator: NSViewRepresentable {
    var minSize: NSSize
    var debugWidth: CGFloat?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView) }
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        window.contentMinSize = minSize

        if let debugWidth, abs(window.frame.width - debugWidth) > 1 {
            var frame = window.frame
            frame.size.width = debugWidth
            window.setFrame(frame, display: true)
        }
    }
}

// MARK: - 滚动条外观

/// 只调整滚动条外观，不改变滚动行为：overlay + 自动隐藏 + 小号。
///
/// SwiftUI 的 `.scrollIndicators(.hidden)` 在个别系统版本上对 `List` 不生效，
/// 用这个作为兜底；也用于日志面板的 NSScrollView。
struct OverlayScrollerConfigurator: NSViewRepresentable {
    var size: NSControl.ControlSize = .small

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(from: nsView) }
    }

    private func configure(from view: NSView) {
        guard let scrollView = sequence(first: view, next: \.superview)
            .first(where: { $0 is NSScrollView }) as? NSScrollView else { return }

        // 尊重系统「始终显示滚动条」：只有 overlay 偏好时才强制 overlay
        if NSScroller.preferredScrollerStyle == .overlay {
            scrollView.scrollerStyle = .overlay
        }
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.controlSize = size
    }
}

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
    var vertical: Bool
    @ViewBuilder let content: () -> Content

    init(_ label: String, vertical: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.vertical = vertical
        self.content = content
    }

    var body: some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: PKD.Space.s))

        layout {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: vertical ? nil : 88, alignment: .leading)
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

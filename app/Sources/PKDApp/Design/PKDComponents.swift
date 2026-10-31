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

/// 把窗口内所有 `NSScrollView` 统一改成 overlay 滚动条。
///
/// 系统「显示滚动条：自动」+ 鼠标时，AppKit 画的是旧式滚动条：
/// 右侧会常驻一条浅色轨道矩形，压在玻璃面板上非常突兀。
/// overlay 样式只在滚动时浮出细滑块，不占位、不画轨道。
///
/// 这里显式覆盖系统偏好——用户明确要求去掉那条白底。
struct WindowScrollStyler: NSViewRepresentable {
    final class Coordinator {
        var lastRun = Date.distantPast
        var observer: NSObjectProtocol?

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        // 设置窗口、弹窗是独立 NSWindow，打开时补一次
        coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                WindowScrollStyler.applyToAllWindows()
            }
        }
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        schedule(view, context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        schedule(nsView, context.coordinator)
    }

    private func schedule(_ view: NSView, _ coordinator: Coordinator) {
        // 节流：RootView 的 body 会因各种状态变化重算，不必每次都遍历视图树
        guard Date().timeIntervalSince(coordinator.lastRun) > 0.4 else { return }
        coordinator.lastRun = Date()

        DispatchQueue.main.async {
            guard let window = view.window else { return }
            Self.apply(to: window.contentView)
            // 切页签/展开检查器会新建滚动视图，稍后再补一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Self.applyToAllWindows()
            }
        }
    }

    static func applyToAllWindows() {
        for window in NSApp.windows {
            apply(to: window.contentView)
        }
    }

    private static func apply(to view: NSView?) {
        guard let view else { return }

        if let scrollView = view as? NSScrollView {
            if scrollView.scrollerStyle != .overlay {
                scrollView.scrollerStyle = .overlay
            }
            if !scrollView.autohidesScrollers {
                scrollView.autohidesScrollers = true
            }
            scrollView.verticalScroller?.controlSize = .small
        }

        for subview in view.subviews {
            apply(to: subview)
        }
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

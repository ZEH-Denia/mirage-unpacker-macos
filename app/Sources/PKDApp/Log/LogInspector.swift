import SwiftUI
import AppKit
import Combine
import PKDKit

/// 日志检查器：由 NavigationSplitView 的 `.inspector` 承载，可折叠。
struct LogInspector: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var accessibility: AccessibilitySettings

    /// 控制器挂在 AppModel 上，菜单栏「清空日志」才能拿到同一实例
    private var controller: LogController { model.logController }

    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            LogTextView(controller: controller, opaque: accessibility.reduceTransparency)
                .overlay {
                    if !controller.hasContent {
                        ContentUnavailableView {
                            Label("暂无日志", systemImage: "text.alignleft")
                        } description: {
                            Text("解包时这里会实时输出引擎日志")
                        }
                        .allowsHitTesting(false)
                    }
                }
        }
        .onReceive(ticker) { _ in
            let lines = model.log.drain()
            if !lines.isEmpty {
                controller.append(lines)
            }
        }
    }

    private var header: some View {
        HStack(spacing: PKD.Space.xs) {
            Text("日志")
                .font(.headline)

            Spacer()

            Button {
                controller.clear()
            } label: {
                Label("清空", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("清空日志显示")
        }
        // 与 NSTextView 的 textContainerInset(8) 对齐，
        // 否则「日志」标题会比下面的日志正文右移 4pt。
        .padding(.horizontal, 8)
        .padding(.vertical, PKD.Space.xs)
    }
}

/// 日志正文：NSTextView 批量追加，避免万行输出把 SwiftUI 主线程打满。
@MainActor
final class LogController: ObservableObject {
    weak var textView: NSTextView?
    private var lineCount = 0
    /// 检查器折叠时 textView 为 nil，此时先缓存；展开后回放，避免日志出现空洞
    private var backlog: [LogSink.Line] = []

    /// 是否已有内容（用于空状态提示）
    @Published private(set) var hasContent = false

    private static let defaultAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.labelColor,
    ]

    func attach(_ textView: NSTextView) {
        self.textView = textView
        guard !backlog.isEmpty else { return }
        let pending = backlog
        backlog.removeAll()
        write(pending)
    }

    func append(_ lines: [LogSink.Line]) {
        guard textView?.textStorage != nil else {
            backlog.append(contentsOf: lines)
            if backlog.count > 6000 {
                backlog.removeFirst(backlog.count - 6000)
            }
            if !hasContent { hasContent = true }
            return
        }
        write(lines)
    }

    func clear() {
        textView?.textStorage?.setAttributedString(NSAttributedString())
        backlog.removeAll()
        lineCount = 0
        hasContent = false
    }

    private func write(_ lines: [LogSink.Line]) {
        guard let textView, let storage = textView.textStorage else { return }

        let chunk = NSMutableAttributedString()
        for line in lines {
            chunk.append(NSAttributedString(string: line.text + "\n", attributes: attributes(for: line.kind)))
            lineCount += 1
        }

        storage.append(chunk)
        trimIfNeeded()
        textView.scrollToEndOfDocument(nil)
        if !hasContent { hasContent = true }
    }

    private func attributes(for kind: LogSink.Kind) -> [NSAttributedString.Key: Any] {
        var attributes = LogController.defaultAttributes
        switch kind {
        case .stdout:
            break
        case .stderr:
            attributes[.foregroundColor] = NSColor.systemRed
        case .warning:
            attributes[.foregroundColor] = NSColor.systemOrange
        case .marker:
            attributes[.foregroundColor] = NSColor.controlAccentColor
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        }
        return attributes
    }

    private func trimIfNeeded() {
        guard lineCount > 6000, let storage = textView?.textStorage else { return }
        let string = storage.string as NSString
        var offset = 0
        var removed = 0

        while removed < 2000 {
            let range = string.range(of: "\n", range: NSRange(location: offset, length: string.length - offset))
            if range.location == NSNotFound { break }
            offset = range.location + 1
            removed += 1
        }

        if offset > 0 {
            storage.deleteCharacters(in: NSRange(location: 0, length: offset))
            lineCount -= removed
        }
    }
}

struct LogTextView: NSViewRepresentable {
    let controller: LogController
    /// 降低透明度开启时用不透明底色，否则交给系统材质
    let opaque: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = opaque
        textView.backgroundColor = opaque ? .textBackgroundColor : .clear
        scrollView.drawsBackground = opaque
        scrollView.backgroundColor = opaque ? .textBackgroundColor : .clear
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // 关键：只允许纵向伸缩 + 容器宽度跟随视图宽度，长路径才会自动折行
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        // 细窄的 overlay 滚动条：只在滚动时出现，不占列宽、不画轨道。
        // 系统「自动」+ 鼠标时默认是旧式滚动条，右侧会多出一条白底矩形。
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.controlSize = .small
        scrollView.horizontalScrollElasticity = .none

        controller.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        textView.drawsBackground = opaque
        textView.backgroundColor = opaque ? .textBackgroundColor : .clear
        scrollView.drawsBackground = opaque
        scrollView.backgroundColor = opaque ? .textBackgroundColor : .clear

        if controller.textView !== textView {
            controller.attach(textView)
        }
    }
}

import SwiftUI
import AppKit
import Combine
import PKDKit

struct LogPanelView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var controller = LogController()

    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            LogTextView(controller: controller)
        }
        .onReceive(ticker) { _ in
            let lines = model.log.drain()
            if !lines.isEmpty {
                controller.append(lines)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .foregroundStyle(.secondary)
            Text("实时日志")
                .font(.callout.weight(.medium))

            Spacer()

            Button {
                controller.clear()
            } label: {
                Image(systemName: "trash")
            }
            .help("清空日志显示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// 日志正文：NSTextView 批量追加，避免万行输出把 SwiftUI 主线程打满。
@MainActor
final class LogController: ObservableObject {
    weak var textView: NSTextView?
    private var lineCount = 0

    private static let defaultAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.labelColor,
    ]

    func append(_ lines: [LogSink.Line]) {
        guard let textView, let storage = textView.textStorage else { return }

        let chunk = NSMutableAttributedString()
        for line in lines {
            chunk.append(NSAttributedString(string: line.text + "\n", attributes: attributes(for: line.kind)))
            lineCount += 1
        }

        storage.append(chunk)
        trimIfNeeded()
        textView.scrollToEndOfDocument(nil)
    }

    func clear() {
        textView?.textStorage?.setAttributedString(NSAttributedString())
        lineCount = 0
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

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
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

        controller.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let textView = scrollView.documentView as? NSTextView, controller.textView !== textView {
            controller.textView = textView
        }
    }
}

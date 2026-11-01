import SwiftUI
import PKDKit

/// 网格里的一张壁纸卡片：16:9、圆角、标题压在图上（参考 Apple Music 的类别卡片）。
///
/// 卡片只接收值参数，**不订阅 AppModel**：`AppModel` 会转发 `queue.objectWillChange`
/// （解包时约 10Hz），若每张卡都观察它，26 张卡会跟着进度条一起重算。
struct WallpaperCard: View {
    let item: WallpaperItem
    let isSelected: Bool
    let isExtracted: Bool
    let xrayStatus: XRayStatus
    let onTap: () -> Void

    @EnvironmentObject private var appearance: AppearanceSettings
    @StateObject private var thumbnail = CardThumbnail()
    @StateObject private var hover = HoverState()

    var body: some View {
        // 用 Rectangle + aspectRatio 定死 16:9，再用 overlay 叠图与文字：
        // 直接把 aspectRatio 加在含 scaledToFill 图片的 ZStack 上，
        // 图片的理想尺寸会顶掉比例，卡片会变成竖图。
        Rectangle()
            .fill(PKD.Palette.card)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay { thumbnailView }
            .overlay {
                // 压暗下半部分，保证白色标题在浅色壁纸上也读得清
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.55), .black.opacity(0.78)],
                    startPoint: .init(x: 0.5, y: 0.42),
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) { caption }
            .overlay(alignment: .topTrailing) { badges }
            .clipShape(RoundedRectangle(cornerRadius: PKD.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PKD.Radius.card, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: isSelected ? 2 : 0
                    )
            }
            .opacity(item.isExtractable ? 1 : 0.55)
            .scaleEffect(hover.isHovering ? 1.015 : 1)
            .shadow(color: .black.opacity(hover.isHovering ? 0.18 : 0), radius: 10, y: 4)
            .zIndex(hover.isHovering ? 1 : 0)
            .animation(animation, value: hover.isHovering)
            .contentShape(RoundedRectangle(cornerRadius: PKD.Radius.card, style: .continuous))
            .onTapGesture(perform: onTap)
            .onHover { hover.isHovering = $0 }
            .help(item.title)
            // 键盘可达：Tab 聚焦后用空格或回车选中，与点击走同一条路径
            .focusable()
            .onKeyPress(.space) { onTap(); return .handled }
            .onKeyPress(.return) { onTap(); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .task(id: item.id) { await loadThumbnail() }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .font(appearance.cardTitleFont.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(metaLine)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.78))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var animation: Animation? {
        appearance.reducesMotion(system: false) ? nil : .easeOut(duration: 0.12)
    }

    private var metaLine: String {
        var parts = [item.typeLabel]
        if item.pkgSize > 0 { parts.append(item.sizeText) }
        if !item.isExtractable { parts.append("不可解包") }
        return parts.joined(separator: " · ")
    }

    /// VoiceOver 需要把状态读全：标题、类型、体积、能否解包、是否已解包、X-Ray 状态
    private var accessibilityDescription: String {
        var parts = [item.title, item.typeLabel]
        if item.pkgSize > 0 { parts.append(item.sizeText) }
        parts.append(item.isExtractable ? "可解包" : "不可解包")
        parts.append(isExtracted ? "已解包" : "未解包")

        switch xrayStatus {
        case .loaded(true): parts.append("含 X-Ray")
        case .loaded(false): parts.append("不含 X-Ray")
        case .scanning: parts.append("X-Ray 读取中")
        case .failed: parts.append("X-Ray 读取失败")
        case .unknown: parts.append("X-Ray 尚未读取")
        case .unavailable: break   // 无 pkg，不参与 X-Ray 分类
        }

        return parts.joined(separator: "，")
    }

    // MARK: - 缩略图

    @ViewBuilder
    private var thumbnailView: some View {
        if !appearance.showThumbnails {
            placeholder
        } else if let image = thumbnail.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .transition(.opacity)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            PKD.Palette.card
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(.tertiary)
        }
    }

    private func loadThumbnail() async {
        guard appearance.showThumbnails, let url = item.previewURL else { return }
        let decodeTask = Task.detached(priority: .utility) { () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            // ThumbnailLoader 自带 NSCache（64MB / 256 条），滚动回来不会重复解码
            guard let cg = ThumbnailLoader.thumbnail(for: url, maxPixel: 480) else { return nil }
            guard !Task.isCancelled else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        let image = await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
        guard !Task.isCancelled else { return }
        if let image { thumbnail.image = image }
    }

    // MARK: - 角标

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if case .loaded(true) = xrayStatus {
                tag("X-Ray", symbol: "eye", tint: .orange)
            }
            if isExtracted {
                tag(nil, symbol: "checkmark.circle.fill", tint: .green)
            }
            if !item.isExtractable {
                tag(nil, symbol: "nosign", tint: .white.opacity(0.9))
            }
        }
        .padding(8)
    }

    private func tag(_ text: String?, symbol: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
            if let text {
                Text(text).font(.caption2.weight(.medium))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

/// 每张卡自己的 hover 状态：避免把 hover 放到共享模型里导致整格重绘
final class HoverState: ObservableObject {
    @Published var isHovering = false
}

/// 卡片缩略图状态（CLT 环境没有 SwiftUI 宏，不能用 @State）
final class CardThumbnail: ObservableObject {
    @Published var image: NSImage?
}

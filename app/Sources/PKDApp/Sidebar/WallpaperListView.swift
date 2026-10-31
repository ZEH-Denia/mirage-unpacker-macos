import SwiftUI
import PKDKit

struct WallpaperListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        List(selection: $model.selection) {
            Section("素材库") {
                ForEach(model.filteredItems) { item in
                    WallpaperRow(item: item)
                        .tag(item.id)
                        .selectionDisabled(!item.isExtractable)
                        .contextMenu {
                            Button("解包此项") {
                                model.selection = [item.id]
                                model.requestExtraction()
                            }
                            .disabled(!item.isExtractable)

                            if model.history.entry(for: item.id) != nil {
                                Button("打开输出目录") {
                                    model.openOutput(for: item)
                                }
                            }

                            Button("在 Finder 中显示") {
                                model.revealInFinder(item.pkgURL ?? item.folderURL)
                            }

                            Button("复制文件夹路径") {
                                model.copyPath(item.folderURL)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "搜索标题或 ID")
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .overlay {
            if model.filteredItems.isEmpty {
                ContentUnavailableView {
                    Label(
                        model.isScanning ? "正在扫描…" : "没有可显示的壁纸",
                        systemImage: model.isScanning ? "hourglass" : "photo.on.rectangle.angled"
                    )
                } description: {
                    Text(model.isScanning ? "正在读取素材库" : "检查素材库路径是否正确，或调整筛选条件")
                } actions: {
                    Button("重新扫描") { model.refresh() }
                        .disabled(model.isScanning)
                    if model.filter != .all {
                        Button("清除筛选") { model.filter = .all }
                    }
                }
            }
        }
    }

    private var footer: some View {
        SidebarStatus(
            text: "\(model.extractableCount) 个可解包 · \(model.totalPkgSize)",
            detail: model.selection.isEmpty ? nil : "已选 \(model.selection.count)",
            isBusy: model.isScanning
        )
    }
}

/// 缩略图异步状态（避免用 @State，CLT 环境缺少 SwiftUI 宏插件）
final class ThumbnailState: ObservableObject {
    @Published var image: NSImage?
}

struct WallpaperRow: View {
    let item: WallpaperItem

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings
    @StateObject private var thumbnail = ThumbnailState()

    var body: some View {
        HStack(spacing: PKD.Space.xs) {
            if appearance.showThumbnails {
                thumbnailView
                    .frame(width: PKD.Size.thumb, height: PKD.Size.thumb)
                    .clipShape(RoundedRectangle(cornerRadius: PKD.Radius.control, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: PKD.Space.xs) {
                    Text(item.typeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if item.pkgSize > 0 {
                        Text(item.sizeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if model.xrayFlags[item.id] == true {
                        StatusTag(symbol: "eye", text: "X-Ray", tint: .orange)
                    }

                    if model.history.entry(for: item.id) != nil {
                        StatusTag(symbol: "checkmark.circle", text: "已解包", tint: .green)
                    }
                }
            }

            Spacer(minLength: 0)

            if !item.isExtractable {
                Image(systemName: "nosign")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("该壁纸没有可解包的 pkg（视频类壁纸）")
            }
        }
        .padding(.vertical, appearance.rowPadding / 2)
        .opacity(item.isExtractable ? 1 : 0.55)
        .task(id: item.id) {
            guard appearance.showThumbnails else { return }
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let image = thumbnail.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .transition(.opacity)
        } else {
            ZStack {
                Rectangle().fill(.quaternary.opacity(0.35))
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func loadThumbnail() async {
        guard let url = item.previewURL else { return }
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let cg = ThumbnailLoader.thumbnail(for: url, maxPixel: 128) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value

        if let image {
            thumbnail.image = image
        }
    }
}

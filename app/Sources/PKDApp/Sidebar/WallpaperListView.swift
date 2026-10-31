import SwiftUI
import PKDKit

struct WallpaperListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
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
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .searchable(text: $model.searchText, prompt: "搜索标题或 ID")
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .toolbar {
            ToolbarItem {
                Picker("筛选", selection: $model.filter) {
                    ForEach(AppModel.LibraryFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .help("筛选列表")
            }
        }
        .overlay {
            if model.filteredItems.isEmpty {
                ContentUnavailableView(
                    model.isScanning ? "正在扫描…" : "没有可显示的壁纸",
                    systemImage: model.isScanning ? "hourglass" : "photo.on.rectangle.angled",
                    description: Text(model.isScanning ? "正在读取素材库" : "检查素材库路径是否正确，或调整筛选条件")
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.isScanning {
                ProgressView().controlSize(.small)
            }
            Text("\(model.extractableCount) 个可解包 · \(model.totalPkgSize)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !model.selection.isEmpty {
                Text("已选 \(model.selection.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
        }
    }
}

/// 缩略图异步状态（避免用 @State，CLT 环境缺少 SwiftUI 宏插件）
final class ThumbnailState: ObservableObject {
    @Published var image: NSImage?
}

struct WallpaperRow: View {
    let item: WallpaperItem

    @EnvironmentObject private var model: AppModel
    @StateObject private var thumbnail = ThumbnailState()
    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(spacing: 10) {
            thumbnailView
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    badge(item.typeLabel, color: item.isExtractable ? .accentColor : .secondary)

                    if item.pkgSize > 0 {
                        Text(item.sizeText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if model.xrayFlags[item.id] == true {
                        badge("X-Ray", color: .orange)
                    }

                    if model.history.entry(for: item.id) != nil {
                        badge("已解包", color: .green)
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
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background {
            if hover.isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .opacity(item.isExtractable ? 1 : 0.55)
        .onHover { hover.isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.isHovering)
        .task(id: item.id) {
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
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
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

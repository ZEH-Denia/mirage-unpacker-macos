import SwiftUI
import PKDKit

struct WallpaperListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        List(selection: $model.selection) {
            Section {
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
            } header: {
                HStack {
                    Text("素材库")
                    Spacer()
                    Text("\(model.filteredItems.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.hidden)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "搜索标题或 ID")
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .overlay {
            if model.filteredItems.isEmpty {
                ContentUnavailableView {
                    Label(
                        model.isScanning ? "正在扫描…" : "没有可显示的壁纸",
                        systemImage: model.isScanning ? "hourglass" : "photo.on.rectangle.angled"
                    )
                } description: {
                    Text(emptyDescription)
                } actions: {
                    Button("重新扫描") { model.refresh() }
                        .disabled(model.isScanning)
                }
            }
        }
    }

    private var emptyDescription: String {
        if model.isScanning {
            return "正在读取素材库"
        }
        if model.filter != .all {
            return "当前筛选：\(model.filter.label)。切换上方筛选，或检查素材库路径。"
        }
        return "检查素材库路径是否正确。"
    }

    /// 筛选与素材放在一起：常驻在列表上方（不用 Section header，避免随内容滚走）
    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            Picker("筛选", selection: $model.filter) {
                ForEach(AppModel.LibraryFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("筛选")

            Picker("筛选", selection: $model.filter) {
                ForEach(AppModel.LibraryFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, PKD.Space.s)
        .padding(.vertical, PKD.Space.xs)
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

                ViewThatFits(in: .horizontal) {
                    metadataLine(full: true)
                        .fixedSize(horizontal: true, vertical: false)
                    metadataLine(full: false)
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

    /// 侧栏行的次要信息：宽度够时显示完整文案，不够时只留符号
    private func metadataLine(full: Bool) -> some View {
        HStack(spacing: PKD.Space.xs) {
            if full {
                Text(item.typeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if item.pkgSize > 0 {
                Text(item.sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.xrayFlags[item.id] == true {
                StatusTag(symbol: "eye", text: full ? "X-Ray" : "", tint: .orange)
            }

            if model.history.entry(for: item.id) != nil {
                StatusTag(symbol: "checkmark.circle", text: full ? "已解包" : "", tint: .green)
            }
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

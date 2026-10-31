import SwiftUI
import PKDKit

struct WallpaperListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var accessibility: AccessibilitySettings

    var body: some View {
        // 筛选放进 List 内部：侧栏内容会被搜索框/工具栏覆盖，
        // 放在 List 外（VStack 或 safeAreaInset）都会被压到搜索框下面看不见。
        List(selection: $model.selection) {
            filterDisclosure
                .selectionDisabled(true)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 4))

            if model.isFilterExpanded {
                filterOptions
                    .selectionDisabled(true)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 6))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

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

    /// 筛选：默认收起成一个按钮，点开才显示四段选项，省出侧栏纵向空间
    private var filterDisclosure: some View {
        Button {
            withAnimation(expandAnimation) {
                model.isFilterExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("筛选")
                    .font(.caption.weight(.medium))

                if model.filter != .all {
                    Text(model.filter.label)
                        .font(.caption)
                        .foregroundStyle(.tint)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(model.isFilterExpanded ? 90 : 0))
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.isFilterExpanded ? "收起筛选" : "展开筛选")
        .accessibilityLabel("筛选，当前 \(model.filter.label)")
        .accessibilityHint(model.isFilterExpanded ? "收起筛选选项" : "展开筛选选项")
    }

    private var expandAnimation: Animation? {
        accessibility.reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    /// 四段选项；侧栏太窄或字号放大放不下时退化为菜单
    private var filterOptions: some View {
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

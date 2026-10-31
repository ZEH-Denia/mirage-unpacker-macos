import SwiftUI
import PKDKit

struct WallpaperListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        // 筛选放进 List 内部：侧栏内容会被搜索框/工具栏覆盖，
        // 放在 List 外（VStack 或 safeAreaInset）都会被压到搜索框下面看不见。
        List(selection: $model.selection) {
            filterMenu
                .selectionDisabled(true)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 4))

            Section {
                if model.filteredItems.isEmpty {
                    // 空状态放进列表里而不是 overlay：
                    // overlay 会盖住上面的筛选行，筛选后无结果时就点不回来了。
                    emptyState
                        .selectionDisabled(true)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8))
                } else {
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
    }

    private var emptyState: some View {
        VStack(spacing: PKD.Space.xs) {
            Image(systemName: model.isScanning ? "hourglass" : "photo.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.tertiary)

            Text(model.isScanning ? "正在扫描…" : "没有可显示的壁纸")
                .font(.callout.weight(.medium))

            Text(emptyDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("重新扫描") { model.refresh() }
                .disabled(model.isScanning)
                .padding(.top, PKD.Space.xxs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PKD.Space.xs)
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

    /// 筛选：一行按钮，点开是竖向的选项面板（与最初版本一致）。
    /// 不用 List 内插入带动画的行——那种写法会卡住主线程。
    private var filterMenu: some View {
        Button {
            model.isFilterMenuPresented.toggle()
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

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 侧栏行内容自带约 20pt 的尾部内缩，箭头会比搜索框右缘短一截；
            // 往右借 10pt，让箭头与搜索框、行的右缘落在同一条线上。
            .padding(.trailing, -10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("筛选素材")
        .accessibilityLabel("筛选，当前 \(model.filter.label)")
        .popover(isPresented: filterPopoverBinding, arrowEdge: .bottom) {
            filterPopover
        }
    }

    private var filterPopoverBinding: Binding<Bool> {
        Binding(
            get: { model.isFilterMenuPresented },
            set: { model.isFilterMenuPresented = $0 }
        )
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(AppModel.LibraryFilter.allCases) { filter in
                Button {
                    model.filter = filter
                    model.isFilterMenuPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Text(filter.label)
                            .font(.body)
                        Spacer(minLength: 12)
                        if model.filter == filter {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 170)
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
            // 文字列必须吃满剩余宽度：靠 Spacer 撑开时，
            // 长标题会把末尾的 nosign 图标挤出侧栏边界。
            .frame(maxWidth: .infinity, alignment: .leading)

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

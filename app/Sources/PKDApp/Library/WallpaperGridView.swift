import SwiftUI
import AppKit
import PKDKit

/// 素材库主区：标题行 + 居中搜索 + 壁纸网格。
struct WallpaperGridView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            LibraryFilterBar()
            grid
        }
    }

    // MARK: - 页头

    private var header: some View {
        HStack(alignment: .center, spacing: PKD.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text("素材库")
                    .font(appearance.titleFont.weight(.bold))

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: PKD.Space.m)

            searchField
                .frame(maxWidth: PKD.Size.searchWidth)
        }
        .padding(.horizontal, PKD.Layout.pageInset)
        .padding(.top, PKD.Space.l)
        .padding(.bottom, PKD.Space.s)
    }

    private var subtitle: String {
        var parts: [String] = []
        if model.filter != .all { parts.append(model.filter.label) }
        if model.typeFilter != .all { parts.append("类型：\(model.typeFilter.label)") }
        if model.xrayFilter != .all { parts.append("X-Ray：\(model.xrayFilter.label)") }
        parts.append("\(model.filteredItems.count) 项")
        if !model.searchText.isEmpty { parts.append("搜索「\(model.searchText)」") }
        if !model.selection.isEmpty { parts.append("已选 \(model.selection.count)") }
        return parts.joined(separator: " · ")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("搜索标题或 ID", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.callout)

            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(PKD.Palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(PKD.Palette.hairline, lineWidth: 1))
    }

    // MARK: - 网格

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: appearance.gridMin, maximum: appearance.gridMax),
            spacing: appearance.gridSpacing
        )]
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: appearance.gridSpacing) {
                ForEach(model.filteredItems) { item in
                    WallpaperCard(
                        item: item,
                        isSelected: model.selection.contains(item.id),
                        isExtracted: model.history.entry(for: item.id) != nil,
                        xrayStatus: model.xrayState(for: item.id)
                    ) {
                        handleTap(item)
                    }
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
            .padding(.horizontal, PKD.Layout.pageInset)
            .padding(.bottom, PKD.Space.l)
        }
        .overlay {
            if model.filteredItems.isEmpty {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                model.isScanning ? "正在扫描…" : "没有可显示的壁纸",
                systemImage: model.isScanning ? "hourglass" : "photo.on.rectangle.angled"
            )
        } description: {
            Text(emptyDescription)
        } actions: {
            if model.hasExtraFilters {
                Button("清除筛选") { model.clearExtraFilters() }
            }
            Button("重新扫描") { model.refresh() }
                .disabled(model.isScanning)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDescription: String {
        if model.isScanning { return "正在读取素材库" }

        var conditions: [String] = []
        if !model.searchText.isEmpty { conditions.append("搜索「\(model.searchText)」") }
        if model.filter != .all { conditions.append(model.filter.label) }
        if model.typeFilter != .all { conditions.append("类型 \(model.typeFilter.label)") }
        if model.xrayFilter != .all { conditions.append("X-Ray \(model.xrayFilter.label)") }

        if !conditions.isEmpty {
            return "当前条件：" + conditions.joined(separator: " · ")
        }
        return "检查素材库路径是否正确。"
    }

    // MARK: - 交互

    /// 单击选中、⌘ 切换、⇧ 区间、双击直接解包。
    ///
    /// 不用 `.onTapGesture(count: 2)`：那会给单击加 250ms 延迟。
    /// 修饰键直接读 `NSEvent.modifierFlags`，因为 SwiftUI 的点击手势拿不到。
    private func handleTap(_ item: WallpaperItem) {
        let flags = NSEvent.modifierFlags
        let isCommand = flags.contains(.command)
        let isShift = flags.contains(.shift)
        let isDoubleClick = NSApp.currentEvent?.clickCount == 2

        if isDoubleClick, item.isExtractable {
            model.selection = [item.id]
            model.requestExtraction(for: [item])
            return
        }

        if isCommand {
            if model.selection.contains(item.id) {
                model.selection.remove(item.id)
            } else {
                model.selection.insert(item.id)
            }
            model.selectionAnchor = item.id
        } else if isShift,
                  let anchor = model.selectionAnchor,
                  let from = model.filteredItems.firstIndex(where: { $0.id == anchor }),
                  let to = model.filteredItems.firstIndex(where: { $0.id == item.id }) {
            let range = from <= to ? from...to : to...from
            model.selection = Set(model.filteredItems[range].map(\.id))
        } else {
            model.selection = [item.id]
            model.selectionAnchor = item.id
        }

        revealDetail()
    }

    /// 选中后把详情露出来：宽窗开检查器，窄窗弹面板
    private func revealDetail() {
        model.inspectorTab = .detail
        if model.compactDetailMode {
            model.isDetailSheetPresented = true
        } else if !model.isInspectorPresented {
            model.setInspectorPresented(true)
        }
    }
}

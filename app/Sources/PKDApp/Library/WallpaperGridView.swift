import SwiftUI
import AppKit
import PKDKit

/// 素材库主区：标题行 + 居中搜索 + 壁纸网格。
struct WallpaperGridView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            LibraryFilterBar()
            if model.filter == .recent {
                HStack {
                    Text("最近查看或导出的素材，按时间排列").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("清空最近使用") { model.clearRecent() }.controlSize(.small)
                }.padding(.horizontal, PKD.Layout.pageInset).padding(.bottom, PKD.Space.xs)
            }
            grid
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importWallpapers(urls)
            return !urls.isEmpty
        } isTargeted: { model.isDropTargeted = $0 }
        .overlay {
            if model.isDropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3)
                    .overlay { Text("拖入壁纸包或文件夹").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 页头

    private var header: some View {
        HStack(alignment: .center, spacing: PKD.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text("素材库")
                    .font(appearance.titleFont.weight(.bold))

                HStack(spacing: PKD.Space.xs) {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if hiddenSelectionCount > 0 {
                        Button("清除隐藏选择") {
                            model.clearHiddenSelection()
                        }
                        .font(.caption)
                        .help("取消选择当前搜索结果中隐藏的素材")
                    }
                }
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
        parts.append("\(model.filteredItems.count) 项")
        if !model.searchText.isEmpty { parts.append("搜索「\(model.searchText)」") }
        if !model.selection.isEmpty { parts.append("已选 \(model.selection.count)") }
        if hiddenSelectionCount > 0 { parts.append("其中 \(hiddenSelectionCount) 项被隐藏") }
        return parts.joined(separator: " · ")
    }

    private var hiddenSelectionCount: Int {
        model.selection.subtracting(Set(model.filteredItems.map(\.id))).count
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("搜索标题或 ID", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                // 只有 placeholder 时 VoiceOver 读不到稳定的控件名；补一个显式 label
                .accessibilityLabel("搜索标题或 ID")

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
        .padding(.horizontal, PKD.Control.hPadding)
        .frame(height: PKD.Control.fieldHeight)
        // 与筛选栏按钮同一套形状：圆角矩形而不是胶囊，半径略大一级
        .background(
            PKD.Palette.controlFill,
            in: RoundedRectangle(cornerRadius: PKD.Control.fieldRadius, style: .continuous)
        )
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
                        xrayStatus: model.xrayState(for: item.id),
                        isFavorite: model.collections.favoriteIDs.contains(item.id)
                    ) {
                        handleTap(item)
                    }
                    .contextMenu {
                        Button(model.collections.favoriteIDs.contains(item.id) ? "取消收藏" : "收藏") { model.toggleFavorite(item) }
                        if item.id.hasPrefix("local-") {
                            Button("移出临时素材") { model.removeImported(item) }
                        }
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
            .animation(sortAnimation, value: model.sort)
            // 密度切换不做过场动画：实测（400 卡）它会制造 13–19 次 CA Stalls、
            // CPU p95 从 ~48% 抬到 ~114%，因为每帧都要重排整屏卡片；
            // 逐帧过渡并不比重排本身更容易看清。排序动画只有 1–3 次 Stalls，保留。
            .animation(layoutAnimation, value: model.isInspectorPresented)
            // 排序菜单本身用 `withAnimation` 提交变更（LibraryFilterBar），只把三个
            // `.animation` 置空拦不住它。减少动态效果时，这里直接把网格子树的动画关掉，
            // 否则「设置 → 动效 → 关闭」下卡片仍会做约 240ms 的重新排列过渡。
            .transaction { transaction in
                if motionReduced {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
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

    /// 减少动态效果时，网格的排序/密度/检查器重排不做过渡动画。
    private var motionReduced: Bool {
        appearance.reducesMotion(system: accessibilityReduceMotion)
    }

    private var sortAnimation: Animation? {
        motionReduced ? nil : .snappy(duration: 0.24)
    }

    private var layoutAnimation: Animation? {
        motionReduced ? nil : .snappy(duration: 0.2)
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
            Button("重新扫描") { model.refresh() }
                .disabled(model.isScanning)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDescription: String {
        if model.isScanning { return "正在读取素材库" }
        if model.searchText.isEmpty, model.filter == .favorites { return "在卡片右键菜单或详情中收藏素材，即可在这里找到。" }
        if model.searchText.isEmpty, model.filter == .recent { return "查看或导出素材后，会在这里按访问时间显示。" }

        var conditions: [String] = []
        if !model.searchText.isEmpty { conditions.append("搜索「\(model.searchText)」") }
        if model.filter != .all { conditions.append(model.filter.label) }

        if !conditions.isEmpty {
            return "当前条件：" + conditions.joined(separator: " · ")
        }
        return "未找到场景壁纸，请检查素材库路径。"
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
        // 只在鼠标事件上读取 clickCount：键盘触发的选中（Space/Return）不是鼠标事件，
        // 在 keyDown 上取 clickCount 会抛 ObjC 异常，SwiftUI 吞掉后整段选中逻辑都不执行。
        let currentEvent = NSApp.currentEvent
        let isMouseEvent = currentEvent?.type == .leftMouseDown || currentEvent?.type == .leftMouseUp
        let isDoubleClick = isMouseEvent && currentEvent?.clickCount == 2

        if isDoubleClick, item.isExtractable {
            model.markVisited(item)
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

        model.markVisited(item)
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

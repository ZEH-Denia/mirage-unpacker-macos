import SwiftUI
import PKDKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var accessibility: AccessibilitySettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView(columnVisibility: columnBinding) {
            NavigationSidebar()
                .navigationSplitViewColumnWidth(
                    min: PKD.Size.sidebarMin,
                    ideal: PKD.Size.sidebarIdeal,
                    max: PKD.Size.sidebarMax
                )
        } detail: {
            ContentColumn()
                .navigationSplitViewColumnWidth(min: PKD.Size.contentMin, ideal: 760)
                .background(PKD.Palette.canvas)
                .inspector(isPresented: inspectorBinding) {
                    InspectorPanel()
                        .inspectorColumnWidth(
                            min: PKD.Size.inspectorMin,
                            ideal: PKD.Size.inspectorIdeal,
                            max: PKD.Size.inspectorMax
                        )
                }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(appearance.accentColor)
        .toolbar { toolbarContent }
        .frame(minWidth: PKD.Size.windowMinWidth, minHeight: PKD.Size.windowMinHeight)
        .background(
            WindowConfigurator(
                minSize: NSSize(width: PKD.Size.windowMinWidth, height: PKD.Size.windowMinHeight),
                debugWidth: UserDefaults.standard.object(forKey: "pkd.debug.windowWidth") as? CGFloat
            )
        )
        .background(WindowScrollStyler())
        .sheet(item: $model.exportGallery) { request in
            ExportGallery(request: request) { model.exportGallery = nil }
        }
        .task {
            // 冒烟钩子：pkd.debug.settings=1 时自动打开设置窗口，供截图回归
            guard UserDefaults.standard.bool(forKey: "pkd.debug.settings") else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            openSettings()
        }
        .onGeometryChange(for: WindowWidthRegion.self) {
            WindowWidthRegion(width: $0.size.width)
        } action: { region in
            // 必须测 NavigationSplitView 外层：折叠检查器会改变内容列宽度，
            // 若测内容列会形成「折叠→变宽→展开→变窄」的回环
            Task { @MainActor in model.noteWindowWidth(region.representativeWidth) }
        }
        // 窄窗详情使用可点击遮罩，点击详情以外的区域即可返回素材库。
        .overlay {
            if model.isDetailSheetPresented {
                compactDetailOverlay
            }
        }
        .alert("确认解包", isPresented: confirmBinding) {
            Button("取消", role: .cancel) { model.pendingConfirm = nil }
            Button("开始解包") {
                if let request = model.pendingConfirm {
                    model.pendingConfirm = nil
                    model.performExtraction(request.items)
                }
            }
        } message: {
            if let request = model.pendingConfirm {
                Text(confirmMessage(request))
            }
        }
        .alert("提示", isPresented: alertBinding) {
            Button("好", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var compactDetailOverlay: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.45)
                    .contentShape(Rectangle())
                    .onTapGesture { model.isDetailSheetPresented = false }
                    .accessibilityHidden(true)

                VStack(spacing: 0) {
                    HStack {
                        Button {
                            model.isDetailSheetPresented = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .help("关闭详情")
                        .accessibilityLabel("关闭详情")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                    DetailInspector()
                }
                .frame(width: min(420, max(0, geometry.size.width - 32)),
                       height: min(620, max(0, geometry.size.height - 32)))
                .background(Color(nsColor: .windowBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 工具栏

    /// 导航已经在侧栏里，工具栏只留全局动作；
    /// 窄窗侧栏会自动收起，那时才补一个导航菜单，避免无路可走。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.layout == .narrow {
            ToolbarItem(placement: .navigation) {
                navMenu
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.refreshCurrentContext()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("刷新当前页面（⌘R）")
            .disabled(model.isScanning || model.isScanningStorage)

            Button {
                model.toggleInspector()
            } label: {
                Label("检查器", systemImage: "sidebar.trailing")
            }
            .labelStyle(.iconOnly)
            .help("显示或隐藏检查器（⌥⌘L）")

            moreMenu

            Button {
                model.requestExtraction()
            } label: {
                Label(
                    "解包所选",
                    systemImage: model.settings.exportImagesOnly
                        ? "photo.on.rectangle.angled"
                        : "shippingbox.and.arrow.backward"
                )
            }
            .labelStyle(.iconOnly)
            .help(extractHelp)
            .disabled(model.extractableSelection.isEmpty)
        }
    }

    private var navMenu: some View {
        Menu {
            ForEach(NavItem.libraryItems) { item in
                Button {
                    model.nav = item
                } label: {
                    Label(item.title, systemImage: item.icon)
                }
            }

            Divider()

            Button { model.nav = .queue } label: { Label("队列", systemImage: "tray.full") }
            Button { model.nav = .storage } label: { Label("存储", systemImage: "externaldrive") }
        } label: {
            Label(model.nav.title, systemImage: model.nav.icon)
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .help("切换页面（当前：\(model.nav.title)）")
    }

    private var extractHelp: String {
        let count = model.extractableSelection.count
        let suffix = count > 1 ? "（\(count) 项）" : ""
        return model.settings.exportImagesOnly
            ? "导出所选壁纸的图片\(suffix)（⌘↩）"
            : "解包所选壁纸\(suffix)（⌘↩）"
    }

    /// 页面级命令合并进一个「更多」菜单，随导航位置变化
    private var moreMenu: some View {
        Menu {
            switch model.nav {
            case .library:
                Button {
                    if let item = model.focusedItem {
                        model.revealInFinder(item.pkgURL ?? item.folderURL)
                    }
                } label: {
                    Label("在 Finder 中显示", systemImage: "magnifyingglass")
                }
                .disabled(model.focusedItem == nil)

                Button {
                    if let item = model.focusedItem {
                        model.openOutput(for: item)
                    }
                } label: {
                    Label("打开输出目录", systemImage: "folder")
                }
                .disabled(model.focusedItem == nil || model.history.entry(for: model.focusedItem?.id ?? "") == nil)

            case .queue:
                Button {
                    model.queue.retryAllFailed()
                } label: {
                    Label("重试失败任务", systemImage: "arrow.clockwise.circle")
                }
                .disabled(model.queue.failedCount == 0)

                Button {
                    model.queue.removeFinished()
                } label: {
                    Label("清除已完成任务", systemImage: "trash")
                }
                .disabled(!model.queue.jobs.contains { $0.state.isTerminal })

            case .storage:
                // 全选 / 移到废纸篓是存储页页头上的常驻按钮，这里不重复
                EmptyView()
            }

            Divider()

            Button {
                model.queue.cancelAll()
            } label: {
                Label("取消全部任务", systemImage: "stop.circle")
            }
            .disabled(model.queue.activeCount == 0)
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .help("更多操作")
    }

    // MARK: - 绑定

    private var columnBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.columnVisibility },
            set: { model.setColumnVisibility($0) }
        )
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { model.isInspectorPresented },
            set: { model.setInspectorPresented($0) }
        )
    }

    // MARK: - 提示

    private var confirmBinding: Binding<Bool> {
        Binding(
            get: { model.pendingConfirm != nil },
            set: { if !$0 { model.pendingConfirm = nil } }
        )
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )
    }

    private func confirmMessage(_ request: AppModel.ConfirmRequest) -> String {
        let estimate = ByteCountFormatter.string(fromByteCount: request.estimateBytes, countStyle: .file)

        if model.settings.exportImagesOnly {
            var text = "将从 \(request.items.count) 个壁纸导出图片到：\n\(model.settings.imageExportRoot.path)"
            var counts: [ExportAssessment.Kind: Int] = [:]
            for item in request.items {
                let info = item.pkgURL.flatMap { model.infoCache[$0.path] }
                let kind = info.map { ExportAssessment(info: $0).kind } ?? .unknown
                counts[kind, default: 0] += 1
            }
            text += "\n\n" + ExportAssessment.Kind.allCases.compactMap { kind in
                guard let count = counts[kind] else { return nil }
                return "\(kind.title)：\(count) 项"
            }.joined(separator: "\n")
            text += "\n\n解包在临时目录进行，完成后只保留图片，其余自动清理。"
            if let available = request.availableBytes {
                text += "\n临时空间需求约 \(estimate)，当前剩余 "
                    + ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                if available < request.estimateBytes {
                    text += "\n\n⚠️ 临时目录所在磁盘剩余空间可能不足。"
                }
            }
            return text
        }

        var text = "将解包 \(request.items.count) 个壁纸，预计占用 \(estimate)。\n输出到：\(model.settings.outputRoot.path)"
        if let available = request.availableBytes {
            let availableText = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            text += "\n磁盘剩余：\(availableText)"
            if available < request.estimateBytes {
                text += "\n\n⚠️ 剩余空间可能不足。"
            }
        }
        return text
    }
}

/// Only notify the model when a resize crosses a layout threshold. The
/// intermediate regions preserve the existing collapse/restore hysteresis.
private enum WindowWidthRegion: Equatable {
    case sidebarCollapsed, sidebarGap, narrow, medium, inspectorGap, wideGap, wide

    init(width: CGFloat) {
        switch width {
        case ...PKD.Breakpoint.sidebarCollapse: self = .sidebarCollapsed
        case ..<PKD.Breakpoint.sidebarRestore: self = .sidebarGap
        case ..<PKD.Breakpoint.tabMenu: self = .narrow
        case ...PKD.Breakpoint.inspectorCollapse: self = .medium
        case ..<PKD.Breakpoint.inspectorRestore: self = .inspectorGap
        case ..<PKD.Breakpoint.tabIcons: self = .wideGap
        default: self = .wide
        }
    }

    var representativeWidth: CGFloat {
        switch self {
        case .sidebarCollapsed: return PKD.Breakpoint.sidebarCollapse
        case .sidebarGap: return PKD.Breakpoint.sidebarCollapse + 1
        case .narrow: return PKD.Breakpoint.sidebarRestore
        case .medium: return PKD.Breakpoint.tabMenu
        case .inspectorGap: return PKD.Breakpoint.inspectorCollapse + 1
        case .wideGap: return PKD.Breakpoint.inspectorRestore
        case .wide: return PKD.Breakpoint.tabIcons
        }
    }
}

// MARK: - 内容区

private struct ContentColumn: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            notice

            Group {
                switch model.nav {
                case .library:
                    WallpaperGridView()
                case .queue:
                    JobQueueView()
                case .storage:
                    StorageView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 任务条占据底部安全区：为它让位，绝不盖住页面内容
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TaskBar()
        }
    }

    @ViewBuilder
    private var notice: some View {
        switch model.engineStatus {
        case .missing(let attempted):
            NoticeBar(
                color: .red,
                icon: "exclamationmark.triangle.fill",
                title: "未找到 repkg 引擎",
                detail: attempted.prefix(2).joined(separator: "  ·  ")
            )
        case .broken(let message):
            NoticeBar(
                color: .orange,
                icon: "exclamationmark.triangle.fill",
                title: "repkg 引擎无法运行",
                detail: message
            )
        case .unknown, .ok:
            EmptyView()
        }
    }
}

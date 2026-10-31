import SwiftUI
import PKDKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var accessibility: AccessibilitySettings

    var body: some View {
        NavigationSplitView(columnVisibility: columnBinding) {
            WallpaperListView()
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
                    LogInspector()
                        .inspectorColumnWidth(
                            min: PKD.Size.inspectorMin,
                            ideal: PKD.Size.inspectorIdeal,
                            max: PKD.Size.inspectorMax
                        )
                }
                .overlay(alignment: .bottomTrailing) {
                    JobHUD()
                        .padding([.trailing, .bottom], PKD.Space.m)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            // 必须测 NavigationSplitView 外层：折叠检查器会改变内容列宽度，
            // 若测内容列会形成「折叠→变宽→展开→变窄」的回环
            Task { @MainActor in model.noteWindowWidth(width) }
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

    // MARK: - 工具栏

    /// 只保留一个后缘组：HIG 要求后缘项常驻、群组不超过三个，
    /// 且 `.primaryAction` 本身就是右对齐语义，不需要 ToolbarSpacer。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            tabSwitcher
                .help("切换详情 / 队列 / 存储（⌘1 ⌘2 ⌘3）")

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
                Label("日志", systemImage: "sidebar.trailing")
            }
            .labelStyle(.iconOnly)
            .help("显示或隐藏日志（⌥⌘L）")

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

    private var extractHelp: String {
        let count = model.extractableSelection.count
        let suffix = count > 1 ? "（\(count) 项）" : ""
        return model.settings.exportImagesOnly
            ? "导出所选壁纸的图片\(suffix)（⌘↩）"
            : "解包所选壁纸\(suffix)（⌘↩）"
    }

    /// 视图切换：宽窗口用文字分段，中等用图标分段，窄窗口退化为菜单
    @ViewBuilder
    private var tabSwitcher: some View {
        switch model.layout {
        case .wide:
            Picker("视图", selection: $model.selectedTab) {
                ForEach(AppModel.Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

        case .medium:
            Picker("视图", selection: $model.selectedTab) {
                ForEach(AppModel.Tab.allCases) { tab in
                    Image(systemName: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

        case .narrow:
            Picker("视图", selection: $model.selectedTab) {
                ForEach(AppModel.Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    /// 页面级命令合并进一个「更多」菜单，随页签变化
    private var moreMenu: some View {
        Menu {
            switch model.selectedTab {
            case .detail:
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
                Button {
                    model.selectAllStorage(nil)
                } label: {
                    Label("全选", systemImage: "checklist")
                }
                .disabled(model.storageItems.isEmpty)

                Button(role: .destructive) {
                    model.requestTrashSelection()
                } label: {
                    Label("移到废纸篓", systemImage: "trash")
                }
                .disabled(model.storageSelection.isEmpty)
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
            text += "\n\n解包在临时目录进行，完成后只保留图片，其余自动清理。"
            if let available = request.availableBytes {
                text += "\n临时空间需求约 \(estimate)，当前剩余 "
                    + ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
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

// MARK: - 内容区

private struct ContentColumn: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            notice

            // 不做 .id() + transition：切页时整棵子树重建会明显卡顿，
            // 直接交换内容更快，也避免与列表/滚动状态互相干扰。
            Group {
                switch model.selectedTab {
                case .detail:
                    WallpaperDetailView()
                case .queue:
                    JobQueueView()
                case .storage:
                    StorageView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

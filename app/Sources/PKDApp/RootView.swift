import SwiftUI
import PKDKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var accessibility: AccessibilitySettings

    var body: some View {
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
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
                .inspector(isPresented: $model.isInspectorPresented) {
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Picker("筛选", selection: $model.filter) {
                    ForEach(AppModel.LibraryFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("筛选列表")
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("视图", selection: $model.selectedTab) {
                ForEach(AppModel.Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .help("切换详情 / 队列 / 存储")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("重新扫描素材库（⌘R）")
            .disabled(model.isScanning)

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
            .help(model.settings.exportImagesOnly ? "只导出正常层 / X-Ray 层图片（⌘↩）" : "解包所选壁纸（⌘↩）")
            .disabled(model.extractableSelection.isEmpty)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.isInspectorPresented.toggle()
            } label: {
                Label("日志", systemImage: "sidebar.trailing")
            }
            .help("显示或隐藏日志（⌥⌘L）")
        }

        ToolbarItem(placement: .secondaryAction) {
            Button {
                model.queue.cancelAll()
            } label: {
                Label("取消全部", systemImage: "stop.circle")
            }
            .help("取消所有进行中的任务（⌘.）")
            .disabled(model.queue.activeCount == 0)
        }
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
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var accessibility: AccessibilitySettings

    var body: some View {
        VStack(spacing: 0) {
            notice

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
            .id(model.selectedTab)
            .transition(.opacity)
        }
        .animation(tabAnimation, value: model.selectedTab)
    }

    private var tabAnimation: Animation? {
        appearance.reducesMotion(system: accessibility.reduceMotion) ? nil : .easeInOut(duration: 0.18)
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

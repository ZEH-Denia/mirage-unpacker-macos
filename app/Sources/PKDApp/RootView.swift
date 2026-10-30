import SwiftUI
import PKDKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            WallpaperListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
        } content: {
            VStack(spacing: 0) {
                SegmentedTabs(
                    selection: $model.selectedTab,
                    badges: [.queue: model.queueBadgeCount]
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                switch model.selectedTab {
                case .detail:
                    WallpaperDetailView()
                case .queue:
                    JobQueueView()
                case .storage:
                    StorageView()
                }
            }
            .navigationSplitViewColumnWidth(min: 440, ideal: 560)
        } detail: {
            LogPanelView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 400)
        }
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .top, spacing: 0) { engineBanner }
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

    @ViewBuilder
    private var engineBanner: some View {
        switch model.engineStatus {
        case .missing(let attempted):
            banner(
                color: .red,
                icon: "exclamationmark.triangle.fill",
                title: "未找到 repkg 引擎",
                detail: attempted.prefix(2).joined(separator: "  ·  ")
            )
        case .broken(let message):
            banner(
                color: .orange,
                icon: "exclamationmark.triangle.fill",
                title: "repkg 引擎无法运行",
                detail: message
            )
        case .unknown, .ok:
            EmptyView()
        }
    }

    private func banner(color: Color, icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(color.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
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
                    model.settings.exportImagesOnly ? "导出图片" : "解包所选",
                    systemImage: model.settings.exportImagesOnly
                        ? "photo.on.rectangle.angled"
                        : "shippingbox.and.arrow.backward"
                )
            }
            .help(model.settings.exportImagesOnly ? "只导出正常层 / X-Ray 层图片（⌘↩）" : "解包所选壁纸（⌘↩）")
            .disabled(model.extractableSelection.isEmpty)

            Button {
                model.queue.cancelAll()
            } label: {
                Label("取消全部", systemImage: "stop.circle")
            }
            .help("取消所有进行中的任务（⌘.）")
            .disabled(model.queue.activeCount == 0)
        }
    }
}

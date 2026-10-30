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
                Picker("", selection: $model.selectedTab) {
                    Text("详情").tag(AppModel.Tab.detail)
                    Text(queueTitle).tag(AppModel.Tab.queue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                switch model.selectedTab {
                case .detail:
                    WallpaperDetailView()
                case .queue:
                    JobQueueView()
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

    private var queueTitle: String {
        let active = model.queue.jobs.filter { !$0.state.isTerminal }.count
        return active > 0 ? "队列 (\(active))" : "队列"
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
                Label("解包所选", systemImage: "shippingbox.and.arrow.backward")
            }
            .help("解包所选壁纸（⌘↩）")
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

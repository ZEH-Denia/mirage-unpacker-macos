import SwiftUI
import AppKit
import PKDKit

struct StorageView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !model.storageRootWarnings.isEmpty {
                warnings
            }

            if model.storageItems.isEmpty {
                ContentUnavailableView {
                    Label(
                        model.isScanningStorage ? "正在统计…" : "没有可清理的内容",
                        systemImage: model.isScanningStorage ? "hourglass" : "externaldrive"
                    )
                } description: {
                    Text(model.isScanningStorage
                         ? "正在计算各目录占用"
                         : "解包产物与导出图片都会出现在这里，可随时清理")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .onAppear {
            if model.storageItems.isEmpty {
                model.refreshStorage()
            }
        }
        .sheet(item: $model.pendingStoragePlan, onDismiss: {
            // 关闭确认面板等同取消：不能静默执行任何清理。
            model.storagePlanDismissed()
        }) { plan in
            confirmSheet(plan)
        }
        .alert("清理结果", isPresented: resultBinding) {
            Button("好", role: .cancel) { model.storageResultMessage = nil }
        } message: {
            Text(model.storageResultMessage ?? "")
        }
    }

    // MARK: - 顶部

    private func confirmSheet(_ plan: CleanupPlan) -> some View {
        CleanupConfirmSheet(plan: plan,
                            onCancel: { model.cancelStorageTrash() },
                            onConfirm: { model.performTrashSelection() })
    }

    private var header: some View {
        PageHeader(title: "存储", subtitle: summaryLine, titleFont: appearance.titleFont) {
            HStack(spacing: PKD.Space.xs) {
                Button(allSelected ? "取消全选" : "全选") {
                    if allSelected {
                        model.storageSelection = []
                    } else {
                        model.selectAllStorage(nil)
                    }
                }
                .disabled(model.storageTrashableItems.isEmpty)

                Button(role: .destructive) {
                    model.requestTrashSelection()
                } label: {
                    Label("移到废纸篓", systemImage: "trash")
                }
                .disabled(model.selectedStorageItems.isEmpty)
            }
        }
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: PKD.Space.xxs) {
            ForEach(model.storageRootWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("列表仍会显示这些目录，但无法证明来源的条目一律只读，不会进入清理计划。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, PKD.Space.m)
        .padding(.bottom, PKD.Space.s)
    }

    private var allSelected: Bool {
        StorageCleanupSummary.allTrashableSelected(model.storageSelection, items: model.storageItems)
    }

    private var summaryLine: String {
        StorageCleanupSummary.headerLine(items: model.storageItems,
                                         selection: model.storageSelection)
    }

    // MARK: - 列表

    /// 分段必须**无条件**直接挂在 List 下。
    ///
    /// 踩过的坑：`ForEach(kinds) { Section { … } }` 和 `if !items.isEmpty { Section { … } }`
    /// 这两种写法都会让 `List(selection:)` 认不出段内行的 tag——`storageSelection`
    /// 明明有值，行却不高亮，点行也选不中，「全选」于是看起来毫无反应。
    /// 改成四段常量存在、只让表头按需显示后，选择恢复正常（实测高亮与计数都对）。
    private var list: some View {
        List(selection: selectionBinding) {
            section(.extracted)
            section(.images)
            section(.temporary)
            section(.orphan)
        }
        .listStyle(.inset)
        .scrollIndicators(.hidden)
    }

    /// 只允许选中「可清理」的条目，未知/只读条目不会被全选或误选。
    private var selectionBinding: Binding<Set<String>> {
        Binding(
            get: {
                StorageCleanupSummary.trashableSelection(model.storageSelection,
                                                         items: model.storageItems)
            },
            set: { newValue in
                model.storageSelection = StorageCleanupSummary.trashableSelection(newValue,
                                                                                  items: model.storageItems)
            }
        )
    }

    private func items(_ kind: StorageItem.Kind) -> [StorageItem] {
        model.storageItems(of: kind)
    }

    private func section(_ kind: StorageItem.Kind) -> some View {
        let items = items(kind)
        return Section {
            ForEach(items) { item in
                row(item)
                    .tag(item.id)
                    .contextMenu {
                        Button("在 Finder 中显示") {
                            model.revealInFinder(item.url)
                        }
                        if item.isTrashable {
                            Button("移到废纸篓", role: .destructive) {
                                model.storageSelection = [item.id]
                                model.requestTrashSelection()
                            }
                        }
                    }
            }
        } header: {
            if !items.isEmpty {
                sectionHeader(kind)
            }
        }
    }

    private func sectionHeader(_ kind: StorageItem.Kind) -> some View {
        HStack {
            Text(kind.sectionTitle)
            Spacer()
            Text(ByteCountFormatter.string(
                fromByteCount: items(kind).reduce(0) { $0 + $1.sizeBytes },
                countStyle: .file
            ))
            .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func row(_ item: StorageItem) -> some View {
        HStack(spacing: PKD.Space.xs) {
            Image(systemName: icon(for: item))
                .font(.callout)
                .foregroundStyle(item.isTrashable ? .secondary : .tertiary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: PKD.Space.xxs) {
                    Text(item.displayName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ownershipBadge(item)
                }

                Text("\(item.fileCount) 个文件"
                     + (item.modified.map { " · " + Self.dateFormatter.string(from: $0) } ?? "")
                     + (item.isTrashable ? "" : " · 只读"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let note = item.note, !item.isTrashable {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(item.sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, PKD.Space.xxs)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func ownershipBadge(_ item: StorageItem) -> some View {
        Text(item.ownership.label)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(badgeColor(item).opacity(0.16), in: Capsule())
            .foregroundStyle(badgeColor(item))
    }

    private func badgeColor(_ item: StorageItem) -> Color {
        switch item.ownership {
        case .owned: return .green
        case .legacy: return .blue
        case .temporary: return .orange
        case .unknown: return .secondary
        }
    }

    private func icon(for item: StorageItem) -> String {
        if !item.isTrashable { return "lock" }
        switch item.kind {
        case .extracted: return "shippingbox"
        case .images: return "photo.on.rectangle.angled"
        case .temporary: return "clock.arrow.circlepath"
        case .orphan: return "questionmark.folder"
        }
    }

    private var resultBinding: Binding<Bool> {
        Binding(
            get: { model.storageResultMessage != nil },
            set: { if !$0 { model.storageResultMessage = nil } }
        )
    }
}

// MARK: - 确认面板

/// 清理确认面板：完整列出将被移动的目录、数量和总大小，取消是默认动作。
private struct CleanupConfirmSheet: View {
    let plan: CleanupPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var summary: StorageCleanupSummary {
        StorageCleanupSummary.make(plan: plan)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PKD.Space.s) {
            HStack(spacing: PKD.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("确认清理")
                    .font(.headline)
            }

            Text(summary.headline)
                .font(.callout)

            Text(summary.safetyNote + " 请确认以下路径确实是本应用的输出。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: PKD.Space.xs) {
                    ForEach(summary.rows) { row in
                        rowView(row)
                    }

                    if summary.rejectedCount > 0 {
                        Divider()
                        Text("以下 \(summary.rejectedCount) 项已跳过（状态变化或不符合安全规则）：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(summary.rejectedRows) { row in
                            rowView(row)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 320)

            HStack {
                Text("取消不会移动任何文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("移到废纸篓", role: .destructive) { onConfirm() }
                    .disabled(plan.items.isEmpty)
            }
        }
        .padding(PKD.Space.l)
        .frame(width: 620)
    }

    private func rowView(_ row: StorageCleanupSummary.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.meta)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

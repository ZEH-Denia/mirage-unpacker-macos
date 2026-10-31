import SwiftUI
import AppKit
import PKDKit

struct StorageView: View {
    @EnvironmentObject private var model: AppModel

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.storageItems.isEmpty {
                ContentUnavailableView(
                    model.isScanningStorage ? "正在统计…" : "没有可清理的内容",
                    systemImage: model.isScanningStorage ? "hourglass" : "externaldrive",
                    description: Text(model.isScanningStorage
                        ? "正在计算各目录占用"
                        : "解包产物与导出图片都会出现在这里，可随时清理")
                )
            } else {
                list
            }

            Divider()
            footer
        }
        .onAppear {
            if model.storageItems.isEmpty {
                model.refreshStorage()
            }
        }
        .alert("确认清理", isPresented: confirmBinding) {
            Button("取消", role: .cancel) { model.storageConfirmCount = nil }
            Button("移到废纸篓", role: .destructive) {
                model.storageConfirmCount = nil
                model.performTrashSelection()
            }
        } message: {
            Text(confirmMessage)
        }
        .alert("清理结果", isPresented: resultBinding) {
            Button("好", role: .cancel) { model.storageResultMessage = nil }
        } message: {
            Text(model.storageResultMessage ?? "")
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("存储占用")
                    .font(.callout.weight(.medium))
                Text("共 \(model.storageItems.count) 项 · "
                     + ByteCountFormatter.string(fromByteCount: model.storageTotalBytes, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.refreshStorage()
            } label: {
                Label("重新统计", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanningStorage)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 列表

    private var list: some View {
        List(selection: $model.storageSelection) {
            ForEach(StorageItem.Kind.allCases, id: \.self) { kind in
                let items = model.storageItems(of: kind)
                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            row(item)
                                .tag(item.id)
                                .contextMenu {
                                    Button("在 Finder 中显示") {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                    }
                                    Button("移到废纸篓", role: .destructive) {
                                        model.storageSelection = [item.id]
                                        model.requestTrashSelection()
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text(kind.sectionTitle)
                            Text("\(items.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(ByteCountFormatter.string(
                                fromByteCount: items.reduce(0) { $0 + $1.sizeBytes },
                                countStyle: .file
                            ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            Button("全选") {
                                model.selectAllStorage(kind)
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func row(_ item: StorageItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: item.kind))
                .font(.callout)
                .foregroundStyle(color(for: item.kind))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(item.fileCount) 个文件"
                     + (item.modified.map { " · " + Self.dateFormatter.string(from: $0) } ?? ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(item.sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func icon(for kind: StorageItem.Kind) -> String {
        switch kind {
        case .extracted: return "shippingbox"
        case .images: return "photo.on.rectangle.angled"
        case .temporary: return "clock.arrow.circlepath"
        case .orphan: return "questionmark.folder"
        }
    }

    private func color(for kind: StorageItem.Kind) -> Color {
        switch kind {
        case .extracted: return .accentColor
        case .images: return .green
        case .temporary: return .orange
        case .orphan: return .purple
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            if model.storageSelection.isEmpty {
                Text("勾选要清理的项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("已选 \(model.storageSelection.count) 项 · "
                     + ByteCountFormatter.string(fromByteCount: model.selectedStorageBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("全选") {
                model.selectAllStorage(nil)
            }
            .disabled(model.storageItems.isEmpty)

            Button("移到废纸篓", role: .destructive) {
                model.requestTrashSelection()
            }
            .disabled(model.storageSelection.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var confirmBinding: Binding<Bool> {
        Binding(
            get: { model.storageConfirmCount != nil },
            set: { if !$0 { model.storageConfirmCount = nil } }
        )
    }

    private var resultBinding: Binding<Bool> {
        Binding(
            get: { model.storageResultMessage != nil },
            set: { if !$0 { model.storageResultMessage = nil } }
        )
    }

    private var confirmMessage: String {
        let count = model.storageConfirmCount ?? 0
        let size = ByteCountFormatter.string(fromByteCount: model.selectedStorageBytes, countStyle: .file)
        return "将把 \(count) 项（\(size)）移到废纸篓。\n\n"
            + "文件不会被立即抹除，可在「访达 → 废纸篓」里恢复。"
    }
}

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
        PageHeader(title: "存储", subtitle: summaryLine, titleFont: appearance.titleFont)
    }

    private var summaryLine: String {
        let total = ByteCountFormatter.string(fromByteCount: model.storageTotalBytes, countStyle: .file)
        var line = "共 \(model.storageItems.count) 项 · \(total)"
        if !model.storageSelection.isEmpty {
            let selected = ByteCountFormatter.string(fromByteCount: model.selectedStorageBytes, countStyle: .file)
            line += " · 已选 \(model.storageSelection.count) 项（\(selected)）"
        }
        return line
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
                                        model.revealInFinder(item.url)
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
                            Spacer()
                            Text(ByteCountFormatter.string(
                                fromByteCount: items.reduce(0) { $0 + $1.sizeBytes },
                                countStyle: .file
                            ))
                            .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollIndicators(.hidden)
    }

    private func row(_ item: StorageItem) -> some View {
        HStack(spacing: PKD.Space.xs) {
            Image(systemName: icon(for: item.kind))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(item.fileCount) 个文件"
                     + (item.modified.map { " · " + Self.dateFormatter.string(from: $0) } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(item.sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, PKD.Space.xxs)
    }

    private func icon(for kind: StorageItem.Kind) -> String {
        switch kind {
        case .extracted: return "shippingbox"
        case .images: return "photo.on.rectangle.angled"
        case .temporary: return "clock.arrow.circlepath"
        case .orphan: return "questionmark.folder"
        }
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

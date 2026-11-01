import SwiftUI
import PKDKit

/// 检查器里的详情：为 260–340pt 的窄栏改写。
///
/// 与原来的整页详情相比：预览改成 16:9 自适应高度（不再写死 300）、
/// 元数据一律纵向排列、包内条目默认折叠，保证一屏能看到关键信息。
struct DetailInspector: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        if let item = model.focusedItem {
            content(item)
        } else {
            ContentUnavailableView {
                Label("未选择壁纸", systemImage: "square.grid.2x2")
            } description: {
                Text("在主区网格里点一张壁纸查看详情；按住 ⌘ 或 ⇧ 可多选")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ item: WallpaperItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PKD.Space.m) {
                preview(item)
                header(item)
                actions(item)
                Divider()
                metadata(item)
                Divider()
                entries(item)
            }
            .padding(PKD.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: item.id) {
            model.loadInfo(for: item)
        }
    }

    // MARK: - 预览

    private func preview(_ item: WallpaperItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: PKD.Radius.card, style: .continuous)
                .fill(.quaternary.opacity(0.25))

            if let url = item.previewURL {
                AsyncPreview(url: url)
            } else {
                VStack(spacing: PKD.Space.xxs) {
                    Image(systemName: "photo").font(.title2)
                    Text("无预览图").font(.caption)
                }
                .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: PKD.Radius.card, style: .continuous))
    }

    // MARK: - 标题

    private func header(_ item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text(metaLine(item))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metaLine(_ item: WallpaperItem) -> String {
        var parts = [item.typeLabel]
        if item.pkgSize > 0 { parts.append(item.sizeText) }
        if !item.contentRating.isEmpty { parts.append(item.contentRating) }
        if case .loaded(true) = model.xrayState(for: item.id) { parts.append("含 X-Ray") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 操作

    private func actions(_ item: WallpaperItem) -> some View {
        VStack(spacing: PKD.Space.xs) {
            Button {
                model.requestExtraction(for: [item])
            } label: {
                Label(
                    model.settings.exportImagesOnly ? "导出此壁纸图片" : "解包此壁纸",
                    systemImage: model.settings.exportImagesOnly
                        ? "photo.on.rectangle.angled"
                        : "shippingbox.and.arrow.backward"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .frame(height: 30)
            .disabled(!item.isExtractable)

            HStack(spacing: PKD.Space.xs) {
                if model.history.entry(for: item.id) != nil {
                    Button {
                        model.openOutput(for: item)
                    } label: {
                        Label("打开输出", systemImage: "folder")
                    }
                }

                Button {
                    model.revealInFinder(item.pkgURL ?? item.folderURL)
                } label: {
                    Label("在 Finder 中显示", systemImage: "magnifyingglass")
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: - 元数据

    private func metadata(_ item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: PKD.Space.xs) {
            KeyValueRow("Workshop ID", vertical: true) {
                Text(item.id)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            KeyValueRow("输出目录", vertical: true) {
                Text(OutputLayout.outputDirectory(for: item, root: model.settings.outputRoot).path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }

            if case .loaded(true) = model.xrayState(for: item.id) {
                KeyValueRow("X-Ray", vertical: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("解包时自动分离正常层与 X-Ray 层")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let entry = model.history.entry(for: item.id) {
                            if let clean = entry.xrayCleanFile {
                                Text("正常层：\(clean)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            if let layer = entry.xrayLayerFile {
                                Text("X-Ray 层：\(layer)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            if let issue = item.issue {
                KeyValueRow("提示", vertical: true) {
                    Text(issueText(issue))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func issueText(_ issue: ProjectIssue) -> String {
        switch issue {
        case .missing: return "缺少 project.json，标题回退为文件夹名"
        case .unreadable(let message): return message
        case .noPackage: return "该目录下没有 pkg 文件（视频类壁纸通常如此）"
        case .unsupportedType(let type): return "类型为 \(type)，不支持解包"
        case .previewMissing(let name): return "预览图 \(name) 不存在"
        }
    }

    // MARK: - 包内条目

    @ViewBuilder
    private func entries(_ item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: PKD.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("包内条目").font(.headline)
                Spacer()
                if let key = item.pkgURL?.path, let info = model.infoCache[key] {
                    Text("\(info.entries.count) 项 · \(ByteCountFormatter.string(fromByteCount: info.totalBytes, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let key = item.pkgURL?.path, let info = model.infoCache[key] {
                EntryListView(info: info)
            } else if item.pkgURL == nil {
                Text("没有 pkg 文件").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: PKD.Space.xs) {
                    ProgressView().controlSize(.small)
                    Text("正在读取包结构…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

final class PreviewState: ObservableObject {
    @Published var image: NSImage?
}

/// 预览图也走降采样，避免把 8K 原图读进内存。
struct AsyncPreview: View {
    let url: URL
    @StateObject private var state = PreviewState()

    var body: some View {
        Group {
            if let image = state.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let cg = ThumbnailLoader.thumbnail(for: url, maxPixel: 1024) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
            if let loaded { state.image = loaded }
        }
    }
}

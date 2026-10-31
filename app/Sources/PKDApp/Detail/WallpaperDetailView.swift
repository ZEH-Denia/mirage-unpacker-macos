import SwiftUI
import PKDKit

struct WallpaperDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let item = model.focusedItem {
            detail(for: item)
        } else {
            ContentUnavailableView(
                "未选择壁纸",
                systemImage: "sidebar.left",
                description: Text("在左侧选择单个壁纸查看详情；按住 ⌘ 或 ⇧ 可多选后批量解包")
            )
        }
    }

    private func detail(for item: WallpaperItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                previewSection(item)
                metadataSection(item)
                    .cardSurface()
                entrySection(item)
                    .cardSurface()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar(item) }
        .task(id: item.id) {
            model.loadInfo(for: item)
        }
    }

    // MARK: - 预览

    private func previewSection(_ item: WallpaperItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.25))

            if let url = item.previewURL {
                AsyncPreview(url: url)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                    Text("无预览图").font(.caption)
                }
                .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 260)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    // MARK: - 元数据

    private func metadataSection(_ item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    label("类型")
                    Text(item.typeLabel)
                }
                GridRow {
                    label("Workshop ID")
                    Text(item.id).textSelection(.enabled).font(.callout.monospaced())
                }
                GridRow {
                    label("包大小")
                    Text(item.pkgSize > 0 ? item.sizeText : "—")
                }
                GridRow {
                    label("分级")
                    Text(item.contentRating.isEmpty ? "—" : item.contentRating)
                }
                if model.xrayFlags[item.id] == true {
                    GridRow {
                        label("X-Ray")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("含 X-Ray 效果，解包时自动分离正常层与 X-Ray 层")
                                .font(.caption)
                                .foregroundStyle(.orange)

                            if let entry = model.history.entry(for: item.id) {
                                if let clean = entry.xrayCleanFile {
                                    Text("正常层：\(clean)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                if let layer = entry.xrayLayerFile {
                                    Text("X-Ray 层：\(layer)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                GridRow {
                    label("输出目录")
                    Text(OutputLayout.outputDirectory(for: item, root: model.settings.outputRoot).path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                if let issue = item.issue {
                    GridRow {
                        label("提示")
                        Text(issueText(issue))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 84, alignment: .leading)
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

    // MARK: - 条目

    @ViewBuilder
    private func entrySection(_ item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
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
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取包结构…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 操作条

    private func actionBar(_ item: WallpaperItem) -> some View {
        HStack(spacing: 10) {
            Button {
                model.selection = [item.id]
                model.requestExtraction()
            } label: {
                Label(
                    model.settings.exportImagesOnly ? "导出图片" : "解包",
                    systemImage: model.settings.exportImagesOnly
                        ? "photo.on.rectangle.angled"
                        : "shippingbox.and.arrow.backward"
                )
            }
            .disabled(!item.isExtractable)

            if model.history.entry(for: item.id) != nil {
                Button {
                    model.openOutput(for: item)
                } label: {
                    Label("打开输出", systemImage: "folder")
                }
            }

            Spacer()

            Button {
                model.revealInFinder(item.pkgURL ?? item.folderURL)
            } label: {
                Label("在 Finder 中显示", systemImage: "magnifyingglass")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
        }
    }
}

final class PreviewState: ObservableObject {
    @Published var image: NSImage?
}

/// 大图预览也走降采样，避免把 8K 原图读进内存。
private struct AsyncPreview: View {
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

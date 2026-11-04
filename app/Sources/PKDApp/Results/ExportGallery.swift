import SwiftUI
import AppKit
import PKDKit

struct ExportGalleryRequest: Identifiable {
    let id = UUID()
    let title: String
    let directory: URL
}

@MainActor
private final class GalleryModel: ObservableObject {
    @Published var images: [ExportedImage] = []
    @Published var selection: URL?
    @Published var preview: NSImage?
    @Published var isLoading = true
    @Published var isDecoding = false
    @Published var error: String?
    @Published var zoom: Double = 1
    var selected: ExportedImage? { images.first { $0.id == selection } }

    func load(_ directory: URL) async {
        let task = Task.detached(priority: .userInitiated) { try ExportedImage.scan(directory: directory) }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            images = result
            selection = result.first?.id
        } catch is CancellationError { return }
        catch { self.error = "无法读取导出结果：\(error.localizedDescription)" }
        isLoading = false
    }

    func decode() async {
        preview = nil
        zoom = 1
        guard let url = selection else { return }
        isDecoding = true
        let task = Task.detached(priority: .userInitiated) { ThumbnailLoader.thumbnail(for: url, maxPixel: 2560) }
        let image = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, selection == url else { return }
        preview = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        isDecoding = false
    }

    func step(_ offset: Int) {
        guard let index = images.firstIndex(where: { $0.id == selection }), images.indices.contains(index + offset) else { return }
        selection = images[index + offset].id
    }
}

struct ExportGallery: View {
    let request: ExportGalleryRequest
    let onClose: () -> Void
    @StateObject private var gallery = GalleryModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("关闭结果预览").accessibilityLabel("关闭结果预览")
                    .keyboardShortcut(.cancelAction)
                Text(request.title).font(.headline).lineLimit(1)
                Spacer()
                Text("\(gallery.images.count) 张图片").foregroundStyle(.secondary)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([gallery.selection ?? request.directory]) }
            }.padding()
            Divider()
            if gallery.isLoading {
                ProgressView("正在读取导出图片…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if gallery.images.isEmpty {
                ContentUnavailableView("没有可预览的图片", systemImage: "photo", description: Text(gallery.error ?? "文件可能已移动、删除或未成功导出。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: $gallery.selection) {
                        ForEach(gallery.images) { image in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(image.url.lastPathComponent).lineLimit(2)
                                Text(image.role).font(.caption).foregroundStyle(.secondary)
                            }.tag(image.id).padding(.vertical, 3)
                        }
                    }.frame(width: 210)
                    Divider()
                    VStack(spacing: 8) {
                        preview
                        if let selected = gallery.selected {
                            Text(selected.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if selected.role == "实验性场景预览" {
                                Text("默认静态姿态；可能未包含其他图层、时钟及动态效果。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Button { gallery.step(-1) } label: { Image(systemName: "chevron.left") }
                                .accessibilityLabel("上一张").keyboardShortcut(.leftArrow, modifiers: [])
                                .disabled(gallery.selection == gallery.images.first?.id)
                            Button { gallery.step(1) } label: { Image(systemName: "chevron.right") }
                                .accessibilityLabel("下一张").keyboardShortcut(.rightArrow, modifiers: [])
                                .disabled(gallery.selection == gallery.images.last?.id)
                            Spacer()
                            Text("预览缩放").font(.caption)
                            Slider(value: $gallery.zoom, in: 0.5...3).frame(width: 110)
                                .accessibilityLabel("预览缩放")
                            Button("适应窗口") { gallery.zoom = 1 }
                        }.controlSize(.small)
                    }.padding()
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 480, idealHeight: 620)
        .task(id: request.id) { await gallery.load(request.directory) }
        .task(id: gallery.selection) { await gallery.decode() }
    }

    private var preview: some View {
        GeometryReader { geometry in
            if let image = gallery.preview {
                let ratio = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: image.size.width * ratio * gallery.zoom, height: image.size.height * ratio * gallery.zoom)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                        .accessibilityLabel(gallery.selected?.url.lastPathComponent ?? "导出图片")
                }
            } else if gallery.isDecoding {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("无法预览此文件").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

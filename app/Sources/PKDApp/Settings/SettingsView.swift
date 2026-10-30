import SwiftUI
import AppKit
import PKDKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsForm(settings: model.settings, model: model)
    }
}

private struct SettingsForm: View {
    @ObservedObject var settings: SettingsStore
    let model: AppModel

    var body: some View {
        Form {
            Section("路径") {
                LabeledContent("素材库") {
                    HStack(spacing: 8) {
                        Text(settings.libraryRoot.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("选择…") { chooseLibraryRoot() }
                        Button("恢复默认") {
                            settings.libraryRoot = LibraryScanner.defaultRoot
                            model.refresh()
                        }
                    }
                }

                LabeledContent("输出目录") {
                    HStack(spacing: 8) {
                        Text(settings.outputRoot.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("选择…") { chooseOutputRoot() }
                        Button("打开") {
                            try? FileManager.default.createDirectory(at: settings.outputRoot, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(settings.outputRoot)
                        }
                    }
                }
            }

            Section("导出模式") {
                Picker("模式", selection: $settings.exportImagesOnly) {
                    Text("完整解包").tag(false)
                    Text("仅导出图片").tag(true)
                }
                .pickerStyle(.segmented)

                if settings.exportImagesOnly {
                    LabeledContent("图片目录") {
                        HStack(spacing: 8) {
                            Text(settings.imageExportRoot.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("选择…") { chooseImageRoot() }
                            Button("打开") {
                                try? FileManager.default.createDirectory(
                                    at: settings.imageExportRoot,
                                    withIntermediateDirectories: true
                                )
                                NSWorkspace.shared.open(settings.imageExportRoot)
                            }
                        }
                    }

                    Text("解包到临时目录，只把「正常层」和「X-Ray 层」复制出来，然后清理临时文件。"
                         + "每张壁纸一个子文件夹（<标题>_<workshopID>），里面是 正常.jpg / X-Ray.jpg；"
                         + "没有 X-Ray 的壁纸导出全部图片。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("解包选项") {
                Toggle("覆盖已存在的文件", isOn: $settings.overwrite)
                Toggle("把 TEX 转换为图片", isOn: $settings.convertTextures)
                Toggle("复制 project.json 与预览图", isOn: $settings.copyProjectFiles)
                    .disabled(settings.flattenOutput)
                Toggle("平铺输出（不保留目录结构）", isOn: $settings.flattenOutput)
                Text("平铺后无法自动复制 project.json（repkg 的限制）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("行为") {
                Toggle("完成后在 Finder 中显示", isOn: $settings.openFinderWhenDone)
                Toggle("批量解包前确认", isOn: $settings.confirmBeforeStart)
                Stepper(
                    "同时解包任务数：\(settings.maxConcurrentJobs)",
                    value: $settings.maxConcurrentJobs,
                    in: 1...2
                )
                .onChange(of: settings.maxConcurrentJobs) { newValue in
                    model.queue.concurrency = newValue
                }
                Text("建议保持 1：单个大包解包时内存峰值可达 2–3 GB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("引擎") {
                LabeledContent("状态") {
                    switch model.engineStatus {
                    case .ok(let text):
                        Text(text).font(.caption).foregroundStyle(.green)
                    case .missing:
                        Text("未找到").font(.caption).foregroundStyle(.red)
                    case .broken(let message):
                        Text(message).font(.caption).foregroundStyle(.orange)
                    case .unknown:
                        Text("检测中…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 540)
    }

    private func chooseLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择素材库"
        panel.directoryURL = settings.libraryRoot
        if panel.runModal() == .OK, let url = panel.url {
            settings.libraryRoot = url
            model.refresh()
        }
    }

    private func chooseImageRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择图片目录"
        panel.directoryURL = settings.imageExportRoot
        if panel.runModal() == .OK, let url = panel.url {
            settings.imageExportRoot = url
        }
    }

    private func chooseOutputRoot() {        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择输出目录"
        panel.directoryURL = settings.outputRoot
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputRoot = url
        }
    }
}

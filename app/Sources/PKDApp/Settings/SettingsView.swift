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
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        Form {
            appearanceSection

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
        .frame(width: 600, height: 680)
    }

    // MARK: - 外观

    @ViewBuilder
    private var appearanceSection: some View {
        Section("外观 · 液态玻璃") {
            Toggle("启用玻璃效果", isOn: $appearance.enabled)

            Toggle("使用系统原生液态玻璃", isOn: $appearance.useNativeGlass)
                .disabled(!AppearanceSettings.nativeGlassSupported)
                .help(AppearanceSettings.nativeGlassSupported
                      ? "调用 macOS 26 起的原生 GlassEffect"
                      : "当前系统版本不支持，只能使用自绘实现")

            Text(AppearanceSettings.nativeGlassSupported
                 ? (appearance.nativeActive
                    ? "正在使用系统原生液态玻璃：模糊强度由系统控制，色调与圆角可调。"
                    : "已切换到自绘实现：全部参数可调，但模糊质感与系统原生略有差异。")
                 : "当前系统低于 macOS 26，只能使用自绘实现。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            LabeledContent("色调") {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(appearance.tintColor)
                        .frame(width: 28, height: 16)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
                        }
                    Slider(value: $appearance.tintHue, in: 0...1)
                }
            }

            LabeledContent("色调浓度") {
                Slider(value: $appearance.tintStrength, in: 0...1)
            }

            LabeledContent("饱和度") {
                HStack(spacing: 10) {
                    Slider(value: $appearance.tintSaturation, in: 0...1)
                    Text(appearance.tintSaturation < 0.02 ? "黑白" : String(format: "%.0f%%", appearance.tintSaturation * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .help("0 为纯黑白灰，适合简约风格；调高则背景流光带颜色")

            LabeledContent("圆角") {
                HStack(spacing: 10) {
                    Slider(value: $appearance.cornerRadius, in: 8...26)
                    Text("\(Int(appearance.cornerRadius))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }
            }

            LabeledContent("磨砂强度") {
                Slider(value: $appearance.blurStrength, in: 0.05...1)
            }
            .disabled(appearance.nativeActive)

            LabeledContent("边缘高光") {
                Slider(value: $appearance.highlight, in: 0...1)
            }
            .disabled(appearance.nativeActive)

            Toggle("面板投影", isOn: $appearance.shadow)
                .disabled(appearance.nativeActive)

            Divider()

            Toggle("背景流光", isOn: $appearance.liquidMotion)

            LabeledContent("流光强度") {
                Slider(value: $appearance.backdropStrength, in: 0...1)
            }

            LabeledContent("流动速度") {
                HStack(spacing: 10) {
                    Slider(value: $appearance.motionSpeed, in: 0.2...2)
                    Text(String(format: "%.1f×", appearance.motionSpeed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .disabled(!appearance.liquidMotion)

            Button("恢复默认外观") {
                appearance.reset()
            }
        }
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

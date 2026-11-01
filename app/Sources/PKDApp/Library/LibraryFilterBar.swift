import SwiftUI
import PKDKit

/// 素材库筛选栏：排序、类型、X-Ray、网格密度、清除筛选。
///
/// 控件形状对齐 Mirage 参考界面：统一 26pt 高、6pt 圆角、扁平填充、无边框无下拉箭头。
/// 单独一行而不是塞进页头，是因为页头右侧已经被搜索框占满。
struct LibraryFilterBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        HStack(spacing: PKD.Space.xs) {
            sortMenu
            typeMenu
            xrayMenu

            if model.isScanningXRay {
                xrayProgress
            }

            Spacer(minLength: PKD.Space.xs)

            if model.hasExtraFilters {
                clearButton
            }

            densityMenu
        }
        .padding(.horizontal, PKD.Layout.pageInset)
        .padding(.bottom, PKD.Space.xs)
    }

    // MARK: - 排序

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySort.allCases) { sort in
                Button {
                    model.sort = sort
                } label: {
                    if model.sort == sort {
                        Label(sort.label, systemImage: "checkmark")
                    } else {
                        Text(sort.label)
                    }
                }
            }
        } label: {
            chip(icon: "arrow.up.arrow.down", text: "排序：\(model.sort.shortLabel)")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(ChipSurface())
        .help("排序方式（会记住，下次启动沿用）")
    }

    // MARK: - 类型

    private var typeMenu: some View {
        Menu {
            ForEach(LibraryTypeFilter.allCases) { filter in
                Button {
                    model.typeFilter = filter
                } label: {
                    if model.typeFilter == filter {
                        Label(filter.label, systemImage: "checkmark")
                    } else {
                        Text(filter.label)
                    }
                }
            }
        } label: {
            chip(icon: "square.stack.3d.up", text: "类型：\(model.typeFilter.label)")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(ChipSurface())
        .help("按素材类型筛选，与搜索和侧栏条件叠加")
    }

    // MARK: - X-Ray

    private var xrayMenu: some View {
        Menu {
            ForEach(XRayFilter.allCases) { filter in
                Button {
                    model.xrayFilter = filter
                } label: {
                    if model.xrayFilter == filter {
                        Label("\(filter.label)（\(model.xrayCount(filter))）", systemImage: "checkmark")
                    } else {
                        Text("\(filter.label)（\(model.xrayCount(filter))）")
                    }
                }
            }
        } label: {
            chip(
                icon: "eye",
                text: model.xrayEngineAvailable ? "X-Ray：\(model.xrayFilter.label)" : "X-Ray：不可用"
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(ChipSurface())
        .disabled(!model.xrayEngineAvailable)
        .help(xrayHelp)
    }

    private var xrayHelp: String {
        if !model.xrayEngineAvailable {
            return "找不到 repkg 引擎，无法判定 X-Ray 状态；补齐引擎后可用"
        }
        if model.isScanningXRay {
            return "正在后台读取包结构，完成后可精确筛选"
        }
        return "按是否含 X-Ray 筛选；无 pkg 的素材不参与该分类"
    }

    private var xrayProgress: some View {
        HStack(spacing: 6) {
            ProgressView(
                value: Double(model.xrayScanDone),
                total: Double(max(model.xrayScanTotal, 1))
            )
            .progressViewStyle(.linear)
            .frame(width: 90)

            Text("\(model.xrayScanDone)/\(model.xrayScanTotal)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .help("正在读取 X-Ray 状态")
    }

    // MARK: - 清除筛选

    private var clearButton: some View {
        Button("清除筛选") {
            model.clearExtraFilters()
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.medium))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, PKD.Control.hPadding)
        .frame(height: PKD.Control.height)
        .help("只清除类型与 X-Ray 条件，不动搜索、侧栏与排序")
    }

    // MARK: - 密度

    private var densityMenu: some View {
        Menu {
            ForEach(AppearanceSettings.Density.allCases) { density in
                Button {
                    appearance.density = density
                } label: {
                    if appearance.density == density {
                        Label(density.label, systemImage: "checkmark")
                    } else {
                        Text(density.label)
                    }
                }
            }
        } label: {
            chip(icon: "square.grid.3x3", text: nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(ChipSurface())
        .help("网格密度：\(appearance.density.label)（与设置里的「界面密度」同步）")
    }

    // MARK: - 共用外观

    /// 与参考界面一致的扁平控件内容：图标 + 文字，不加任何背景
    private func chip(icon: String, text: String?) -> some View {
        HStack(spacing: PKD.Control.iconGap) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let text {
                Text(text)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
    }
}

/// 扁平控件外表面：26pt 高、6pt 圆角、轻微填充、无边框。
///
/// 必须套在 `Menu` 外层而不是 label 上——`.menuStyle(.borderlessButton)` 会把
/// label 自身的背景吃掉，套在外面才画得出来。
private struct ChipSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, PKD.Control.hPadding)
            .frame(height: PKD.Control.height)
            .background(
                PKD.Palette.controlFill,
                in: RoundedRectangle(cornerRadius: PKD.Control.radius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: PKD.Control.radius, style: .continuous))
    }
}

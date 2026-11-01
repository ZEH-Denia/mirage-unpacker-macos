import SwiftUI
import PKDKit

/// 素材库筛选栏：排序、类型、X-Ray、网格密度、清除筛选。
///
/// 单独一行而不是塞进页头，是因为页头右侧已经被搜索框占满；
/// 这一行只在素材库页出现，队列/存储页不受影响。
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
                Button("清除筛选") {
                    model.clearExtraFilters()
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .help("只清除类型与 X-Ray 条件，不动搜索、侧栏与排序")
            }

            densityMenu
        }
        .padding(.horizontal, PKD.Layout.pageInset)
        .padding(.bottom, PKD.Space.xs)
    }

    // MARK: - 排序

    private var sortMenu: some View {
        Menu {
            // 不用 Picker(.inline)：Menu 里的 Picker 渲染方式随系统版本变化，
            // 显式 Button + 勾选图标在任何版本都一致。
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
            Label("排序：\(model.sort.shortLabel)", systemImage: "arrow.up.arrow.down")
        }
        .controlSize(.small)
        .fixedSize()
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
            Label("类型：\(model.typeFilter.label)", systemImage: "square.stack.3d.up")
        }
        .controlSize(.small)
        .fixedSize()
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
            Label(
                model.xrayEngineAvailable ? "X-Ray：\(model.xrayFilter.label)" : "X-Ray：不可用",
                systemImage: "eye"
            )
        }
        .controlSize(.small)
        .fixedSize()
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

    // MARK: - 密度

    private var densityMenu: some View {
        Menu {
            Picker("网格密度", selection: $appearance.density) {
                ForEach(AppearanceSettings.Density.allCases) { density in
                    Text(density.label).tag(density)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("网格密度", systemImage: "square.grid.3x3")
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .fixedSize()
        .help("网格密度：\(appearance.density.label)（与设置里的「界面密度」同步）")
    }
}

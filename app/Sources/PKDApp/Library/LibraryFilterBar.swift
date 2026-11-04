import SwiftUI
import PKDKit

/// 素材库工具栏：排序和网格密度。
///
/// 控件形状对齐 Mirage 参考界面：统一 26pt 高、6pt 圆角、扁平填充、无边框无下拉箭头。
/// 单独一行而不是塞进页头，是因为页头右侧已经被搜索框占满。
struct LibraryFilterBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        HStack(spacing: PKD.Space.xs) {
            sortMenu
                .disabled(model.filter == .recent)
            Button { model.chooseLocalPackages() } label: {
                Label("打开壁纸包…", systemImage: "folder.badge.plus")
            }
            .labelStyle(.iconOnly)
            .help("打开壁纸包或文件夹（⌘O），也可拖入素材库")
            .disabled(model.isImporting)

            Spacer(minLength: PKD.Space.xs)

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
                    withAnimation(.snappy(duration: 0.24)) {
                        model.sort = sort
                    }
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

import SwiftUI

/// 右侧检查器外壳：详情与日志共用一个面板，头部小分段切换。
///
/// 这样主区可以整块让给网格，日志也不再单独占一列。
struct InspectorPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch model.inspectorTab {
            case .detail:
                DetailInspector()
            case .logs:
                LogInspector()
            }
        }
    }

    private var header: some View {
        HStack(spacing: PKD.Space.xs) {
            Picker("面板", selection: $model.inspectorTab) {
                Text("详情").tag(AppModel.InspectorTab.detail)
                Text("日志").tag(AppModel.InspectorTab.logs)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: PKD.Space.xs)

            if model.inspectorTab == .logs {
                Button {
                    model.logController.clear()
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!model.logController.hasContent)
                .help("清空日志显示")
            }
        }
        .padding(.horizontal, PKD.Space.s)
        .padding(.vertical, PKD.Space.xs)
    }
}

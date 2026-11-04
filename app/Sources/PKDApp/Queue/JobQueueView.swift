import SwiftUI
import PKDKit

private final class QueueDisplayOptions: ObservableObject {
    enum Filter: String, CaseIterable {
        case all = "全部", active = "未结束", attention = "需处理", finished = "已结束"
        func matches(_ state: JobState) -> Bool {
            switch self {
            case .all: return true
            case .active: return !state.isTerminal
            case .attention:
                if case .failed = state { return true }
                if case .partial = state { return true }
                return false
            case .finished: return state.isTerminal
            }
        }
    }
    @Published var filter: Filter = .all
}

struct JobQueueView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings
    @StateObject private var display = QueueDisplayOptions()
    private var visibleJobs: [ExtractJob] { model.queue.jobs.filter { display.filter.matches($0.state) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.queue.jobs.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        filterPicker.fixedSize()
                        Spacer()
                        queueActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        filterPicker
                        HStack { queueActions; Spacer() }
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, PKD.Layout.pageInset)
                .padding(.bottom, PKD.Space.s)
            }

            if model.queue.jobs.isEmpty {
                ContentUnavailableView {
                    Label("队列为空", systemImage: "tray")
                } description: {
                    Text("在主区选中壁纸，然后按 ⌘↩ 或点工具栏的解包按钮")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleJobs.isEmpty {
                ContentUnavailableView("没有符合条件的任务", systemImage: "line.3.horizontal.decrease.circle", description: Text("切换任务范围可以查看其他任务。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visibleJobs) { job in
                        JobRow(job: job)
                    }
                }
                .listStyle(.inset)
                .scrollIndicators(.hidden)
            }
        }
    }

    private var filterPicker: some View {
        Picker("任务范围", selection: $display.filter) {
            ForEach(QueueDisplayOptions.Filter.allCases, id: \.self) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 360)
    }

    private var queueActions: some View {
        Group {
            Button("重试失败项") { model.queue.retryAllFailed() }
                .disabled(model.queue.failedCount == 0)
            Button("清除已结束") { model.queue.removeFinished() }
                .disabled(!model.queue.jobs.contains { $0.state.isTerminal })
        }
    }

    private var header: some View {
        PageHeader(title: "队列", subtitle: summary, titleFont: appearance.titleFont)
    }

    private var summary: String {
        let snapshot = QueueSummary(states: model.queue.jobs.map(\.state))
        return snapshot.total == 0 ? "共 0 个任务" : "共 \(snapshot.total) 项 · " + snapshot.description
    }
}

struct JobRow: View {
    @ObservedObject var job: ExtractJob
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: PKD.Space.xxs) {
            HStack(spacing: PKD.Space.xs) {
                statusIcon
                Text(job.item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(job.item.sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(job.state.label)
                    .font(.caption)
                    .foregroundStyle(stateColor)
            }

            if job.state.isRunning {
                progressRow
            } else if let report = job.report {
                summaryRow(report)
            }

            if !job.warnings.isEmpty, !job.state.isRunning {
                Text(job.warnings.prefix(2).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            if !job.xray.isEmpty {
                StatusTag(
                    symbol: "eye",
                    text: "X-Ray 已分离：\(job.xray.shortDescription ?? "")",
                    tint: .secondary
                )
                .lineLimit(1)
                .truncationMode(.middle)
            }

            if let export = job.exportedImages, !export.isEmpty {
                StatusTag(
                    symbol: "photo.stack",
                    text: "新增 \(export.files.count) 张 · 跳过 \(export.skippedFiles.count) 张：\(export.summary)",
                    tint: .secondary
                )
                .lineLimit(1)
                .truncationMode(.middle)
            }

            HStack(spacing: PKD.Space.xs) {
                if job.state.isRunning {
                    Button("取消") { model.queue.cancel(job.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption)
                } else if case .failed = job.state {
                    Button("重试") { model.queue.retry(job.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption)
                }

                if job.report?.verdict.isSuccess == true {
                    Button("查看图片") {
                        model.exportGallery = ExportGalleryRequest(title: job.item.title, directory: job.exportedImages?.directory ?? job.outputDirectory)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
                    .disabled(!job.state.isTerminal)
                    // 这里只做「在 Finder 中定位」，与详情页的「打开输出」区分开
                    Button("在 Finder 中显示") {
                        model.revealInFinder(job.exportedImages?.directory ?? job.outputDirectory)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
                }

                Spacer()

                Text(job.durationText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, PKD.Space.xxs)
        .accessibilityElement(children: .contain)
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let fraction = job.progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack(spacing: PKD.Space.xxs) {
                Text(job.progress.phaseText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let total = job.progress.entriesTotal {
                    Text("\(job.progress.entriesDone)/\(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let current = job.progress.currentEntry {
                    Text("· \(current)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func summaryRow(_ report: ExtractReport) -> some View {
        HStack(spacing: PKD.Space.xs) {
            Text("\(report.outputFileCount) 个文件")
            if report.entriesSkipped > 0 {
                Text("跳过 \(report.entriesSkipped)")
            }
            if !report.missingEntries.isEmpty {
                Text("缺失 \(report.missingEntries.count)")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var statusIcon: some View {
        Group {
            switch job.state {
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
            case .inspecting, .running:
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
            case .cancelling:
                Image(systemName: "stop.circle").foregroundStyle(.orange)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .partial:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .cancelled:
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var stateColor: Color {
        switch job.state {
        case .succeeded: return .green
        case .partial: return .yellow
        case .failed: return .red
        default: return .secondary
        }
    }
}

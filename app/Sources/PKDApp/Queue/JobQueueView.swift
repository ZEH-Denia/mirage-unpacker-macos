import SwiftUI
import PKDKit

struct JobQueueView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if model.queue.jobs.isEmpty {
                ContentUnavailableView {
                    Label("队列为空", systemImage: "tray")
                } description: {
                    Text("在左侧选择壁纸，然后按 ⌘↩ 或点击工具栏的解包按钮")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.queue.jobs) { job in
                        JobRow(job: job)
                    }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        model.queue.retryAllFailed()
                    } label: {
                        Label("重试失败", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(model.queue.failedCount == 0)

                    Button {
                        model.queue.removeFinished()
                    } label: {
                        Label("清除已完成", systemImage: "trash")
                    }
                    .disabled(!model.queue.jobs.contains { $0.state.isTerminal })
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .help("队列操作")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PKD.Space.xxs) {
            Text("队列")
                .font(appearance.titleFont.weight(.bold))

            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PKD.Space.l)
        .padding(.top, PKD.Space.l)
        .padding(.bottom, PKD.Space.s)
    }

    private var summary: String {
        if model.queue.activeCount > 0 {
            return "\(model.queue.activeCount) 个进行中 · 共 \(model.queue.jobs.count) 个任务"
        }
        return "共 \(model.queue.jobs.count) 个任务"
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
                    text: "已导出 \(export.files.count) 张：\(export.summary)",
                    tint: .secondary
                )
                .lineLimit(1)
                .truncationMode(.middle)
            }

            HStack(spacing: PKD.Space.xs) {
                if job.state.isRunning {
                    Button("取消") { model.queue.cancel(job.id) }
                        .buttonStyle(.link)
                        .font(.caption)
                } else if case .failed = job.state {
                    Button("重试") { model.queue.retry(job.id) }
                        .buttonStyle(.link)
                        .font(.caption)
                }

                if job.report?.verdict.isSuccess == true {
                    Button(job.exportedImages == nil ? "打开输出" : "打开图片目录") {
                        model.revealInFinder(job.exportedImages?.directory ?? job.outputDirectory)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                Spacer()

                Text(job.durationText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, PKD.Space.xxs)
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

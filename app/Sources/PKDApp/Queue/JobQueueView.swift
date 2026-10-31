import SwiftUI
import PKDKit

struct JobQueueView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.queue.jobs.isEmpty {
            ContentUnavailableView(
                "队列为空",
                systemImage: "tray",
                description: Text("在左侧选择壁纸，然后按 ⌘↩ 或点击工具栏的解包按钮")
            )
        } else {
            List {
                ForEach(model.queue.jobs) { job in
                    JobRow(job: job)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if model.queue.activeCount > 0 {
                ProgressView().controlSize(.small)
                Text("\(model.queue.activeCount) 个进行中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("共 \(model.queue.jobs.count) 个任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.queue.failedCount > 0 {
                Button("重试失败 (\(model.queue.failedCount))") {
                    model.queue.retryAllFailed()
                }
            }

            Button("清除已完成") {
                model.queue.removeFinished()
            }
            .disabled(!model.queue.jobs.contains { $0.state.isTerminal })
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: ExtractJob
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                Text(job.item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(job.item.sizeText)
                    .font(.caption2)
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
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            if !job.xray.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .font(.caption2)
                    Text("X-Ray 已分离：\(job.xray.shortDescription ?? "")")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption2)
                .foregroundStyle(.orange)
            }

            if let export = job.exportedImages, !export.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "photo.stack")
                        .font(.caption2)
                    Text("已导出 \(export.files.count) 张：\(export.summary)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption2)
                .foregroundStyle(.green)
            }

            HStack(spacing: 8) {
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
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
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

            HStack(spacing: 6) {
                Text(job.progress.phaseText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let total = job.progress.entriesTotal {
                    Text("\(job.progress.entriesDone)/\(total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let current = job.progress.currentEntry {
                    Text("· \(current)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func summaryRow(_ report: ExtractReport) -> some View {
        HStack(spacing: 10) {
            Text("\(report.outputFileCount) 个文件")
            if report.entriesSkipped > 0 {
                Text("跳过 \(report.entriesSkipped)")
            }
            if !report.missingEntries.isEmpty {
                Text("缺失 \(report.missingEntries.count)")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2)
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
        case .cancelled: return .secondary
        default: return .secondary
        }
    }
}

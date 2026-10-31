import SwiftUI
import PKDKit

/// 底部任务条：横向悬浮条，对应 Apple Music 的迷你播放条。
///
/// 只在有任务进行时出现，为它让出安全区（safeAreaInset），
/// 因此不会盖住网格最后一行或页面底部的任何控件。
struct TaskBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var accessibility: AccessibilitySettings

    private var activeJobs: [ExtractJob] {
        model.queue.jobs.filter { !$0.state.isTerminal }
    }

    var body: some View {
        Group {
            if let job = activeJobs.first {
                TaskBarContent(
                    job: job,
                    activeCount: activeJobs.count,
                    glassMode: appearance.effectiveGlassMode,
                    reduceTransparency: accessibility.reduceTransparency,
                    onCancel: { model.queue.cancelAll() },
                    onOpenLogs: {
                        model.inspectorTab = .logs
                        model.setInspectorPresented(true)
                    }
                )
            }
        }
        .animation(animation, value: activeJobs.count)
    }

    private var animation: Animation? {
        appearance.reducesMotion(system: accessibility.reduceMotion) ? nil : .easeInOut(duration: 0.2)
    }
}

/// 单独拆出来观察 job：进度大约 10Hz 变化，只让这条状态栏重绘，不牵动网格。
private struct TaskBarContent: View {
    @ObservedObject var job: ExtractJob
    let activeCount: Int
    let glassMode: AppearanceSettings.GlassMode
    let reduceTransparency: Bool
    let onCancel: () -> Void
    let onOpenLogs: () -> Void

    var body: some View {
        HStack(spacing: PKD.Space.s) {
            indicator

            VStack(alignment: .leading, spacing: 1) {
                Text("正在解包 \(activeCount) 项")
                    .font(.callout.weight(.medium))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: PKD.Space.s)

            if let fraction = job.progress.fraction {
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button("取消") { onCancel() }
                .controlSize(.small)

            Button {
                onOpenLogs()
            } label: {
                Image(systemName: "text.alignleft")
            }
            .buttonStyle(.borderless)
            .help("查看日志")
        }
        .padding(.horizontal, PKD.Space.m)
        .padding(.vertical, 10)
        .pkdFloatingBar(mode: glassMode, reduceTransparency: reduceTransparency)
        .padding(.horizontal, PKD.Space.s)
        .padding(.bottom, PKD.Space.s)
    }

    private var detail: String {
        var parts = [job.item.title]
        let phase = job.progress.phaseText
        if !phase.isEmpty { parts.append(phase) }
        if let total = job.progress.entriesTotal, total > 0 {
            parts.append("\(job.progress.entriesDone)/\(total)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var indicator: some View {
        if let fraction = job.progress.fraction {
            ZStack {
                Circle()
                    .strokeBorder(PKD.Palette.hairline, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
        }
    }
}

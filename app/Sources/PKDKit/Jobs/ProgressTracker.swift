import Foundation

/// 单次解包的进度推算。
///
/// repkg 不打印条目总数，所以进度必须由外部先跑 `info -e` 提供 `entriesTotal`；
/// `* Extracting:` 是在写文件**之前**打印的，因此条目要等到下一条事件才算完成。
public struct ProgressTracker {
    private let sizes: [String: Int64]
    private var pendingEntry: String?
    private var lastFraction: Double = 0

    public private(set) var progress = ExtractProgress()

    public init(expected: PkgInfo?) {
        if let expected {
            var map: [String: Int64] = [:]
            for entry in expected.entries {
                map[entry.path] = entry.size
            }
            sizes = map
            progress.entriesTotal = expected.entries.count
            progress.bytesTotal = expected.totalBytes
        } else {
            sizes = [:]
        }
    }

    public mutating func beginInspecting() {
        progress.phase = .inspecting
    }

    public mutating func beginExtracting() {
        progress.phase = .extracting
    }

    public mutating func handle(_ event: RepkgEvent) -> ExtractProgress {
        switch event {
        case .entryExtracting(let path), .entrySkipped(let path):
            completePending()
            pendingEntry = path
            progress.currentEntry = path
            progress.phase = .extracting

        case .textureReading(let name):
            progress.phase = .converting
            progress.currentEntry = name

        case .done:
            completePending()
            progress.phase = .finishing
            if let total = progress.entriesTotal {
                progress.entriesDone = total
            }
            if let total = progress.bytesTotal {
                progress.bytesDone = total
            }

        default:
            break
        }

        // 单调不回退，避免进度条跳回去
        if let fraction = progress.fraction {
            if fraction < lastFraction {
                let total = progress.bytesTotal ?? 0
                if total > 0 {
                    progress.bytesDone = Int64(lastFraction * Double(total))
                }
            } else {
                lastFraction = fraction
            }
        }

        return progress
    }

    private mutating func completePending() {
        guard let path = pendingEntry else { return }
        progress.entriesDone += 1
        progress.bytesDone += sizes[path] ?? 0
        pendingEntry = nil
    }
}

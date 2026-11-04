import Foundation

public struct QueueSummary: Sendable {
    public private(set) var queued = 0
    public private(set) var active = 0
    public private(set) var succeeded = 0
    public private(set) var partial = 0
    public private(set) var failed = 0
    public private(set) var cancelled = 0
    public var total: Int { queued + active + succeeded + partial + failed + cancelled }
    public var description: String {
        let parts = [(queued, "排队"), (active, "进行中"), (succeeded, "成功"), (partial, "部分完成"), (failed, "失败"), (cancelled, "取消")]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
    public init(states: [JobState]) {
        for state in states {
            switch state {
            case .queued: queued += 1
            case .inspecting, .running, .cancelling: active += 1
            case .succeeded: succeeded += 1
            case .partial: partial += 1
            case .failed: failed += 1
            case .cancelled: cancelled += 1
            }
        }
    }
}

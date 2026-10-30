import Foundation

/// 把任意切分的字节流还原成完整的文本行。
///
/// 设计要点：**按字节 0x0A 切分，只在完整行上做 UTF-8 解码**。
/// 0x0A 不可能出现在 UTF-8 多字节序列内部，因此中文文件名不会因为
/// 网络/管道分块而被切成乱码（U+FFFD）。
public struct LineStream {
    private var buffer = Data()
    private let maxLineBytes: Int

    public init(maxLineBytes: Int = 64 * 1024) {
        self.maxLineBytes = maxLineBytes
    }

    /// 追加一块字节，返回本次凑齐的完整行（已去掉行尾 `\r`）。
    public mutating func consume(_ chunk: Data) -> [String] {
        buffer.append(chunk)

        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            lines.append(Self.decode(lineData, maxLineBytes: maxLineBytes))
        }

        // 没有换行的超长行（异常堆栈）：强制吐出，避免缓冲无限增长
        if buffer.count > maxLineBytes {
            lines.append(Self.decode(buffer, maxLineBytes: maxLineBytes))
            buffer.removeAll(keepingCapacity: true)
        }

        return lines
    }

    /// 进程结束后冲刷残留：最后一行可能没有换行符
    /// （repkg 走 `Environment.Exit(0)` 时就是这种情况）。
    public mutating func finish() -> [String] {
        guard !buffer.isEmpty else { return [] }
        let line = Self.decode(buffer, maxLineBytes: maxLineBytes)
        buffer.removeAll(keepingCapacity: true)
        return [line]
    }

    private static func decode(_ data: Data, maxLineBytes: Int) -> String {
        var slice = data
        if slice.last == 0x0D {
            slice = slice.dropLast()
        }

        guard slice.count <= maxLineBytes else {
            let head = String(decoding: slice.prefix(maxLineBytes), as: UTF8.self)
            return head + " …（已截断）"
        }
        return String(decoding: slice, as: UTF8.self)
    }
}

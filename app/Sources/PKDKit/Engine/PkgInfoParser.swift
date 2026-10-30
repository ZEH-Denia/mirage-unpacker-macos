import Foundation

public struct PkgEntryInfo: Sendable, Equatable, Hashable, Codable {
    public let path: String
    public let size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }

    /// 顶层目录名，用于在详情页里做分组（`materials/xxx.tex` → `materials`）
    public var group: String {
        guard let slash = path.firstIndex(of: "/") else { return "（根目录）" }
        return String(path[path.startIndex..<slash])
    }
}

public struct PkgInfo: Sendable, Equatable, Codable {
    public let packagePath: String
    public let entries: [PkgEntryInfo]

    public init(packagePath: String, entries: [PkgEntryInfo]) {
        self.packagePath = packagePath
        self.entries = entries
    }

    public var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.size }
    }

    public var textureCount: Int {
        entries.filter { $0.path.lowercased().hasSuffix(".tex") }.count
    }
}

/// 解析 `repkg info -e` 的输出。
public struct PkgInfoParser {
    public private(set) var packagePath: String?
    public private(set) var entries: [PkgEntryInfo] = []
    public private(set) var sawDone = false
    public private(set) var fatal: RepkgEvent.FatalSignal?

    public init() {}

    public mutating func feed(_ line: String) {
        if line.isEmpty { return }

        if line == "Done" {
            sawDone = true
            return
        }

        if line == "Input file not found" {
            fatal = .inputNotFound
            return
        }

        if line == "Input file/directory doesn't exist!" {
            fatal = .inputPathDoesNotExist
            return
        }

        if line.hasPrefix("### Package info: ") {
            packagePath = String(line.dropFirst("### Package info: ".count))
            return
        }

        // 条目行：`* <path> - <n> bytes`；路径本身可能含 " - "，所以取最后一个
        guard line.hasPrefix("* "), line.hasSuffix(" bytes") else { return }

        let body = String(line.dropFirst(2).dropLast(" bytes".count))
        guard let separator = body.range(of: " - ", options: .backwards) else { return }

        let path = String(body[body.startIndex..<separator.lowerBound])
        let sizeText = String(body[separator.upperBound...])
        guard let size = Int64(sizeText) else { return }

        entries.append(PkgEntryInfo(path: path, size: size))
    }

    public func result() -> PkgInfo? {
        guard sawDone, fatal == nil, let path = packagePath else { return nil }
        return PkgInfo(packagePath: path, entries: entries)
    }
}

import Foundation

public struct RepkgLocation: Sendable {
    public let url: URL
    public let source: String
}

/// 定位 repkg 可执行文件。
/// 顺序：环境变量 → bundle 内的辅助可执行文件 → 可执行文件同级 → 仓库开发路径。
public enum RepkgLocator {
    public static func candidates() -> [RepkgLocation] {
        var list: [RepkgLocation] = []

        if let override = ProcessInfo.processInfo.environment["PKD_REPKG_PATH"], !override.isEmpty {
            list.append(RepkgLocation(url: URL(fileURLWithPath: override), source: "环境变量 PKD_REPKG_PATH"))
        }

        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "repkg") {
            list.append(RepkgLocation(url: bundled, source: "App 内置"))
        }

        let executableDir = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
        list.append(RepkgLocation(url: executableDir.appendingPathComponent("repkg"), source: "可执行文件同级"))

        // 开发期回退：<repo>/tools/bin/repkg（由源码路径反推，仅调试构建有效）
        var repoRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repoRoot.deleteLastPathComponent()
        }
        list.append(RepkgLocation(
            url: repoRoot.appendingPathComponent("tools/bin/repkg"),
            source: "开发目录"
        ))

        return list
    }

    public static func locate() -> Result<RepkgLocation, LocateError> {
        let all = candidates()
        for candidate in all where FileManager.default.isExecutableFile(atPath: candidate.url.path) {
            return .success(candidate)
        }
        return .failure(.notFound(attempted: all.map { "\($0.source): \($0.url.path)" }))
    }

    public enum LocateError: Error, Equatable {
        case notFound(attempted: [String])

        public var message: String {
            switch self {
            case .notFound:
                return "未找到 repkg 引擎"
            }
        }

        public var attemptedPaths: [String] {
            switch self {
            case .notFound(let attempted):
                return attempted
            }
        }
    }
}

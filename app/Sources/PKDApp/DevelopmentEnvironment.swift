import Foundation

/// 仅供独立开发副本使用；未指定根目录时直接终止，避免意外扫描真实素材库。
enum DevelopmentEnvironment {
    static let isDevelopment = Bundle.main.bundleIdentifier == "com.zeh.pkd.development"
    static let root: URL? = {
        guard isDevelopment else { return nil }
        guard let path = ProcessInfo.processInfo.environment["PKD_DEVELOPMENT_ROOT"], path.hasPrefix("/") else {
            fatalError("开发副本必须通过 tools/dev/launch.sh 启动")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()
}

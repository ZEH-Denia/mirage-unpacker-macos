import Foundation

/// 冒烟/自动化导出的测试环境隔离规则。
///
/// 背景：正式应用的 `imageExportRoot` 默认就是真实用户目录（例如 `~/Pictures/MirageImages`）。
/// 如果自动化直接复用这个配置，测试产物会写进用户目录，清理类测试也会对着真实数据做。
/// 因此「仅导出图片」模式下的冒烟导出**必须**显式给出隔离的图片目录；否则拒绝执行。
public enum TestEnvironmentIsolation {
    public static let imageRootKey = "PKD_SMOKE_IMAGE_ROOT"
    public static let pkgKey = "PKD_SMOKE_PKG"
    public static let outputRootKey = "PKD_SMOKE_OUT"

    public enum Decision: Sendable, Equatable {
        /// 允许执行；`imageRoot` 非空时应在执行期间临时替换，执行后恢复。
        case allowed(imageRoot: URL?)
        /// 拒绝执行，`reason` 可直接展示/写日志。
        case refused(reason: String)
    }

    /// 解析隔离的图片目录：优先环境变量，其次开发副本根目录。
    public static func resolveImageRoot(environment: [String: String],
                                        developmentRoot: URL?) -> URL? {
        if let raw = environment[imageRootKey], raw.hasPrefix("/"), raw != "/" {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        if let developmentRoot {
            return developmentRoot.appendingPathComponent("Images", isDirectory: true)
        }
        return nil
    }

    /// 冒烟导出是否允许执行。
    ///
    /// - 非「仅导出图片」模式：沿用原有 `PKD_SMOKE_OUT`（可指向隔离目录），不额外拦截。
    /// - 「仅导出图片」模式：必须解析出隔离图片目录，且不能与当前正式配置相同。
    public static func decision(exportImagesOnly: Bool,
                                environment: [String: String],
                                developmentRoot: URL?,
                                configuredImageRoot: URL?) -> Decision {
        guard exportImagesOnly else { return .allowed(imageRoot: nil) }

        guard let isolated = resolveImageRoot(environment: environment,
                                              developmentRoot: developmentRoot) else {
            return .refused(reason: "仅导出图片模式的冒烟导出必须设置 \(imageRootKey) 或使用开发副本隔离根目录；已拒绝执行，避免写入正式用户目录")
        }

        if developmentRoot == nil, let configured = configuredImageRoot {
            let isolatedPath = isolated.standardizedFileURL.resolvingSymlinksInPath().path
            let configuredPath = configured.standardizedFileURL.resolvingSymlinksInPath().path
            if isolatedPath == configuredPath {
                return .refused(reason: "隔离图片目录与正式配置相同（\(configuredPath)）；已拒绝执行，避免污染正式默认路径")
            }
        }
        return .allowed(imageRoot: isolated)
    }
}

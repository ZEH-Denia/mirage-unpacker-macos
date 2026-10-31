import Foundation

/// repkg 输出中被识别出来的语义事件。
public enum RepkgEvent: Sendable, Equatable {
    case packageStarted(path: String)
    case entryExtracting(path: String)
    case entrySkipped(path: String)
    case fileCopied(path: String)
    case textureReading(name: String)
    case projectJSONWarning(message: String)
    case textureWarning(TextureWarning)
    case unrecognizedExtension(ext: String)
    case fatal(FatalSignal)
    case terminating
    case done
    case continuation(String)
    case unparsed(String)

    public enum TextureWarning: Sendable, Equatable {
        case read
        case write
    }

    public enum FatalSignal: Sendable, Equatable {
        /// extract 的措辞：`Input file not found`
        case inputNotFound
        /// info 的措辞：`Input file/directory doesn't exist!`
        case inputPathDoesNotExist
        /// 包内条目路径逃出输出目录时的安全拒绝。
        case unsafePackageEntryPath
    }
}

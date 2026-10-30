import Foundation
import Combine

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var libraryRoot: URL {
        didSet { defaults.set(libraryRoot.path, forKey: Keys.libraryRoot) }
    }

    @Published public var outputRoot: URL {
        didSet { defaults.set(outputRoot.path, forKey: Keys.outputRoot) }
    }

    @Published public var overwrite: Bool {
        didSet { defaults.set(overwrite, forKey: Keys.overwrite) }
    }

    @Published public var convertTextures: Bool {
        didSet { defaults.set(convertTextures, forKey: Keys.convertTextures) }
    }

    @Published public var copyProjectFiles: Bool {
        didSet { defaults.set(copyProjectFiles, forKey: Keys.copyProjectFiles) }
    }

    @Published public var flattenOutput: Bool {
        didSet { defaults.set(flattenOutput, forKey: Keys.flattenOutput) }
    }

    @Published public var openFinderWhenDone: Bool {
        didSet { defaults.set(openFinderWhenDone, forKey: Keys.openFinderWhenDone) }
    }

    @Published public var maxConcurrentJobs: Int {
        didSet { defaults.set(maxConcurrentJobs, forKey: Keys.maxConcurrentJobs) }
    }

    @Published public var onlySceneType: Bool {
        didSet { defaults.set(onlySceneType, forKey: Keys.onlySceneType) }
    }

    @Published public var confirmBeforeStart: Bool {
        didSet { defaults.set(confirmBeforeStart, forKey: Keys.confirmBeforeStart) }
    }

    /// 仅导出图片模式：解包到临时目录，只把正常层 / X-Ray 层复制到 imageExportRoot，然后清理临时文件
    @Published public var exportImagesOnly: Bool {
        didSet { defaults.set(exportImagesOnly, forKey: Keys.exportImagesOnly) }
    }

    @Published public var imageExportRoot: URL {
        didSet { defaults.set(imageExportRoot.path, forKey: Keys.imageExportRoot) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let home = FileManager.default.homeDirectoryForCurrentUser

        libraryRoot = defaults.string(forKey: Keys.libraryRoot).map { URL(fileURLWithPath: $0) }
            ?? LibraryScanner.defaultRoot
        outputRoot = defaults.string(forKey: Keys.outputRoot).map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Pictures/MirageExtracted", isDirectory: true)

        overwrite = defaults.object(forKey: Keys.overwrite) as? Bool ?? false
        convertTextures = defaults.object(forKey: Keys.convertTextures) as? Bool ?? true
        copyProjectFiles = defaults.object(forKey: Keys.copyProjectFiles) as? Bool ?? true
        flattenOutput = defaults.object(forKey: Keys.flattenOutput) as? Bool ?? false
        openFinderWhenDone = defaults.object(forKey: Keys.openFinderWhenDone) as? Bool ?? true
        maxConcurrentJobs = defaults.object(forKey: Keys.maxConcurrentJobs) as? Int ?? 1
        onlySceneType = defaults.object(forKey: Keys.onlySceneType) as? Bool ?? false
        confirmBeforeStart = defaults.object(forKey: Keys.confirmBeforeStart) as? Bool ?? true
        exportImagesOnly = defaults.object(forKey: Keys.exportImagesOnly) as? Bool ?? false
        imageExportRoot = defaults.string(forKey: Keys.imageExportRoot).map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Pictures/MirageImages", isDirectory: true)
    }

    public func makeRequest(for item: WallpaperItem) -> ExtractRequest? {
        guard let pkg = item.pkgURL else { return nil }
        return ExtractRequest(
            input: pkg,
            outputDirectory: OutputLayout.outputDirectory(for: item, root: outputRoot),
            overwrite: overwrite,
            convertTextures: convertTextures,
            copyProjectFiles: copyProjectFiles && !flattenOutput,
            flatten: flattenOutput
        )
    }

    private enum Keys {
        static let libraryRoot = "pkd.libraryRoot"
        static let outputRoot = "pkd.outputRoot"
        static let overwrite = "pkd.overwrite"
        static let convertTextures = "pkd.convertTextures"
        static let copyProjectFiles = "pkd.copyProjectFiles"
        static let flattenOutput = "pkd.flattenOutput"
        static let openFinderWhenDone = "pkd.openFinderWhenDone"
        static let maxConcurrentJobs = "pkd.maxConcurrentJobs"
        static let onlySceneType = "pkd.onlySceneType"
        static let confirmBeforeStart = "pkd.confirmBeforeStart"
        static let exportImagesOnly = "pkd.exportImagesOnly"
        static let imageExportRoot = "pkd.imageExportRoot"
    }
}

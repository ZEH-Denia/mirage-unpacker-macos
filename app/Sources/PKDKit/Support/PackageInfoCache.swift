import CryptoKit
import Foundation

/// Disk cache for expensive `repkg info` results.
/// Entries are keyed by package path and invalidated when size or modification time changes.
public struct PackageInfoCache: Sendable {
    private struct Record: Codable {
        let schema: Int
        let packagePath: String
        let fileSize: Int64
        let modifiedAt: Date
        let info: PkgInfo
    }

    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.zeh.pkd/PackageInfo", isDirectory: true)
    }

    public func load(for package: URL) async -> PkgInfo? {
        await Task.detached(priority: .utility) {
            loadSynchronously(for: package.standardizedFileURL)
        }.value
    }

    public func store(_ info: PkgInfo, for package: URL) async {
        await Task.detached(priority: .utility) {
            storeSynchronously(info, for: package.standardizedFileURL)
        }.value
    }

    private func loadSynchronously(for package: URL) -> PkgInfo? {
        guard let fingerprint = fingerprint(for: package),
              let cacheURL = cacheURL(for: package),
              let data = try? Data(contentsOf: cacheURL),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schema == 1,
              record.packagePath == package.path,
              record.fileSize == fingerprint.size,
              record.modifiedAt == fingerprint.modifiedAt else {
            return nil
        }
        return record.info
    }

    private func storeSynchronously(_ info: PkgInfo, for package: URL) {
        guard let fingerprint = fingerprint(for: package),
              let cacheURL = cacheURL(for: package) else { return }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let record = Record(
                schema: 1,
                packagePath: package.path,
                fileSize: fingerprint.size,
                modifiedAt: fingerprint.modifiedAt,
                info: info
            )
            try JSONEncoder().encode(record).write(to: cacheURL, options: .atomic)
        } catch {
            // A cache write failure must never fail package inspection or extraction.
        }
    }

    private func fingerprint(for package: URL) -> (size: Int64, modifiedAt: Date)? {
        guard let values = try? package.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modifiedAt = values.contentModificationDate else { return nil }
        return (Int64(size), modifiedAt)
    }

    private func cacheURL(for package: URL) -> URL? {
        let digest = SHA256.hash(data: Data(package.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }
}

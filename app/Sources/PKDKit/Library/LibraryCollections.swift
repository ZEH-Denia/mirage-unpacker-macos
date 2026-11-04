import Foundation
import Combine

/// 仅保存素材标识与访问时间，不修改壁纸目录或保存预览图片。
@MainActor
public final class LibraryCollections: ObservableObject {
    private struct Snapshot: Codable {
        var favorites: Set<String> = []
        var visits: [String: Date] = [:]
    }
    @Published public private(set) var favoriteIDs: Set<String> = []
    @Published public private(set) var visits: [String: Date] = [:]
    private let file: URL
    private var readable = true

    public init(fileURL: URL? = nil) {
        file = fileURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PKD/collections.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
                favoriteIDs = snapshot.favorites
                visits = snapshot.visits
            } catch { readable = false }
        }
    }

    public func toggleFavorite(_ id: String) throws {
        var next = Snapshot(favorites: favoriteIDs, visits: visits)
        if !next.favorites.insert(id).inserted { next.favorites.remove(id) }
        try save(next)
    }

    public func recordVisit(_ id: String, at date: Date = Date()) throws {
        var next = Snapshot(favorites: favoriteIDs, visits: visits)
        next.visits[id] = date
        let newest = next.visits.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(100)
        next.visits = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        try save(next)
    }

    public func clearRecent() throws { try save(Snapshot(favorites: favoriteIDs)) }

    private func save(_ next: Snapshot) throws {
        guard readable else { throw CollectionError.unreadable }
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        favoriteIDs = next.favorites
        visits = next.visits
    }

    private enum CollectionError: LocalizedError {
        case unreadable
        var errorDescription: String? { "收藏记录无法读取，已保留原文件。请先备份并检查 collections.json。" }
    }
}

import Foundation
import Darwin

/// Lifecycle for the disposable extraction directories used by “仅导出图片”.
///
/// Safety model:
/// - Every directory lives directly under a dedicated root inside the user's
///   `temporaryDirectory` (`PKD-temp/`), never under an output/import location.
/// - Each directory has a JSON owner marker plus an `owner.lock` file held with
///   `flock(LOCK_EX)` for the whole job. A crashed/KILLed process loses the lock
///   automatically; a live instance keeps it, so janitors can distinguish
///   active from abandoned directories without trusting a PID alone.
/// - Cleanup scans only that root, rejects symlinks/redirected paths, preserves
///   unknown or recently-created owners, and deletes only stale directories
///   whose lock is free. It never scans an arbitrary `TMPDIR/PKD-extract-*`
///   pattern and never touches user output or import sources.
public enum TemporaryOutputs {
    public static let rootName = "PKD-temp"
    public static let markerName = "owner.json"
    public static let lockName = "owner.lock"
    public static let schemaVersion = 1
    public static let defaultMaxAge: TimeInterval = 24 * 60 * 60

    public struct Owner: Codable, Equatable {
        public let schema: Int
        public let bundleID: String
        public let instanceID: UUID
        public let jobID: UUID
        public let pid: Int32
        public let createdAt: Date
    }

    public final class Lease {
        public let directory: URL
        private let lockFD: Int32
        private let stateLock = NSLock()
        private var released = false

        fileprivate init(directory: URL, lockFD: Int32) {
            self.directory = directory
            self.lockFD = lockFD
        }

        /// Removes the directory and releases the flock. Idempotent.
        public func release() {
            stateLock.lock()
            if released {
                stateLock.unlock()
                return
            }
            released = true
            stateLock.unlock()

            _ = flock(lockFD, LOCK_UN)
            _ = close(lockFD)
            try? FileManager.default.removeItem(at: directory)
        }

        deinit {
            // Leases are normally released explicitly. If a caller drops one,
            // release the kernel lock and clean only this exact directory.
            if !released {
                _ = flock(lockFD, LOCK_UN)
                _ = close(lockFD)
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// Default root inside the current user's temporary directory.
    public static func root(base: URL = FileManager.default.temporaryDirectory) -> URL {
        base.appendingPathComponent(rootName, isDirectory: true)
    }

    /// Creates a fresh leased job directory under `root`. Returns nil if the
    /// root is redirected/non-directory or the marker/lock cannot be created.
    public static func makeLease(root: URL,
                                 jobID: UUID,
                                 instanceID: UUID,
                                 bundleID: String = Bundle.main.bundleIdentifier ?? "com.zeh.pkd") -> Lease? {
        guard prepareRoot(root) else { return nil }
        let directory = root.appendingPathComponent(jobID.uuidString, isDirectory: true)
        guard !isSymlink(directory) else { return nil }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            return nil
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard isDirectoryNotSymlink(directory), pathIsDirectChild(directory, of: root) else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }

        let owner = Owner(
            schema: schemaVersion,
            bundleID: bundleID,
            instanceID: instanceID,
            jobID: jobID,
            pid: getpid(),
            createdAt: Date()
        )
        let markerURL = directory.appendingPathComponent(markerName)
        let lockURL = directory.appendingPathComponent(lockName)
        guard writeMarker(owner, to: markerURL),
              createLockFile(at: lockURL) else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }

        let fd = open(lockURL.path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(fd)
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return Lease(directory: directory, lockFD: fd)
    }

    /// Scans only `root` and removes stale, unowned directories. Returns the
    /// directories actually removed.
    @discardableResult
    public static func cleanupAbandoned(root: URL,
                                        currentInstanceID: UUID,
                                        currentPID: Int32 = getpid(),
                                        bundleID: String = Bundle.main.bundleIdentifier ?? "com.zeh.pkd",
                                        now: Date = Date(),
                                        maxAge: TimeInterval = defaultMaxAge) -> [URL] {
        guard isDirectoryNotSymlink(root), !isSymlink(root) else { return [] }
        let canonicalRoot = canonical(root)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var removed: [URL] = []
        for entry in entries {
            guard !isSymlink(entry), isDirectory(entry) else { continue }
            guard pathIsDirectChild(entry, of: canonicalRoot) else { continue }
            let canonicalEntry = canonical(entry)
            guard isDirectChild(canonicalEntry, of: canonicalRoot) else { continue }

            let markerURL = entry.appendingPathComponent(markerName)
            guard !isSymlink(markerURL), isRegularFile(markerURL),
                  let owner = readMarker(markerURL),
                  owner.schema == schemaVersion,
                  owner.bundleID == bundleID else {
                // Unknown/foreign owner: leave it alone.
                continue
            }
            if owner.instanceID == currentInstanceID {
                continue
            }
            // A PID matching ours but with another instance ID cannot be proven
            // stale; preserve it rather than guessing.
            if owner.pid == currentPID {
                continue
            }
            if now.timeIntervalSince(owner.createdAt) < maxAge {
                continue
            }

            let lockURL = entry.appendingPathComponent(lockName)
            guard !isSymlink(lockURL), isRegularFile(lockURL) else { continue }
            let fd = open(lockURL.path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                // A live instance still owns this directory.
                _ = close(fd)
                continue
            }
            // Re-check after acquiring the lock; a path could have been swapped.
            guard !isSymlink(entry),
                  isDirectory(entry),
                  isDirectChild(canonical(entry), of: canonicalRoot),
                  let currentOwner = readMarker(markerURL),
                  currentOwner == owner else {
                _ = flock(fd, LOCK_UN)
                _ = close(fd)
                continue
            }

            _ = flock(fd, LOCK_UN)
            _ = close(fd)
            if removeDirectorySafely(entry, under: canonicalRoot) {
                removed.append(entry)
            }
        }
        return removed
    }

    // MARK: - safe filesystem helpers

    private static func prepareRoot(_ root: URL) -> Bool {
        if FileManager.default.fileExists(atPath: root.path) {
            return isDirectoryNotSymlink(root) && !isSymlink(root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            return isDirectoryNotSymlink(root) && !isSymlink(root)
        } catch {
            return false
        }
    }

    private static func writeMarker(_ owner: Owner, to url: URL) -> Bool {
        guard !isSymlink(url) else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(owner) else { return false }
        return FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    private static func readMarker(_ url: URL) -> Owner? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Owner.self, from: data)
    }

    private static func createLockFile(at url: URL) -> Bool {
        guard !isSymlink(url) else { return false }
        return FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    }

    private static func removeDirectorySafely(_ url: URL, under root: URL) -> Bool {
        guard !isSymlink(url), isDirectory(url), isDirectChild(canonical(url), of: root) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func isDirectoryNotSymlink(_ url: URL) -> Bool {
        isDirectory(url) && !isSymlink(url)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func pathIsDirectChild(_ url: URL, of parent: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path
    }

    private static func isDirectChild(_ url: URL, of parent: URL) -> Bool {
        let child = url.standardizedFileURL.path
        let base = parent.standardizedFileURL.path
        guard child.hasPrefix(base + "/") else { return false }
        return !child.dropFirst(base.count + 1).contains("/")
    }
}

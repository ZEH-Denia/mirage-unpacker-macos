import Foundation
import Darwin

// Offscreen safety tests for TemporaryOutputs' owner marker + flock janitor.
// Compiles the real TemporaryOutputs.swift (no stubs).
// Usage: fault-temp-cleanup-tests <scratch-dir>

@main
struct TempCleanupTests {
    static var failures: [String] = []
    static let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        .appendingPathComponent("pkd-temp-tests-\(UUID().uuidString)", isDirectory: true)
    static let bundleID = "com.zeh.pkd.temp-tests"
    static let currentInstance = UUID()
    static let now = Date()

    static func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
        if condition() { print("  PASS \(name)") }
        else { print("  FAIL \(name)\(detail().isEmpty ? "" : " — \(detail())")"); failures.append(name) }
    }

    static func mkdir(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func writeOwner(_ dir: URL, instance: UUID, pid: Int32, age: TimeInterval) {
        let owner = TemporaryOutputs.Owner(
            schema: TemporaryOutputs.schemaVersion,
            bundleID: bundleID,
            instanceID: instance,
            jobID: UUID(),
            pid: pid,
            createdAt: now.addingTimeInterval(-age)
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(owner) {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(TemporaryOutputs.markerName).path,
                                           contents: data, attributes: [.posixPermissions: 0o600])
        }
        FileManager.default.createFile(atPath: dir.appendingPathComponent(TemporaryOutputs.lockName).path,
                                       contents: Data(), attributes: [.posixPermissions: 0o600])
    }

    static func cleanup(_ root: URL = root, currentPID: Int32 = getpid(), now: Date = now) -> [URL] {
        TemporaryOutputs.cleanupAbandoned(root: root,
                                          currentInstanceID: currentInstance,
                                          currentPID: currentPID,
                                          bundleID: bundleID,
                                          now: now)
    }

    static func main() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        print("Temp cleanup tests — \(root.path)")

        // 0) normal lease + release removes directory.
        let leaseRoot = TemporaryOutputs.root(base: root)
        let lease = TemporaryOutputs.makeLease(root: leaseRoot, jobID: UUID(), instanceID: currentInstance, bundleID: bundleID)
        check("lease created", lease != nil)
        let leaseDir = lease?.directory
        lease?.release()
        check("normal release removes directory", leaseDir.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false)

        // 1) recent abandoned directory is preserved.
        let recent = mkdir("recent")
        writeOwner(recent, instance: UUID(), pid: 999_998, age: 3600)
        _ = cleanup()
        check("recent preserved", FileManager.default.fileExists(atPath: recent.path))

        // 2) stale exited directory (no lock) is removed.
        let stale = mkdir("stale")
        writeOwner(stale, instance: UUID(), pid: 999_999, age: 48 * 3600)
        _ = cleanup()
        check("stale removed", !FileManager.default.fileExists(atPath: stale.path))

        // 3) unknown owner (no marker) is preserved.
        let unknown = mkdir("unknown")
        check("unknown preserved", FileManager.default.fileExists(atPath: unknown.path))

        // 4) active lock is preserved even if old.
        let activeDir = mkdir("active")
        writeOwner(activeDir, instance: UUID(), pid: 999_997, age: 48 * 3600)
        let lockURL = activeDir.appendingPathComponent(TemporaryOutputs.lockName)
        let fd = open(lockURL.path, O_RDWR | O_NOFOLLOW)
        if fd >= 0 { _ = flock(fd, LOCK_EX | LOCK_NB) }
        _ = cleanup()
        check("active flock preserved", FileManager.default.fileExists(atPath: activeDir.path))
        if fd >= 0 { _ = flock(fd, LOCK_UN); _ = close(fd) }
        _ = cleanup()
        check("released stale removed", !FileManager.default.fileExists(atPath: activeDir.path))

        // 5) same PID but different instance is preserved (PID reuse safety).
        let samePID = mkdir("same-pid")
        writeOwner(samePID, instance: UUID(), pid: getpid(), age: 48 * 3600)
        _ = cleanup()
        check("same PID different instance preserved", FileManager.default.fileExists(atPath: samePID.path))

        // 6) symlink inside root is not followed and external target survives.
        let outside = mkdir("outside-target")
        let sentinel = outside.appendingPathComponent("sentinel")
        FileManager.default.createFile(atPath: sentinel.path, contents: Data("keep".utf8))
        let link = root.appendingPathComponent("redirect")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        _ = cleanup()
        check("symlink entry not followed", FileManager.default.fileExists(atPath: sentinel.path))
        check("symlink entry itself preserved", FileManager.default.fileExists(atPath: link.path))

        // 7) root that is a symlink is refused entirely.
        let altBase = mkdir("alt-base")
        let externalRoot = TemporaryOutputs.root(base: altBase)
        try? FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        let externalSentinel = externalRoot.appendingPathComponent("keep")
        FileManager.default.createFile(atPath: externalSentinel.path, contents: Data("keep".utf8))
        let symlinkRoot = root.appendingPathComponent("symlink-root")
        try? FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: externalRoot)
        _ = cleanup(symlinkRoot)
        check("symlink root refused", FileManager.default.fileExists(atPath: externalSentinel.path))

        // 7b) stale directory containing an internal symlink: delete the
        // directory but never follow the link or delete its external target.
        let staleLink = mkdir("stale-with-link")
        writeOwner(staleLink, instance: UUID(), pid: 999_995, age: 48 * 3600)
        let externalTarget = mkdir("external-target")
        let externalFile = externalTarget.appendingPathComponent("keep-me")
        FileManager.default.createFile(atPath: externalFile.path, contents: Data("keep".utf8))
        let innerLink = staleLink.appendingPathComponent("redirect")
        try? FileManager.default.createSymbolicLink(at: innerLink, withDestinationURL: externalFile)
        _ = cleanup()
        check("stale dir with symlink removed", !FileManager.default.fileExists(atPath: staleLink.path))
        check("internal symlink target not deleted", FileManager.default.fileExists(atPath: externalFile.path))

        // 8) explicit unknown bundle owner is preserved.
        let foreign = mkdir("foreign")
        writeOwner(foreign, instance: UUID(), pid: 999_996, age: 48 * 3600)
        let foreignMarker = foreign.appendingPathComponent(TemporaryOutputs.markerName)
        if let data = try? Data(contentsOf: foreignMarker),
           var text = String(data: data, encoding: .utf8) {
            text = text.replacingOccurrences(of: bundleID, with: "com.example.other")
            try? text.write(to: foreignMarker, atomically: true, encoding: .utf8)
        }
        _ = cleanup()
        check("foreign bundle owner preserved", FileManager.default.fileExists(atPath: foreign.path))

        if failures.isEmpty { print("ALL TEMP CLEANUP TESTS PASSED") }
        else { print("FAILURES: \(failures.joined(separator: ", "))"); exit(1) }
    }
}

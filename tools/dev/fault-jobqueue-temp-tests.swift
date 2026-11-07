import Foundation
import PKDKit

// Offscreen integration: real JobQueue + TemporaryOutputs leases.
// Usage: fault-jobqueue-temp-tests <scratch-dir> <fake-engine>

@main
struct JobQueueTempTests {
    static var failures: [String] = []
    static func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
        if condition() { print("  PASS \(name)") }
        else { print("  FAIL \(name)\(detail().isEmpty ? "" : " — \(detail())")"); failures.append(name) }
    }
    static func item(pkg: URL) -> WallpaperItem {
        let size = (try? pkg.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return WallpaperItem(id: "verify-temp", folderURL: pkg.deletingLastPathComponent(),
                             title: "临时目录验证", type: "scene", previewURL: nil,
                             pkgURL: pkg, contentRating: "", tags: [], pkgSize: size, issue: nil)
    }
    static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    @MainActor
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 4 else { print("usage: <scratch> <fake-engine> <pkg>"); exit(2) }
        let base = URL(fileURLWithPath: args[1], isDirectory: true)
        let engine = URL(fileURLWithPath: args[2])
        let pkg = URL(fileURLWithPath: args[3])
        let tempRoot = TemporaryOutputs.root(base: base)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let suite = "verify.temp.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        settings.outputRoot = base.appendingPathComponent("out")
        settings.exportImagesOnly = true
        settings.openFinderWhenDone = false
        settings.confirmBeforeStart = false
        let log = LogSink(logDirectory: base.appendingPathComponent("logs"))
        let queue = JobQueue(engineURL: engine, log: log, temporaryBase: base)
        queue.concurrency = 1
        let jobs = queue.enqueue(items: [item(pkg: pkg)], settings: settings,
                                 imageExportDestination: base.appendingPathComponent("images"))
        guard let job = jobs.first else { check("enqueue", false); exit(1) }

        var waited = 0.0
        while Date().timeIntervalSince1970 > 0, waited < 5 {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: tempRoot.path),
               let dir = entries.first {
                let dirURL = tempRoot.appendingPathComponent(dir)
                let marker = dirURL.appendingPathComponent(TemporaryOutputs.markerName)
                let lock = dirURL.appendingPathComponent(TemporaryOutputs.lockName)
                check("active job has owner marker", FileManager.default.fileExists(atPath: marker.path))
                check("active job has lock file", FileManager.default.fileExists(atPath: lock.path))
                if let data = try? Data(contentsOf: marker),
                   let owner = try? JSONDecoder().decode(TemporaryOutputs.Owner.self, from: data) {
                    check("owner marker job/instance", owner.jobID != UUID() && owner.pid == getpid())
                }
                break
            }
            await sleep(0.1); waited += 0.1
        }
        check("active temp dir observed", !((try? FileManager.default.contentsOfDirectory(atPath: tempRoot.path)) ?? []).isEmpty)
        check("job active before cancel", !job.state.isTerminal, "state \(job.state.label)")

        queue.cancelAll()
        var cancelWait = 0.0
        while !job.state.isTerminal, cancelWait < 10 {
            await sleep(0.1); cancelWait += 0.1
        }
        check("cancel terminal", job.state == .cancelled, "state \(job.state.label)")
        let residual = (try? FileManager.default.contentsOfDirectory(atPath: tempRoot.path)) ?? []
        check("cancel releases temp lease", residual.isEmpty, "residual \(residual)")
        defaults.removePersistentDomain(forName: suite)
        if failures.isEmpty { print("ALL JOBQUEUE TEMP TESTS PASSED") }
        else { print("FAILURES: \(failures.joined(separator: ", "))"); exit(1) }
    }
}

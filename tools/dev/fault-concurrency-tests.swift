import Foundation
import PKDKit

// Offscreen regression for JobQueue concurrency=2: normal completion + cancel.
// Usage: fault-concurrency-tests <scratch> <real-engine> <pkg> <fake-slow-engine>

@main
struct ConcurrencyTests {
    static var failures: [String] = []
    static func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
        if condition() { print("  PASS \(name)") }
        else { print("  FAIL \(name)\(detail().isEmpty ? "" : " — \(detail())")"); failures.append(name) }
    }
    static func item(_ pkg: URL, _ id: String, _ title: String) -> WallpaperItem {
        let size = (try? pkg.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return WallpaperItem(id: id, folderURL: pkg.deletingLastPathComponent(), title: title,
                             type: "scene", previewURL: nil, pkgURL: pkg, contentRating: "",
                             tags: [], pkgSize: size, issue: nil)
    }
    static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    @MainActor static func waitTerminal(_ jobs: [ExtractJob], _ timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if jobs.allSatisfy({ $0.state.isTerminal }) { return true }
            await sleep(0.1)
        }
        return jobs.allSatisfy({ $0.state.isTerminal })
    }

    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 5 else { print("usage"); exit(2) }
        let base = URL(fileURLWithPath: args[1], isDirectory: true)
        let real = URL(fileURLWithPath: args[2])
        let pkg = URL(fileURLWithPath: args[3])
        let slow = URL(fileURLWithPath: args[4])
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let suite = "verify.concurrency.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        settings.outputRoot = base.appendingPathComponent("out")
        settings.exportImagesOnly = false
        settings.openFinderWhenDone = false
        settings.confirmBeforeStart = false
        let log = LogSink(logDirectory: base.appendingPathComponent("logs"))
        let queue = JobQueue(engineURL: real, log: log, temporaryBase: base)
        queue.concurrency = 2
        let jobs = queue.enqueue(items: [item(pkg, "c1", "并发一"), item(pkg, "c2", "并发二")], settings: settings)
        check("enqueue two", jobs.count == 2)
        let done = await waitTerminal(jobs, 60)
        check("concurrent 2 completes", done, jobs.map { $0.state.label }.joined(separator: ","))
        check("concurrent 2 both success", jobs.allSatisfy { if case .succeeded = $0.state { return true }; return false },
              jobs.map { $0.state.label }.joined(separator: ","))
        check("concurrent 2 both output files", jobs.allSatisfy { (try? FileManager.default.contentsOfDirectory(atPath: $0.outputDirectory.path).count) ?? 0 > 0 })

        // Cancel both with a fake slow extract (fast info) and concurrency 2.
        let cancelQueue = JobQueue(engineURL: slow, log: log, temporaryBase: base.appendingPathComponent("cancelbase"))
        cancelQueue.concurrency = 2
        let cancelJobs = cancelQueue.enqueue(items: [item(pkg, "x1", "取消一"), item(pkg, "x2", "取消二")], settings: settings)
        check("enqueue cancel two", cancelJobs.count == 2)
        await sleep(1.0)
        cancelQueue.cancelAll()
        let cancelled = await waitTerminal(cancelJobs, 15)
        check("cancel all terminal", cancelled, cancelJobs.map { $0.state.label }.joined(separator: ","))
        check("cancel all states", cancelJobs.allSatisfy { $0.state == .cancelled })
        check("cancel all no temp leases", ((try? FileManager.default.contentsOfDirectory(atPath: TemporaryOutputs.root(base: base.appendingPathComponent("cancelbase")).path)) ?? []).isEmpty)
        defaults.removePersistentDomain(forName: suite)
        if failures.isEmpty { print("ALL CONCURRENCY TESTS PASSED") }
        else { print("FAILURES: \(failures.joined(separator: ", "))"); exit(1) }
    }
}

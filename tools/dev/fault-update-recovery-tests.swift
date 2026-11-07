import Foundation

// State-machine tests for UpdateRecoveryStore (no Sparkle/UI required).
// Usage: fault-update-recovery-tests

@main
struct UpdateRecoveryTests {
    static var failures: [String] = []
    static let suiteName = "pkd.update-recovery.tests.\(UUID().uuidString)"
    static let defaults = UserDefaults(suiteName: suiteName)!

    static func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
        if condition() {
            print("  PASS \(name)")
        } else {
            let extra = detail()
            print("  FAIL \(name)\(extra.isEmpty ? "" : " — \(extra)")")
            failures.append(name)
        }
    }

    static func isAtLeast(_ current: String, _ target: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(current), b = parts(target)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    static func main() {
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        print("UpdateRecovery state-machine tests")
        let store = UpdateRecoveryStore(defaults: defaults, now: { base })

        // 1) Merely finding/downloading/scheduling an update creates no record.
        check("no record at launch is silent",
              store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "1.8.1", at: base, isAtLeast: isAtLeast) == nil)

        // 2) Install started but host died uncleanly (SIGKILL/crash) -> no false failure.
        store.recordInstallStart(targetVersion: "1.8.2", targetBuild: "1.8.2", at: base)
        check("record exists after install hand-off", store.hasPendingAttempt())
        check("unclean termination does not report failure",
              store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "1.8.1", at: base.addingTimeInterval(60), isAtLeast: isAtLeast) == nil)
        check("unclean record cleared after evaluation", !store.hasPendingAttempt())

        // 3) Clean termination + old version -> real recovery notice.
        store.recordInstallStart(targetVersion: "1.8.2", targetBuild: "1.8.2", at: base)
        store.markCleanTermination()
        let notice = store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "1.8.1", at: base.addingTimeInterval(60), isAtLeast: isAtLeast)
        check("clean termination + old version reports failure", notice != nil)
        check("notice carries target/current", notice?.targetVersion == "1.8.2" && notice?.currentVersion == "1.8.1")
        check("notice text guides to GitHub", notice?.message.contains("GitHub Releases") == true)
        check("notice is one-shot", store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "1.8.1", at: base.addingTimeInterval(61), isAtLeast: isAtLeast) == nil)

        // 4) Successful install (new version launched) -> silent and record cleared.
        store.recordInstallStart(targetVersion: "1.8.2", targetBuild: "1.8.2", at: base)
        store.markCleanTermination()
        check("new version launch is silent",
              store.evaluateOnLaunch(currentVersion: "1.8.2", currentBuild: "1.8.2", at: base.addingTimeInterval(60), isAtLeast: isAtLeast) == nil)
        check("success clears record", !store.hasPendingAttempt())

        // 4b) Sparkle compares CFBundleVersion (build), not short version.
        // Same short 1.8.1, target build 102, current build 101 -> failure,
        // even though the short versions are equal.
        store.recordInstallStart(targetVersion: "1.8.1", targetBuild: "102", at: base)
        store.markCleanTermination()
        check("same short / lower build reports failure",
              store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "101", at: base.addingTimeInterval(60), isAtLeast: isAtLeast) != nil)

        // 4c) Higher build with same short is success.
        store.recordInstallStart(targetVersion: "1.8.1", targetBuild: "101", at: base)
        store.markCleanTermination()
        check("higher build with same short is success",
              store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "102", at: base.addingTimeInterval(60), isAtLeast: isAtLeast) == nil)

        // 4d) Build values conflict with short versions: build wins in both directions.
        store.recordInstallStart(targetVersion: "1.9.0", targetBuild: "10", at: base)
        store.markCleanTermination()
        check("build priority over higher short version",
              store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "9", at: base.addingTimeInterval(60), isAtLeast: isAtLeast) != nil)
        store.recordInstallStart(targetVersion: "1.7.0", targetBuild: "9", at: base)
        store.markCleanTermination()
        check("higher build over lower short succeeds",
              store.evaluateOnLaunch(currentVersion: "1.9.0", currentBuild: "10", at: base.addingTimeInterval(60), isAtLeast: isAtLeast) == nil)

        // 4e) Without target build, short version is the fallback.
        store.recordInstallStart(targetVersion: "1.8.2", targetBuild: nil, at: base)
        store.markCleanTermination()
        check("no target build falls back to short version",
              store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "999", at: base.addingTimeInterval(60), isAtLeast: isAtLeast) != nil)
        store.recordInstallStart(targetVersion: "1.8.1", targetBuild: nil, at: base)
        store.markCleanTermination()
        check("no target build uses short success",
              store.evaluateOnLaunch(currentVersion: "1.8.2", currentBuild: "1", at: base.addingTimeInterval(60), isAtLeast: isAtLeast) == nil)

        // 4f) Missing current build falls back to short version.
        store.recordInstallStart(targetVersion: "1.8.2", targetBuild: "102", at: base)
        store.markCleanTermination()
        check("missing current build falls back to short failure",
              store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: nil, at: base.addingTimeInterval(60), isAtLeast: isAtLeast) != nil)

        // 5) Repeated willInstallUpdate for same target is idempotent and preserves clean flag.
        store.recordInstallStart(targetVersion: "1.8.2", targetBuild: "1.8.2", at: base)
        store.markCleanTermination()
        store.recordInstallStart(targetVersion: "1.8.2", targetBuild: "1.8.2", at: base.addingTimeInterval(5))
        check("repeat willInstall keeps clean flag",
              store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "1.8.1", at: base.addingTimeInterval(60), isAtLeast: isAtLeast) != nil)

        // 6) A later, different target attempt resets the clean flag.
        store.recordInstallStart(targetVersion: "1.9.0", targetBuild: "1.9.0", at: base.addingTimeInterval(120))
        check("different target without clean termination is silent",
              store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "1.8.1", at: base.addingTimeInterval(180), isAtLeast: isAtLeast) == nil)

        // 7) Stale records are discarded.
        store.recordInstallStart(targetVersion: "1.8.2", targetBuild: "1.8.2", at: base)
        store.markCleanTermination()
        check("stale record is silent",
              store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "1.8.1",
                                     at: base.addingTimeInterval(UpdateRecoveryStore.maxAge + 1), isAtLeast: isAtLeast) == nil)

        // 8) Clock going backwards is treated as stale/unsafe.
        store.recordInstallStart(targetVersion: "1.8.2", targetBuild: "1.8.2", at: base.addingTimeInterval(100))
        store.markCleanTermination()
        check("future timestamp is not reported",
              store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "1.8.1", at: base, isAtLeast: isAtLeast) == nil)

        // 9) Explicit cancel/error clears the record (no next-launch false positive).
        store.recordInstallStart(targetVersion: "1.8.2", targetBuild: "1.8.2", at: base)
        store.markCleanTermination()
        store.clear()
        check("explicit clear prevents future notice",
              store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "1.8.1", at: base.addingTimeInterval(60), isAtLeast: isAtLeast) == nil)

        // 10) Corrupt persisted data is discarded, never crashes.
        defaults.set(Data("not-json".utf8), forKey: UpdateRecoveryStore.storageKey)
        check("corrupt record is ignored",
              store.evaluateOnLaunch(currentVersion: "1.8.1", currentBuild: "1.8.1", at: base, isAtLeast: isAtLeast) == nil)
        check("corrupt record is removed", !store.hasPendingAttempt())

        // 11) Numeric version comparison edge (1.8.10 > 1.8.9) is delegate-provided;
        // verify the store uses the comparator rather than string equality.
        store.recordInstallStart(targetVersion: "1.8.9", targetBuild: "1.8.9", at: base)
        store.markCleanTermination()
        check("comparator decides success",
              store.evaluateOnLaunch(currentVersion: "1.8.10", currentBuild: "1.8.10", at: base.addingTimeInterval(60), isAtLeast: isAtLeast) == nil)

        if failures.isEmpty {
            print("ALL UPDATE RECOVERY TESTS PASSED")
        } else {
            print("FAILURES: \(failures.joined(separator: ", "))")
            exit(1)
        }
    }
}

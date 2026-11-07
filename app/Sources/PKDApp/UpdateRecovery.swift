import Foundation

/// A persisted record of an update that reached Sparkle's install hand-off.
///
/// Sparkle's standard user driver can present failures that happen while the
/// requesting app is still alive. The final installation step runs in the
/// separate `Autoupdate` process; if that fails, the host app has already
/// terminated and no delegate callback can reach it. The only reliable place to
/// learn about that case is the next launch: compare the installed version with
/// the target that was being installed.
///
/// This type deliberately contains no Sparkle dependency so its state machine
/// can be tested in isolation.
struct PendingUpdateAttempt: Codable, Equatable {
    let schema: Int
    let targetVersion: String
    let targetBuild: String?
    let installStartedAt: Date
    var cleanTermination: Bool
}

struct UpdateRecoveryNotice: Equatable {
    let targetVersion: String
    let currentVersion: String

    var message: String {
        "上次应用内更新没有完成（目标版本 \(targetVersion)，当前仍为 \(currentVersion)）。"
            + "安装替换阶段可能失败或被中断。请前往 GitHub Releases 手动下载最新版，"
            + "并按页面说明替换应用。"
    }
}

/// UserDefaults-backed pending-install state machine.
///
/// Rules:
/// - A record is written only in `updater(_:willInstallUpdate:)`, i.e. after the
///   user authorised installation; merely finding/downloading/scheduling an
///   update does **not** create a record.
/// - If the new version is running, the update succeeded: clear silently.
/// - If the old version is running after a clean termination, the installation
///   was handed to Sparkle and did not complete: show the recovery notice.
/// - If the old version is running after an unclean termination (crash/SIGKILL),
///   there is not enough evidence that installation actually failed; clear
///   without a notice to avoid a false failure report.
/// - Records older than 30 days are treated as stale.
final class UpdateRecoveryStore {
    static let storageKey = "pkd.update.pendingInstallAttempt"
    static let schemaVersion = 1
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// Called from Sparkle's `willInstallUpdate` delegate, which runs before the
    /// host terminates and before the Autoupdate process performs the final
    /// replacement. Calling it twice for the same target is idempotent and keeps
    /// an already-recorded clean-termination flag.
    func recordInstallStart(targetVersion: String, targetBuild: String?, at date: Date? = nil) {
        let timestamp = date ?? now()
        let previous = load()
        let normalizedBuild = (targetBuild?.isEmpty == false) ? targetBuild : nil
        let sameTarget = previous?.targetVersion == targetVersion
            && previous?.targetBuild == normalizedBuild
        let record = PendingUpdateAttempt(
            schema: Self.schemaVersion,
            targetVersion: targetVersion,
            targetBuild: normalizedBuild,
            installStartedAt: sameTarget ? previous!.installStartedAt : timestamp,
            cleanTermination: sameTarget ? previous!.cleanTermination : false
        )
        save(record)
    }

    /// Observed via `NSApplication.willTerminateNotification`. For an install
    /// hand-off this is sent by Sparkle's normal Apple quit event, so a later
    /// old-version launch is meaningful failure evidence rather than a crash.
    func markCleanTermination() {
        guard var record = load() else { return }
        record.cleanTermination = true
        save(record)
    }

    /// Evaluate once during launch. Clears the record in all cases; returns a
    /// notice only when installation was started, the host terminated cleanly,
    /// and the installed version is still older than the target.
    func evaluateOnLaunch(
        currentVersion: String,
        currentBuild: String?,
        at date: Date? = nil,
        isAtLeast: (String, String) -> Bool
    ) -> UpdateRecoveryNotice? {
        guard let record = load() else { return nil }

        // Sparkle compares CFBundleVersion (SUAppcastItem.versionString) when
        // deciding update order; CFBundleShortVersionString is display-only.
        // Therefore, when both builds are available, the build comparison is
        // authoritative: never let an equal/higher short version mask a lower
        // build (e.g. target build 102 vs current build 101 on short 1.8.1).
        // Short version is only a fallback when either build is unavailable.
        let targetBuild = record.targetBuild?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentBuildValue = currentBuild?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let installedTarget: Bool
        if !targetBuild.isEmpty, !currentBuildValue.isEmpty {
            installedTarget = isAtLeast(currentBuildValue, targetBuild)
        } else {
            installedTarget = isAtLeast(currentVersion, record.targetVersion)
        }
        if installedTarget {
            clear()
            return nil
        }

        let age = (date ?? now()).timeIntervalSince(record.installStartedAt)
        guard age >= 0, age <= Self.maxAge else {
            clear()
            return nil
        }
        guard record.cleanTermination else {
            // Force quit/crash: do not claim a product failure we cannot prove.
            clear()
            return nil
        }

        clear()
        return UpdateRecoveryNotice(targetVersion: record.targetVersion, currentVersion: currentVersion)
    }

    /// Explicitly drop a pending record (e.g. the user cancelled installation,
    /// or an in-process error was already presented to the user).
    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// Exposed for regression tests/diagnostics; not used by the UI.
    func hasPendingAttempt() -> Bool {
        load() != nil
    }

    // MARK: - persistence

    private func load() -> PendingUpdateAttempt? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        guard let record = try? JSONDecoder().decode(PendingUpdateAttempt.self, from: data),
              record.schema == Self.schemaVersion,
              !record.targetVersion.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return nil
        }
        return record
    }

    private func save(_ record: PendingUpdateAttempt) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

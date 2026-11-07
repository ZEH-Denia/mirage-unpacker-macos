import AppKit
import Sparkle
import SwiftUI

struct UpdateFailure: Identifiable {
    let id = UUID()
    let message: String
}

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published var failure: UpdateFailure?

    private var updaterController: SPUStandardUpdaterController!
    private var manualCheckInProgress = false
    private var updateAttemptInProgress = false
    private let recovery = UpdateRecoveryStore()

    private let releasesURL = URL(string: "https://github.com/ZEH-Denia/mirage-unpacker-macos/releases/latest")!

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: !DevelopmentEnvironment.isDevelopment,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        recoverPendingUpdateFailureIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Sparkle's final installation step runs in the separate Autoupdate
    /// process. If it fails after this app has already terminated, no delegate
    /// callback can reach us. The next launch compares the installed version
    /// with a record written at Sparkle's documented install hand-off.
    private func recoverPendingUpdateFailureIfNeeded() {
        guard !DevelopmentEnvironment.isDevelopment else { return }
        let info = Bundle.main.infoDictionary
        let currentVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
        let currentBuild = info?["CFBundleVersion"] as? String ?? currentVersion
        guard let notice = recovery.evaluateOnLaunch(
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            isAtLeast: Self.versionAtLeast
        ) else { return }
        failure = UpdateFailure(message: notice.message)
    }

    private static func versionAtLeast(_ current: String, _ target: String) -> Bool {
        SUStandardVersionComparator.default.compareVersion(current, toVersion: target) != .orderedAscending
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        // Sparkle requests a normal Apple quit before installing. Only a clean
        // termination is treated as evidence that installation was attempted.
        recovery.markCleanTermination()
    }

    func checkForUpdates() {
        guard !DevelopmentEnvironment.isDevelopment else { return }
        manualCheckInProgress = true
        updaterController.updater.checkForUpdates()
    }

    func openGitHubReleases() {
        NSWorkspace.shared.open(releasesURL)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        updateAttemptInProgress = true
    }

    /// Called immediately before Sparkle hands the update to its installer
    /// (after the user authorised installation). Persist the target so a failed
    /// final replacement can be reported on next launch.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        updateAttemptInProgress = true
        recovery.recordInstallStart(
            targetVersion: item.displayVersionString,
            targetBuild: item.versionString
        )
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        presentFallback(for: error)
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        updateAttemptInProgress = false
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        defer {
            if updateCheck.rawValue == 0 {
                manualCheckInProgress = false
            }
            updateAttemptInProgress = false
        }

        guard let error else { return }
        let nsError = error as NSError
        let isNoUpdateAvailable = nsError.domain == SUSparkleErrorDomain && nsError.code == 1001
        let userCancelledInstallation = nsError.domain == SUSparkleErrorDomain && nsError.code == 4007
        if userCancelledInstallation {
            // The user explicitly declined installation at the authorization
            // step; this is not a product failure.
            recovery.clear()
            return
        }
        guard !isNoUpdateAvailable else { return }

        if manualCheckInProgress || updateAttemptInProgress {
            presentFallback(for: error)
        }
    }

    private func presentFallback(for error: Error) {
        // An in-process error is reported immediately; do not show it again on
        // the next launch.
        recovery.clear()
        guard failure == nil else { return }

        let details = error.localizedDescription
        failure = UpdateFailure(
            message: "PKD 无法通过应用内更新完成本次更新。请前往 GitHub Releases 手动下载最新版，并按页面说明替换应用。\n\n原因：\(details)"
        )
    }
}

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

    private let releasesURL = URL(string: "https://github.com/ZEH-Denia/mirage-unpacker-macos/releases/latest")!

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        manualCheckInProgress = true
        updaterController.updater.checkForUpdates()
    }

    func openGitHubReleases() {
        NSWorkspace.shared.open(releasesURL)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        updateAttemptInProgress = true
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
        guard !isNoUpdateAvailable, !userCancelledInstallation else { return }

        if manualCheckInProgress || updateAttemptInProgress {
            presentFallback(for: error)
        }
    }

    private func presentFallback(for error: Error) {
        guard failure == nil else { return }

        let details = error.localizedDescription
        failure = UpdateFailure(
            message: "PKD 无法通过应用内更新完成本次更新。请前往 GitHub Releases 手动下载最新版，并按页面说明替换应用。\n\n原因：\(details)"
        )
    }
}

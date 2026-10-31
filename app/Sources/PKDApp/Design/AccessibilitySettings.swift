import SwiftUI
import AppKit

/// 系统辅助功能偏好。
///
/// 这个 SDK 的 SwiftUI 接口被裁剪过，没有 `accessibilityReduceMotion` /
/// `accessibilityReduceTransparency` 这些 EnvironmentValue，只能走 AppKit。
@MainActor
final class AccessibilitySettings: ObservableObject {
    @Published private(set) var reduceMotion = false
    @Published private(set) var reduceTransparency = false
    @Published private(set) var increaseContrast = false

    private var observer: NSObjectProtocol?

    init() {
        reload()

        observer = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.reload()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func reload() {
        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
    }
}

import SwiftUI
import PKDKit

@main
struct PKDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var appearance = AppearanceSettings()

    var body: some Scene {
        WindowGroup("PKD 解包器") {
            RootView()
                .environmentObject(model)
                .environmentObject(appearance)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新素材库") {
                    model.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("解包所选") {
                    model.requestExtraction()
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button("取消全部任务") {
                    model.queue.cancelAll()
                }
                .keyboardShortcut(".", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(appearance)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 同步强杀子进程：否则退出后 repkg 会继续往输出目录写 GB 级文件
        AppModel.current?.queue.terminateAllChildren()
    }
}

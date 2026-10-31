import SwiftUI
import PKDKit

@main
struct PKDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var appearance = AppearanceSettings()
    @StateObject private var accessibility = AccessibilitySettings()

    init() {
        // 1.3.0 及更早版本的皮肤参数已废弃
        AppearanceSettings.purgeLegacyKeys()
    }

    var body: some Scene {
        WindowGroup("PKD 解包器") {
            RootView()
                .environmentObject(model)
                .environmentObject(appearance)
                .environmentObject(accessibility)
                .onAppear { appearance.applyTheme() }
        }
        .defaultSize(width: 1100, height: 740)
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

            CommandMenu("视图") {
                Button("详情") { model.selectedTab = .detail }
                    .keyboardShortcut("1", modifiers: .command)
                Button("队列") { model.selectedTab = .queue }
                    .keyboardShortcut("2", modifiers: .command)
                Button("存储") { model.selectedTab = .storage }
                    .keyboardShortcut("3", modifiers: .command)

                Divider()

                Button(model.isInspectorPresented ? "隐藏日志" : "显示日志") {
                    model.isInspectorPresented.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])

                Button(model.columnVisibility == .detailOnly ? "显示侧栏" : "隐藏侧栏") {
                    model.columnVisibility = model.columnVisibility == .detailOnly ? .all : .detailOnly
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
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

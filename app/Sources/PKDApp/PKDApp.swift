import SwiftUI
import PKDKit

@main
struct PKDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var appearance = AppearanceSettings()
    @StateObject private var accessibility = AccessibilitySettings()

    init() {
        // 本应用统一使用 overlay 滚动条。
        //
        // 系统偏好是「显示滚动条：自动」且接了鼠标时，`NSScroller.preferredScrollerStyle`
        // 就是 `.legacy`——AppKit 会给每个滚动视图画一条常驻的白色轨道。侧栏是半透明灰底，
        // 这条白底非常突兀；而 SwiftUI 的列表每次更新都会把 `scrollerStyle` 重置回系统偏好，
        // 所以逐个滚动视图设 `.overlay` 会被立刻撤销（实测 1 秒内退回 legacy）。
        //
        // 这个键只写进应用自己的 defaults 域，不改系统设置；AppKit 读到后
        // preferredScrollerStyle 直接变成 overlay，SwiftUI 再怎么重置也只会重置成 overlay。
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")

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
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新素材库") {
                    model.refreshCurrentContext()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("解包所选") {
                    model.requestExtraction()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.extractableSelection.isEmpty)

                Button("取消全部任务") {
                    model.queue.cancelAll()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.queue.activeCount == 0)

                Divider()

                Button("打开输出目录") {
                    if let item = model.focusedItem {
                        model.openOutput(for: item)
                    }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.focusedItem.map { model.history.entry(for: $0.id) != nil } != true)

                Button("在 Finder 中显示") {
                    if let item = model.focusedItem {
                        model.revealInFinder(item.pkgURL ?? item.folderURL)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.focusedItem == nil)
            }

            CommandMenu("任务") {
                Button("重试失败任务") { model.queue.retryAllFailed() }
                    .disabled(model.queue.failedCount == 0)

                Button("清除已完成任务") { model.queue.removeFinished() }
                    .disabled(!model.queue.jobs.contains { $0.state.isTerminal })

                Divider()

                Button("取消全部任务") { model.queue.cancelAll() }
                    .disabled(model.queue.activeCount == 0)
            }

            CommandMenu("视图") {
                Button("详情") { model.selectedTab = .detail }
                    .keyboardShortcut("1", modifiers: .command)
                Button("队列") { model.selectedTab = .queue }
                    .keyboardShortcut("2", modifiers: .command)
                Button("存储") { model.selectedTab = .storage }
                    .keyboardShortcut("3", modifiers: .command)

                Divider()

                Menu("筛选") {
                    ForEach(AppModel.LibraryFilter.allCases) { filter in
                        Button(filter.label) { model.filter = filter }
                    }
                }

                Divider()

                Button(model.isInspectorPresented ? "隐藏日志" : "显示日志") {
                    model.toggleInspector()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])

                Button("清空日志") {
                    model.logController.clear()
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!model.logController.hasContent)

                Button(model.columnVisibility == .detailOnly ? "显示侧栏" : "隐藏侧栏") {
                    model.setColumnVisibility(
                        model.columnVisibility == .detailOnly ? .all : .detailOnly
                    )
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

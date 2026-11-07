# 队列取消 / 强退恢复 / 引擎失败 / 日志判定 验收报告（任务 3）

- 负责人：queue-faults（Teammate）
- 日期：2026-11-06 19:54–20:50（Asia/Shanghai）
- 结论一句话：**取消与引擎失败的终态/UI 判定、旧产物保护、临时目录清理（可控路径）均通过；SIGKILL 强退存在两个真实可恢复性缺口（孤儿 repkg 继续写盘 + TMPDIR 陈旧临时目录无人清理）；文件日志存在两个真实缺陷（`LogSink.close()` 不冲刷 <16KiB 的 `pendingFileText` 尾块：短任务在未开检查器时完全没有日志文件，长任务经 >16KiB overflow 路径写出主体但缺终态尾行；之后 drain 再次打开文件时以 offset 0 覆盖/截断已有内容）。队列终态没有被误报为成功。**
- 被测产品代码：**只读**，未修改任何产品源文件（JobQueue/AppModel/LogSink/ProcessRunner 等均未触碰）。
- **2026-11-07 更新**：§5.1/§5.2 的 `LogSink` 缺陷已直接修复（§10）；§5.3 的 SIGKILL 孤儿/陈旧临时目录已用“父实例监控 + 专属 root + owner/flock janitor”修复（§11）；§5.4 失败文案已带退出码/分类（§11）。旧 §5.3 的 `TMPDIR/PKD-extract-*` 简单 janitor 建议已被更严格的实现取代、不再采用。

## 1. 隔离方式与被测构建（provenance）

| 项 | 值 |
|---|---|
| 仓库 HEAD | `473ca4b6bebb61253cfdb6176ff92a5dea99645b` |
| 被测二进制 | `app/dist/PKD.app`（18:59 构建，1.8.1） |
| dist 主程序 SHA-256 | `f79e22ebe65151d491a34bb437f245afce8045f75c93365a7f7e76211b825c45` |
| dist 内置 repkg SHA-256 | `75ed361db4a31cacfcacdd6d54ab08f50e3c1581ef7609658b6c8cb7e775e7ce` |
| 测试副本 | `app/.build/fault-<ts>/app/PKD Fault.app`，bundle id **com.zeh.pkd.development**（`DevelopmentEnvironment.swift` 硬性要求，否则会退回真实数据根） |
| 隔离数据根 | `app/.build/fault-<ts>/root`（经 Info.plist `LSEnvironment.PKD_DEVELOPMENT_ROOT` + 进程环境双保险） |
| 副本主程序 | 重命名 `Contents/MacOS/PKDFault` + ad-hoc 重签（sha `17cf93f6…`，哈希受重命名/签名影响，不代表源码变化） |
| 启动方式 | 直接执行 bundle 内可执行文件；**必须重命名**，否则其它分工按 `process "PKD"` 的 System Events 自动化会命中本副本并关闭其窗口（实测复现，见 §7.4） |
| 源码状态说明 | 测试期间其它分工在 20:07+ 改了 AppModel/WallpaperCard/GridView/Storage 等；**本报告结论只对应 18:59 构建的二进制** |
| 测试配置 | 副本为 dev 模式，`仅导出图片` 被代码强制开启（临时目录解包→导出→清理）；自动化用例通过 `defaults write com.zeh.pkd.development pkd.confirmBeforeStart false` 关闭确认弹窗；日志真实性用例另用产品自带调试钩子 `PKD_SMOKE_INSPECTOR=1` + `pkd.debug.inspectorTab=logs`。**以上 defaults 键已在收尾删除** |

主要证据目录（gitignored）：`app/.build/fault-20261106-203349/`（主证据）；`app/.build/fault-20261106-200852/`（早期同构建运行，含被覆盖日志的残留件）。报告内提到的 `EVID` 均指主证据目录。

## 2. 用例与命令

```bash
# 准备+启动隔离副本（生成中性合成 fixture：小包/慢包/损坏包/第二个小包）
tools/dev/fault-launch.sh --fresh
# 取消（单任务取消 + 运行中/排队中“取消全部”）
FAULT_EV=app/.build/fault-<ts> tools/dev/fault-cancel.sh
# SIGKILL 强退 + 重启
FAULT_EV=app/.build/fault-<ts> tools/dev/fault-kill.sh
# 引擎失败（非0退出 / exit0 但无 Done 哨兵 / 真损坏包）
FAULT_EV=app/.build/fault-<ts> tools/dev/fault-engine.sh
# 日志真实性（检查器隐藏/晚开/失败/取消）
FAULT_EV=app/.build/fault-<ts> tools/dev/fault-log-truth.sh
FAULT_EV=app/.build/fault-<ts> tools/dev/fault-log-probe.sh
# 引擎缺失（沙箱内拒绝编译期回退路径，不改仓库内引擎）
FAULT_EV=app/.build/fault-<ts> tools/dev/fault-engine-missing.sh
```

fixture：`tools/dev/fault-make-fixtures.py` 只写隔离根；`01 正常小包`（82KB）、`02 慢速大包`（192MB/40045 条目，实测真实 repkg 解包约 7.5s，用于取消/强退窗口）、`03 损坏包`（garbage scene.pkg）、`04 后续正常`。未改动现有生成器、未复制任何用户素材。

## 3. 结果总表（真实通过/失败/未验证）

| # | 用例 | 期望 | 实测 | 结论 |
|---|---|---|---|---|
| 1 | 运行中单任务取消（队列行「取消」按钮） | 终态 `已取消`、repkg 停止、临时产物清理、旧产物不动 | 取消前 `共 1 项 · 1 进行中`、temp 162304KB、repkg 存活；取消后 `共 1 项 · 1 取消`、temp=none、repkg=none；`Images/02…` 未创建；`Images/01…` 3 张图 sha256 全对 | **通过** |
| 2 | 运行中+排队中「取消全部任务」 | 两者都取消、排队任务不产出、无残留进程/临时目录 | 取消前 `共 2 项 · 1 排队 · 1 进行中`；取消后 `共 2 项 · 2 取消`、两个输出目录都不存在、temp=none、repkg=none | **通过** |
| 3 | 取消时临时目录清理范围 | 只删本任务 TMPDIR 解包目录，不动旧导出/用户数据 | 仅 `$TMPDIR/PKD-extract-<uuid>` 被删；`Images/01…` 校验 0 差异 | **通过** |
| 4 | SIGKILL 后子进程 | 不应继续无主写盘 | app 死后 repkg **变孤儿（ppid=1）**并继续写，temp 从 12788 文件/158MB 涨到 **40055 文件/266MB** 才自然结束 | **失败（可恢复性缺口）** |
| 5 | SIGKILL 后临时目录 | 重启后应被清理或可自愈 | 重启后陈旧 `PKD-extract-784295D6…`（266MB）仍在（脚本记录了路径并在留证后删除） | **失败（可恢复性缺口）** |
| 6 | 强退重启后队列状态 | 不得卡在 running/幽灵任务 | 重启后队列 `共 0 个任务`（队列本就只在内存，属设计），无 running 残留 UI | **通过**（“无法恢复任务”属设计，不算缺陷） |
| 7 | 强退后旧文件/历史 | 旧导出与历史不损坏 | `Images/01…` sha256 校验 0 差异；`history.json` 前后 sha256 相同；`collections.json` 变化但 JSON 合法、favorites 保留；只重启不操作时 collections 完全不变（变化来自测试自身点选产生的 visits 记录） | **通过（有说明）** |
| 8 | 引擎非 0 退出（wrapper exit 1） | `失败` 终态、不得假成功、自动重试一次 | UI `失败：repkg 异常退出（包可能已损坏）`、出现「重试」按钮、日志有 1 条「自动重试一次」、无成功终态 | **通过**（附文案小问题，见 §6.3） |
| 9 | 引擎 exit 0 但无 `Done` 哨兵（RePKG 真实退出码语义） | 必须判失败 | UI `失败：解包未正常结束（未收到完成标记）`，日志同名终态 + 重试行；**未误判成功** | **通过** |
| 10 | 真损坏 scene.pkg（真实引擎，SIGABRT 134） | 失败终态、重试一次、旧产物不破坏、临时清理 | UI `失败：repkg 异常退出（包可能已损坏）`；系统产生 repkg crash report；temp=none | **通过** |
| 11 | 失败后队列继续 | 后续任务正常执行 | 失败任务后再入队 `01` → `共 1 项 · 1 成功` | **通过** |
| 12 | repkg 缺失 | 红色告示 + 任务失败且如实报错 | 沙箱内（拒绝编译期回退路径、副本内置引擎移除）UI 可见 `未找到 repkg 引擎`，任务 `失败：未找到 repkg 引擎`；仓库 `tools/bin/repkg` 未被改动 | **通过** |
| 13 | 日志文件是否总落盘（README 声称“完整日志同时写入 Logs/”） | 每个任务都应有完整对应文件 | **短任务（<16KiB 日志）在检查器未渲染「日志」页时完全没有文件**（本任务 L1 两次复现；verifier `qa-logtest-evidence/` 独立复现“无文件/晚写”，见 `app/.build/verify-20261106-200255/`）；**长任务因 >16KiB overflow 路径即使不开检查器也会写出主体**（verifier `qa-bigjob-evidence/truncation-before.txt`：`before: size=1040461`），但缺终态尾行；打开日志页后 drain 才补写（本任务 L2） | **失败** |
| 14 | 日志晚到写入是否保序/保内容 | 只追加，不得破坏已写内容 | 本任务单次实测：已写 1,040,236 字节、首行为任务标题的日志，重新打开日志页后变成 1,455 字节且首行变成解包中条目（机制：offset 0 重开覆盖/截断；数值为单次观测）。verifier 独立复现同一机制：`app/.build/verify-20261106-200255/logsink-repro.txt`（`20001 → 17`，`contains_big=false`）、`qa-bigjob-evidence/`（`1,040,461 → 1,694` 字节，`truncated-after.log` 首行为解包条目） | **失败** |
| 15 | 日志终态判定真实性（日志文件被完整写出时） | 成功/失败/取消终态与 UI 一致 | 成功：`结束：成功`；引擎失败：`结束：失败：repkg 异常退出（包可能已损坏）`；无哨兵：`结束：失败：解包未正常结束（未完成标记）`；取消：`收到中断信号，正在停止…` + `结束：已取消`；失败用例日志均含「自动重试一次」 | **通过（文件被完整写出时；短任务未开检查器则无文件，见 #13）** |
| 16 | SIGKILL 时的日志 | — | 被杀任务日志可能只有部分内容、无终态（5AF7/FC3E）；属 SIGKILL 语义，但与 #4/#5 叠加后“无任何恢复线索” | **未验证/限制** |
| 17 | 「完整解包」模式（输出目录直写）下取消的半成品范围 | 旧文件保持、半成品范围合理 | 主证据全部在 dev 默认「仅导出图片」模式采集；早期会话在完整解包模式手工取消过一次（表现为输出目录保留部分文件），**未形成脚本化证据** | **未验证** |
| 18 | 读取包结构阶段取消 / 2 并发取消 | 终态正确 | 未覆盖（fixture 包信息读取过快；并发 2 可调但未测） | **未验证** |
| 19 | 失败任务点「重试」按钮实际重跑 | 能重跑/不卡队列 | 只验证了「重试」按钮出现（每次失败都有）；未实际点击重跑 | **未验证** |

## 4. 关键证据摘录

- 取消单任务：`EVID/evidence/cancel/b-single-facts.txt`、`b-single.csv`（时间序列）、`b-single-precancel-tree.txt`/`postcancel-tree.txt`（AX 快照）、`old-output-01.sha256` + `b-single-old-output-verify.txt`（0 问题）。
- 取消全部：`EVID/evidence/cancel/c-all-facts.txt`、`c-all.csv`。
- 强退：`EVID/evidence/kill/kill-facts.txt`（含 `pre_temp_files=12788 → post_temp_files=40055`、`pre_temp_kb=158360 → 266732`、`orphan_repkg_pid=34425`）、`orphan-observation.csv`（ppid=1 持续增长）、`post-restart-queue-tree.txt`、`post-restart-old-output-verify.txt`、`history-before.sha256`/`history_after`。
- 引擎失败：`EVID/evidence/engine/e1-crash-facts.txt`、`e2-nodone-facts.txt`、`e3-corrupt-facts.txt`、`e1b-facts.txt`（失败后继续成功）、`e1-*-post-tree.txt`（UI 文案）、`engine-final.txt`（引擎恢复校验）。
- 引擎缺失：`EVID/evidence/engine-missing/setup.txt`（`bundled engine removed: yes / repo_engine_untouched: yes`、`engine_missing_notice_visible=yes`）、`facts.txt`（`failed_message_visible=yes`、`temp_dirs=0`）、`post-tree.txt`。
- 日志判定：`EVID/evidence/logtruth/transcript.txt` 与 `l1..l4-facts.txt`；`EVID/evidence/logtruth2/log-verdicts.txt`（逐文件终态/重试行/中断行统计）、`logs-snapshot/`（不可再变的副本）、`earlier-evidence/NOTE.txt`（1,040,236 → 1,455 字节覆盖记录 + 残留日志副本，单次实测）。
- verifier 独立复现（不属本任务产出，供交叉复核）：`app/.build/verify-20261106-200255/logsink-repro.txt`（20,001 → 17 字节）、`app/.build/verify-20261106-200255/qa-logtest-evidence/`（短任务无文件/晚写）、`app/.build/verify-20261106-200255/qa-bigjob-evidence/`（`truncation-before.txt` 1,040,461 字节 → `truncated-after.log` 1,694 字节）。

## 5. 真实产品缺陷（附精确建议，未改代码）

> 当前工作区这些文件有其它分工的未提交改动，行号按当前文件内容给出；合入前请 rebase 核对。完整 diff 建议如下（均为最小改动）。

### 5.1 P1 日志晚到写入会覆盖/截断已写内容
`app/Sources/PKDKit/Support/LogSink.swift:89-110`
原因：`close(jobID:)` 只关句柄，未冲刷该任务残留的 `pendingFileText`（因此 <16KiB 的尾块不会成为文件内容的一部分）；之后 `write()` 对新句柄未定位到文件末尾，且 `createFile(contents:nil)` 会截断已有文件 → 下次 drain 晚到时把旧日志覆盖掉（本任务单次实测 1,040,236 → 1,455 字节；verifier 独立复现 20,001 → 17 与 1,040,461 → 1,694 字节，机制相同）。

```diff
     public func close(jobID: UUID) {
+        lock.lock()
+        let chunk = pendingFileText.removeValue(forKey: jobID)
+        lock.unlock()
+        if let chunk { write(chunk, jobID: jobID) }
         lock.lock()
         let handle = handles.removeValue(forKey: jobID)
         lock.unlock()
         try? handle?.close()
     }
@@
-            FileManager.default.createFile(atPath: url.path, contents: nil)
-            handle = (try? FileHandle(forWritingTo: url)) ?? FileHandle.nullDevice
+            if !FileManager.default.fileExists(atPath: url.path) {
+                FileManager.default.createFile(atPath: url.path, contents: nil)
+            }
+            let opened = try? FileHandle(forWritingTo: url)
+            try? opened?.seekToEnd()
+            handle = opened ?? FileHandle.nullDevice
             handles[jobID] = handle
```
风险：低。`seekToEnd()` 需 macOS 10.15.4+（项目已用 SwiftUI 新 API，满足）。注意 `close()` 中 `pendingFileText` 是 `private`，同文件内可直接访问。

### 5.2 P1 日志落盘不可靠：短任务无文件、长任务缺终态尾行、晚到写入覆盖旧内容（与 README 承诺不符）
`app/Sources/PKDApp/Log/LogInspector.swift:14,28-33`（唯一 drain 定时器）+ `app/Sources/PKDKit/Support/LogSink.swift:71`（`drain()` 才落盘）+ `LogSink.swift:89`（`close()` 不冲刷尾块）

表现（分层，勿一概而论）：
- **短任务（<16KiB 输出）**：日志只进 `pendingFileText`；检查器未渲染「日志」页时 `close()` 不冲刷，任务结束后 `Logs/` 里没有对应文件；之后打开日志页 drain 才补写。
- **长任务**：>16KiB 的 overflow 路径会把主体写盘（即使检查器未开），但 `close()` 不冲刷剩余尾块，文件缺 `结束：…` 等终态尾行。
- **两者共同点**：`drain()` 晚到写入时新句柄未 `seekToEnd()`，会以 offset 0 覆盖/截断已写出内容（verifier 独立复现 `20001 → 17` 与 `1,040,461 → 1,694`）。
建议二选一：
1. **最小**：把 drain/flush 从视图搬到 `AppModel`，在 `AppModel.init` 里建 0.1s Timer 持续 `log.drain()` 并喂 `logController`（`LogInspector` 中删除对应 `onReceive(ticker)`，避免双写）。
2. 保守：保留现状，至少在 `LogSink.close(jobID:)` 内冲刷（依赖 5.1），保证任务结束时文件完整；但任务进行中仍无实时文件。
建议 1，diff（`AppModel.init` 内、`self.queue = JobQueue(...)` 之后）：
```diff
+        let drainTicker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
+        drainTicker.sink { [weak self] _ in
+            guard let self else { return }
+            let lines = self.log.drain()
+            if !lines.isEmpty { self.logController.append(lines) }
+        }.store(in: &cancellables)
```
风险：低；注意与 `LogInspector` 的现有 ticker 不可同时存在（会重复显示/双写）。

### 5.3 P1 SIGKILL 遗留：孤儿 repkg + 陈旧 TMPDIR 临时目录
根因：`applicationWillTerminate`（`app/Sources/PKDApp/PKDApp.swift:161-164`）与 `JobQueue.terminateAllChildren()`（JobQueue.swift:428-432）只在正常退出路径执行；SIGKILL 时既不杀子进程，也不清理 `JobQueue.enqueue` 创建的临时目录（JobQueue.swift:43-46, `PKD-extract-<UUID>`）。
建议（不改变现有正常退出行为）：
1. **启动 janitor（必修）**：`AppModel.init`（`self.queue = JobQueue(...)` 附近，AppModel.swift:176 前）调用：
```swift
JobQueue.removeAbandonedTemporaryOutputs()
```
在 `JobQueue` 新增强制限定范围的方法（只碰 `FileManager.default.temporaryDirectory` 下 `PKD-extract-` 前缀目录，且要求目录内存在本 app 写的标记文件/或年龄 > 24h）：
```swift
/// 清理 SIGKILL/崩溃遗留的「仅导出图片」临时解包目录。
/// 只处理 temporaryDirectory 下 PKD-extract-<UUID> 形状的目录，其它任何路径/前缀一律不碰。
public static func removeAbandonedTemporaryOutputs(olderThan age: TimeInterval = 24 * 3600) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(
        at: fm.temporaryDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
    ) else { return }
    let cutoff = Date().addingTimeInterval(-age)
    for url in entries where url.lastPathComponent.hasPrefix("PKD-extract-") {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate,
              modified < cutoff else { continue }
        try? fm.removeItem(at: url)
    }
}
```
风险：24h 阈值可避免误删同用户另一个仍在运行的实例的目录；如要更积极可配合“目录内 owner pid 文件 + kill(pid,0) 判活”。
2. **可选（彻底）**：`ProcessRunner.run` 用 `posix_spawn` 的 `POSIX_SPAWN_SETPGROUP` 让 repkg 进入独立进程组，并配合 Shell/终止时 `kill(-pgid)`；`Foundation.Process` 无此开关，改动面较大，建议先做 janitor。
证据：`EVID/evidence/kill/kill-facts.txt`、`orphan-observation.csv`。

### 5.4 P3 失败文案精度（非假成功，仅可读性）
`app/Sources/PKDKit/Engine/ExtractModels.swift`（`Failure.crashed.message`）把所有非 0 退出都描述为“包可能已损坏”，引擎自身崩溃/不兼容时也一样。建议带退出码：`"repkg 异常退出（退出码 \(code)，包可能已损坏或引擎不兼容）"`，并在 UI 警告里补充 stderr 尾部（`ExtractReport.stderrTail` 已有，`JobQueue` 日志可打印前 3 行）。风险：文案变更可能影响既有断言（`PKDSelfTest`/`verify.sh`），需同步检查。

## 6. 清理与收尾证据

| 项 | 状态 |
|---|---|
| 测试 app 进程 | 0（`pgrep -f "fault-*/PKD Fault.app"` 为空） |
| 测试 repkg / 孤儿进程 | 0 |
| TMPDIR 残留 | 0（`$TMPDIR/PKD-extract-*` 无匹配；kill 用例记录的 266MB 目录在留证后由脚本按记录路径删除） |
| 副本内置引擎 | 已恢复原始 SHA-256 `75ed361d…`，`codesign --verify --deep --strict` 通过 |
| 仓库 `tools/bin/repkg` | 未改动（沙箱方案拒绝编译期回退路径，未 rename/chmod 仓库引擎） |
| defaults | 已删除测试写入的 `pkd.confirmBeforeStart`、`pkd.debug.inspectorTab`；`com.zeh.pkd`（正式域）未写任何测试数据 |
| 受保护文件 | **我未编辑/还原/格式化**任何受保护文件。`sha256sum -c app/.build/update-flow-backup-.../protected-files-sha256.txt` 有 3 项 FAILED（`ExperimentalPuppetPreview.swift`、`PKDSelfTest/main.swift`、`tools/testdata/make_render_scene.py`），这 3 个文件的 mtime 为 20:21–20:29，是**其它分工在本会话期间的改动**（基线哈希记录于约 19:53），不是本次任务写入；其余 4 项 OK |
| 新增文件 | 仅 `tools/dev/fault-*`（脚本）与 `tools/dev/fault-queue/REPORT.md`；证据在 `app/.build/fault-*`（gitignored） |
| 正式 app/真实数据 | 未启动、未安装、未写入 `~/Library/Application Support/PKD` 或 `~/Library/Preferences/com.zeh.pkd.plist`（早期一次误用 dist bundle id 直接运行仅发生只读扫描，未入队任何任务；已在发现后立即终止并改用 dev bundle id + 独立根） |

## 7. 限制与说明

1. **模式限制**：dev 副本在 `AppModel.init` 强制 `exportImagesOnly = true`，因此主证据是“仅导出图片”模式（临时目录解包→导出→清理）。真实用户常用的“完整解包”直写输出目录模式下的取消半成品范围**未脚本化验证**（§3 #17）。
2. **队列不持久化**：`JobQueue.jobs` 只在内存；强退重启后队列为空是设计，不应作为缺陷；需要“恢复任务”属于产品需求变更，不在本次缺陷清单。
3. **日志文件完整性受缺陷 #5.2 影响**：短任务未开检查器时无文件、长任务缺终态尾行、晚到写入可覆盖旧内容；因此“日志判定属实”仅在文件被完整写出时成立。UI 队列状态/失败文案在所有用例中都与真实结果一致（AX 快照可查）。
4. **窗口被外部关闭的干扰**：测试早期（未重命名可执行文件前）其它分工按 `process "PKD"` 的 System Events 自动化命中并关闭了本副本窗口，导致两次中途失败；重命名 `PKDFault` 后完全稳定。该干扰只影响测试工具，不构成产品缺陷。
5. 未做真实用户壁纸/真实素材验证；全部为 `fault-make-fixtures.py` 生成的中性合成内容。
6. `collections.json` 在强退用例中变化，经单独实验确认是 UI 点选产生的 visits 更新（重启本身不改变文件），JSON 合法、favorites 保留；未发现数据损坏。

## 8. 建议的集成（给 verify.sh / selftest，不越权修改）

- `app/scripts/verify.sh` 第 6/7 步之外，建议新增“日志落盘完整性”用例：无 UI 检查器时跑一次合成任务，断言 `<LogDir>/<jobID>.log` 存在且末行为 `结束：…`——当前实现会失败，正好锁住 5.1/5.2 回归。
- 建议 selftest 增加 `--cancel-during-extract`（慢包 + 取消）与 `--kill-recovery`（janitor）两个批处理用例，避免只能靠 UI 手工验收。
- 若修复 5.3，请同步在 `PKDSelfTest` 增加“陈旧 PKD-extract 目录被清理、非该前缀目录不被碰”的单测。

## 9. 后台复核状态（2026-11-06 22:15，按「后台检测优先」策略）

自 22:14 起不抢占/激活前台、不向前台应用发送真实键鼠、不切壁纸、不改 TCC；只做独立后台进程、离屏/隔离输出与静态检查。此前 UI 证据保留为历史；依赖前台交互的步骤列为「前台待补」，不将新策略下的前台复验计为通过。

### 9.1 本次纯后台复核（通过）

| 项 | 结果 | 证据 |
|---|---|---|
| 离屏 LogSink 截断 | 缺陷仍在：20,001B → close 后缺尾行 → drain 后 17B 覆盖；`flushFiles` 对照 20,014B 完整 | `app/.build/offline-check-20261106-2216/logsink-probe3.txt` |
| 离屏 JobQueue 引擎失败 | valid `成功`；missing/crash/nodone/corrupt 均 `失败` 终态，未假成功 | 同目录 `probe2-*.txt` |
| 离屏取消（PKDKit 直连，无 UI） | 取消前 `解包中 active=1` → 取消后 `已取消 active=0`、waited=0.1s、输出仅 `_logs`、无残留进程 | 同目录 `probe4-cancel.txt` |
| 离屏 SIGKILL 模拟（PKDKit 直连，无 UI） | 杀死承载 JobQueue 的探针进程后，临时目录 `PKD-extract-99EB…` 仍在；假引擎变孤儿（ppid=1）继续写，文件数 63→99；清理后残留 0。复现了缺陷 #4/#5 的最小形态 | 同目录 `probe5-kill/facts.txt` |
| 静态缺陷标记（2026-11-07 修复前） | 当时 `LogSink.close()` 无 flush、`createFile` 仍存在；`JobQueue` 仅创建 `PKD-extract-`、无 janitor。**现已修复**，见 §10/§11 | 同目录 `state-audit.txt`（历史） |
| 状态 | `/Applications/PKD.app`、用户 collections/history、defaults 均未变；无测试进程/TMPDIR/挂载 | 同目录 `state-audit.txt` |

### 9.2 前台待补（不假称通过）

取消/取消全部 UI、强退后的队列 UI 终态、日志页渲染触发、引擎缺失红色告示、失败任务「重试」按钮实际点击、完整解包模式取消。此前证据保留为历史记录，但按新策略需前台复验；22:14 之后未再激活测试窗口或发送键鼠事件。


## 10. 修复记录（2026-11-07，LogSink 直接修复）

本轮用户授权直接修复 `app/Sources/PKDKit/Support/LogSink.swift`（仍不改 JobQueue/AppModel）。

### 10.1 修复内容

- 每个 job 的文件行在锁内按调用顺序入队，写入统一在单一串行 `ioQueue` 执行；append/overflow/drain/close 不再竞争同一文件句柄。
- `close(jobID:)` 先冲刷该 job 的 `<16 KiB` 未落盘尾块，再关闭句柄，并等待本 job 已入队写入完成；返回后立即读文件即完整。
- 文件只以追加方式打开：`seekToEnd()`，绝不 `createFile(contents:nil)` 截断已有内容；close 后的 drain/flush/晚到 append 只追加、不覆盖。
- 重复 close 幂等；close 后 append 会重新以追加方式打开同一文件。
- `flushFiles()` 返回前等待已入队写入；`drain()` 保持 10Hz 非阻塞（要“返回即落盘”请用 flush/close）。
- 性能：100,000 行 append 约 0.06 s，close 约 0.001 s（本机 M4 Pro，测试真实 LogSink）。

### 10.2 回归（真实 LogSink，非替身）

命令：`bash tools/dev/fault-logsink-tests.sh`
证据：`app/.build/logsink-tests-20261107-091500/`（编译日志 + run.log）
覆盖：小缓冲 close、原 probe3 序列、close 后 drain/flush 不截断、重复 close、晚到 append、多 job 隔离、并发 append+drain、flush/append 竞争、close/append 竞争、20,000 行 overflow、100k 行性能。
结果：**全部通过**（含顺序、无丢失、无重复断言）。

### 10.3 队列侧复核（修复后的 PKDKit）

命令（离屏 PKDKit 探针，无 GUI）：
- `probe2-close`（不调用 `flushFiles()`）：valid/missing/crash/nodone/corrupt 均 `logExists=true logHasEnd=true`，日志末行为 `结束：…`；证明 `JobQueue` 的 `close(jobID:)` 已足以落盘终态。
- `probe4`：取消前 `解包中 active=1` → 取消后 `已取消 active=0`，无产物、无残留进程；取消日志末行为 `结束：已取消 · 产物 0 个文件 · 1 秒`（close 已落盘）。
- `probe5`：2026-11-07 修复前，SIGKILL 后会留下孤儿 repkg/陈旧 TMPDIR；该问题已在 §11 用 supervisor + `TemporaryOutputs` janitor 修复，本条为历史记录。

证据：`app/.build/background-fix-20261107-0915/`（`valid.txt`、`missing.txt`、`crash.txt`、`nodone.txt`、`corrupt.txt`、`cancel.txt`、`kill/facts.txt`）。


## 11. 生命周期/临时目录/失败文案 修复（2026-11-07 追加）

本轮用户额外授权 `Jobs/JobQueue.swift`、`RepkgSession/进程调用相关文件`、`AppModel.init` 仅生命周期接线、`ExtractModels` 失败文案及新测试。所有实现均未改渲染、`main.swift`、StorageSafety、README/verify.sh/VERSION。

### 11.1 SIGKILL 孤儿 repkg：父实例监控（ProcessRunner）

实现位置：`app/Sources/PKDKit/Engine/ProcessRunner.swift`（`ProcessRequest.superviseParentDeath`，仅 `RepkgSession.extract` 启用）。

结构：

- App 的 `Process` 是 `/bin/sh` **wrapper**；wrapper 先启动独立的 **monitor**，monitor 是真正 repkg 的父进程。
- wrapper 记录自己的 PID 与 App PID；monitor 每 50 ms 检查 wrapper 的 PPID 是否仍等于 App PID。
- App 被 SIGKILL 时 wrapper 可能仍在（不会被自动杀），但 monitor 观察到 wrapper 的父 PID 已不是 App，即终止**它自己 spawn 的 repkg**（TERM→短暂等待→KILL），然后退出；wrapper 随之退出。不扫描/不 pkill 其它进程。
- App 正常退出/`cancelImmediately` 杀 wrapper 时，monitor 同样观察到 wrapper 消失并清理自己的 repkg；正常取消时 wrapper/monitor 转发 SIGINT/SIGTERM，最后兜底 KILL。
- monitor 只杀自己的直接子进程；PID/PGID 归属不依赖宽泛匹配。当前 repkg 不派生长期子进程；若未来引擎派生 grandchildren，需要扩展为进程组清理（本报告明确标为边界）。

回归（真实 `ProcessRunner`，无 GUI）：

```bash
bash tools/dev/fault-supervisor-tests.sh
```

**12 项 PASS**：正常退出/输出完整、取消及时且无残留、immediate cancel 无残留、父进程 SIGKILL 后引擎消失且停止写盘、并发 2 正常、含空格/引号/`$()`/反引号的路径与参数经纯 argv 传递且 sentinel 未被创建。证据：`app/.build/supervisor-tests-20261107-101155/run.log`。
JobQueue 侧复核：`probe2-close` valid 成功、crash 失败（日志完整）；`probe4` 取消 0.3 s、无残留；`concurrency` 2 正常完成 + 2 个取消均无残留（见 §11.3）。

### 11.2 临时目录回收：专属 root + owner 标记 + flock

实现位置：`app/Sources/PKDKit/Jobs/TemporaryOutputs.swift`、`JobQueue` 使用、`AppModel.init` 启动清理接线。

- 目录只创建在 `FileManager.temporaryDirectory/PKD-temp/` 专属 root，绝不使用用户输出/导入目录。
- 每个 job 目录含 `owner.json`（schema、bundleID、instanceID、jobID、PID、createdAt）与 `owner.lock`；进程存活期间持有 `flock(LOCK_EX)`，SIGKILL 时由内核释放。
- janitor 只扫描该 root；拒绝 symlink/非目录/路径重定向；要求 owner 标记有效、bundleID 匹配、非当前 instance、非当前 PID、年龄 ≥24h、lock 可获取；未知 owner/近期/活跃目录一律保留。删除前再次 canonical 校验并只删除 root 直接子目录。
- 未扫描旧版本遗留的 `TMPDIR/PKD-extract-*`，不删除真实 TMPDIR 历史数据；新 JobQueue 不再创建该前缀到 TMPDIR 根。

回归：

```bash
bash tools/dev/fault-temp-cleanup-tests.sh
bash tools/dev/fault-jobqueue-temp-tests.sh
```

- temp cleanup **14 项 PASS**：正常 release、近期保留、陈旧删除、unknown 保留、active flock 保留/释放后删除、同 PID 不同实例保留、root symlink 拒绝、stale 目录内 symlink 不跟随且外部目标不删、foreign bundle 保留。证据：`app/.build/temp-cleanup-tests-20261107-095957/run.log`。
- JobQueue 集成 **7 项 PASS**：活动 job 有 owner/lock、取消后 lease 释放、无残留。证据：`app/.build/jobqueue-temp-tests-20261107-095958/run.log`。
- 并发 2 **8 项 PASS**：两个真实 repkg job 均成功且各有产物；两个慢引擎取消均 cancelled、无临时 lease。证据：`app/.build/concurrency-tests-20261107-095959/run.log`。

### 11.3 非零退出文案

实现位置：`ExtractModels.ExtractReport.failureMessage` + `JobQueue` 使用。

- 退出码恒为 0 的历史事实仍用 Done 哨兵判定；非 0 时文案包含退出码与分类：无法启动（126/127）、权限/只读、磁盘不足、环境不兼容、被强制终止、引擎异常终止（134/139）、未知 stderr 首行。
- 不再把所有非 0 退出统称“包已损坏”；取消仍优先判 cancelled，不误报失败。
- 用 mock engine 复验：exit 127→“无法启动 repkg（退出码 127）”；Permission denied→权限；No space→磁盘；Library not loaded→环境；134→“异常终止（退出码 134）…”。证据：`app/.build/turn4-queue-20261107-0955/{missing,perm,disk,env,corrupt}.txt`。
- 真实 repkg + 合成损坏包：失败文案含 134，不再笼统归因包损坏；日志/LS 状态仍 failed。

### 11.4 本轮边界

- 未做真实 GUI 下的 SIGKILL（无前台；但 supervisor 的父进程 SIGKILL 回归使用真实 ProcessRunner/JobQueue 等价的离屏进程）。
- repkg 若派生长寿 grandchildren，当前只保证直接子进程被终止；未观察到该行为，明确保留为边界。
- 历史 PC 上的旧 `TMPDIR/PKD-extract-*` 目录不会被 janitor 删除（安全取舍）。
- 未改 `main.swift`/渲染/StorageSafety；正常取消/完成/并发 2 已按上述测试回归。

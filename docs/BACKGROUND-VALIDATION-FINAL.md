# 后台验收补完记录（2026-11-07）

本文件只记录 **不激活前台、不发送真实键鼠、不切壁纸、不改 TCC** 条件下可独立完成的检查。
需要前台交互的项仍标为「待补」，不因为已有历史证据而改称新策略下已通过。

## 0. 结论

- `LogSink` 的 close 丢尾行 / 晚到 drain 覆盖旧文件缺陷已修复；用真实 `LogSink` 的 23 项生命周期/并发回归全部通过。
- 新增更新失败“下次启动恢复提示”状态机（`UpdateRecovery.swift` + `UpdateManager` 接入）；**25 项**状态机测试通过（含同 shortVersion 不同 build、build 优先于 shortVersion）；构建通过；真实 F5 弹窗仍待前台验证。
- 队列取消/引擎失败/日志落盘在修复后的 PKDKit 上复验通过；**SIGKILL 孤儿 repkg 已由父实例 supervisor 修复**（app 被 SIGKILL 后 monitor 只终止自己 spawn 的引擎）；**临时目录改为专属 PKD-temp + owner.json + flock janitor**；**非零退出文案带退出码/分类**。
- UI 4 分钟内存检查（S9，`--no-activate`）已实跑：无 4 分钟内持续失控增长，但只覆盖 4 分钟、400 卡、后台窗口，不能外推长时或前台滚动场景。
- 可重复合成基线再次 29/29 通过。
- 未 commit/push/release/安装；未改 VERSION、README、verify.sh；按额外授权修改了 JobQueue/AppModel.init/ProcessRunner/RepkgSession/ExtractModels 与新增生命周期模块；未改 UI 源码。

## 1. LogSink 修复（本批直接修改）

文件：[`app/Sources/PKDKit/Support/LogSink.swift`](../app/Sources/PKDKit/Support/LogSink.swift)
SHA-256：`4f83939a581ffadd65c5321d7c73fb97f74b45423e73408c401dc9e36c48ab04`

修复要点：

- 每个 job 的日志行在锁内按调用顺序入队，文件写入统一走单一串行 `ioQueue`；append/overflow/drain/close 不再竞争未定位的 FileHandle。
- `close(jobID:)` 先冲刷 `<16 KiB` 尾块，再关闭句柄并等待已入队写入完成；返回即包含终态尾行。
- 文件只以追加方式打开（`seekToEnd`），不做 `createFile(contents:nil)` 截断；close 后 drain/flush/晚到 append 只追加，不覆盖旧日志。
- 重复 close 幂等；close 后 append 会重新打开同一文件继续追加。
- `flushFiles()` 返回前等待写入；`drain()` 保持 10Hz 非阻塞。
- 没有把所有写入塞主线程；100,000 行 append 实测约 0.06 s，close 约 0.001 s（M4 Pro）。

### 1.1 回归（真实 LogSink）

```bash
bash tools/dev/fault-logsink-tests.sh
```

证据：`app/.build/logsink-tests-20261107-091500/`（`compile.log` + `run.log`）
结果：**23 项 PASS**，覆盖小缓冲 close、原 probe3 序列、close 后 drain/flush 不截断、重复 close、晚到 append、多 job 隔离、并发 append+drain、flush/append 竞争、close/append 竞争、20,000 行 overflow、100k 行性能。

### 1.2 队列真实路径复核（无 UI）

用修复后的 PKDKit 编译离屏探针（不调用 `flushFiles()`）：

- valid：`logExists=true logHasEnd=true`，末行 `结束：成功 …`
- missing/crash/nodone/corrupt：均 `失败` 终态且日志含 `结束：失败：…`，未假成功
- cancel：`解包中 active=1` → `已取消 active=0`，无产物、无残留进程；日志末行 `结束：已取消 · 产物 0 个文件 · 1 秒` 已由 close 落盘
- SIGKILL：2026-11-07 追加修复前曾复现孤儿 repkg/陈旧 `$TMPDIR/PKD-extract-*`；现由 supervisor + PKD-temp janitor 处理，见 §9
- 磁盘预检：在 20 MiB 隔离 sparse image 上，200 MiB 稀疏包触发 `警告：预计需要 629.1 MB，剩余 Zero KB`，任务继续并在引擎失败后正确落败；未填真实盘、未对用户目录 chmod

证据：`app/.build/background-fix-20261107-0915/`（`valid.txt`、`missing.txt`、`crash.txt`、`nodone.txt`、`corrupt.txt`、`cancel.txt`、`disk-precheck.txt`、`kill/facts.txt`）

## 2. 更新失败“下次启动恢复提示”

新增：[`app/Sources/PKDApp/UpdateRecovery.swift`](../app/Sources/PKDApp/UpdateRecovery.swift)
修改：[`app/Sources/PKDApp/UpdateManager.swift`](../app/Sources/PKDApp/UpdateManager.swift)
SHA-256：`5ae5a8bd750a73f95943bea07391164d17acc4c3e195b79ecaf95dd4e1d992e6` / `885c2e23e3a88690e5caba62611c0e7f801ea2c1143479d53eb4cf380cdd5e4f`

规则：

- Sparkle 官方 `updater(_:willInstallUpdate:)`（安装交接、宿主终止前）写目标版本/构建号；仅发现/下载/排队不写记录。
- `NSApplication.willTerminateNotification` 标记 clean termination（Sparkle 用 Apple quit event）。
- 下次启动：当前版本 ≥ 目标 → 静默清除；超过 30 天 → 静默清除；非 clean termination（强退/崩溃）→ 不报；clean + 仍低版本 → 复用现有「更新未能完成」弹窗与「前往 GitHub 手动下载」按钮。
- 用户取消安装（4007）或宿主存活时已弹错误 → 清除记录，避免重复/误报。
- 版本判定以 Sparkle 的 `SUAppcastItem.versionString`（CFBundleVersion/build）为准；目标与当前 build 都存在时只比较 build，绝不让 shortVersion 的相等/更高掩盖更低 build；只有 build 缺失才回退 shortVersion。
- **无需 PKDApp/AppModel 接线**：`PKDApp` 已有 `$updater.failure` 弹窗绑定；新文件由 SwiftPM 自动包含。

测试：

```bash
bash tools/dev/fault-update-recovery-tests.sh
```

证据：`app/.build/update-recovery-tests-20261107-094817/run.log`；**25 项状态机断言 PASS**（无记录静默、clean+旧版提示、新版静默、重复 willInstall、不同目标、过期、时钟回退、显式取消、损坏记录、版本比较边界、同 shortVersion 不同 build、build 优先、short fallback）。
构建：`cd app && swift build --disable-sandbox` 通过；Debug 产物含恢复提示字符串。
未验证：真实 F5 安装失败后重启是否真的弹窗（需前台），以及 Sparkle 自定义驱动的极窄竞态；详见 `docs/UPDATE-FAILURE-VALIDATION.md` §12。

## 3. UI 4 分钟内存检查（S9，后台）

使用 UI 批次固定二进制 `app/.build/ui-qa/app/PKD QA fixed3.app`（SHA-256 `5efb38c5…`），不重建、不改 UI 源码：

```bash
python3 -u tools/dev/perf-scenarios.py \
  --app "app/.build/ui-qa/app/PKD QA fixed3.app" \
  --label bg-20261107-0916 --only S9 --no-activate
```

证据：`app/.build/ui-qa/evidence/perf/bg-20261107-0916/`（`result.json`、`env.json`、`notes.md`）
结果（4.0 min，2328 个 2 s 采样，118 个动作；`not-frontmost` 异常符合 `--no-activate` 预期）：

| 指标 | 值 |
|---|---|
| footprint 首次 / 末次 / 峰值 | 120.0 MB / 146.7 MB / 163.4 MB |
| footprint 前半均值 / 后半均值 | 143.1 MB / 147.3 MB |
| CPU mean / p50 / p95 / worst | 8.15% / 0.17% / 57.96% / 148.67% |
| 线程 | 7–19 |
| wakeups | 43.8 /s |
| 动作数 | 118 |

判读：数值在约 1 分钟后进入 145–156 MB 平台，末段没有再持续抬高；**4 分钟内没有观察到失控增长**。但两半均值仍有约 4 MB 差异、峰值 163 MB，且只有 4 分钟，不能推断长时无泄漏；不做 fps 结论（本机无 Instruments，CA Stalls 只是代理）。

协作说明：本机没有可消息的活动 UI Harness teammate；本报告只读取其 `docs/UI-PERFORMANCE-ACCESSIBILITY.md` 与 `tools/dev/perf-*` 固定环境，使用其 fixed3 bundle，**未修改 UI 源码或 UI 文档**。S9 结果供 UI 批次并入；若其要求前台复测，按前台验收窗口另排。UI 文档 §4 原将 S9 记为“环境阻塞/未完成”，本报告是后台条件下的补充数据，不改变其前台结论。

## 4. 静态/编译边界（UI 批次相关）

- `Package.swift` 平台 `.macOS(.v14)`；`otool -l` 实测 Debug 与 fixed3 的 `LC_BUILD_VERSION minos = 14.0`、`sdk = 14.0`。
- 全仓库未发现 `#Preview`/`@Entry`/自定义宏 API；UI 新 API 仅 `glassEffect` 等两处 `#available(macOS 26.0, *)` 守卫。
- 当前工作树（含其它批次未提交 UI/存储改动）`swift build --disable-sandbox` 与 `swift build -c release --disable-sandbox --product PKD` 均通过；本批没有改 UI 源码。最终日志：`app/.build/final-debug-build.log`、`app/.build/final-release-build.log`。
- **仍未验证**：VoiceOver 实际朗读、真实 HID 滚轮/前台滚动、macOS 14 真机运行、超过 4 分钟的内存趋势。UI 批次文档中的 K9/Space/Return、S2/S6/S7 等项目仍按其自身「未验证/环境阻塞」记录，本报告不替它宣称通过。

## 5. 可重复合成基线

```bash
./tools/build-repkg.sh
bash tools/dev/baseline-verify.sh
```

2026-11-07 复跑：**29/29 通过**，证据 `app/.build/baseline-20261107-check/`。
生成器、expected manifest、`verify.sh` 均未改（`verify.sh` SHA-256 仍为 `cab3ce73…`）。

## 6. 状态与清理

- HEAD `473ca4b`；未 commit/push/release；未安装正式 app；`/Applications/PKD.app` 仍 1.8.1（PKD `f79e22…`）。
- `updates/appcast.xml` 仍 `cc4da11…`；用户 collections/history 与测试前一致；`com.zeh.pkd` 无 `SUFeedURL`/`SUAutomaticallyUpdate`。
- 后台检查未激活任何 app 窗口、未发送真实键鼠、未切壁纸、未改 TCC；无测试进程/挂载/`PKD-extract-*` 残留。
- 保护文件：`README.md`/`VERSION`/`verify.sh` 未由本批修改；其它批次对 UI/存储文件的改动保持原样。按额外授权，本批修改了 `JobQueue.swift`、`ProcessRunner.swift`、`RepkgSession.swift`、`ExtractModels.swift`、`AppModel.init`（仅生命周期接线）并新增 `TemporaryOutputs.swift`。

## 7. 待补 / 需集成人接线

1. **前台**：成功更新路径、F1–F5 实际弹窗、F5 后下一次启动的恢复弹窗、G3 手动下载按钮点击。
2. **ProcessRunner supervisor 边界**：只保证终止自己 spawn 的直接 repkg 子进程；若未来 repkg 派生长寿 grandchildren，需要进程组清理（当前未观察到此行为）。
3. **commit 前**：`app/scripts/verify.sh` 增加合成基线步骤并失败计数、真实基线改为显式可选（不静默 skip）；发布前 `codesign --verify` + `sign_update --verify updates/appcast.xml`。
4. **UI 剩余**：VoiceOver/真滚轮/macOS 14 真机；按 UI 批次文档继续，不在本报告内伪造。

## 8. 本批新增/修改文件

- 修改：`app/Sources/PKDKit/Support/LogSink.swift`、`app/Sources/PKDApp/UpdateManager.swift`、`app/Sources/PKDKit/Engine/ProcessRunner.swift`、`app/Sources/PKDKit/Engine/RepkgSession.swift`、`app/Sources/PKDKit/Engine/ExtractModels.swift`、`app/Sources/PKDKit/Jobs/JobQueue.swift`、`app/Sources/PKDApp/AppModel.swift`（仅 init 生命周期接线）
- 新增：`app/Sources/PKDApp/UpdateRecovery.swift`、`app/Sources/PKDKit/Jobs/TemporaryOutputs.swift`、`tools/dev/fault-logsink-tests.*`、`tools/dev/fault-update-recovery-tests.*`、`tools/dev/fault-supervisor-tests.*`、`tools/dev/fault-temp-cleanup-tests.*`、`tools/dev/fault-jobqueue-temp-tests.*`、`tools/dev/fault-concurrency-tests.*`
- 更新：`docs/UPDATE-FAILURE-VALIDATION.md`、`tools/dev/fault-queue/REPORT.md`、`docs/BACKGROUND-VALIDATION-FINAL.md`
- 未改：`PKDApp.swift`、`Storage`、渲染/UI 源码、`README`、`VERSION`、`verify.sh`、`Package.swift`、生成器。


## 9. 追加：SIGKILL 生命周期、临时目录与失败文案（2026-11-07，额外授权）

### 9.1 SIGKILL 孤儿 repkg 修复

- `RealProcessRunner` 在 extract 时使用 `/bin/sh` wrapper + monitor：monitor 是 repkg 的直接父进程，50 ms 检查 wrapper 的 PPID 是否仍等于 App PID；App 被 SIGKILL 后 wrapper 仍在，monitor 发现父实例消失，只终止自己 spawn 的 repkg（TERM→KILL）。App 正常取消/退出时由 wrapper/monitor 转发信号并兜底。
- 不使用 broad pkill；monitor 只持有自己子进程的 PID，`cancelImmediately`/正常退出/SIGKILL 三种路径都不影响其它 PKD 实例或其它 app 的引擎。
- 回归：`bash tools/dev/fault-supervisor-tests.sh` → **12 项 PASS**（正常退出、取消及时、immediate cancel、父进程 SIGKILL 后引擎消失且停止写盘、并发 2、含空格/引号/`$()`/反引号的路径与参数经纯 argv 传递且 sentinel 未被创建）。证据：`app/.build/supervisor-tests-20261107-101155/run.log`。
- 真实 `probe2-close` valid/crash 与 `probe4` 取消 0.3 s 无残留；JobQueue 并发 2 完成/取消均通过。

### 9.2 临时目录安全回收

- 新增 `TemporaryOutputs`：目录只在 `temporaryDirectory/PKD-temp/` 专属 root；每 job 有 `owner.json` + `owner.lock`，进程存活期间持有 `flock(LOCK_EX)`；SIGKILL 后锁自动释放。
- janitor 只扫描该 root；拒绝 symlink/非目录/路径重定向；要求有效 owner、匹配 bundleID、非当前 instance/PID、年龄 ≥24h、lock 可获取；未知/近期/活跃/同 PID 不同 instance 一律保留；不扫描旧 `TMPDIR/PKD-extract-*`，不删真实 TMPDIR 历史数据。
- 回归：`bash tools/dev/fault-temp-cleanup-tests.sh` → **14 项 PASS**（active/recent/stale/unknown/同 PID 不同实例/root 与目录内 symlink/foreign bundle/正常 release）；`bash tools/dev/fault-jobqueue-temp-tests.sh` → **7 项 PASS**（活动 job marker/lock、取消释放、无残留）；`bash tools/dev/fault-concurrency-tests.sh` → **8 项 PASS**（2 并发正常完成 + 2 取消无残留）。证据目录：`app/.build/temp-cleanup-tests-20261107-095957/`、`app/.build/jobqueue-temp-tests-20261107-095958/`、`app/.build/concurrency-tests-20261107-095959/`。
- 磁盘预检仍只在隔离 sparse image 上安全注入（20 MiB 卷 + 稀疏大包），未填真实盘、未 chmod 用户目录。

### 9.3 非零退出文案

- `ExtractReport.failureMessage` 带退出码和分类：无法启动（126/127）、权限/只读、磁盘不足、环境不兼容、强制终止、异常终止（134/139）、未知 stderr 首行；`JobQueue` 使用该文案。
- mock engine 复验：127→“无法启动 repkg（退出码 127）”；Permission denied→权限；No space→磁盘；Library not loaded→环境；134→异常终止；不再把所有非 0 退出笼统说成包损坏。证据：`app/.build/turn4-queue-20261107-0955/{missing,perm,disk,env,corrupt}.txt`。

### 9.4 边界

- 未做真实 GUI SIGKILL（无前台）；supervisor 父进程 SIGKILL 回归使用真实 ProcessRunner/JobQueue 离屏进程，不依赖 GUI。
- repkg 若派生长寿 grandchildren，当前只保证直接子进程终止；未观察到该行为，留下进程组清理扩展点。
- 未改渲染/main.swift/StorageSafety；正常取消/完成/并发 2 已按测试回归。

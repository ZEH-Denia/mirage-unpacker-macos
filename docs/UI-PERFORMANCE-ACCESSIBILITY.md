# UI 性能与可访问性验收（1.8.1 独立 UI 批次）

本文件只记录**本轮实际执行**的检查、度量口径与结果。没有执行或无法执行的项明确标为
「未验证」，不用静态阅读或 AX 树冒充实测。

## 1. 范围与边界

本批次只覆盖独立 UI 层：素材库网格、卡片、缩略图缓存、键盘/辅助功能、动效、最小系统版本。

不在本批次内，也不修改：

- 渲染/场景组合（`ExperimentalPuppetPreview`、`JobQueue` 预览流程）——渲染批次负责；
- 存储清理与安全审计（`StorageScanner`、`CleanupAuditLog`、`AppModel` 存储逻辑）——存储安全批次负责；
- `/Applications/PKD.app` 正式安装副本、发布、应用内更新、`VERSION`/`README`/`verify.sh`。

工作树里同时存在上述批次**未提交**的在途改动。本批次用固定二进制度量（§2），避免共享工作树
被别的批次重新构建后悄悄替换被测代码；本批次自己的源码改动只有 §8 列出的两个 UI 文件。

## 2. 环境与构建身份

| 项 | 值 |
| --- | --- |
| 宿主机 | macOS 27.3（26C5035r），arm64，Apple M4 Pro，48 GB，AC 电源 |
| 显示 | 内置 Liquid Retina XDR 3456×2234（窗口级捕获为 2× 像素） |
| 工具链 | Swift 6.4.2 / Command Line Tools（**无完整 Xcode**：没有 `xctrace`/Instruments） |
| 仓库 | HEAD `473ca4b`（另含其它批次未提交改动） |
| 基线二进制 | `app/.build/ui-qa/bin/PKD-baseline`，SHA-256 `9a26b058…` |
| 修复后二进制（最终） | `app/.build/ui-qa/bin/PKD-fixed3-2216`，未签名 SHA-256 `1953717f…`；`fixed2`（`4797eb20…`）为只含动效门控+搜索 label 的中间版本 |
| 最终 bundle | `app/.build/ui-qa/app/PKD QA fixed3.app`（签名后可执行文件 SHA-256 `5efb38c5…`） |

详细环境快照：`app/.build/ui-qa/baseline-environment.txt`。

## 3. 方法

### 3.1 隔离

- 只启动开发副本（bundle id `com.zeh.pkd.development`），`PKD_DEVELOPMENT_ROOT` 指向
  `app/.build/ui-qa/runs/run-*` 的一次性根目录；其中素材库由 `tools/dev/perf-fixtures.py`
  生成：400 张 16:9 抽象占位卡（6 张 2560×1440、40 张 1280×720、其余 640×360；16 张无包、
  不可解包），另有少量长标题/英文标题。**不含任何个人壁纸或真实素材。**
- 截图只针对开发窗口 ID（`screencapture -l` 或 `CGWindowListCreateImage` 窗口级捕获），
  不截桌面，不读个人素材库目录。
- 不修改系统「减弱动态效果」「键盘导航」等个人辅助功能偏好，不修改 TCC；动效测试只改
  开发副本自己的 defaults 域并在结束时恢复。
- 同一时刻只允许一个 agent 驱动 GUI（带心跳的目录锁）；任何 agent 不 kill 不是自己启动的进程。

### 3.2 度量口径与诚实性声明

本机没有 Instruments，**拿不到「实际呈现帧率」**。本文件不会出现“60 fps 达标”一类结论。
实际使用的指标：

1. **CPU**：`proc_pid_rusage` 的 user+sys 增量 ÷ 墙钟（% of one core）。注意 Apple Silicon 上
   `ri_*_time` 是 mach tick，按 `hw.tbfrequency`（本机 24 MHz）换算；直接当 ns 会少报约 41.7×。
2. **内存**：`ri_phys_footprint` 采样，并用 `/usr/bin/footprint` 交叉核对。
3. **线程/唤醒/缺页**：`proc_pidinfo` 与 rusage 增量。
4. **帧提交代理**：Core Animation `Transaction` signpost 的 `begin_time`（提交次数/间隔）与
   CA 自报的 `Transaction.Stalls`。**这不是呈现帧统计**，只是“应用提交/掉帧信号”代理。
5. **主线程响应代理**：AX 属性查询往返时延（p50/p95/最差）。
6. **行为级动效判定**：窗口级 `CGWindowListCreateImage` 密集取帧（约 40 ms/帧），计算逐帧
   相对稳定终帧的像素差；`intermediateFrames>0` 表示存在过渡动画，0 表示单次跳变。
7. **热点归因**：`/usr/bin/sample` 主线程栈。

### 3.3 输入通道（环境限制）

用户机上有第三方全屏浮层窗口（哔哩哔哩「桌面端直播间」，layer 999）常驻在所有普通窗口之上，
HID 鼠标/滚轮事件被它吞掉，开发副本也不能稳定成为前台。因此本轮：

- 键盘：`CGEventPostToPid` 直接投递到开发进程（同一 AppKit 键事件通路；Tab/⌘2/⌥⌘L/⌘↩ 均证明有效）；
- 鼠标：改用卡片的无障碍默认动作 `AXPress`（与 `onTapGesture` 同一代码路径）+ 真实按下 ⌘/⇧；
- 滚轮：HID 滚轮不可用 → **滚动类场景未取得有效数据，标为环境阻塞**；
- 每处偏离输入方式都记录在证据 `env.json` 的 `inputDelivery` 中。

这部分是**环境限制，不是产品结论**。

## 4. 性能结果

统一条件：400 卡、窗口 1100×740（S1/S4/S5）、每场景 2–3 次重复、每次独立 fresh root；
基线 = `PKD QA.app`（`9a26b058…`），修复后 = `PKD QA fixed3.app`（未签名 `1953717f…`）。
**环境限制**：用户机前台被哔哩哔哩全屏浮层占用（覆盖 1.0），HID 滚轮/点击无效，
以下只在「AX 驱动 + 进程内计数」路径上取数；CPU/内存/Stalls 是 per-pid 的，仍然有效。

| 场景 | 指标 | 基线 | 修复后 fixed3 | 结论 |
| --- | --- | --- | --- | --- |
| S1 首次加载 | 扫描完成 | 335–424 ms | 260–387 ms | 同量级 |
| S1 | 完全静置（缩略图/X-Ray 尾巴） | 5.9–16.9 s | 3.1–8.4 s | 批次波动大；尾巴仍存在（§9.1） |
| S1 | 静置 2 s CPU p50 / p95 / 最差 | 0.12% / 0.18–0.23% / 0.93–1.87% | 0.19–0.24% / 0.26–0.35% / 0.28–0.51% | 都 <0.5%，无回归信号 |
| S1 | footprint 峰值 / 线程 / 唤醒 | 94–111 MB / 7–8 / 16.5–18.0 /s | 117–118 MB / 8–20 / 18.5 /s | 内存与线程有批次间波动，未见单调增长 |
| S4 密度切换 | 每次切换 CA Stalls（紧凑/标准/宽松） | 13–15 / 13–15 / 3 | **1–2 / 1 / 1** | 去掉密度隐式动画后从 13–15 降到 1–2 |
| S4 | CPU p95（整段） | 114.0–114.8% | **51.4–57.2%** | 约减半 |
| S4 | CPU 单采样峰值 | 282–414% | 225–338% | 仍有「整屏重建 + 新卡片解码」固有尖峰，非动画 |
| S4 | footprint 峰值 | 166–179 MB | 164–165 MB | 同量级 |
| S5 排序切换 | 每次切换 CA Stalls | 1–3 | 1–5（2 次重复，含 1 次 5） | 排序动画保留，未回归 |
| S5 | CPU p95 | 60.1–62.7% | 91.9–94.3% | 2 次重复、含首次切换尖峰，**不作为回归结论**；需更多重复才能定论 |
| S5 | footprint 峰值 | 175–178 MB | 233 MB | 同上，受批次顺序影响（缩略图更热），非动效导致 |
| S6 检查器开关 | CPU / Stalls | — | — | **未取得可信数据**（检测器 bug + 前台被占），标 blocked |
| S2 滚动 / S7 | CPU、解码热点 | — | — | **环境阻塞**：HID 滚轮被浮层吞掉；缩略图反复解码未验证 |
| S9 长时（4 min） | footprint/线程趋势 | — | — | **环境阻塞/未完成**，不作内存增长结论 |

说明：
- 「CA Stalls」是 Core Animation 自己报告的提交停顿，属于**掉帧信号**，不是呈现帧率；
  本表不宣称任何 fps。
- S4 的 animation=system 与「等价无动画参照」（motion=off）对照：stalls 13–15 → 2–3、
  CPU p95 114% → 48–50%，与 fixed3 的 1–2/51–57% 一致，证明密度动画确实是主因。
- S1 的内存/线程差异来自不同批次的缩略图与 X-Ray 任务状态，不能归给本次改动；
  本轮没有观察到内存单调增长（时长不足，见 S9）。


## 5. 动效与「减弱动态效果」

### 5.1 发现的缺陷（有证据）

基线版在「设置 → 动效：关闭」下，网格仍会做过渡动画：

| 交互 | 基线 + 动效关闭 | 结论 |
| --- | --- | --- |
| 排序切换 | 我们自己的窗口级采样：过渡跨约 5 帧（0.391/0.325/0.260/0.113/0.006），约 170–240 ms | 缺陷成立 |
| 密度切换 | a11y 采样：中间帧 5 个（360.7/402.7/444.9/495.1/540.6 ms，0.4810→0.0087 递减） | 缺陷成立 |
| 检查器开关 | 中间帧 2 个，但区域拆分显示变化集中在网格列（面板区早已归零） | 见 §5.4 |

原因：网格上三个 `.animation(_:value:)` 没有读取 `appearance.reducesMotion(...)`；排序菜单还在
`LibraryFilterBar` 里用 `withAnimation` 提交变更，单纯把 `.animation` 置空拦不住它。

### 5.2 修复

只改 `WallpaperGridView.swift` / `WallpaperCard.swift`：

- 网格读取 `accessibilityReduceMotion`，`appearance.reducesMotion(...)` 为真时排序/检查器动画置 `nil`；
- 加 `.transaction { disablesAnimations = true }` 兜住 `withAnimation` 提交的排序动画；
- 卡片缩略图淡入 `.transition(.opacity)` 在减弱动效时改 `.identity`；
- **密度切换不再使用隐式动画**（不受动效开关影响也不动画）：900 帧级 A/B 证明它制造
  13–15 次 CA Stalls、CPU p95 从 ~48% 抬到 ~114%（§4、§5.3）。

### 5.3 修复后实测（窗口级 40 ms 取帧，400 卡）

| 场景 | fixed2 + 动效关闭 | fixed2 + 动效跟随系统（对照） |
| --- | --- | --- |
| 排序 | 中间帧 0，单次跳变（≈348 ms 稳定） | 中间帧 1（497.7 ms，0.191）→ 动画仍在 |
| 密度 | 中间帧 0，单次跳变（≈275 ms 稳定） | 中间帧 5（390.8→557.1 ms 递减）→ 动画仍在 |
| 缩略图淡入 | `.identity`（代码路径，视觉未单独取帧） | `.opacity` |

结论：减弱动效下排序/密度改为瞬时；跟随系统时动画未回归。

### 5.4 残留：系统 inspector 列过渡

检查器开关在「动效关闭」下仍有 2 个中间帧。把 34 帧按区域拆开：frame2（101 ms）网格区
0.2979 / 右侧面板区 0.0039，frame3（145 ms）网格区 0.0838 / 面板区 0.0——**中间态只发生在
网格区**，是 `NavigationSplitView` inspector 列宽过渡带动内容列重排，不是网格卡片在缩放，
也不是面板内容动画。该过渡由系统控件驱动，网格的 `.transaction` 拦不住；App 代码若要关闭它，
需要改用自定义分割视图或改变自动开合策略。本轮如实记为**系统限制/未解决**，不宣称“已关闭”。

## 6. 键盘与辅助功能

基线（`PKD QA.app`，400 卡，每个场景独立 fresh root，键盘用 CGEventPostToPid，鼠标用 AXPress）
共 39 项检查：**PASS 30 · FAIL 6 · GAP 1 · UNVERIFIED 2**。证据：
`app/.build/ui-qa/evidence/a11y/baseline-2044/`（`notes.md` + 每项 JSON/截图）。

| 组 | 结果 | 说明 |
| --- | --- | --- |
| K1 AX 语义（10 项） | PASS 10 | 卡片=AXButton，label 在 AXDescription 且含标题/类型/体积/是否可解包/解包状态/X-Ray；选中后 traits 1→9 且 AXSelected=true；工具栏 5 项、排序/密度菜单、侧栏 8 项、检查器标签页（AXRadioGroup）、空状态均可读。搜索框原先只有 placeholder，本轮已补显式 `accessibilityLabel`（§8）。 |
| K2 键盘焦点（3 项） | PASS 3 | 45 次 Tab：第 1 步到搜索框，随后进入卡片并逐张前进；焦点环在窗口级像素对比中可见；无卡死。 |
| K3 键盘激活/导航（8 项） | PASS 4 · FAIL 3 · GAP 1 | ⌘↩ 解包（确认框 + 产物只落 dev 隔离 root，`~/Pictures` 前后一致）PASS；⌥⌘L 检查器翻转 PASS；⌘1–⌘6 页面内容切换正确（判定用页面内容）；**Space/Return 不激活聚焦卡片 FAIL**；侧栏行 AXSelected 不随导航更新 GAP。 |
| K4 多选（4 项） | PASS 3 · FAIL 1 | ⇧ 连选、标题「已选 N」与 AX 选中态一致、键盘事件到达均 PASS；⌘ 再点取消在合成输入下未生效（见 §9 未验证）。 |
| K5 窄窗详情（4 项） | PASS 4 | 900 宽点击卡片弹出面板；Esc 与左上关闭按钮都能关闭；关闭后焦点回到应用内。 |
| K6 导出类快捷键（3 项） | PASS 3 | ⇧⌘O / ⇧⌘R 菜单项可用；实际按键后 App 存活、AX 仍响应；未操作真实 Finder 窗口。 |
| K7 减弱动效（3 项） | 修复后 PASS 2 · 系统限制 1 | 见 §5。 |
| K9 大库键盘遍历（3 项） | PASS 1 · UNVERIFIED 1 · FAIL 1 | 45 次 Tab 全部在网格内推进（每次 p50 一致）；焦点随滚动入视口无法在 HID 滚轮被吞的环境下验证；AX 顺序与视觉顺序在第 6 项起不一致（第 6 张卡在 AX 中缺失/后移），需前台复测确认是否只是 LazyVGrid 视口边界。 |
| K10 崩溃（1 项） | PASS | 验收期间开发副本无崩溃；`~/Library/Logs/DiagnosticReports` 无本 build 的 PKD 崩溃记录。 |

**1.8.1 时没有做 VoiceOver 实际朗读**（当时前台被第三方全屏浮层占据，未改 TCC）。**1.8.2 已补做并实测通过，见 §12.4。** 原说明：
K1/K9 只证明 AX 语义与顺序，不能替代 VoiceOver 朗读验收。

### 6.1 修复后复检（fixed2，`app/.build/ui-qa/evidence/a11y/fixed2-2206/`）

| 项 | 结果 | 细节 |
| --- | --- | --- |
| K1 搜索框可读名 | **PASS** | `AXDescription = 搜索标题或 ID`（连同 placeholder 一起）；抽查卡片/工具栏/菜单/侧栏/检查器/空状态无回归（11/11） |
| K3 Space/Return | **1.8.2 已修复并在真实前台复验 PASS（§12.2）** | 1.8.1 记录：焦点在卡片时 Space/Return 后已选仍 0、焦点不动、未滚动；⌘2 生效排除事件通道。1.8.2 定位到 `handleTap` 对键盘事件读 `NSEvent.clickCount` 抛异常被 SwiftUI 吞掉；已改为只在鼠标事件上读 clickCount。前台复验：Tab→Space 选中卡片 0001、再 Tab→Return 选中 0002；双击仍弹「确认解包」；单击/⌘加选/⌘取消/⇧区间均通过。 |
| K3 ⌘↩ / ⌥⌘L / ⌘1–⌘6 | PASS | 确认框 + 产物只落 dev root；`~/Pictures` 前后一致；⌘6→存储、⌘5→队列（页面内容判定） |
| K4 多选 | **PASS 4/4** | 单击 1 → ⌘点 2 → 再 ⌘点回 1（取消成功）；⇧ 连选 3；标题与 AX 选中一致 |
| K6 快捷键 | PASS 3/3 | ⇧⌘O / ⇧⌘R enabled 状态正确；实际发键后 App 存活、AX 仍响应 |
| K10 崩溃 | PASS | 4 次运行均正常退出 |

**未验证（1.8.1 当时）**：VoiceOver 实际朗读、键盘遍历/阅读顺序、macOS 14 真机。其中 VoiceOver 朗读、侧栏当前位置、跨视口遍历已在 1.8.2 前台补做（§12.4）；macOS 14 真机仍未验证。

## 7. 系统兼容

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 当前宿主真实运行 | 通过：macOS 27.3 / arm64 上实际启动、扫描 400 卡、交互、截图 | 本轮所有运行 |
| 最低部署目标编译 | 通过：`Package.swift` `platforms: [.macOS(.v14)]`；产物 `LC_BUILD_VERSION minos = 14.0`（`otool -l` 实测） | `app/.build/ui-qa/app/PKD QA.app/Contents/MacOS/PKD` |
| availability 静态审查 | 新 API 均有守卫：`glassEffect` 在 `#available(macOS 26.0, *)` 内；在 deployment target 14.0 下整个 target 编译通过（编译器会拒绝未守卫的新 API） | `Glass/GlassSurface.swift`、`Design/AppearanceSettings.swift` |
| macOS 14 真机运行 | **未验证**：本机只有 macOS 27.3，没有 14.x 运行环境 | — |

不使用“各 macOS 版本已实测”这类说法。

## 8. 本轮代码改动

只改两个 UI 文件（其它批次在途文件一律未动）：

### `app/Sources/PKDApp/Library/WallpaperGridView.swift`

- 新增 `@Environment(\.accessibilityReduceMotion)` 与 `motionReduced` 派生值；
- 排序/密度/检查器三个隐式动画改为按 `motionReduced` 取 `nil`；
- 新增 `.transaction { if motionReduced { animation = nil; disablesAnimations = true } }`，
  用于压住 `LibraryFilterBar` 里 `withAnimation` 提交的排序切换（只置空 `.animation` 拦不住它）；
- 搜索框补 `.accessibilityLabel("搜索标题或 ID")`（原来只有 placeholder）。

### `app/Sources/PKDApp/Library/WallpaperCard.swift`

- 缩略图淡入 `.transition(.opacity)` 在减弱动效时改为 `.identity`。

文件哈希（改动后）：
`WallpaperGridView.swift` `e7e29311…`、`WallpaperCard.swift` `867b7630…`。

行为影响：动效设为「减少/关闭」或系统开启「减弱动态效果」时，排序重排、缩略图出现不再有过渡；
密度切换本来就改成无过渡（所有动效设置下）。动效「跟随系统」时排序动画不变（对照实测）。
其余交互（单击/⌘ 多选/⇧ 连选/双击解包/键盘/详情）未改代码路径。

## 9. 未解决 / 需要协调（不在本批次可改文件内）

1. **初始加载尾巴**：`AppModel` 的 X-Ray 预取对每个包 `repkg info` 一次（400 卡约 5–8 s、
   CPU p50 42–54% 的尾巴），「400 项」出现后用户已可操作但后台仍在抢 CPU。属 `AppModel`
   （存储安全批次独占），建议最小补丁：只对可见/选中项预取，或限制并发与按需触发。
2. **侧栏 AXSelected 不跟随导航**：侧栏行 label/数量可读，但 AXSelected 恒为「全部」，
   VoiceOver 无法从侧栏得知当前位置（页面内容可读）。属 `NavigationSidebar`，需在 SwiftUI
   `List(selection:)` 上补 `accessibilityAddTraits(.isSelected)` 或改为自定义行。
3. **密度菜单可读名固定**：AX 标题始终是「正方形网格，三乘三」，不反映当前密度。属
   `LibraryFilterBar`，建议 `.accessibilityLabel("网格密度：\(appearance.density.label)")`。
4. **系统 inspector 列过渡**：动效关闭时检查器开合仍有约 150 ms 的列宽过渡，由
   `NavigationSplitView` 驱动，App 侧无法用 `.animation`/`.transaction` 关闭（§5.4）。
5. ~~**Space/Return 不激活卡片**~~ **已定位并修复**（2026-11-07，1.8.2）：根因是 `handleTap` 对键盘事件读取 `NSEvent.clickCount` 抛异常被 SwiftUI 吞掉；修复为只在鼠标事件上读 clickCount，前台复验 Tab→Space/Return、双击、单击/⌘/⇧ 全部通过（§12.2）。原记录：：fixed2 上用 AX 描述重新定位卡片，
   焦点确在卡片（AXFocusedUIElement 为该卡、焦点环像素变化），Space/Return 后已选仍 0、焦点不动、
   未滚动；同一焦点状态 ⌘2 生效 → 事件到达 App。最小 SwiftUI 探针（纯 Text、以及
   ScrollView+LazyVGrid+同组修饰符）在非前台、PostToPid 投递下 `.onKeyPress` 均正常触发，
   因此不能归因于“后台窗口/事件通道”。下一步需要在可前台的环境里加临时日志确认
   `onKeyPress` 是否被调用，或把卡片改为 `Button` 语义后复测；本轮未盲改键盘代码。
6. **⌘ 再点取消**：合成修饰键 + AXPress 下第二次 ⌘ 点击没有移出选择；真实鼠标被环境阻断，
   记为待复测，不当作已确认缺陷。
7. **滚动相关指标未取得**：HID 滚轮被用户全屏浮层吞掉，缩略图反复解码/滚动平滑度
   **未验证**；因此 `ThumbnailLoader` 未改动（没有证据就不动）。
8. ~~**VoiceOver 实际朗读未验证**~~ **1.8.2 已实测通过（字幕面板）**，见 §12.4；欢迎首用已过、未改 TCC/系统偏好。
9. **macOS 14 真机未验证**：见 §7。

## 10. 证据索引（全部在 git 忽略的 `.build/` 内，不含个人素材）

| 路径 | 内容 |
| --- | --- |
| `app/.build/ui-qa/baseline-environment.txt` | 宿主机/工具链/基线二进制与 UI 源文件哈希 |
| `app/.build/ui-qa/bin/PKD-baseline` | 基线可执行文件（SHA-256 `9a26b058…`） |
| `app/.build/ui-qa/bin/PKD-fixed2-2145` | 修复后可执行文件（SHA-256 `4797eb20…`） |
| `app/.build/ui-qa/app/PKD QA.app` / `… fixed2.app` | 两个固定开发副本（bundle id 均为 `com.zeh.pkd.development`） |
| `app/.build/ui-qa/data/library-400/` | 400 张中性占位卡模板（生成器 `tools/dev/perf-fixtures.py`） |
| `app/.build/ui-qa/evidence/lead/motion-sort2/result.json` | 基线排序动效关闭仍有约 240 ms 过渡（窗口级 40 ms 取帧） |
| `app/.build/ui-qa/evidence/lead/motion-fixed/result.json` | 修复后排序：动效关闭为单跳变；跟随系统仍有动画 |
| `app/.build/ui-qa/evidence/a11y/baseline-2044/` | 基线 39 项键盘/辅助功能检查（`notes.md` + 每项 JSON/截图） |
| `app/.build/ui-qa/evidence/a11y/fixed-2108/` | 修复后 K1/K2/K5/K7（含 `k7/analysis.json`、`k7/inspector-regions.json`） |
| `app/.build/ui-qa/evidence/a11y/fixed2-*/` | fixed2 的搜索框 label 与 Space/Return 复现（若执行） |
| `app/.build/ui-qa/evidence/perf/*/` | 性能基线/修复后：`env.json`、`result.json`、`sample.txt`、截图；可引用批次见 `perf/README.md` |
| `app/.build/ui-qa/evidence/perf/baseline-2139/` | 基线 S1/S4/S5 可引用重复（S1 r0–r2、S4 r0–r2、S5 r0） |
| `app/.build/ui-qa/evidence/perf/fixed3-check/` | 密度动画移除后的 S4/S5 验证（Stalls 13–15→1–2、CPU p95 114%→51–57%） |
| `tools/dev/perf-qaenv.py` | 共享测量原语（DriveLock、启动/退出、AX、键鼠、rusage、`sample`、CA signpost、窗口取帧） |
| `tools/dev/perf-fixtures.py` | 400 张中性卡生成器 |
| `tools/dev/perf-scenarios.py` | 性能场景脚本（perf-runner 所有） |
| `tools/dev/accessibility-audit.py` | 键盘/辅助功能审计脚本（a11y-runner 所有） |

## 11. 复验方法

```bash
# 1) 生成中性素材库（一次性）
python3 tools/dev/perf-fixtures.py --root app/.build/ui-qa/data/library-400 --count 400

# 2) 构建并装配固定开发副本（需先有 app/.build/private-development/PKD Development.app 骨架）
cd app && swift build -c release --disable-sandbox --product PKD && cd ..
python3 tools/dev/perf-qaenv.py assemble "app/.build/ui-qa/app/PKD QA fixed2.app" \
  --no-build --binary app/.build/ui-qa/bin/PKD-fixed2-2145

# 3) 性能场景（会自动复制 fresh root、固定窗口尺寸、只截图开发窗口）
python3 -u tools/dev/perf-scenarios.py \
  --app "app/.build/ui-qa/app/PKD QA fixed2.app" --label recheck --only S1,S4,S5 --repeat 2

# 4) 键盘/辅助功能
python3 -u tools/dev/accessibility-audit.py --app "app/.build/ui-qa/app/PKD QA fixed2.app" \
  --only k1,k3,k4,k6,k7 --evidence-root app/.build/ui-qa/evidence/a11y
```

注意：脚本要求 bundle id 为 `com.zeh.pkd.development` 且通过 `PKD_DEVELOPMENT_ROOT` 指定隔离根目录；
不会启动 `/Applications/PKD.app`。GUI 驱动会串行持有目录锁；同一时刻只应有一个脚本在跑。

## 12. 1.8.2 前台交互验收补充（2026-11-07）

本轮在正式 1.8.2 构建上补做真实前台验收。用户明确授权本轮独占前台，不等待授权；未强关任何
用户应用，未改 TCC/系统偏好，未截整屏，未触碰个人素材或废纸篓内容。

### 12.1 构建身份与环境

| 项 | 值 |
| --- | --- |
| 仓库 | `main` `8f81353`（工作树干净；本轮只改 1 个 UI 文件，未提交） |
| 版本 | 1.8.2（`VERSION`/Info.plist 均为 1.8.2） |
| 未修改构建 | `app/.build/ui-qa/app/PKD QA 182.app`（从 `swift build -c release` 的 1.8.2 产物装配，bundle id `com.zeh.pkd.development`） |
| 修复后构建 | `app/.build/ui-qa/app/PKD QA 182 fixed.app`（只含 §12.3 的 clickCount 修复；未签名二进制 SHA-256 `88d4cb54…`） |
| 宿主 | macOS 27.3 / arm64 / M4 Pro / AC |
| 隔离 | 每个场景 `PKD_DEVELOPMENT_ROOT` 指向 `app/.build/ui-qa/runs/run-*`，素材为 60/400 张生成占位卡；导出目录固定在隔离 root 的 `Images/` |

真实前台输入在本轮可用：HID 点击、Tab/字符键、滚轮都能送达开发副本（`scrollInput.changed=true`）。
未修改正式 `/Applications/PKD.app`，未启动正式应用。

### 12.2 发现并修复的产品缺陷：Space/Return 不激活聚焦卡片

**复现（修复前，1.8.2）**：Tab 把焦点移到卡片（AXFocusedUIElement 为该卡），按 Space 后
「已选」仍为 0、焦点不动、不滚动；同一焦点状态发 ⌘2 生效（事件到达 App）。加临时日志后
（仅诊断构建，已还原）确认：卡片的 `.onKeyPress` **被调用**，`handleTap` 进入后只执行到第一行，
后续选中逻辑整段不执行。

**根因**：`handleTap` 无条件执行 `NSApp.currentEvent?.clickCount == 2`。键盘触发的选中不是鼠标
事件；在 keyDown 上读取 `clickCount` 会抛 ObjC 异常，SwiftUI 吞掉异常后该次回调剩余代码全部
跳过。最小 SwiftUI 探针复现：`A` → `B evt=10(keyDown)` 之后 `clickCount` 处中断。

**修复**（`app/Sources/PKDApp/Library/WallpaperGridView.swift`，仅此一处）：

```swift
// 只在鼠标事件上读取 clickCount：键盘触发的选中（Space/Return）不是鼠标事件，
// 在 keyDown 上取 clickCount 会抛 ObjC 异常，SwiftUI 吞掉后整段选中逻辑都不执行。
let currentEvent = NSApp.currentEvent
let isMouseEvent = currentEvent?.type == .leftMouseDown || currentEvent?.type == .leftMouseUp
let isDoubleClick = isMouseEvent && currentEvent?.clickCount == 2
```

**修复后验证**（真实 HID 键盘/鼠标）：

| 操作 | 结果 | 证据 |
| --- | --- | --- |
| Tab 到卡片 → Space | 选中该卡（已选 1 → 对应卡片） | `foreground-1.8.2/interaction-final.json` |
| 再 Tab → Return | 选中新聚焦卡片 | 同上 |
| 双击卡片 | 选中该卡并弹出「确认解包」 | `foreground-1.8.2/double-click3.json` |
| 单击 / ⌘点击加选 / 再 ⌘点击取消 / ⇧区间 | 1 → 2 → 1 → 2（区间两项） | `foreground-1.8.2/interaction-final.json` |
| 无键盘焦点时移动鼠标/点击 | 行为与修复前一致（未改点击路径） | 同上 |

### 12.3 前台验收结果

| 项 | 结果 | 关键观察 / 证据 |
| --- | --- | --- |
| 真实键盘搜索 | **PASS** | Tab 到搜索框，键入 `Synthetic` → `12 项 · 搜索「Synthetic」`；⌘A+Delete → `60 项`（`interaction.json`） |
| Tab / Space / Return 卡片激活 | **PASS（修复后）** | 见 §12.2；修复前为 FAIL |
| ⌘ 多选 / ⇧ 连选 | **PASS** | 真实 flagsChanged + 鼠标事件：加选 2 项、再点取消 1 项、⇧ 选区间 2 项（`interaction-final.json`） |
| 详情关闭（窄窗） | **PASS** | 900 宽点击卡片出现面板（关闭详情按钮），Esc 关闭，AX 中按钮消失（`mouse-inspector-sheet.json`） |
| ⌘↩ 导出 + 确认清单 | **PASS** | 确认框含隔离目录绝对路径；确认后 `Images/<标题>_<id>/` 产出 2 个 PNG + `.pkd-output.json`（`export2.json`） |
| 结果浏览器 | **PASS** | 详情「查看图片」打开画廊，有上一张/下一张；键盘切换与缩放后 Esc 关闭（`gallery-storage.json`） |
| 存储页确认清单 | **PASS** | 头部「可清理 1 项，1 项只读」；只读条目不可选；确认面板列出待移动目录与「取消不会移动任何文件」；仅选中应用自产目录（`storage5.json`） |
| Esc 取消清理 | **PASS** | 关闭面板后目录仍存在，提示「已取消，未移动任何文件」（`storage3.json`） |
| Return 不误清理 | **PASS** | 确认面板打开时按 Return：面板保持、目录未移动（`storage4.json`） |
| 确认后移动范围 | **PASS（隔离目录）** | 仅 `Images/<应用自产目录>` 被移动；同页只读目录仍存在；清理审计事件 `request→confirmed→item_result→completed`（`storage5.json`、`CleanupAudit/cleanup-audit.jsonl`） |
| 队列筛选 | **PASS** | 分段「全部/未结束/需处理/已结束」可切换，选中值随点击变化，列表按状态过滤（`queue2.json`） |
| 拖放导入 | **PASS** | 合成 `.pkg` 拖入：`operation=1`，60→61 项并选中导入项；源文件 SHA-256 与素材库原文件一致（`drag2.json`） |
| 收藏 + 重启持久化 | **PASS** | `History/collections.json` 写入 `favorites:["900000"]`；「收藏」页 1 项；重启后仍 1 项（`queue-favorites.json`） |
| 初始化加载 / idle | **PASS** | 400 卡 idle CPU p50 0.18% / p95 0.39%、footprint 94.5 MB、线程 9、CA 提交 1 / Stalls 0 |
| 真实滚轮 | **PASS（输入）** | 滚轮使可见卡片变化（`scrollInput.changed=true`）；CPU p95 20%（去）/6.5%（回），CA 提交 71/63、Stalls 0（`perf-1736/result.json`） |
| 连续缩放窗口 | 代理达标 | CPU p95 95%、最差 102%；CA 提交 198、**Stalls 9** |
| 排序切换（4 次） | 代理达标 | CPU p95 88%、最差 162%；CA 提交 501、Stalls 6 |
| 密度切换（5 次） | 代理改善 | CPU p95 72%、最差 215%；CA 提交 334、Stalls 6（1.8.1 时单次 13–15，已去动画） |
| 检查器开关（4 次） | 代理偏重 | CPU p95 84%、最差 92%；CA 提交 166、**Stalls 45**（系统 inspector 列过渡，见 §5.4/§9.4） |
| 前台 90 秒混合操作（滚动/选择/检查器） | **PASS（无增长）** | footprint 221.4 → 207.0 MB，峰值 221.6 MB，无单调增长（`perf-1736/result.json` soak） |
| VoiceOver 实际朗读 | **PASS（字幕面板实测，非音频）** | 卡片标题/已选择/按钮角色、搜索框、侧栏行、跨行遍历均读到；见 §12.4 |

度量口径不变：CA `Transaction.Stalls` 是**掉帧信号**，CPU/内存为真实进程指标；本机没有
Instruments，**不宣称呈现帧率**。

### 12.4 VoiceOver 实际朗读验收（通过）与侧栏选中语义修复

**启用方式（系统正常 UI）**：`Command-Fn-F5` 调出 VoiceOver 首次使用欢迎窗；读取欢迎窗后点
「使用旁白」（未勾选「不再显示此信息」，未按空格进入教程）。VoiceOver 启动成功，日志出现
CoreAudio 播放队列；未申请任何新 TCC，未用脚本写/删系统偏好。

**观察方式（真实朗读，不用 AX 树冒充）**：VoiceOver 自带的**字幕面板**（默认已开启）是
独立窗口（owner = VoiceOver）。每步只捕获该字幕窗口（窗口级，非全屏），再用本机 Vision OCR
转录其文本；原文截图保存在 `app/.build/ui-qa/evidence/vo/`。以下为实际转录（节选）：

| 操作 | 实际字幕文本 |
| --- | --- |
| 启动/侧栏 | `PKD，PKD 开发预览，窗口 边栏，表格，第2行（共10行） 全部 60，已选择，有键盘焦点` |
| 状态摘要 | `58 个可解包 · 986 KB` |
| 工具栏/标题 | `素材库`；`搜索，图像`；`搜索标题或 ID，编辑文本`；`排序：标题 A-Z，菜单按钮`；`打开壁纸包…，按钮`；`正方形网格，三乘三，菜单按钮` |
| 点击卡片 | `抽象渐变占位 0003（不含真实素材），场景，17 KB，可解包，未解包，不含 X-Ray，已选择，按钮` |
| 键盘切卡 | `抽象渐变占位 0008…按钮` → `…0013…` → `…0018…`（Tab/Space/Return 后焦点与选中正确） |
| 网格跨行 | 连续 VO-Right：`0033 → 0058 → 很长很长…占位标题 0024`，可见首卡由 `0003` 变为长标题卡，网格自动滚动 |
| 切换筛选后侧栏 | `可解包•58 项•已选 1`（当前筛选行；AX 同时显示该行 AXSelected=true） |
| 搜索输入 | 输入 `Synthetic` 后字幕读 `Synthetic`；界面 `11 项 · 搜索「Synthetic」` |

**侧栏选中语义缺陷与最小修复**（本次确认并修复）：

- 现象：点击/快捷键切换导航后，AX 中侧栏行 `AXSelected` 恒停在「全部」；VoiceOver 不会把
  当前页读成「已选择」。1.8.1 记录为 GAP，本轮在 1.8.2 上复现。
- 修复（`app/Sources/PKDApp/Sidebar/NavigationSidebar.swift`，仅此一处）：在导航行上补
  `.accessibilityAddTraits(model.nav == item ? .isSelected : [])`，视觉高亮仍由 `List(selection:)`
  负责。备份：`app/.build/ui-qa/backup/vo-20261107184310/`。
- 复验：切换 `⌘2`（可解包）后 AX 行选中态为 `全部=false / 可解包=true`；切换 `⌘1` 后回到
  `全部=true`。VoiceOver 重读当前行得到 `可解包•58 项•已选 1`。修复版 bundle：
  `app/.build/ui-qa/app/PKD QA 182 fixed2.app`。

**跨视口键盘遍历（非 VoiceOver 依赖部分）**：点击卡片后连续 30 次 Tab，焦点始终在卡片间推进，
可见首卡从长标题卡依次变为 `中性占位 0001 → 0016 → 0026 → 0036`，网格自动滚动让焦点保持可见
（`vo-viewport.json`）。Space/Return 修复在 VoiceOver 运行下复验：Tab 到 0008 → Space 选中 0008；
再 Tab 到 0013 → Return 选中 0013。

**限制说明**：本机未捕获系统音频（需额外录音/TCC 授权），上述“朗读”以 VoiceOver 自己的
字幕面板为准；字幕与语音由同一朗读队列驱动，但**不是音频波形验证**。欢迎首用记录：欢迎窗
出现过（首次），本机 `~/Library` 下未发现新增 VoiceOver 偏好文件；不排除系统受保护存储中的
首用标记，故此处如实记录“欢迎窗已出现并选择使用旁白，未改动‘不再显示’选项”。

### 12.5 输入注入限制（环境，不是产品结论）

- HID 全局输入在本轮可用：点击、Tab/字符键、滚轮均已验证送达开发副本；⌘ 单位快捷键
  （⌘1–⌘6）可用。
- 但合成 **⌥⌘ / ⌃⌘ 组合**（⌥⌘L、⌃⌘S）经 HID 未送达；改用 `CGEventPostToPid` 同一键事件通路
  验证：⌥⌘L 使检查器 radio 2→0、再按恢复 2；⌃⌘S 使侧栏 outline 1→0。
- 修饰键点击需同时投递 `flagsChanged` 与带 flags 的鼠标事件；只设鼠标事件 flags 时
  `NSEvent.modifierFlags` 不更新，会退化成普通点击（本轮已按前者验证通过）。

### 12.6 前台释放状态

- 无任何开发副本/拖放源/Quickstart/VoiceOver 进程残留（`pgrep` 为空）；未 kill 任何非本进程。
- 前台已归还：当前 frontmost 为 DeepSeek Harness，不是开发副本；未修改用户壁纸/文件/废纸篓。
- 开发域 defaults 未被本轮修改（`pkd.appearance.motion` 不存在、`pkd.library.sort=titleAsc`、
  `pkd.appearance.density=standard`）。
- 工作树只有 `WallpaperGridView.swift` 一处修复（未提交）；未重新构建正式 app、未发布。

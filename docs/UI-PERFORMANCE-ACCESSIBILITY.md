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

**没有做 VoiceOver 实际朗读**：不擅自修改 TCC/系统辅助功能偏好，且本机前台被第三方全屏浮层占据；
K1/K9 只证明 AX 语义与顺序，不能替代 VoiceOver 朗读验收。

### 6.1 修复后复检（fixed2，`app/.build/ui-qa/evidence/a11y/fixed2-2206/`）

| 项 | 结果 | 细节 |
| --- | --- | --- |
| K1 搜索框可读名 | **PASS** | `AXDescription = 搜索标题或 ID`（连同 placeholder 一起）；抽查卡片/工具栏/菜单/侧栏/检查器/空状态无回归（11/11） |
| K3 Space/Return | **FAIL（复现，非投递问题）** | 焦点确在卡片（AXFocusedUIElement 就是该卡，焦点环像素有变化）；Space 后已选仍 0、焦点不动、未滚动、检查器未开；Return 同样；**同一焦点状态发 ⌘2 → 页面切到「可解包 · 384 项」= 事件到达 App**。与最小 SwiftUI 探针（纯 Text / ScrollView+LazyVGrid 同组修饰符，非前台，PostToPid 均能触发 `.onKeyPress`）对照，问题在真 App 卡片修饰符链/容器组合，不在后台状态或事件通道。根因未定位，本轮未盲改。 |
| K3 ⌘↩ / ⌥⌘L / ⌘1–⌘6 | PASS | 确认框 + 产物只落 dev root；`~/Pictures` 前后一致；⌘6→存储、⌘5→队列（页面内容判定） |
| K4 多选 | **PASS 4/4** | 单击 1 → ⌘点 2 → 再 ⌘点回 1（取消成功）；⇧ 连选 3；标题与 AX 选中一致 |
| K6 快捷键 | PASS 3/3 | ⇧⌘O / ⇧⌘R enabled 状态正确；实际发键后 App 存活、AX 仍响应 |
| K10 崩溃 | PASS | 4 次运行均正常退出 |

**未验证**：VoiceOver 实际朗读（K8）、键盘遍历与阅读顺序（K9，环境/时间）、macOS 14 真机。

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
5. **Space/Return 不激活卡片**（已复现的 FAIL，根因未定位）：fixed2 上用 AX 描述重新定位卡片，
   焦点确在卡片（AXFocusedUIElement 为该卡、焦点环像素变化），Space/Return 后已选仍 0、焦点不动、
   未滚动；同一焦点状态 ⌘2 生效 → 事件到达 App。最小 SwiftUI 探针（纯 Text、以及
   ScrollView+LazyVGrid+同组修饰符）在非前台、PostToPid 投递下 `.onKeyPress` 均正常触发，
   因此不能归因于“后台窗口/事件通道”。下一步需要在可前台的环境里加临时日志确认
   `onKeyPress` 是否被调用，或把卡片改为 `Button` 语义后复测；本轮未盲改键盘代码。
6. **⌘ 再点取消**：合成修饰键 + AXPress 下第二次 ⌘ 点击没有移出选择；真实鼠标被环境阻断，
   记为待复测，不当作已确认缺陷。
7. **滚动相关指标未取得**：HID 滚轮被用户全屏浮层吞掉，缩略图反复解码/滚动平滑度
   **未验证**；因此 `ThumbnailLoader` 未改动（没有证据就不动）。
8. **VoiceOver 实际朗读未验证**：不改 TCC/系统偏好，见 §6。
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

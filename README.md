# Mirage Unpacker for macOS

浏览 Mirage（macOS 上的 Wallpaper Engine 替代品）素材库，批量解包 `scene.pkg` 并转换纹理的原生 macOS 应用。
纯 SwiftUI 界面，内嵌 [RePKG](https://github.com/notscuffed/repkg) 作为解包引擎。

A native macOS GUI for unpacking Wallpaper Engine `scene.pkg` files in the Mirage library.
Built with SwiftUI; uses RePKG as the unpacking engine.

---

## 与 Mirage 的关系

本项目是 [Mirage](https://github.com/laobamac/MirageWallpaper) 的**配套工具**，不是替代品，也不是它的分支。

| | 做什么 |
|---|---|
| [Mirage](https://github.com/laobamac/MirageWallpaper) | macOS 上的动态壁纸引擎，负责把 Wallpaper Engine 的壁纸**播放**到桌面（支持 web / video / scene） |
| 本项目 | 只负责**解包与查看**：浏览 Mirage 已下载的素材库、把 `scene.pkg` 拆成图片和模型、分离 X-Ray 图层、清理占用的磁盘空间 |

两者通过文件系统协作，没有进程间通信：

```
Mirage 订阅下载
      ↓
~/Library/Application Support/Mirage/Workshop/content/431960/<workshopID>/
      │   project.json / preview.jpg / scene.pkg
      ↓
本项目读取这个目录 → 解包 / 导出图片 / 清理
```

`431960` 是 Wallpaper Engine 在 Steam 创意工坊的 AppID，Mirage 沿用了同一套目录结构，所以本工具读的是 Mirage 的数据目录。

**独立性**：本项目不包含 Mirage 的任何代码，不修改 Mirage 的文件，也不依赖它运行——删掉 Mirage 之后本工具照样能用（只是没有壁纸可解包）。Mirage 采用 GPL-3.0，本项目采用 MIT，两者是彼此独立的程序，仅共享文件系统上的目录约定。

- Mirage 仓库：https://github.com/laobamac/MirageWallpaper
- Mirage 文档：https://mirage.simplehac.cn

---

## 下载

[![Release](https://img.shields.io/github/v/release/ZEH-Denia/mirage-unpacker-macos?label=%E4%B8%8B%E8%BD%BD&color=brightgreen)](https://github.com/ZEH-Denia/mirage-unpacker-macos/releases/latest)

不想自己编译的话，直接从 [Releases](https://github.com/ZEH-Denia/mirage-unpacker-macos/releases/latest) 下载最新版（Apple Silicon）。发布资产是 DMG：双击打开，把 `PKD.app` 拖到窗口里的 `Applications` 图标即可。

资产统一命名为 `Mirage-Unpacker-for-macOS-<版本>.dmg`，同一 DMG 用于手动安装和 Sparkle 应用内更新。

首次打开：**右键点图标 → 打开**（ad-hoc 签名、未公证，属正常现象）。若仍被拦：`xattr -dr com.apple.quarantine /Applications/PKD.app`

安装后可从菜单栏「检查更新…」更新。若应用内检查、下载或安装失败，弹窗提供「前往 GitHub 手动下载」按钮。由于应用未做 Apple 公证，首次下载的新版本仍可能出现 macOS 安全提示。

> Intel Mac 暂无预编译包，请按下方「构建」从源码编译。

---

## 功能

- **素材库网格**：自动扫描 Mirage 的 `431960` 目录，以 16:9 卡片铺开预览图、标题、包大小与内容分级，支持多选与批量解包
- **批量解包**：多选后一键入队，串行执行（可调至 2 并发），实时进度 + 彩色日志
- **包结构预览**：解包前即可查看包内条目（按目录分组、显示各自大小）
- **X-Ray 图层分离**：自动识别壁纸的 X-Ray 效果，把「正常层」和「X-Ray 层」两张图分别命名导出
- **仅导出图片模式**：只要那两张图？解包到临时目录，把图复制到你指定的文件夹后自动清理，不占额外空间
- **存储清理**：列出解包产物与导出图片的占用，勾选后移到废纸篓，删哪个由你决定
- **界面**：参考 Apple Music 的信息架构——导航侧栏、内容优先的网格、底部悬浮任务条；玻璃材质按 HIG 只用在控制层，内容区保持标准背景
- **磁盘预检**：批量前估算产物大小并检查剩余空间
- **可取消 / 可重试**：SIGINT → SIGTERM → SIGKILL 三级取消；崩溃类失败自动重试一次
- **应用内更新**：Sparkle 定期检查更新，也可手动检查；更新失败时可跳转 GitHub Releases 手动下载安装
- **独立解包引擎**：RePKG 编译为 self-contained 单文件随 `.app` 分发，用户无需安装 .NET

## 系统要求

| 项目 | 要求 |
|---|---|
| 系统 | macOS 14 (Sonoma) 或更高，Apple Silicon / Intel |
| 构建 | Command Line Tools（`xcode-select --install`），**不需要完整 Xcode** |
| 构建引擎 | .NET 8 SDK（仅编译 RePKG 时需要，见下方说明） |
| 原生液态玻璃 | macOS 26 或更高（低版本自动回退到自绘实现，功能不受影响） |

## 构建

```bash
git clone https://github.com/ZEH-Denia/mirage-unpacker-macos.git
cd mirage-unpacker-macos

# 1. 编译解包引擎（首次会自动 clone 上游并应用 macOS 补丁）
./tools/build-repkg.sh              # Apple Silicon；Intel 用 ./tools/build-repkg.sh osx-x64

# 2. 解析 Sparkle 更新框架（首次构建或升级 Sparkle 时）
(cd app && swift package resolve --disable-sandbox)

# 3. 打包应用
(cd app && ./scripts/make-app.sh)   # 产出 app/dist/PKD.app

# 4. 安装（可选）
cp -R app/dist/PKD.app /Applications/
```

### 发布应用内更新

每个发布版本都递增 `VERSION`，构建号默认使用相同的数字版本。打包后在生成 appcast 的同一台 Mac 上运行 Sparkle 工具，签名私钥保存在该用户的登录钥匙串中：

```bash
VERSION=1.6.2 # 替换为本次发布版本
(cd app && PKD_VERSION="$VERSION" PKD_BUILD="$VERSION" ./scripts/make-app.sh)
(cd app && ./scripts/package-release.sh "$VERSION")
(cd app && ./scripts/generate-appcast.sh "$VERSION" "v$VERSION")
```

先把 DMG 上传到对应 GitHub Release，再提交 `updates/appcast.xml`。GitHub Actions 会把签名 feed 部署到 GitHub Pages。EdDSA 私钥不放进仓库或 App；丢失时旧安装无法验证换钥更新，需要用户从 Releases 手动安装。

`build-repkg.sh` 会依次尝试 `~/.dotnet/dotnet`、`/opt/homebrew/bin/dotnet`、`/usr/local/share/dotnet/dotnet`。
若都没有，按脚本提示安装（Homebrew 或官方 `dotnet-install.sh`，后者不需要 sudo）。

## 使用

打开应用后是「左导航 + 主区网格 + 右检查器」三栏：

- **左侧导航**：素材库四档筛选（全部 / 可解包 / 未解包 / 已解包）、队列、存储，行尾带数量
- **主区网格**：单击选中并在右侧看详情，`⌘` 点选多个、`⇧` 连选，**双击直接解包**
- **右侧检查器**：顶部在「详情 / 日志」之间切换——详情看预览、输出路径与包内条目，日志是实时引擎输出（完整日志同时写入 `~/Library/Logs/PKD/`）
- 窗口窄到放不下右栏时，点壁纸会自动弹出详情面板
- 解包进行时，底部会出现一条横向任务条：进度环、当前阶段、百分比与取消按钮

快捷键：

| 操作 | 快捷键 |
|---|---|
| 解包所选 | `⌘↩` |
| 筛选：全部 / 可解包 / 未解包 / 已解包 | `⌘1` `⌘2` `⌘3` `⌘4` |
| 队列 / 存储 | `⌘5` `⌘6` |
| 显示或隐藏检查器 | `⌥⌘L` |
| 重新扫描素材库 | `⌘R` |
| 取消全部任务 | `⌘.` |

默认输出到 `~/Pictures/MirageExtracted/<标题>_<workshopID>/`，可在设置里修改。
产物包含原始 `.tex`、转换后的图片、`.tex-json` 元信息、`scene.json`、`project.json` 与预览图。

## X-Ray 图层分离

不少场景类壁纸带 X-Ray 效果：正常图片上挂一个 shader，鼠标位置会透出第二张纹理。

X-Ray 不是独立图层文件，而是 `effects/xray/effect.json` 驱动的标准 WE 效果。本应用在解包后按
`scene.json → models/*.json → materials/*.json` 的引用链解析出两个纹理，把导出的图片重命名为：

```
materials/未标题-1 拷贝 [正常].jpg
materials/未标题-2 拷贝 [X-Ray].jpg
```

`.tex` 原始文件保持不动，重复解包结果幂等。列表中带 `X-Ray` 徽标的壁纸即表示检测到该效果。

## 仅导出图片模式

如果你只想要图，不想要整包解包产物（`scene.json`、`.tex`、模型、着色器……），在设置里把模式切成 **仅导出图片**：

```
设置 → 导出模式 → [完整解包 | 仅导出图片]
```

之后工具栏按钮会变成「导出图片」，行为是：

1. 解包到系统临时目录
2. 把「正常层」「X-Ray 层」复制到**以壁纸命名的子文件夹**，文件名为 `正常.jpg` / `X-Ray.jpg`
3. 删除临时目录

```
~/Pictures/MirageImages/
├── 鸣潮_3608924541/
│   ├── 正常.jpg      8000×4500
│   └── X-Ray.jpg     8000×4500
└── 鸣潮 susujiu_3681598261/
    ├── 正常.png
    └── X-Ray.png
```

子文件夹名带 workshopID，是因为素材库里会出现多个同名壁纸（比如好几个都叫「鸣潮」），只用标题会互相覆盖。
没有 X-Ray 效果的壁纸会导出全部图片（排除 `preview.jpg`），保留原文件名。同一壁纸重复导出会覆盖同名文件，不会堆出 ` (2)`。

实测：40.6 MB 的包 → 只多出一个子文件夹和两张 8000×4500 的 JPEG，临时目录自动清理。

## 界面

按 Apple Human Interface Guidelines 组织的原生结构：

```
┌──────────────┬────────────────────────────────┬──────────────┐
│ 侧栏          │ 内容区（标准背景）              │ 日志检查器    │
│ 系统 sidebar  │ 大标题 + 元信息                 │ ⌥⌘L 可折叠    │
│ material     │ 列表 / 分组                     │              │
└──────────────┴────────────────────────────────┴──────────────┘
   工具栏：详情·队列·存储 │ 刷新 日志 更多 解包
```

侧栏顶部是一行**筛选入口**（漏斗图标 + 当前条件 + 上下箭头），点开弹出竖向的选项面板：全部 / 可解包 / 未解包 / 已解包，当前项打勾。收起时按钮上仍显示当前条件，不会丢状态。

滚动条统一为 **overlay 样式**：只在滚动时浮出细滑块，不占位、不画轨道。系统「显示滚动条：自动」配合鼠标时，AppKit 默认会画旧式滚动条，右侧常驻一条浅色轨道矩形，压在玻璃面板上很突兀——所以这里显式覆盖，主窗口与设置窗口都生效。

### 液态玻璃用在哪

HIG 对材质有一条硬性规定：

> **不要在内容层中使用 Liquid Glass。** 它用于在交互元素与内容之间建立明确区分，出现在内容层会造成视觉层次混乱。

所以玻璃只出现在**控制层**，且全部由系统绘制：

| 位置 | 实现 |
|---|---|
| 侧栏 / 工具栏 / 检查器 | macOS 26 上是原生 Liquid Glass；旧系统是系统 sidebar / toolbar 材质 |
| 浮动任务胶囊 | 唯一一处自绘玻璃，`glassEffect(.regular.interactive())`，指针悬停有液态响应；旧系统降级为 `.regularMaterial` |

内容区是纯 `windowBackgroundColor`，没有模糊、没有描边、没有投影。

### 可调项（设置 → 外观）

| 设置 | 取值 |
|---|---|
| 主题 | 跟随系统 / 浅色 / 深色 |
| 强调色 | 系统默认 + 7 种 |
| 玻璃效果 | 系统原生 / 标准材质 / 关闭 |
| 界面密度 | 紧凑 / 标准 / 宽松 |
| 字号 | 小 / 标准 / 大 |
| 动效 | 跟随系统 / 减弱 / 关闭 |
| 在侧栏显示缩略图 | 开 / 关 |

配色与字体不再暴露色相、饱和度、圆角、高光这类皮肤参数——HIG 要求材质与颜色按语义选取，而不是按外观挑选。字号全部映射到系统文本样式，最小 `.caption`（10pt），不写死点数。

### 无障碍

- **降低动态效果**：页切换过渡、悬停动画、胶囊入场全部关闭
- **降低透明度**：玻璃与材质换不透明背景，日志改用不透明底色
- **增强对比度**：分隔线与次要文字升为实色 / 主色
- 深浅色全部走 `NSColor` 语义色，没有硬编码黑白

### 自适应

窗口变窄时按列最小宽自动让位，不用手动拖面板：

| 窗口宽度 | 行为 |
|---|---|
| ≥ 1100 | 视图切换显示文字分段 |
| < 1100 | 分段退化为图标 |
| ≤ 1020 | 自动折叠日志检查器（≥ 1060 时恢复） |
| < 900 | 视图切换退化为菜单 |
| ≤ 780 | 自动折叠侧栏（≥ 820 时恢复） |
| 640 | 窗口最小宽度，内容仍可读 |

- 详情页底部按钮在窄窗口下自动降级为图标（`AdaptiveLabelStyle`）
- 元数据行在窄窗口下由「标签 + 值」横排改为上下竖排（`AnyLayout`）
- 侧栏筛选条放不下时从分段控件退化为菜单（`ViewThatFits`）
- 手动折叠过的面板不会被自动恢复覆盖——自动折叠会记录用户意图，用户一操作即清除标记

### 快捷键

| 操作 | 快捷键 |
|---|---|
| 全部壁纸 / 可解包 / 未解包 / 已解包 | ⌘1 / ⌘2 / ⌘3 / ⌘4 |
| 队列 / 存储 | ⌘5 / ⌘6 |
| 显示或隐藏日志 | ⌥⌘L |
| 清空日志 | ⌘K |
| 显示或隐藏侧栏 | ⌃⌘S |
| 刷新当前页面 | ⌘R |
| 解包所选 / 取消全部任务 | ⌘↩ / ⌘. |
| 打开输出目录 / 在 Finder 中显示 | ⇧⌘O / ⇧⌘R |

命令只有一处主入口，其余为上下文入口（右键菜单、行内按钮）。工具栏每一项在菜单栏里都有对应命令，符合 HIG 对 macOS 工具栏的要求。

## 存储清理

一个 8K 壁纸的完整解包产物约 65 MB，攒几个就很占地方。中间栏的 **「存储」** 页会统计三类占用：

| 分类 | 位置 |
|---|---|
| 完整解包产物 | `~/Pictures/MirageExtracted` 下的每个子文件夹 |
| 导出图片 | `~/Pictures/MirageImages` 下的每个子文件夹 |
| 残留临时文件 | 系统临时目录里 `PKD-extract-` 开头的目录（异常退出才会留下） |

每项显示占用大小、文件数、修改时间。勾选后点「移到废纸篓」——**是移到废纸篓而不是直接删除**，可以在访达里恢复。删掉后对应的「已解包」标记也会自动消失。

安全约束（防止误删）：

- 只允许删除这两个根目录的**直接子项**，根目录本身和更深的文件不可删
- 临时目录只认 `PKD-extract-` 前缀
- 越界路径会被拒绝并记录在结果提示里
- 删除前弹窗二次确认，列出项数与总大小

## 工作原理

```
SwiftUI (PKDApp)
   │
   ├── PKDKit ── RepkgSession ── Process ──► repkg extract / info
   │                │                        （文本输出逐行解析）
   │                ├── LineStream           按字节 0x0A 切行，UTF-8 安全
   │                ├── RepkgOutputParser   行 → 语义事件
   │                └── ExtractVerdict      成败判定
   │
   ├── LibraryScanner / XRayAnalyzer        素材库与图层识别
   └── JobQueue / LogSink                   任务调度与日志汇聚
```

### 几个值得记录的坑

1. **`repkg` 的退出码恒为 0**。成功、文件不存在、参数错误全都返回 0，所以成败只能靠输出哨兵判定：
   收到 `Done` 才算完成，`Input file not found` 算失败，有 `Done` 但输出目录为空也算失败。
2. **进度条要两段式**。`extract` 不打印条目总数，必须先跑一次 `info -e` 拿到条目数与字节数。
   且 `* Extracting:` 是在写文件**之前**打印的，条目要等下一条事件才算完成。
3. **不能用 `readabilityHandler` 读输出**。进程退出后它可能不再触发，最后几行（含 `Done`）会丢，
   判定随即失效。这里用的是两个并发阻塞读循环 + `DispatchGroup.wait()`。
4. **没有 Xcode 就没有 SwiftUI 宏**。本机只有 Command Line Tools，缺 `libSwiftUIMacros.dylib`，
   `@State` / `@Environment` / `@Bindable` 全部无法编译，因此界面统一使用
   `ObservableObject` + `@Published` + `@StateObject` / `@EnvironmentObject`。
5. **`repkg version` 的输出走 stderr**（CommandLineParser 的行为），探活时两路都要读。

## 已知限制

- 不使用 Developer ID 或 Apple 公证，`.app` 保持 ad-hoc 签名；首次打开需按 macOS 提示手动允许。Sparkle 使用独立 EdDSA 密钥验证更新包，不能替代 Gatekeeper 公证
- 日志面板显示统一日志流（用 `=== 标题 [id] ===` 分隔任务），未做按任务过滤
- 视频类壁纸（`type: video`，无 pkg）会灰显且不可勾选
- 上游 RePKG 更新后，`tools/repkg-macos.patch` 可能需要手动 rebase

## 目录结构

```
app/
  Package.swift                  SwiftPM 清单
  Sources/PKDKit/                引擎封装、素材库、队列、日志（纯逻辑，可单测）
  Sources/PKDApp/                SwiftUI 界面
  Sources/PKDApp/UpdateManager.swift  Sparkle 更新器与失败时的 GitHub 回退
  Sources/PKDSelfTest/           自测可执行目标（CLT 环境无 XCTest）
  scripts/make-app.sh            组装 .app + 图标 + ad-hoc 签名
  scripts/package-release.sh     打包可拖入 Applications 的 DMG
  scripts/generate-appcast.sh    使用本机 Keychain 私钥签名更新并生成 appcast
  scripts/verify.sh              回归验证
updates/                         GitHub Pages 上的 Sparkle 更新 feed
tools/
  build-repkg.sh                 编译引擎（clone 上游 + 应用补丁）
  repkg-macos.patch              RePKG macOS 移植与发布补丁
  testdata/                      合成测试包生成器与像素校验脚本
```

## 验证

```bash
cd app && ./scripts/verify.sh
```

覆盖：87 项单元断言（切行 / 解析 / 判定表 / X-Ray / 图片导出 / 存储清理 / 包信息缓存）、队列全链路、真实包逐文件比对、失败路径判定。

## 许可

本项目代码为 MIT，见 [`LICENSE`](LICENSE)。
内嵌引擎 RePKG（MIT）及其依赖的声明见 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。

本项目不含任何壁纸素材；请自行确保对所处理的内容拥有合法使用权。

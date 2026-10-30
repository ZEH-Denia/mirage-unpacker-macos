# Mirage Unpacker for macOS

浏览 Mirage（macOS 上的 Wallpaper Engine 替代品）素材库，批量解包 `scene.pkg` 并转换纹理的原生 macOS 应用。
纯 SwiftUI 界面，内嵌 [RePKG](https://github.com/notscuffed/repkg) 作为解包引擎。

A native macOS GUI for unpacking Wallpaper Engine `scene.pkg` files in the Mirage library.
Built with SwiftUI; uses RePKG as the unpacking engine.

---

## 下载

[![Release](https://img.shields.io/github/v/release/5w57ywswf7-cloud/mirage-unpacker-macos?label=%E4%B8%8B%E8%BD%BD&color=brightgreen)](https://github.com/5w57ywswf7-cloud/mirage-unpacker-macos/releases/latest)

不想自己编译的话，直接下载 **`PKD-1.0.0-macos-arm64.zip`**（Apple Silicon，约 29 MB）：

1. 解压，把 `PKD.app` 拖进 `/Applications`
2. 首次打开：**右键点图标 → 打开**（ad-hoc 签名、未公证，属正常现象）
3. 若仍被拦：`xattr -dr com.apple.quarantine /Applications/PKD.app`

> Intel Mac 暂无预编译包，请按下方「构建」从源码编译。

---

## 功能

- **素材库浏览**：自动扫描 Mirage 的 `431960` 目录，读取 `project.json` 显示标题、预览图、包大小、内容分级
- **批量解包**：多选后一键入队，串行执行（可调至 2 并发），实时进度 + 彩色日志
- **包结构预览**：解包前即可查看包内条目（按目录分组、显示各自大小）
- **X-Ray 图层分离**：自动识别壁纸的 X-Ray 效果，把「正常层」和「X-Ray 层」两张图分别命名导出
- **磁盘预检**：批量前估算产物大小并检查剩余空间
- **可取消 / 可重试**：SIGINT → SIGTERM → SIGKILL 三级取消；崩溃类失败自动重试一次
- **零外部依赖**：引擎编译为 self-contained 单文件，随 `.app` 一起分发，用户无需安装 .NET

## 系统要求

| 项目 | 要求 |
|---|---|
| 系统 | macOS 14 (Sonoma) 或更高，Apple Silicon / Intel |
| 构建 | Command Line Tools（`xcode-select --install`），**不需要完整 Xcode** |
| 构建引擎 | .NET 8 SDK（仅编译 RePKG 时需要，见下方说明） |

## 构建

```bash
git clone https://github.com/5w57ywswf7-cloud/mirage-unpacker-macos.git
cd mirage-unpacker-macos

# 1. 编译解包引擎（首次会自动 clone 上游并应用 macOS 补丁）
./tools/build-repkg.sh              # Apple Silicon；Intel 用 ./tools/build-repkg.sh osx-x64

# 2. 打包应用
cd app && ./scripts/make-app.sh     # 产出 app/dist/PKD.app

# 3. 安装（可选）
cp -R app/dist/PKD.app /Applications/
```

`build-repkg.sh` 会依次尝试 `~/.dotnet/dotnet`、`/opt/homebrew/bin/dotnet`、`/usr/local/share/dotnet/dotnet`。
若都没有，按脚本提示安装（Homebrew 或官方 `dotnet-install.sh`，后者不需要 sudo）。

## 使用

打开应用后：

- 左侧列表勾选壁纸（`⌘` 多选、`⇧` 连选），按 **⌘↩** 开始解包
- **⌘R** 重新扫描素材库，**⌘.** 取消全部任务
- 中间「详情」页可看包内条目；「队列」页看进度与结果
- 右侧是实时日志，完整日志同时写入 `~/Library/Logs/PKD/`

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

- 无开发者证书，`.app` 为 ad-hoc 签名。他人首次打开需右键「打开」，或 `xattr -d com.apple.quarantine`
- 日志面板显示统一日志流（用 `=== 标题 [id] ===` 分隔任务），未做按任务过滤
- 视频类壁纸（`type: video`，无 pkg）会灰显且不可勾选
- 上游 RePKG 更新后，`tools/repkg-macos.patch` 可能需要手动 rebase

## 目录结构

```
app/
  Package.swift                  SwiftPM 清单
  Sources/PKDKit/                引擎封装、素材库、队列、日志（纯逻辑，可单测）
  Sources/PKDApp/                SwiftUI 界面
  Sources/PKDSelfTest/           自测可执行目标（CLT 环境无 XCTest）
  scripts/make-app.sh            组装 .app + 图标 + ad-hoc 签名
  scripts/verify.sh              回归验证
tools/
  build-repkg.sh                 编译引擎（clone 上游 + 应用补丁）
  repkg-macos.patch              相对上游的 5 处改动
  testdata/                      合成测试包生成器与像素校验脚本
```

## 验证

```bash
cd app && ./scripts/verify.sh
```

覆盖：59 项单元断言（切行 / 解析 / 判定表 / X-Ray）、队列全链路、真实包逐文件比对、失败路径判定。

## 许可

本项目代码为 MIT，见 [`LICENSE`](LICENSE)。
内嵌引擎 RePKG（MIT）及其依赖的声明见 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。

本项目不含任何壁纸素材；请自行确保对所处理的内容拥有合法使用权。

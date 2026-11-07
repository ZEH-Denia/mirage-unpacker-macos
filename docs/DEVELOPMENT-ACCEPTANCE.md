# 本地开发验收记录

日期：2026-11-05。版本文件基线 1.7.5，开发分支 `feature/export-workflow`。

## 本轮交付

| 批次 | 最终行为 | 验证证据 |
| --- | --- | --- |
| 开发隔离与备份 | 独立 bundle ID、素材库、历史、缓存、日志和输出；使用生成的占位素材 | `DevelopmentEnvironment`、开发启动脚本、备份恢复验证 |
| 导出前分析 | 详情和批量确认区分单纹理、模型、分层及未知情况，避免承诺完整还原 | 基础自测、详情与确认窗口的实际操作 |
| 结果浏览器 | 应用内切图、缩放、尺寸/格式/体积信息、Finder 与关闭入口 | 合成多图层画面浏览；本轮普通导出后切图，尺寸由 64×64 更新为 640×360 |
| 冲突规则与队列 | 保留两份/跳过/覆盖，入队时固定规则；统计新增/跳过，按状态查看任务 | 11 项队列验证；前批设置选择、全跳过和队列筛选交互记录 |
| 静态场景组合 | 支持受限的普通图片与多个 puppet，二维变换、层顺序及整层透明度 | 14 项合成渲染检查（后续增至 27 项），实际队列与结果浏览器检查 |
| 素材整理与导入 | 收藏与最近使用持久化，文件打开/拖放临时导入，刷新保留，移出只影响应用列表 | 双进程 13 项生命周期检查；收藏/最近重启恢复、真实拖放、刷新、右键移出和源文件哈希检查 |

所有新增图片均由测试生成器产生，不读取个人壁纸。截图仅指定开发应用自己的窗口 ID，不截取整个桌面。开发副本禁用自动更新及登录项开关，不覆盖 `/Applications/PKD.app`。

## 本轮修正

“清除隐藏选择”原来从选择集合中减去可见 ID，导致保留隐藏项、取消可见项。现在对选择集合与当前可见 ID 取交集。双进程检查覆盖同时选中两项后搜索、清理的情况；实际收藏页面取消收藏后，点击清理按钮，已选与隐藏数量均正确归零。

## 已执行验证

| 命令 / 操作 | 结果 |
| --- | --- |
| `cd app && swift build --disable-sandbox` | 成功 |
| `cd app && swift build -c release --disable-sandbox --product PKD` | 成功 |
| `cd app && ./.build/debug/pkd-selftest` | 156 项断言通过（本批次记录时的基线；收尾补充后见下节，最终 161 项） |
| `cd app && ./.build/debug/pkd-selftest --queue ../tools/testdata/test_scene.pkg` | 10 项断言通过 |
| `cd app && ./.build/debug/pkd-selftest --image-conflicts ../tools/testdata/test_scene.pkg` | 11 项断言通过 |
| `cd app && ./.build/debug/pkd-selftest --render-fixtures .build/render-fixture` | 14 项断言通过（本批次记录时；收尾后为 27 项） |
| `python3 tools/dev/verify-library.py --app <当前开发 app 路径>` | 两个不同 PID，13 项生命周期检查通过 |
| 780×640 窄窗，选卡片打开详情并点击左上关闭 | 关闭正常，未遮挡关闭入口 |
| 普通图片导出、打开结果、下一张、关闭 | 图片与尺寸更新正确 |
| 实际收藏切换、空状态、重启恢复、清空最近使用 | 结果正确；清空最近使用保留收藏 |
| 实际系统拖放 → 工具栏刷新 → 右键移出临时素材 | 12 → 13 → 13 → 12 项；刷新保留选择，移出清空选择 |
| 导入来源文件名与 SHA-256 比对 | 全部不变 |
| 备份 bundle 克隆、ZIP 恢复与逐文件比对 | 87 个文件一致，Git HEAD 为变更前的 `e262f08` |

构建仍会显示已有的同模块 import 警告和 Command Line Tools 搜索路径警告；没有构建失败。

## 本机证据

这些文件均位于被 Git 忽略的 `.build` 中，不包含个人图片：

- `app/.build/library-lifecycle-imxmw33e/summary.json`：最新双进程 13 项检查。
- `app/.build/library-validation-20261105-051609/ui-import-validation.json`：真实拖入、刷新、移出及来源哈希检查。
- 同目录 `ui-refreshed.txt` / `ui-removed.txt`：稳定状态后的 AX 树，分别为 13 项已选 1、12 项无选择。
- 同目录 `library-restored.png` / `narrow-detail.png`：仅包含抽象占位图的开发窗口截图。
- `app/.build/backup-restore-s4977tva/workspace`：变更前源码的独立恢复目录。

## 复验方法

先用 `tools/dev/launch.sh` 生成开发副本。验证脚本要求传入当前构建并签名、bundle ID 为 `com.zeh.pkd.development` 的 app；拒绝正式应用。它在全新的 `.build/library-lifecycle-*` 中生成素材，直接启动两个进程并分别检查报告，只结束自己创建的测试进程。

```bash
cd app
swift build --disable-sandbox
cd ..
python3 tools/dev/verify-library.py --app 'app/.build/private-development/PKD Development.app'
```

开发副本必须已由启动脚本重新构建，避免用旧二进制验证新源码。`library-seed` / `library-verify` 是成对的开发场景；`library-inspect` 可在同一根目录中重新导入验证包，用于真实刷新与移出操作，不代替输入操作的验收。

`tools/dev/ax-audit.swift <开发 PID> tree` 可直接读取开发窗口。它检查 bundle ID，拒绝控制正式应用；`main/...` 路径避免工具提示窗口改变顶层索引。原生菜单可能等待选择才返回，发生超时时应检查当前菜单，而不是重复触发。`context` 在同一进程中打开并选择菜单项。

拖放辅助源支持首次点击；鼠标脚本可额外传入拖放源 PID，在同一次执行中先激活源窗口。测试时先激活目标开发窗口，避免多个开发副本互相遮挡。本轮最初发生过 CoreDrag 错误及窗口激活干扰；修正测试源和激活顺序后，最终返回 `operation=1`，并确认目标列表增加，不能仅凭 copy 返回值判定导入成功。

## 1.8.0 收尾补充验证

上表是本轮开发批次的记录。之后的收尾阶段新增场景组合与动画纹理检查，自测断言从 156 项增至 161 项；以下为最终状态（重建当前源码后执行）。

| 命令 / 操作 | 结果 |
| --- | --- |
| `cd app && swift build --disable-sandbox` | 成功 |
| `cd app && ./.build/debug/pkd-selftest` | 161 项断言通过 |
| `cd app && ./.build/debug/pkd-selftest --render-fixtures .build/render-fixture` | 25 项断言通过（含裁剪偏移、父子变换、循环父节点、脚本绑定回退、单图层跳过条件；本轮后为 27 项） |
| `cd app && ./.build/debug/pkd-selftest --scene-semantics .build/render-fixture` | 58 项断言通过（角度单位、绑定默认值、百分比与逐层不透明度、色调、尺寸优先、未确认属性回退、条件绑定与未渲染对象计数） |
| 共享单纹理场景 `--scene-queue <pkg> 400 320` | 5 项断言通过（纹理数少也按实际引用判断组合） |
| `bash tools/testdata/verify_animation.sh` | PNG 编码与原始像素动画的两帧像素、时长、尺寸通过；超大 PNG 图集被拒绝并保留原 TEX |
| 真实场景 `--scene-queue <pkg> 4096 2304 --expect-no-texture-errors` | 6 项断言通过（不带该 flag 时为 5 项），无纹理转换错误 |
| 旧版与修改后引擎解包同一真实场景 | 43 个输出文件路径与 SHA-256 全部一致 |

判断规则与不足见 [SCENE-RENDERING-VALIDATION.md](SCENE-RENDERING-VALIDATION.md)。真实素材仅在本机使用，未加入仓库。

## 验证边界

- 场景组合仍是实验性静态预览：不执行脚本、粒子、动态效果、时钟、3D 或未知材质，不承诺与实际 Wallpaper Engine 运行画面完全相同。
- 本轮没有使用真实个人素材做画面对照，也没有做跨所有 macOS 版本的兼容性或帧率基准测试。
- AX 标签和操作已经检查；没有把它等同于人工 VoiceOver 朗读验收。
- 发布流程、应用内更新服务器和正式安装未变更，本轮没有对外发布。

## 1.8.2 集成准备状态

以下为 1.8.2 预览批次的收口记录（构建统一 `/usr/bin/arch -arm64 /usr/bin/swift build --disable-sandbox`）：

| 命令 / 操作 | 结果 |
| --- | --- |
| `cd app && ./.build/debug/pkd-selftest` | 161 项断言通过 |
| `--render-fixtures .build/render-fixture` | 27 项断言通过 |
| `--scene-semantics .build/render-fixture` | 132 项断言通过（含骨骼蒙皮：非单位旋转/缩放、权重归一、X 轴塌陷、blend<1、七类异常回退） |
| `--image-conflicts <pkg>` / `--queue <pkg>` | 11 项 / 10 项断言通过 |
| `--storage-safety` | 存储安全回归通过（owned/temp 可清理、unknown/legacy 只读、重导出不接管） |
| `bash tools/dev/baseline-verify.sh` | 可重复合成基线通过（解包 + 逐文件 SHA-256 + 独立像素断言 + 两次解包 + 篡改检测） |
| `bash tools/dev/fault-logsink-tests.sh` | LogSink 生命周期回归通过 |
| `python3 tools/testdata/verify_golden.py` | 30 项断言通过（专属子目录、带归属标记） |
| `python3 tools/testdata/test_evidence_tool_safety.py` | 29 项测试通过（受保护路径拒绝、清理边界、矩阵分类） |
| `bash tools/testdata/verify_animation.sh` | PNG 图集与原始像素动画通过；超大输入被拒绝并保留原 TEX |

**最终 verify 结果**：`bash app/scripts/verify.sh` → 退出码 0，通过 18、失败 0、必需项未验证 0；覆盖缺口 1 项（历史真实基线不可恢复）。生命周期 runner 计数：LogSink 23 / 更新恢复 25 / supervisor 12 / 临时目录 14 / JobQueue 租约 7 / 并发 8；存储安全 129、合成基线 29、金标准 30、证据工具 29。Release 构建与 release 二进制（161/132/129）亦通过。

**仍未验证（不得视为通过）**：历史真实包逐文件比对（`extracted/<历史基线目录>` 已不可恢复，日常只作覆盖缺口，`--with-real-baseline` 才作验收项）；前台交互（结果浏览器、存储清理确认、队列筛选、键盘搜索、更新弹窗）、VoiceOver 人工朗读、真实滚轮手势、macOS 14 旧系统兼容运行。生命周期与并发 runner（LogSink/更新恢复/supervisor/临时目录/JobQueue 租约/并发）已接线为 `verify.sh` 的默认必需项并通过。

场景组合仍是实验性静态预览：不执行脚本、不渲染粒子/文本/音频、动画只取第 0 帧；与播放器画面**有改善但未完全一致**（无损参考口径 4.5165 → 4.1436）。

# 本地开发验收记录

日期：2026-11-05。版本文件基线 1.7.5，开发分支 `feature/export-workflow`。

## 本轮交付

| 批次 | 最终行为 | 验证证据 |
| --- | --- | --- |
| 开发隔离与备份 | 独立 bundle ID、素材库、历史、缓存、日志和输出；使用生成的占位素材 | `DevelopmentEnvironment`、开发启动脚本、备份恢复验证 |
| 导出前分析 | 详情和批量确认区分单纹理、模型、分层及未知情况，避免承诺完整还原 | 基础自测、详情与确认窗口的实际操作 |
| 结果浏览器 | 应用内切图、缩放、尺寸/格式/体积信息、Finder 与关闭入口 | 合成多图层画面浏览；本轮普通导出后切图，尺寸由 64×64 更新为 640×360 |
| 冲突规则与队列 | 保留两份/跳过/覆盖，入队时固定规则；统计新增/跳过，按状态查看任务 | 11 项队列验证；前批设置选择、全跳过和队列筛选交互记录 |
| 静态场景组合 | 支持受限的普通图片与多个 puppet，二维变换、层顺序及整层透明度 | 14 项合成渲染检查，实际队列与结果浏览器检查 |
| 素材整理与导入 | 收藏与最近使用持久化，文件打开/拖放临时导入，刷新保留，移出只影响应用列表 | 双进程 13 项生命周期检查；收藏/最近重启恢复、真实拖放、刷新、右键移出和源文件哈希检查 |

所有新增图片均由测试生成器产生，不读取个人壁纸。截图仅指定开发应用自己的窗口 ID，不截取整个桌面。开发副本禁用自动更新及登录项开关，不覆盖 `/Applications/PKD.app`。

## 本轮修正

“清除隐藏选择”原来从选择集合中减去可见 ID，导致保留隐藏项、取消可见项。现在对选择集合与当前可见 ID 取交集。双进程检查覆盖同时选中两项后搜索、清理的情况；实际收藏页面取消收藏后，点击清理按钮，已选与隐藏数量均正确归零。

## 已执行验证

| 命令 / 操作 | 结果 |
| --- | --- |
| `cd app && swift build --disable-sandbox` | 成功 |
| `cd app && swift build -c release --disable-sandbox --product PKD` | 成功 |
| `cd app && ./.build/debug/pkd-selftest` | 156 项断言通过 |
| `cd app && ./.build/debug/pkd-selftest --queue ../tools/testdata/test_scene.pkg` | 10 项断言通过 |
| `cd app && ./.build/debug/pkd-selftest --image-conflicts ../tools/testdata/test_scene.pkg` | 11 项断言通过 |
| `cd app && ./.build/debug/pkd-selftest --render-fixtures .build/render-fixture` | 14 项断言通过 |
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

## 验证边界

- 场景组合仍是实验性静态预览：不执行脚本、粒子、动态效果、时钟、3D 或未知材质，不承诺与实际 Wallpaper Engine 运行画面完全相同。
- 本轮没有使用真实个人素材做画面对照，也没有做跨所有 macOS 版本的兼容性或帧率基准测试。
- AX 标签和操作已经检查；没有把它等同于人工 VoiceOver 朗读验收。
- 发布流程、应用内更新服务器和正式安装未变更，本轮没有对外发布。

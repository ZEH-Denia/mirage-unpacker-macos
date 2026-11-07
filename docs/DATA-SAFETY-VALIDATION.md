# 存储清理与输出数据保护验证

本文记录 1.8.1 上「存储清理 / 输出目录数据保护」的实现、独立攻击面复核、验证证据与集成边界。
目标不是给历史事故下结论，而是堵住可证实的误删风险面，并让清理行为可追溯、可 fail closed。

## 1. 背景与目标

历史现象：用户导出目录曾整体消失；早期快照之间还出现过带编号副本批量消失。调查结论是
**根因未查明**（缺确认执行证据与废纸篓内容证据），不能归因用户，也不能绝对排除 app 的其他原因。
但调查确认了几条真实风险面：存储页把导出根下所有直接子目录都当成可清理产物、一键全选、确认框不显示路径、
归属只靠目录名/位置、冒烟导出未隔离真实图片根、清理动作无持久记录。

## 2. 最终安全语义（核心规则）

### 2.1 一句话规则

**只有「应用新建」或「之前确实可信且未混入未知内容」的目录，才允许整目录可清理；其它一律只读。**
标签不同不等于删除权限不同：`legacy` 仅用于展示，不能清理；`确认框提示路径`不能替代文件归属证明。

### 2.2 归属等级与权限

| 等级 | 含义 | 清理权限 |
|---|---|---|
| `owned` | 应用私有记录（路径 + 设备 + inode + **完整内容指纹**）全部匹配 | 可进入清理计划 |
| `legacy` | 旧记录/历史候选：只用于解释来源与展示 | **只读**，不参与计划/全选 |
| `temporary` | 系统临时目录下带 `PKD-extract-` 前缀的应用残留（需完整指纹） | 可清理（非用户导出目录） |
| `unknown` | 预存目录、仅历史路径、被替换、混入用户文件、根范围过大、符号链接等 | **只读** |

### 2.3 导出前的可信快照（`ExportEligibility`）

导出任务**入队后、任务运行前**，对目标目录计算并保存：

- `newDirectory`：目标目录不存在（应用将新建）→ 导出成功后登记 `owned`；
- `trustedOwned`：目标已存在，且既有 `owned` 记录 **inode 一致 + 完整内容指纹完全一致**（纯应用产物）→ 导出成功后刷新 `owned`（正常重复导出仍可清理）；
- `untrusted`：目标已存在但无可信证明（用户预存、被替换、导出后被改动、仅历史记录）→ **导出成功后拒绝登记，目录保持只读**。

要点：

- **预存目录 + 向其中导出一次** 不会把整目录武装为可清理（也不再创建 legacy 可清理绑定）；历史路径只有展示价值。
- **同 inode 的 owned 目录混入用户文件后再次导出**：入队时指纹不一致 → `untrusted` → 不刷新、不接管，保持只读。
- **同名路径被替换（inode 变化）后再次导出**：`untrusted`，且旧的 owned 记录不会被错误刷新。
- **纯应用目录重复导出**：`trustedOwned` → 继续 `owned` 且可清理（有测试保证不误禁）。
- 若要支持「用户预存目录里的新导出文件可清理」，需要逐文件产物 **manifest** 级归属证明；在该能力实现前，这类目录一律只读（不以重新导出默认恢复）。
- 登记 `owned` 要求：目录标记写入成功 **且** 归属文件写入后**回读校验到该记录**；任一失败回滚并保持只读。

### 2.4 内容指纹与确认前后校验

目录指纹：枚举条目（跳过 `.DS_Store`、`._*`、应用自己的 `.pkd-output.json`），按相对路径排序后对
「相对路径 | 大小 | 修改时间(ms) | 类型(f/d/l)」做 SHA-256，并记录条目数与完整性。

- 扫描 → 生成计划 → 确认执行三次比对；路径/设备/inode/类型、目录大小/mtime、条目数、完整指纹任一不一致 → 拒绝/跳过。
- 超过 `StorageContentFingerprint.entryLimit = 20_000` 条 → `complete=false` → 只读。
- **能检测**：条目增删/改名、文件大小/mtime 变化、文件/目录/符号链接类型变化。
- **不能检测**：大小与 mtime 都不变的内容改写、xattr/ACL；存在最后一次校验与 `trash` 之间的**极小 TOCTOU 窗口**（不声称完全无竞态）。

### 2.5 输出根与路径边界

拒绝 `/`、家目录、家目录上级、`/Users`、`/Applications`、`/Library`、`/System`、`/private`、`/Volumes`、系统临时目录、
家目录下 `Pictures`/`Documents`/`Desktop`/`Downloads`/`Movies`/`Music`/`Library`/`Public` 等整目录作为输出根；
根不安全时条目全部只读并显示原因。解包根与图片根相同/嵌套 → 只读。根自身不是条目；目标包含输出根（如 `..`）拒绝。
根是符号链接时按真实路径枚举与归属；执行时按**当前**根再校验（计划后改根不执行）；确认期间父路径重定向 →
canonical/inode 变化跳过；大小写不同路径去重最多一个进入计划；重复 inode/路径拒绝。

### 2.6 确认交互（代码就绪，前台行为待补）

确认面板列出每个目录**完整路径**、分类、归属、大小、文件数，可滚动；取消绑定 Esc/关闭、破坏性按钮无默认键；
只读条目带锁不可选；空计划禁用破坏性按钮。**本轮未做真实鼠标/键盘验收**（见第 6 节）。

### 2.7 清理审计日志（CleanupAudit）

`~/Library/Application Support/PKD/CleanupAudit/cleanup-audit.jsonl`（0700/0600、不进 Git、不上传）。
事件：`request` / `cancelled` / `confirmed` / `item_result` / `completed`；只含目录路径/分类/归属/大小/设备/inode/结果，
不含图片或文件内容；同步追加 + `synchronize()` + close，4 MB 轮转，并发追加有锁保护不丢尾。

### 2.8 测试环境隔离

「仅导出图片」模式冒烟导出必须提供隔离图片根（`PKD_SMOKE_IMAGE_ROOT` 或 `PKD_DEVELOPMENT_ROOT`）且不得等于正式配置，
否则拒绝；隔离目录仅本次任务临时替换并在结束后恢复。非该模式保留 `PKD_SMOKE_OUT`。

## 3. 本轮反例验证结果（真实隔离 fixture）

| 反例 | 结果 |
|---|---|
| 预存目录（含用户哨兵文件）→ 向其中导出一次 | eligibility=`untrusted`，登记被拒；扫描为 `unknown` 只读；**全选不含它、清理计划为空** |
| owned 目录混入用户文件 → 再次导出 | eligibility=`untrusted`，不刷新指纹；目录只读，计划为空 |
| owned 目录被同名替换（inode 变化）→ 再次导出 | eligibility=`untrusted`，拒绝登记；旧 owned 记录不刷新；只读 |
| 只有历史路径、仅名字相似、符号链接 | 一律只读；不进入计划/全选 |
| 纯应用目录重复导出 | eligibility=`trustedOwned`，仍为 `owned` 且可清理（不误禁） |
| 旧 v2 文件里的 legacy 绑定 | 展示为 `legacy`，**只读**，不可清理 |
| 根 symlink / 根相同/嵌套 / 先计划后改根 / 父路径重定向 / 大小写路径 | 按真实路径或拒绝执行，均不误删（逐项断言） |
| 归属文件损坏 / 标记篡改 / marker 写入失败 / store 抛错 / 静默 no-op 写入 | 告警或拒绝登记、无 owned 残留、失败回滚；损坏证据保留 `.corrupt` |
| 注入权限拒绝（部分失败） | 成功项照常、失败项保留、审计记录 failed |
| 审计并发 80 条 / 4MB 轮转 / 0600 | 全部记录可读回、不丢尾、权限正确 |

## 4. 测试与验证

测试：`app/Sources/PKDSelfTest/StorageSafetyTests.swift`；独立运行：`tools/dev/verify-storage-safety.sh`。
fixture 在 `app/.build/storage-safety-<时间戳>/fixture`，`trash` 注入为 fixture 内 sink，故障由注入接口模拟，
不 chmod/不填盘真实目录、不触碰真实废纸篓。

| 项目 | 命令 | 结果 |
|---|---|---|
| 构建（Debug） | `cd app && swift build --disable-sandbox` | 通过 |
| 构建（Release） | `cd app && swift build -c release --disable-sandbox` | 通过 |
| 既有自测 | `./.build/debug/pkd-selftest` | 通过（161 项断言） |
| 存储安全隔离回归 | `bash tools/dev/verify-storage-safety.sh` | 通过（129 项断言） |

## 5. 集成清单（必须接线）

**不需要修改** `JobQueue`、`ImageExporter`、`HistoryStore`、`LogSink`、`UpdateManager`：

- `AppModel` 在 `queue.enqueue(...)` 返回后、任务真正运行前，用现有公开成员
  （`ExtractJob.item`、`imageExportDestination`、`OutputLayout.folderName`）算出目标目录，
  调用 `OutputOwnershipStore.exportEligibility(directory:existingRecord:fs:)` 保存快照；
  导出成功后按快照调用 `recordAfterExport(..., eligibility:)`。**无需 JobQueue 新接口**。
- 若将来希望由导出侧提供逐文件 manifest（以允许「预存目录内新导出文件」独立可清理），需要新增导出结果文件清单接口；
  该能力实现前，预存目录保持只读，这是当前设计选择。
- 必须接线：`main.swift` 参数解析前加
  ```swift
  if CommandLine.arguments.contains("--storage-safety") {
      exit(StorageSafetyTests.run(verbose: true) ? 0 : 1)
  }
  ```
  建议 `verify.sh` 追加 `./.build/debug/pkd-selftest --storage-safety` 并计入 `FAILED`。
- 验收顺序：Debug build → `pkd-selftest`(161) → `--storage-safety`(129) → Release build → 前台清单。

## 6. 前台交互验收（待补，本轮未执行、不声称通过）

本轮只做后台/离屏验证：不激活前台、不发送真实键鼠事件、不切换壁纸、不改 TCC。待补：

- [ ] 真实点击确认面板「移到废纸篓」与「取消」；
- [ ] Esc / 关闭面板 / 窗口关闭按钮等同取消；
- [ ] 长路径清单滚动、换行、文本选中；
- [ ] 只读条目点选无高亮、右键无「移到废纸篓」；
- [ ] Return 不触发破坏性操作；
- [ ] 正式 app 存储页首次扫描、告警条、清理结果提示。

未完成前不应对外声称「UI 验收通过」。

## 7. 限制与未覆盖

- **不改变历史事故结论**：本批修复的是同类风险面，仍缺确认动作执行者、`~/.Trash` 实际内容（TCC）、副本骤减窗口内的外部操作记录。
- 内容指纹不覆盖「大小与 mtime 均不变的内容改写」、xattr/ACL；>2 万条目只读；存在极小 TOCTOU 窗口。
- 预存目录即使导出后仍只读（缺逐文件 manifest 证明）；用户若要清理这类目录需人工在 Finder 处理。
- owned 目录导出后若被用户放入文件 → 只读（需移除新增文件或重新导出且重新通过可信快照；导出本身不会在不一致时刷新）。
- 升级前的旧产物若只有历史路径/旧格式记录 → 只读。
- `isSafeToTrash/trash` 旧接口保留给自测 CLI，只做路径白名单；界面流程一律 `makePlan` + `execute`。
- 本轮未安装/未运行 GUI、未激活前台、未发真实键鼠、未改 TCC、未切壁纸；未触碰真实用户目录与真实废纸篓。

## 8. 备份与留档

- 上一批改动前备份：`app/.build/data-safety-backup-20261106-195206/`
- 本轮加固前快照：`app/.build/data-safety-review-backup-<时间戳>/`
- 证据目录：`app/.build/storage-safety-<时间戳>/`

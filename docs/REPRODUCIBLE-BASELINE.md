# 可重复合成基线（替代已丢失的 extracted/<历史基线目录>）

本文记录 2026-11-06 建立的**仓库可重复合成基线**。它替代已不可恢复的真实解包基线，用于在干净
checkout 中验证 RePKG 解包链路（PKG 读取、TEX→PNG 转换、直通文件、sidecar 元数据）的逐文件
字节与像素行为。

## 结论（先看这一段）

- **原真实基线 `extracted/<历史基线目录>` 不可恢复**。该目录被 `.gitignore` 忽略且已从本机消失；
  原素材是受版权保护的 Workshop 内容，未入库。**本轮没有、也无法重新验证原基线，不得声称原基线通过。**
- 新增的合成基线可在干净 checkout 用 `bash tools/dev/baseline-verify.sh` 复跑，本次实测
  **29 项检查全部通过**（三次独立运行，其中一次为含本文档的最终快照，见下方证据表）。
- 真实素材的「43 个输出文件路径与 SHA-256 全部一致」只是**历史记录**，仅保留为**已脱敏**的
  元数据清单
  （[real-43-file-regression-manifest.json](../tools/testdata/real-43-file-regression-manifest.json)），
  不包含任何素材内容，也无法在当前仓库重跑。

## 三种基线必须区分

| 基线 | 状态 | 位置 | 能否在当前仓库重跑 |
| --- | --- | --- | --- |
| 原真实基线 `extracted/<历史基线目录>` | **不可恢复**（gitignored，已不存在） | 无 | ❌ 不能；本轮未验证 |
| 真实 43 文件历史回归记录 | 仅历史元数据（已脱敏路径 + SHA-256） | `tools/testdata/real-43-file-regression-manifest.json` | ❌ 不能（缺真实素材与两版引擎运行快照） |
| 新合成可重复基线 | 可跑、可重复、独立期望 | `tools/testdata/baseline-scene/`、`tools/testdata/baseline-scene.expected.json` | ✅ 能（见下） |

## 新基线组成

| 文件 | 作用 |
| --- | --- |
| `tools/testdata/make_baseline_pkg.py` | 纯标准库确定性生成器：生成合成 `scene.pkg` + 旁置 `project.json` |
| `tools/testdata/baseline-scene/scene.pkg` | 已入库夹具（3052 字节；含 14 个条目） |
| `tools/testdata/baseline-scene/project.json` | 供 `repkg extract -c` 复制的项目元数据（145 字节） |
| `tools/testdata/baseline-scene.expected.json` | 期望清单：21 个输出文件路径 + SHA-256 + 引擎版本 + 纹理期望摘要 |
| `tools/dev/baseline_check.py` | 检查器：逐文件比对、独立像素/结构断言、两次解包、篡改检测 |
| `tools/dev/baseline-verify.sh` | 一键入口：前置检查（缺失非零退出）→ 调用检查器 → 输出证据目录 |
| `tools/testdata/real-43-file-regression-manifest.json` | 真实 43 文件历史记录的**元数据清单**（已脱敏路径 + SHA-256，不含内容） |

夹具内容（全部由生成器已知输入决定）：

- `scene.json`（含 2 个对象）、`models/quad.json`、`models/puppet.json`、`models/puppet.mdl`
- `materials/quad.json`、`materials/puppet.json`、`materials/xray.json`、`effects/xray/effect.json`
- `shaders/xray.vert`、`shaders/xray.frag`
- 3 张纹理：`materials/quad.tex`（8×8 RGBA8888 四象限纯色）、
  `materials/puppet.tex`（8×8 RGBA8888 左右两半，含 alpha=128）、
  `materials/dxt5.tex`（4×4 DXT5，RGB565 纯红端点）
- 1 张直通图片：`materials/overlay.png`（4×4 纯白，由生成器直接写入 PNG）

解包输出为 21 个文件，按来源拆分如下（不重复计数）：

- 14 个包内条目**原样直通**（其中已包含 3 个 `.tex` 原文件）；
- 3 张 TEX **额外转换**出的 3 个 `.png` + 3 个 `.tex-json` sidecar（`.tex` 本身属于上面的直通条目，
  不再重复计）；
- `-c` 复制的 1 个 `project.json`。

即 **14 + 3 + 3 + 1 = 21**。夹具与清单合计 7,083 字节（`scene.pkg` 3,052 + `project.json` 145 +
期望清单 3,886），本轮新增的入库文件合计 70,323 字节（约 69 KB，远小于 2 MB 上限）。

## 干净 checkout 的完整命令

```bash
git clone https://github.com/ZEH-Denia/mirage-unpacker-macos.git
cd mirage-unpacker-macos

# 基线唯一需要单独准备的依赖：RePKG 引擎
# tools/bin/ 被 .gitignore 忽略，需按 README 构建（Apple Silicon）
./tools/build-repkg.sh

# 一键验收（退出码 0 通过 / 1 检查失败 / 2 前置条件缺失）
bash tools/dev/baseline-verify.sh
```

可选项：

```bash
REPKG=/path/to/repkg bash tools/dev/baseline-verify.sh   # 指定已有引擎
BASELINE_WORK_DIR=/tmp/my-evidence bash tools/dev/baseline-verify.sh  # 指定证据目录
```

脚本默认把证据写到 `app/.build/baseline-<时间戳>/`（gitignored），包含两次解包日志、
`report.json`、`generated/`、`tampered/` 等。

**前置条件缺失时脚本以退出码 2 结束并说明原因，不会静默跳过**：缺 `python3`（需 3.8+）、
缺 `tools/bin/repkg`、缺已入库夹具/生成器/清单都会直接报错。`tools/bin/repkg` 是 Git 忽略的
本地构建产物，这是干净 checkout 唯一需要额外准备的东西（由 `./tools/build-repkg.sh` 重建）。

## 检查内容（29 项）

1. 夹具与生成器：入库 `scene.pkg` 的 SHA-256 与清单一致；生成器重新生成的文件与入库文件
   **逐字节一致**（确定性的直接证据）。
2. 引擎身份：`repkg version`（stderr）与清单记录的版本一致；不一致直接失败，防止引擎升级后
   悄悄改变输出哈希。
3. 解包真实行为：进程退出码 0；日志含完成哨兵 `Done`；无 `Failed`/`Exception`；输出非空
   （引擎退出码恒 0，所以成败判定同时看日志哨兵）。
4. 逐文件比对：输出文件数、路径集合、每个文件 SHA-256 全部与期望清单一致
   （21 个文件，无缺失、无多余、无不一致）。
5. 独立期望（期望不取自 RePKG 输出）：
   - 包内 14 个条目在输出中**逐字节等于生成器写入的字节**（纹理、模型、JSON、着色器、直通 PNG）；
   - `-c` 复制的 `project.json` 逐字节等于生成器内容；
   - 3 个 `.tex-json` 的 `format` 由纹理头 format 字段推导（rgba8888 / dxt5），`nomip` 由
     `mipmapCount=1` 推导，键集合固定为 6 个；
   - `quad.png` 尺寸 8×8 且全部 64 个像素等于生成器四象限颜色；
   - `puppet.png` 尺寸 8×8 且全部 64 个像素等于生成器左右两半颜色（含 alpha=128 直通）；
   - `dxt5.png` 尺寸 4×4 且全部像素等于由 RGB565 端点（`0xF800`）按 5/6 位扩展公式推导的纯红 RGBA；
   - `overlay.png` 尺寸 4×4 且全部像素等于生成器已知纯白。
6. 可重复性：在两个独立目录各解包一次，21 个文件的 SHA-256 映射完全相同，且都匹配期望清单。
7. 篡改检测：复制一份输出，改动 `shaders/xray.vert` 与 `materials/quad.png` 的首字节后，
   比对必须报错并指出这两个文件（证明比对真的在校验内容，而不是只数文件）。

### 期望值来源（为什么不是「先跑再记」）

- **像素/结构期望**由生成器常量与格式语义推导：`QUAD_COLORS`、`PUPPET_LEFT/RIGHT`、
  `DXT5_RGB565`（5 位扩展 `(v<<3)|(v>>2)`、6 位扩展 `(v<<2)|(v>>4)`）、`OVERLAY_COLOR`、
  纹理头字段、包内条目字节。检查器直接 import 生成器读取这些值。
- **SHA-256 清单**是引擎输出的黄金快照（golden），用于锁定字节级回归；它始终与上述独立断言
  一起校验，任一不符都失败。

引擎升级后的更新流程（默认保护不变：版本不符直接失败）：

```bash
# 1) 直接更新会被拒绝（引擎版本与清单不一致 → exit 1，不会写盘）
python3 tools/dev/baseline_check.py --repo . --update-manifest

# 2) 人工确认换引擎后显式允许：先跑完全部独立断言，全部通过才重写 SHA-256 golden
python3 tools/dev/baseline_check.py --repo . --update-manifest --allow-engine-version-change

# 3) 复核输出差异、提交新清单，再执行验收
bash tools/dev/baseline-verify.sh
```

`--allow-engine-version-change` **只能与 `--update-manifest` 同时使用**（单独使用会参数报错并
exit 2）；即使允许换版本，独立像素/结构断言仍必须全部通过才写盘，验收模式（不带
`--update-manifest`）始终要求引擎版本与清单一致。

## 证据表（通过 / 失败 / 未验证）

干净快照构造：`git archive HEAD`（473ca4b，不含 `.git`、`extracted/`、`app/.build/`、
`tools/bin/`）解到 `app/.build/baseline-20261106-195915/clean-repo/`，再加入本轮新增的
入库文件，并单独放入按 `./tools/build-repkg.sh` 构建的 `tools/bin/repkg`（Git 忽略，故不能
随 checkout 提供）。三次完整运行分别写 `run-1/`、`run-2/`、`run-3/`。

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| 干净快照（无 `.git`/`extracted/`/`app/.build`）中跑通合成基线 | ✅ 通过 | `app/.build/baseline-20261106-195915/run-1.log`、`run-1/report.json`（29/29） |
| 同一快照第二次独立运行 | ✅ 通过 | `.../run-2.log`、`run-2/report.json`（29/29） |
| 含本文档的最终快照第三次独立运行 | ✅ 通过 | `.../run-3.log`、`run-3/report.json`（29/29） |
| 三次运行的 21 文件 SHA-256 映射一致 | ✅ 通过 | 规范化映射 SHA-256 均为 `80ae4b9c…b650a0` |
| 篡改 2 个输出文件后比对报错 | ✅ 通过 | 见 `report.json` 的「篡改检测」两项 |
| 缺 RePKG 引擎时非零退出（不静默跳过） | ✅ 通过（exit 2） | `.../preflight-missing-engine.log` |
| 缺期望清单时非零退出（不静默跳过） | ✅ 通过（exit 2） | `.../preflight-missing-manifest.log` |
| 引擎版本与清单不符时默认快速失败 | ✅ 通过（exit 1，仅版本检查失败） | `.../flow-a.log` |
| `--update-manifest` 未显式允许版本变更时拒绝写盘 | ✅ 通过（exit 1，清单保持伪版本未被改写） | `.../flow-b.log` |
| `--allow-engine-version-change` 单独使用报参数错误 | ✅ 通过（exit 2） | `.../flow-c.log` |
| 显式允许后重写清单，随后验收通过 | ✅ 通过（写入后 29/29） | `.../flow-d.log`、`flow-e.log` |
| 重写出的清单与已入库清单逐字节一致（幂等） | ✅ 通过（`diff` 无输出） | `.../flow-f.log` |
| 生成器确定性（重新生成与入库逐字节一致） | ✅ 通过 | `report.json` 前两项检查 |
| 原真实基线 `extracted/<历史基线目录>` 复跑 | ❌ 不可执行/未验证 | 目录被 gitignore 且已不存在；真实素材不入库 |
| 真实 43 文件历史记录重跑 | ❌ 未验证/不可重跑 | 仅元数据清单；缺素材与两版引擎快照 |
| 覆盖真实版权素材与真实场景格式变体 | ❌ 未覆盖 | 见「已知局限」 |
| 其他引擎版本 / 其他 macOS / 其他 Python 版本 | ❌ 未验证 | 本次仅 macOS arm64、Python 3.9.9、引擎 `0.4.0+8005eb2` |

`flow-*.log` 是在临时副本中把清单引擎版本改成伪值后的流程测试，**没有改动已入库清单**：
先确认默认会失败/拒绝写盘，再确认显式允许后能更新并重新验收；`flow-f.log` 另外确认重写结果
与已入库清单逐字节一致。

## 对 verify.sh / CI 的集成建议（本次未修改 verify.sh）

现状问题：`app/scripts/verify.sh` 第 5 步在缺真实包或基线时打印 `⏭ 跳过`，不增加失败计数，
最终仍可能以 0 退出——回归保护实际依赖「本机恰好还有真实素材和基线」，干净 checkout 无法覆盖。

建议（按侵入程度从低到高，片段仅供参考，需由 `verify.sh` 所有者实施）：

1. **最小改动**：在第 4 步之后插入一步「合成基线」，失败必须计数：
   ```bash
   echo "==> 5/8 合成可重复基线"
   if bash "$REPO/tools/dev/baseline-verify.sh"; then
     pass "合成基线逐文件 + 像素 + 两次解包 + 篡改检测通过"
   else
     fail "合成基线未通过（见 app/.build/baseline-*/report.json）"
   fi
   ```
2. **把真实包比对改成显式可选**：缺真实素材时打印「未验证」而非「跳过」，并且只有显式
   授权（如 `PKD_REAL_BASELINE=1`）才进入比对；缺依赖时在总结里单独列出「未验证」项，
   不要让「跳过」等价于「通过」。
3. **CI**：在 CI 里先构建引擎（`./tools/build-repkg.sh`，需要 dotnet），再运行
   `bash tools/dev/baseline-verify.sh` 并以退出码为门禁（0 通过 / 1 失败 / 2 前置缺失），
   同时上传 `app/.build/baseline-*/` 作为证据工件。真实素材步骤在 CI 中应始终标记为「未验证」。
4. **失败语义**：任何被跳过的检查都应在结尾汇总为「N 项未验证」；退出码仍为 0 只允许出现在
   「所有检查都执行且通过」的情况。

## 已知局限

- **纯合成数据**：不覆盖真实版权素材、真实 Workshop 场景的格式变体（LZ4 压缩纹理、多级 mipmap、
  动画图集、视频包等），也不覆盖 43 文件历史记录的具体内容；真实素材只用于历史元数据清单。
- **引擎版本敏感**：转换后的 PNG 字节由 RePKG 内嵌的 ImageSharp 编码器产生，清单已绑定
  `0.4.0+8005eb2`。升级引擎后需人工复核输出差异再
  `--update-manifest --allow-engine-version-change`，否则脚本会失败。
- **引擎构建没有固定上游 commit**：`./tools/build-repkg.sh` 会 clone 上游 HEAD 再打
  `tools/repkg-macos.patch`，因此换机器/换时间构建出的引擎版本可能不同。此时本基线会因
  「引擎版本与清单不一致」**快速失败**——这是预期的保护，不是回归；集成时建议固定引擎 commit，
  或用 `REPKG=/path/to/同版本/repkg` 指定已验证版本的二进制。
- **real-43 清单的隐私说明**：`tools/testdata/real-43-file-regression-manifest.json` 只收录
  **已脱敏**的真实素材相对路径与 SHA-256 哈希，**不含任何文件内容或素材副本**。文件名中的个人
  可识别部分已替换为稳定占位符（如 `materials/<redacted-shot-1>.tex`、
  `materials/<redacted-wechat-1>.png`，同一真实文件在 43 条中映射一致），目录结构与扩展名保留、
  SHA-256 不变；原始真实路径仅保存在本机 gitignored 的 `app/.build` 证据中，不随仓库分发。
- **未覆盖应用层**：X-Ray 图层识别、场景静态组合、JobQueue 等 Swift 逻辑不在本基线范围
  （仍由 `pkd-selftest` 与 `verify.sh` 其他步骤覆盖）。
- **`-c` 的 `preview.jpg` 复制未覆盖**：夹具未放 `preview.jpg`（无有效 JPEG 生成器），只验证了
  `project.json` 的复制。
- 仅在 macOS arm64 + Python 3.9.9 实测；脚本要求 Python ≥ 3.8，未在其他平台验证。

## 复现与重新生成

```bash
# 验收（干净 checkout；需先构建 tools/bin/repkg）
bash tools/dev/baseline-verify.sh

# 只看夹具本身能否确定性地重建（不需要引擎输出比对）
python3 tools/testdata/make_baseline_pkg.py /tmp/baseline-regen
cmp /tmp/baseline-regen/scene.pkg tools/testdata/baseline-scene/scene.pkg

# 引擎升级后重新记录 SHA-256 黄金快照（先通过全部独立断言才允许写盘）
python3 tools/dev/baseline_check.py --repo . --update-manifest
```

本轮证据目录：`app/.build/baseline-20261106-195915/`（`clean-repo/`、`run-1/`~`run-3/`、
三次运行的 `report.json` 与日志、`preflight-*.log`、`flow-*.log`（清单更新流程 5 步）、
`redaction-check.log`（real-43 清单脱敏检查）、`summary.json`、`commands.txt`、
`new-files.sha256`、`git-status.txt`；全部 gitignored）。

## 后台复核（2026-11-06 22:16）

按「后台检测优先」策略（不激活前台、不发真实键鼠、不切壁纸、不改 TCC）重新在干净 checkout 上执行：
`git archive HEAD` + 本轮新增文件 + `tools/bin/repkg`，`bash tools/dev/baseline-verify.sh` →
**exit 0、29/29 通过**。证据：`app/.build/offline-check-20261106-2216/baseline-clean.log`。
2026-11-07 在修复 LogSink（不涉及基线与生成器）后再次复跑：**29/29 通过**，证据
`app/.build/baseline-20261107-check/`。
本基线的全部检查均为后台/离屏执行，不依赖前台交互；原真实基线仍不可恢复、未声称通过。

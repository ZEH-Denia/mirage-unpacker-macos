# 应用内更新验收：隔离真实 E2E 与失败路径验证

- 执行人：update-e2e（任务 1+2）
- 执行时间：2026-11-06 19:54 – 20:20（Asia/Shanghai）
- 代码基线：`HEAD 473ca4b`（`chore: publish Sparkle appcast for 1.8.0`），工作区 `VERSION=1.8.1`（未提交）
- 环境：macOS 27.3（arm64）、Swift 6.4.2（CLT，无 Xcode）、Sparkle 2.10.1
- 结论：**成功路径完整走通（发现→下载→EdDSA 校验→安装→重启，1.8.0→1.8.1）；4 条失败路径经真实菜单与真实委托弹出「更新未能完成」；1 条安装失败被 Sparkle 的 Autoupdate 层拦截，未出现应用内弹窗（如实记录）**
- `app/Sources/PKDApp/UpdateManager.swift` **2026-11-06 未修改**（当时证据不足以证明缺陷，理由见 §7）；2026-11-07 按新授权接入持久恢复模块，见 §12

所有证据在 `app/.build/update-e2e-20261106-195511/`（gitignored），脚本在 `tools/dev/update-*`。
用户数据、偏好、`/Applications/PKD.app`、`updates/appcast.xml` 均已核对未变（§9）。

---

## 1. 结论表

| # | 用例 | 结果 | 关键证据 |
|---|---|---|---|
| S | 成功更新 1.8.0 → 1.8.1（官方 app → 本地签名 feed） | **通过** | `evidence/ax-update-available.txt`、`ax-installing.txt`、`postinstall-app.sha256`、`SELECTED-LOGS.txt` |
| S2 | 更新后运行态版本 / 路径 / 签名 / 用户数据 | **通过** | `evidence/main-window-after-update.png`、`ax-after-update-uptodate-check.txt`、`snapshots/userdata-*`、`/Applications` 哈希对比 |
| F1 | feed 不可达（端口关闭，connection refused） | **通过** | `evidence/ax-f1-feed-unreachable-*.dump`、`ax-f1-app-alert.txt`、`screenshot-f1-app-alert.png` |
| F2 | feed HTTP 500 | **通过** | `evidence/ax-f2-http500-sparkle.txt`、`ax-f2-http500-app-alert.txt`、`logs/http500.log` |
| F3 | appcast 签名被篡改 | **通过** | `evidence/ax-f3-tampered-appcast-sparkle.txt`、`-app-alert.txt` |
| F4 | DMG 被篡改（appcast 合法、包内 EdDSA 不匹配） | **通过** | `evidence/ax-f4-tampered-dmg-sparkle.txt`、`-app-alert.txt`、`SELECTED-LOGS.txt` |
| F5 | 安装失败（隔离安装父目录只读） | **部分通过**：真实安装失败被触发（Autoupdate `renamex_np … Operation not permitted`），但**没有**应用内「更新未能完成」弹窗——app 进程已被 Sparkle 终止，委托无从回调。旧 app 完好 | `evidence/ax-f5-install-readonly-sparkle.txt`、`ax-f5-install-readonly-current.txt`（AX `NO_MATCHING_WINDOW`）、`SELECTED-LOGS.txt`（Autoupdate EPERM）；app 进程消失见 §5 说明（当时未把 `ps` 输出落盘，现无残留进程） |
| G | 「前往 GitHub 手动下载」指向的 releases/latest 可达并跳 v1.8.0 | **通过** | `evidence/github-url-reachability.txt`（302 → `/releases/tag/v1.8.0` → 200） |
| G2 | 1.8.0 DMG 资产 URL 可达 | **通过** | 同上（302 → `release-assets.githubusercontent.com`，`206` + 1024 字节；`HEAD 200`） |
| G3 | 弹窗按钮确实存在且绑定该 URL | **通过（部分实测）**：AX 读到按钮 `前往 GitHub 手动下载`；硬编码字面量在发布二进制中存在；**未真的点击**（避免接管用户浏览器），URL 可达性用 curl 验证 | `ax-f1-app-alert.txt`、`grep -a` 输出见 §6 |
| R | 未更新场景（已是最新 1.8.1）不应弹失败框 | **通过** | `evidence/ax-after-update-uptodate-check.txt`（Sparkle「您使用的就是最新版！」；**没有**「更新未能完成」） |
| — | 后台自动检查 / 增量更新 / release notes / 公证门禁 | **未验证** | 见 §8 |

---

## 2. 隔离方式

### 2.1 目录（全部在 gitignored 的 `app/.build/update-e2e-20261106-195511/`）

```
installed/PKD.app/            官方 1.8.0 副本（从官方 DMG 复制），更新后变 1.8.1；测试唯一被写/替换的 app
feed/                         1.8.1 用的本地 feed（DMG + EdDSA 签名 appcast.xml），HTTP 服务根
faults/candidate-1.8.2/       合成 1.8.2 测试包（= 1.8.1 构建 + plutil 改版本 + ad-hoc 重签），仅用于故障注入
faults/feed-1.8.2/            合法 1.8.2 feed
faults/feed-tampered-appcast/ 篡改过 title 的 appcast（签名必然失效）
faults/feed-tampered-dmg/     合法 appcast + 翻转 1 字节（XOR 0xFF）的 DMG（长度不变）
faults/feed-install-fail/     合法 1.8.2 feed（用于只读安装父目录用例）
logs/                         app stdout/stderr、各 HTTP 服务日志、Sparkle os_log 全量、关键时间点
evidence/                     AX dump、截图、哈希清单、汇总日志
snapshots/                    测试前后 defaults 与 ~/Library/Application Support/PKD 快照
bin/                          编译后的 AX 工具（update-ax / update-window-id）
```

### 2.2 被更新的 app 来自哪里

- `app/dist/Mirage-Unpacker-for-macOS-1.8.0.dmg`（官方资产，SHA-256 `f1e01a065f48a49442ac8548c52b47f75a6211f80ed8ad72039a00321e9a987d`，与 Lead 核实的 GitHub 下载件一致）；
  `hdiutil attach -nobrowse -readonly` 到隔离挂载点后 `ditto` 出 `PKD.app`，随即卸载。
- 隔离副本版本 `1.8.0`，`codesign --verify --deep --strict` 通过，签名 `adhoc`，`CFBundleIdentifier=com.zeh.pkd`，95 个文件（`evidence/installed-180.sha256`）。
- **新包**：`app/dist/PKD.app`（今日 18:59 构建，`CFBundleShortVersionString=1.8.1`）；其 DMG `app/dist/Mirage-Unpacker-for-macOS-1.8.1.dmg` 内 app 与 `dist/PKD.app` **逐文件哈希完全一致**（本次实测 `diff` 为空）。

### 2.3 签名（私钥未导出）

- 私钥仅在登录钥匙串（`svce=https://sparkle-project.org`，`acct=ed25519`），公钥与 `Info.plist` 模板的 `SUPublicEDKey`（`9BA+eKQTU6UavJtkXrrveh85eVs4hlYKheV5F/XSAKk=`）一致（钥匙串条目注释亦如此）。
- `sign_update` / `generate_appcast` 直接读钥匙串，**全程无 GUI 授权弹窗、未导出/备份私钥**：
  - `sign_update -p /tmp/su-probe.txt` → 退出 0、输出 88 字符签名；
  - `generate_appcast --account ed25519 …` → 退出 0，写出带 `<!-- sparkle-signatures: … -->` 的 appcast。

### 2.4 让未改动的官方 app 走本地 feed

Sparkle 2.10.1 的 `SPUUpdater` 接受 user defaults 覆盖 `SUFeedURL`（`app/.build/checkouts/Sparkle/SPUUpdater.m:1155` 附近）。实测日志确认：

```
PKD[84321] The feed URL (http://127.0.0.1:18731/appcast.xml) may need to change to use HTTPS…
PKD[84321] Warning: A feed URL was found stored in user defaults for PKD 解包器…
```

同时本地 `http://127.0.0.1` **未被 ATS 拦截**（先用最小 app bundle + `URLSession` 探针确认，`OK: status=200`）。

> 另：测试中 AX 点击一度误触 Sparkle 弹窗的「以后自动下载并安装更新」复选框，产生 `SUAutomaticallyUpdate=1`（测试副作用，收尾已删除，见 §3 注与 §9）。

> ⚠️ 该覆盖写在用户真实域 `com.zeh.pkd`。本次测试前已快照 `defaults read` 与 `com.zeh.pkd.plist`，结束时删除测试键并逐字核对（§9）。测试期间**没有**与其它 agent 并发写该域。

### 2.5 UI 驱动（按 PID/窗口，不做全局盲点）

- `tools/dev/update-ax.swift`：AX 树 dump（role/title/value/description/identifier/frame）+ 按 role/title 精确/子串匹配派发 `kAXPressAction`；先精确后子串，避免「安装更新」命中「以后自动下载并安装更新」复选框。
- `tools/dev/update-window-id.swift`：取该 PID 的 `CGWindowID`，配合 `screencapture -l<id>` 截**指定窗口**（不截屏猜区域）。
- `tools/dev/update-run-case.sh`：设定 `SUFeedURL` → 点击真实菜单项「检查更新…」→ 轮询窗口 → 关闭 Sparkle 自带对话框 → 读到产品 SwiftUI 弹窗 → dump/截图。
- 菜单项通过 `System Events` 按 `unix id` 定位进程后点击；AX 读取的是**运行时真实控件树**，不是脚本里预设的字符串。

---

## 3. 可重复命令

以下命令均为本次实际执行过的形态（`$E2E` 为证据目录）。

> 例外：清理段里的 `defaults delete com.zeh.pkd SUAutomaticallyUpdate` **没有**对应的 `defaults write`——`SUAutomaticallyUpdate=1` 是测试过程中 AX 点击的子串匹配误触了 Sparkle 弹窗里的「以后自动下载并安装更新」复选框所产生的（测试副作用，不是脚本设定），收尾时删除并在 §9 核对。从零复现本用例不需要写该键。

```bash
cd /path/to/mirage-unpacker-macos
E2E="$PWD/app/.build/update-e2e-20261106-195511"
SP="$PWD/app/.build/artifacts/Sparkle/Sparkle/bin"

# --- 0) 快照用户数据与默认域（先做，后做）---
mkdir -p "$E2E/snapshots/userdata-before"
cp -a "$HOME/Library/Application Support/PKD" "$E2E/snapshots/userdata-before/"
cp -a "$HOME/Library/Preferences/com.zeh.pkd.plist" "$E2E/snapshots/userdata-before/"
(cd "$HOME/Library/Application Support/PKD" && shasum -a 256 *) > "$E2E/snapshots/userdata-before/SHA256SUMS"
shasum -a 256 "$HOME/Library/Preferences/com.zeh.pkd.plist" >> "$E2E/snapshots/userdata-before/SHA256SUMS"
defaults read com.zeh.pkd > "$E2E/snapshots/defaults-before.txt"

# --- 1) 从官方 1.8.0 DMG 部署隔离副本（绝不写 /Applications）---
mkdir -p "$E2E/mnt-180" "$E2E/installed"
hdiutil attach -nobrowse -readonly -mountpoint "$E2E/mnt-180" app/dist/Mirage-Unpacker-for-macOS-1.8.0.dmg
ditto "$E2E/mnt-180/PKD.app" "$E2E/installed/PKD.app"
diskutil eject "$E2E/mnt-180"
codesign --verify --deep --strict "$E2E/installed/PKD.app"

# --- 2) 生成并自检本地签名 feed（私钥仅在钥匙串）---
PORT=18731
cp app/dist/Mirage-Unpacker-for-macOS-1.8.1.dmg "$E2E/feed/"
"$SP/generate_appcast" --account ed25519 --download-url-prefix "http://127.0.0.1:$PORT/" "$E2E/feed"
"$SP/sign_update" --verify "$E2E/feed/appcast.xml"                       # 退出 0
SIG=$(python3 -c "import re;print(re.search(r'sparkle:edSignature=\"([^\"]+)\"',open('$E2E/feed/appcast.xml').read()).group(1))")
"$SP/sign_update" --verify "$E2E/feed/Mirage-Unpacker-for-macOS-1.8.1.dmg" "$SIG"   # 退出 0

# --- 3) 起本地 HTTP feed（仅 127.0.0.1）---
nohup python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$E2E/feed" \
  > "$E2E/logs/http-feed.log" 2>&1 &

# --- 4) 采集 Sparkle 日志 + 指向本地 feed + 启动隔离副本 ---
log stream --style compact --predicate 'subsystem == "org.sparkle-project.Sparkle"' \
  > "$E2E/logs/sparkle-oslog-e2e.log" 2>&1 &
defaults write com.zeh.pkd SUFeedURL -string "http://127.0.0.1:$PORT/appcast.xml"
open -n --stdout "$E2E/logs/app-stdout.log" --stderr "$E2E/logs/app-stderr.log" "$E2E/installed/PKD.app"
PID=$(pgrep -f "update-e2e-20261106-195511/installed/PKD.app/Contents/MacOS/PKD" | head -1)

# --- 5) 编译 AX 工具并驱动真实菜单 ---
tools/dev/update-e2e-build-tools.sh "$E2E"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to click menu item \"检查更新…\" of menu 1 of menu bar item 2 of menu bar 1"
"$E2E/bin/update-ax" "$PID" windows
"$E2E/bin/update-ax" "$PID" dump --window-title "软件更新" --max-depth 8
"$E2E/bin/update-ax" "$PID" press button 安装更新 --window-title "软件更新"
"$E2E/bin/update-ax" "$PID" press button 安装并重启应用 --window-title "正在更新"

# --- 6) 失败路径：合成 1.8.2 候选包 + 各故障 feed ---
tools/dev/update-make-fault-feed.sh "$E2E/faults" 1.8.2 "$PORT"

# F1 feed 不可达：指向从未监听的端口
tools/dev/update-run-case.sh "$PID" f1-feed-unreachable "http://127.0.0.1:18732/appcast.xml" "$E2E/evidence" appcast

# F2 HTTP 500
nohup python3 tools/dev/update-fault-server.py http500 18733 "$E2E/faults/feed-1.8.2" \
  > "$E2E/logs/http500.log" 2>&1 &
tools/dev/update-run-case.sh "$PID" f2-http500 "http://127.0.0.1:18733/appcast.xml" "$E2E/evidence" appcast

# F3 篡改 appcast（改 title 使签名失效；sign_update --verify 退出 1）
tools/dev/update-run-case.sh "$PID" f3-tampered-appcast "http://127.0.0.1:18734/appcast.xml" "$E2E/evidence" appcast

# F4 合法 appcast + 篡改 DMG（第 5000000 字节 XOR 0xFF，长度不变；EdDSA 校验失效）
tools/dev/update-run-case.sh "$PID" f4-tampered-dmg "http://127.0.0.1:18735/appcast.xml" "$E2E/evidence" download

# F5 安装父目录只读 → 真实安装失败
chmod 555 "$E2E/installed"
tools/dev/update-run-case.sh "$PID" f5-install-readonly "http://127.0.0.1:18736/appcast.xml" "$E2E/evidence" download
chmod 755 "$E2E/installed"

# --- 7) 收尾（顺序重要：先停服务/进程，再恢复 defaults 与数据）---
for p in 18731 18733 18734 18735 18736; do
  pid=$(lsof -nP -iTCP:"$p" -sTCP:LISTEN -t 2>/dev/null); [ -n "$pid" ] && kill "$pid"; done
defaults delete com.zeh.pkd SUFeedURL
# 该键来自测试中误勾选「以后自动下载并安装更新」复选框，不是本脚本写入（见上方说明）
defaults delete com.zeh.pkd SUAutomaticallyUpdate
defaults write com.zeh.pkd SULastCheckTime -date "2026-11-06 11:00:52 +0000"   # 原值
defaults read com.zeh.pkd | diff "$E2E/snapshots/defaults-before.txt" -          # 应为空
```

`generate_appcast` 生成的 appcast 自带签名尾部；`updates/appcast.xml`（仓库里的发布 feed）**全程未被写入**：
`shasum -a 256 updates/appcast.xml` = `cc4da11241dfe7eb1ed47fc992c0df81447276ef8f6fe213e2580e537f32870b`，与 `git show HEAD:updates/appcast.xml` 一致。

---

## 4. 成功路径证据（S / S2）

### 4.1 时间线

| 时间 | 事件 | 证据 |
|---|---|---|
| 19:57:21 | 隔离 1.8.0 启动（PID 84321） | `logs/e2e-launch.time`、`logs/app.pid` |
| 19:57:22 | Sparkle 读到 defaults 里的本地 `SUFeedURL` | `logs/sparkle-oslog-e2e.log` |
| 19:57:42 | 点击真实菜单「检查更新…」；appcast 拉取并通过 EdDSA | `logs/click-check.time`、`… OK: EdDSA signature is correct for appcast` |
| 19:57:4x | Sparkle「软件更新」窗：`PKD 解包器 1.8.1可供下载，您现在的版本是1.8.0。` | `evidence/ax-update-available.txt`、`sparkle-dialog-update-available.png` |
| 19:58:4x | 点「安装更新」；下载于 19:58:52 完成并通过包 EdDSA | `… OK: EdDSA signature is correct for update` |
| 19:58:5x | 「正在更新PKD 解包器 / 可以开始安装了 / 安装并重启应用」 | `evidence/ax-installing.txt`、`sparkle-dialog-installing.png` |
| 20:00:01 | 点「安装并重启应用」（AX 返回 `-25204`，因窗口随即销毁；实际已生效） | `logs/click-install-relaunch.time` |
| 20:00:04 | 新进程 PID 87241 启动 | `logs/sparkle-oslog-e2e.log`（`PKD[87241]`） |

### 4.2 更新结果核对

| 检查项 | 结果 | 证据 |
|---|---|---|
| `CFBundleShortVersionString` | 1.8.0 → **1.8.1**（`CFBundleVersion` 同为 1.8.1） | `installed/PKD.app/Contents/Info.plist` |
| 安装路径不变 | 仍是 `$E2E/installed/PKD.app`（bundle 目录 mtime 19:58，内容整体替换） | `ls -ld` |
| 代码签名 | `codesign --verify --deep --strict` 通过；`Identifier=com.zeh.pkd`、`Signature=adhoc`；`spctl -a -vvv` 返回 accepted，但同机输出带 `override=security disabled`（本机关闭了 Gatekeeper 强制，**不代表**通过公证/Developer ID 校验） | 同左 |
| 内容确实是 feed 里的包 | 安装后 95 个文件 SHA-256 **与 feed 中 1.8.1 DMG 内 app 逐文件一致**（`diff` 为空） | `evidence/postinstall-app.sha256` vs `dmg181.sha` |
| 运行态版本 | 更新后 `installed/PKD.app` 的 `CFBundleShortVersionString` 与 `CFBundleVersion` 均为 **1.8.1**；第二次检查更新时 Sparkle 自述「PKD 解包器 1.8.1是当前的最新版本。」（即运行中的 app 认为自己是 1.8.1） | `installed/PKD.app/Contents/Info.plist`、`ax-after-update-uptodate-check.txt` |
| 集合/历史 | `collections.json`、`history.json` 内容与 SHA-256 完全不变 | `snapshots/userdata-*` |
| 偏好 | 用户设置键全部保留；仅 Sparkle 记账键（`SULastCheckTime`）变化 + 测试键 | `evidence/defaults-diff-success.txt` |
| `/Applications/PKD.app` | 95 个文件哈希与测试前完全一致，未触碰 | `/tmp/applications-pkd-before.txt` vs after（§9） |
| 无更新时不应弹失败框 | 第二次手动检查：只有 Sparkle「您使用的就是最新版！」，**无**「更新未能完成」（`SUErrorNoUpdate` 被 UpdateManager 过滤） | `ax-after-update-uptodate-check.txt` |

---

## 5. 失败路径证据（F1–F5）

四条 appcast/下载阶段失败的共同形态（均为**真实产品路径**）：

1. 点击菜单「检查更新…」（`PKDApp.swift:49-53` 的 `updater.checkForUpdates()`）；
2. Sparkle 自身先弹错误框（`SPUStandardUserDriver`，AX `_NS:87` 警告框，按钮「取消更新」）；
3. 用户关闭该框后 update cycle 结束，`UpdateManager` 的 `updater(_:didFinishUpdateCycleFor:error:)`（`UpdateManager.swift:51-72`）收到 error；
4. 弹出产品 SwiftUI 弹窗：标题「更新未能完成」，正文含**当次真实错误文本**，按钮「前往 GitHub 手动下载」/「关闭」（AX `AXSheet`）。

> 说明：①「Sparkle 框 + 产品框」是两个弹窗，这是 Sparkle 标准用户驱动的行为，不是 UpdateManager 的 bug；②产品弹窗里的「原因：」按当次真实错误动态生成：F1/F2 同为 Sparkle 错误码 2001 的本地化文案（但底层根因不同，见日志），F3 是英文 `improperly signed` 原文，F4 是中文「此更新未正确签名…」，可排除写死文案。

| 用例 | 注入方式 | Sparkle 框（AX 实测） | 产品弹窗「原因：」（AX 实测） | Sparkle 日志 |
|---|---|---|---|---|
| F1 | `SUFeedURL=http://127.0.0.1:18732/appcast.xml`（无监听 → connection refused） | `更新错误！` / `获取升级信息时出现错误，请稍后再试。` / `取消更新` | `获取升级信息时出现错误，请稍后再试。` | `SUSparkleErrorDomain 2001`，底层 `NSURLError -1004 无法连接服务器` |
| F2 | 自建服务对所有请求回 500（`http://127.0.0.1:18733`） | 同上 | 同上（Sparkle 把 500 也归为 2001） | `internal server error (500)`；服务日志 `GET /appcast.xml HTTP/1.1 500` |
| F3 | 合法 appcast 改 `<title>` 使签名失效（`sign_update --verify` 报 `expected 1098, read 1116`） | `更新错误！` / `The update feed is improperly signed and could not be validated…` | 同左（英文原样） | `EdDSA signature does not match. … 1098 vs 1116` |
| F4 | 合法 appcast + DMG 第 5,000,000 字节翻转 1 字节（XOR 0xFF，长度不变） | 下载后 `更新错误！` / `此更新未正确签名，无法验证其真实性。请稍后再试或联系App开发者。` | 同左 | appcast EdDSA **OK** → 包 EdDSA 失败；并记录 `Developer ID code signing as fallback` 不可用（ad-hoc 无 TeamID） |
| F5 | 合法 1.8.2 feed + `chmod 555 $E2E/installed` | 走到「正在更新 → 可以开始安装了 → 安装并重启应用」 | **无产品弹窗** | `Autoupdate`：`Failed to renamex_np PKD.app with PKD.app.`（`NSPOSIXErrorDomain Code=1 Operation not permitted`）→ `Failed to finalize installation` |

F5 细节（如实记录，不标“通过弹窗”）：点击「安装并重启应用」后 app 进程（PID 87241）退出（当时未把 `ps` 输出落盘；事后 AX 返回 `NO_MATCHING_WINDOW`，`pgrep -f …/installed/PKD.app/Contents/MacOS/PKD` 无匹配），Autoupdate 在临时目录做替换失败；**旧 app 未被移动**，`chmod 755` 恢复后 95 文件哈希仍等于 `postinstall-app.sha256`、`codesign --verify --deep --strict` 仍通过、版本仍 1.8.1。也就是说：**安装阶段失败发生在 Sparkle 的独立 Autoupdate 进程里，产品进程已退出，`UpdateManager` 没有回调机会**，用户不会看到应用内提示。此点属 Sparkle 行为边界，不在本文件修复范围（§7/§8）。

原始 AX dump（全部为运行时读取，非脚本串）：
`evidence/ax-f1-feed-unreachable-after.txt.dump`、`ax-f1-app-alert.txt`、`ax-f2-http500-sparkle.txt`、`ax-f2-http500-app-alert.txt`、`ax-f3-tampered-appcast-sparkle.txt`、`ax-f3-tampered-appcast-app-alert.txt`、`ax-f4-tampered-dmg-sparkle.txt`、`ax-f4-tampered-dmg-app-alert.txt`、`ax-f5-install-readonly-sparkle.txt`，
截图 `evidence/screenshot-f*.png`、`window-f1-*.png`。

---

## 6. GitHub 手动下载回退可达性（G / G2 / G3）

- 按钮存在（AX）：`AXButton title="前往 GitHub 手动下载" id=action-button-1`（`evidence/ax-f1-app-alert.txt`）。
- 目标 URL 硬编码于 `UpdateManager.swift:18`，发布二进制中确实存在该字面量：
  `grep -a -o "https://github.com/ZEH-Denia/mirage-unpacker-macos/releases/latest" installed/PKD.app/Contents/MacOS/PKD` → 命中。
- `releases/latest`：`HTTP/2 302` → `location: …/releases/tag/v1.8.0` → 最终 `HTTP/2 200`（`evidence/github-url-reachability.txt`）。
- 资产 `…/releases/download/v1.8.0/Mirage-Unpacker-for-macOS-1.8.0.dmg`：`302` → `release-assets.githubusercontent.com`；带 `Range: 0-1023` 跟随后 `206`、`CONTENT_LENGTH=1024`；`HEAD` 最终 `200`。
- 未真的点击按钮：会调用 `NSWorkspace.shared.open`（`UpdateManager.swift:35-37`）接管用户默认浏览器；按任务约束只验证可达性与绑定关系。

---

## 7. 关于 `app/Sources/PKDApp/UpdateManager.swift`：2026-11-06 未修改（2026-11-07 见 §12）

判定依据（均有实测）：

1. **委托链正常**：四条失败用例都最终弹出了产品弹窗，说明 `didFinishUpdateCycleFor:error:` 被正确调用；重复 4 次手动检查仍能弹（第 1 次的失败不会让 `manualCheckInProgress`/`updateAttemptInProgress` 卡死）。
2. **无更新不误报**：`SUErrorNoUpdate(1001)` 被过滤，实测只显示 Sparkle「您使用的就是最新版！」。
3. **用户取消不误报**：代码对 `4007`（用户取消安装）也做了过滤（本次未构造该场景，属未验证项，但代码路径与已实测的 1001 同形）。
4. **F5 无弹窗的原因不在本文件**：`Autoupdate` 是独立进程，失败时宿主 app 已退出；`SPUUpdaterDelegate` 的 `didAbortWithError` 也在同一宿主进程内，无法解决。
5. `didFinishUpdateCycleFor` 的 `updateCheck.rawValue == 0` 判断与 Sparkle 定义一致（`SPUUpdateCheck.h`：`SPUUpdateCheckUpdates = 0` 即用户主动检查）。

因此**不做改动**，避免在无缺陷证据时引入回归。可选（非必需）增强见 §8 第 1 条。

---

## 8. 对非本人文件的集成建议（精确位置）

> 这些文件在 2026-11-06 不在本任务写入范围，均未修改；2026-11-07 仅 `UpdateManager.swift` 按新授权接入 `UpdateRecovery`（§12），其余建议仍由对应 owner 决定。

1. **`app/Sources/PKDApp/UpdateManager.swift:39-45`（本任务拥有）** — 可选：实现
   `func updater(_ updater: SPUUpdater, didAbortWithError error: Error)` 仅写日志。
   Sparkle 会**先**调 `didAbortWithError` 再调 `didFinishUpdateCycleFor:error:`（`SPUUpdater.m:802-812`），对用户可见行为无影响，只便于现场取证。当前无需改动。

2. **`app/Sources/PKDApp/PKDApp.swift:35-44`** — 弹窗 UI 不变即可用。若要消除「Sparkle 自带错误框 + 产品弹窗」双弹窗，只能自定义 `SPUUserDriver`（成本高、易引入回归），建议**保持现状**，改为在文档里说明（见下一条）。

3. **`README.md`「发布应用内更新」小节（当前 104-118 行）** — 建议新增两段：
   - 本地 feed 自测：`defaults write com.zeh.pkd SUFeedURL http://127.0.0.1:<port>/appcast.xml`，测完 `defaults delete com.zeh.pkd SUFeedURL`（否则会一直走测试 feed；`SUFeedURL` 只用于测试，不应进发布物）。
   - 失败语义：ad-hoc 签名没有 Developer ID 回退（Sparkle 日志会明确写 “The download archive cannot be validated with Apple Developer ID code signing as fallback”），且**安装阶段**失败由 Sparkle 的 Autoupdate 进程处理，应用可能直接退出且没有应用内提示。

4. **`README.md`「已知限制」小节（当前 322 行起）** — 建议加 1 条：
   「应用内更新失败时会先出现 Sparkle 自身的错误框，关闭后才出现带 GitHub 手动下载入口的提示；若失败发生在最后的安装替换阶段，应用可能退出且不显示应用内提示，请到 Releases 手动下载。」

5. **`app/scripts/generate-appcast.sh:29-30`** — 建议让下载前缀可覆盖，便于复用官方脚本做本地 E2E：
   ```bash
   DOWNLOAD_PREFIX="${PKD_APPCAST_PREFIX:-https://github.com/ZEH-Denia/mirage-unpacker-macos/releases/download/$TAG/}"
   ```
   （其余逻辑不变；发布时仍默认 GitHub 前缀）

6. **`app/scripts/verify.sh`（第 92 行「7/7 动画纹理」之后追加 8/8，仅建议）** —
   发布前才跑的低成本一致性检查，**不要**进日常回归（本地 `dist` 版本常高于已发布 feed）：
   ```bash
   echo "==> 8/8 发布签名/feed 一致性"
   ( cd "$ROOT/app" && codesign --verify --deep --strict dist/PKD.app ) || exit 1
   "$ROOT/app/.build/artifacts/Sparkle/Sparkle/bin/sign_update" --verify "$ROOT/updates/appcast.xml" || exit 1
   ```

7. **`docs/DEVELOPMENT-ACCEPTANCE.md`** — 建议在验收清单里加一行指向本文件：
   「应用内更新：见 `docs/UPDATE-FAILURE-VALIDATION.md`（隔离 E2E + 5 类失败路径 + 证据路径）」。

8. **`app/Resources/Info.plist.template:23-32`** — 无需改动。提醒：`SUFeedURL` 必须保持 GitHub Pages 正式地址，测试用 defaults 覆盖并**及时删除**；`SUPublicEDKey` 与 keychain 条目必须成对，换钥会导致旧安装无法验证。

---

## 9. 清理与恢复核对（已逐项验证）

| 项 | 结果 | 证据 |
|---|---|---|
| `com.zeh.pkd` 域恢复 | `defaults read` 与测试前快照**逐字相同**（`diff` 为空）；删除 `SUFeedURL`/`SUAutomaticallyUpdate`，`SULastCheckTime` 写回原值；plist 的 `plutil -convert xml1` 结果与快照**完全相同**（二进制容器因 cfprefsd 重写字节不同，语义一致） | `snapshots/defaults-before.txt` vs `defaults-restored.txt` |
| `~/Library/Application Support/PKD` | `collections.json` `c4f6ce…`、`history.json` `501010…` 与测试前一致 | `snapshots/userdata-after-final.txt` |
| `/Applications/PKD.app` | 95 文件哈希与测试前完全一致，仍 1.8.1，`ls -ld` 时间未变 | `/tmp/applications-pkd-before.txt` vs after |
| `updates/appcast.xml` | SHA-256 与 `HEAD` blob 相同 | `git show HEAD:updates/appcast.xml \| shasum -a 256` |
| 测试进程/服务/挂载 | 5 个 HTTP 服务已停（`lsof` 无 18731/18733/18734/18735/18736）、`log stream` 已停、无测试 app 进程、无测试挂载点 | 本节命令输出 |
| Sparkle 下载缓存 | `~/Library/Caches/com.zeh.pkd/org.sparkle-project.Sparkle/{Installation,PersistentDownloads}` 为空（失败用例后自行清理） | `find` 输出 |
| 仓库写入范围 | 2026-11-06 仅新增 `tools/dev/update-*.{swift,sh,py}`、`docs/UPDATE-FAILURE-VALIDATION.md`，证据在 `app/.build/update-e2e-*`；当时 `UpdateManager.swift` 未改（2026-11-07 见 §12） | `git status` |

> 保护文件说明：本次**没有**写 README/VERSION/JobQueue/ExperimentalPuppetPreview/PKDSelfTest/verify.sh/docs/make_render_scene.py。但会话期间保护清单里 `ExperimentalPuppetPreview.swift`（20:07）与 `PKDSelfTest/main.swift`（20:08）被其它 agent 修改，属并发工作，非本任务所为（`shasum -c` 对这 2 个文件报 FAILED）。`README.md`、`VERSION`、`verify.sh`、`make_render_scene.py`、`JobQueue.swift` 仍与保护哈希一致。

---

## 10. 限制与未覆盖

1. **只有 ad-hoc 签名链路**：本次新旧 app 都是 ad-hoc。Developer ID / 公证 / Gatekeeper 放行路径、以及 Sparkle 的「Developer ID 回退校验」全部**未验证**（F4 日志恰好证明该回退在 ad-hoc 下不可用）。
2. **没有真正安装到 `/Applications`**（任务禁止）：安装失败用例用隔离目录只读实现；需要管理员授权的安装（Sparkle 弹出授权框）未覆盖。
3. **安装阶段失败无应用内提示（F5）**：真实触发但产品弹窗不可达；这是边界事实，不是通过项。
4. **后台自动检查 / gentle reminders / 定时器**未验证：只走了用户主动「检查更新…」。若要覆盖，需要改写 `SULastCheckTime` 并等定时器触发，且会进一步污染偏好域。
5. **增量（delta）更新、release notes、`minimumSystemVersion`/架构门槛、跳过版本（skip）**未覆盖。
6. **网络类故障只做了 loopback 层**（连接拒绝、HTTP 500）。未做 DNS/超时/半途断流；未改系统代理/TCC（禁止）。
7. **Gatekeeper/quarantine**：本地生成的 DMG 与解出的 app 没有 `com.apple.quarantine` 属性，因此未经过「首次打开需允许」的真实路径。
8. **签名私钥**：只通过 `sign_update`/`generate_appcast` 使用；未验证 keychain ACL 变更或用例之外的工具。
9. 1.8.2 候选包是**合成测试包**（1.8.1 构建 + 版本号 + ad-hoc 重签），不是发布产物，也未上传任何远端。
10. 截图按 `CGWindowID` 抓整窗，体积较大（数 MB/张），如需归档可自行压缩。
11. `defaults` 的二进制 plist 字节因 cfprefsd 重写而变化，但 `defaults read` 与 XML 归一化内容完全一致；如需字节级还原，应在测试前用 `defaults export` 并在结束后 `defaults import`（注意 `import` 不会删除多出的键，仍需手工 `delete`）。
12. UI 自动化施力于测试副本自身窗口/菜单；测试窗口会短暂抢焦点（按 PID 定向，未操作其它 app）。

---

## 11. 后台复核状态（2026-11-06 22:15，按「后台检测优先」策略）

自 2026-11-06 22:14 起按用户新策略执行：**不抢占/激活前台、不向前台应用发送真实键鼠、不切换壁纸、不更改 TCC**；只做独立后台进程、离屏/隔离输出、AX 非激活动作和静态检查。此前 19:54–20:20 的 UI 证据保留为历史记录，但凡依赖前台交互的步骤，在新策略下重新列为「前台待补」，**不把新策略下的前台复验计为通过**。

### 11.1 本次纯后台复核（只读/离屏，均通过）

| 项 | 结果 | 证据 |
|---|---|---|
| 公开 feed 签名 | ✅ `sign_update --verify updates/appcast.xml` exit 0 | `app/.build/offline-check-20261106-2216/network-signatures.txt` |
| E2E 本地 feed / 1.8.1 DMG 签名 | ✅ 均 exit 0 | 同上 |
| 公开资产哈希 | ✅ 1.8.0 DMG = `f1e01a…987d`（与 GitHub 资产一致） | 同上 |
| GitHub 手动入口 | ✅ `releases/latest` 200 → `v1.8.0`；资产 200、`content-length=11683840` | 同上 |
| 正式 app / 用户数据 / defaults | ✅ `/Applications/PKD.app` 1.8.1、PKD `f79e22…` 未变；`collections` `c4f6ce…`、`history` `501010…` 未变；无 `SUFeedURL`/`SUAutomaticallyUpdate` | `state-audit.txt` |
| `UpdateManager` / `UpdateRecovery` | ✅ 2026-11-07 新增恢复模块并接入 `UpdateManager`（SHA `885c2e…`/`5ae5…`）；原 F1–F4 行为不变；构建与 25 项状态机测试通过，真实 F5 下次启动弹窗仍待前台 | §12、`app/.build/update-recovery-tests-20261107-094817/run.log` |
| 合成基线（干净 checkout） | ✅ exit 0、29/29（与 [REPRODUCIBLE-BASELINE.md](REPRODUCIBLE-BASELINE.md) 一致） | `app/.build/offline-check-20261106-2216/baseline-clean.log` |
| 离屏 LogSink 复现 | ✅ 复现成功（2026-11-06 时缺陷仍在：20,001B→close 后缺尾行→drain 后 17B 覆盖）；**2026-11-07 已修复**，修复后 23 项回归通过，见 §12 与 `docs/BACKGROUND-VALIDATION-FINAL.md` | `logsink-probe3.txt`（历史）、`app/.build/logsink-tests-20261107-091500/run.log` |
| 离屏 JobQueue 引擎失败 | ✅ missing/crash/nodone/corrupt 均 `失败` 终态；valid `成功`；无假成功 | `probe2-*.txt` |
| 离屏取消 | ✅ 取消前 `解包中 active=1` → 取消后 `已取消 active=0`，无产物、无残留进程 | `probe4-cancel.txt` |

### 11.2 前台待补（不假称通过）

以下项目此前已执行并留证，但按新策略需要在前台交互窗口重新验收/复验：

1. 成功路径：真实菜单「检查更新…」、Sparkle「软件更新」窗、点击「安装更新」「安装并重启应用」、重启后窗口版本确认。
2. F1–F4：Sparkle 自带错误框关闭、产品 SwiftUI「更新未能完成」弹窗及按钮的可见/可点性。
3. F5：只读安装父目录的实际安装失败与旧 app 完好性的现场确认。
4. G3：手动下载按钮实际点击（本轮只验证 URL 可达与 AX 存在）。
5. 更新后偏好/集合/历史在 UI 侧的现场确认（后台已用哈希核对）。

> 口径：历史 E2E 证据可作为“曾经通过”的参考；本文件**不声称**在 22:14 新策略下重新完成了前台验收。22:14 之后未再激活任何测试窗口、未发送键鼠事件。

---

## 12. Autoupdate 阶段失败的持久恢复提示（2026-11-07 实现）

### 12.1 问题

F5 的真实失败发生在 Sparkle 的独立 `Autoupdate` 进程：宿主 app 已被 Sparkle 的正常 Apple quit 事件终止，`SPUUpdaterDelegate` 不可能再回到宿主进程弹窗。用户最初要求“更新失败时软件内引导 GitHub”，因此需要把失败证据持久化到下一次启动。

### 12.2 实现（仅 UpdateManager + 新模块，无需 PKDApp 接线）

新增 `app/Sources/PKDApp/UpdateRecovery.swift`（纯 Foundation 状态机），并在 `UpdateManager.swift` 接入：

- Sparkle 官方委托 `updater(_:willInstallUpdate:)`（`SPUInstallerDriver.m:553`，在安装交接、宿主终止前调用）写入目标版本/构建号；**只是发现、下载或“退出时安装”排队都不写记录**。
- `NSApplication.willTerminateNotification` 标记“干净终止”。Sparkle 用 Apple quit event（`InstallerProgressAppController.sendTerminationSignal`），因此正常安装交接会走这里；SIGKILL/崩溃不会。
- 下次启动调用 `UpdateRecoveryStore.evaluateOnLaunch`：
  - 当前版本 ≥ 目标 → 静默清除；
  - 记录超过 30 天 → 静默清除；
  - 非干净终止（可能强退/崩溃）→ **不报**，避免把不可证明的失败误报给用户；
  - 干净终止 + 当前仍低于目标 → 一次性 `UpdateFailure`，复用现有「更新未能完成」弹窗与「前往 GitHub 手动下载」按钮（`PKDApp.swift` 已有绑定，**无需改 PKDApp**）。
- 用户取消安装（`SUInstallationCanceledError` 4007）或在宿主仍存活时已弹出错误 → 清除记录，避免下次启动重复/误报。
- **版本判定以 Sparkle 的 `versionString`（CFBundleVersion/build）为准**：目标与当前 build 都存在时只比较 build，绝不用 shortVersion 的 OR 掩盖更低 build（例如目标 build 102 / 当前 build 101，即使 shortVersion 都是 1.8.1 也必须判失败）；只有 build 缺失时才回退 shortVersion。
- 未改动 `PKDApp.swift`、`AppModel`、`JobQueue`、`verify.sh`、`VERSION`；`UpdateManager` 的原有 F1–F4 行为保持。

### 12.3 后台验证

- `swift build --disable-sandbox` 通过（含新 `UpdateRecovery.swift` 与 `UpdateManager` 接入）。
- `bash tools/dev/fault-update-recovery-tests.sh`：**25 项状态机断言全部通过**（无记录静默、干净终止+旧版本提示、新版本静默、重复 willInstall 保持 clean、不同目标重置、过期、时钟回退、显式取消清除、损坏记录清除、版本比较器边界、同 shortVersion 不同 build、build 优先、short fallback）。
  证据：`app/.build/update-recovery-tests-20261107-094817/run.log`。
- 代码级依据：Sparkle 2.10.1 的 `willInstallUpdate` 在 `SPUInstallerDriver.m:553` 于安装交接前调用；`Autoupdate` 的失败路径不会回调已终止宿主。

### 12.4 未验证 / 边界（不假称通过）

1. **真实 F5 故障后重启是否弹窗**：需要前台执行一次“只读安装父目录失败 → 重启”才能确认；本轮仅验证状态机与构建，**未实测真实弹窗**。
2. 若安装交接后用户 **强制退出**（非正常 terminate），记录会因 `cleanTermination=false` 被静默清除，可能漏报一次真实安装失败；这是为“不误报”做的保守取舍。
3. 30 天过期窗口是产品选择；超过 30 天才再次启动则不再提示。
4. 安装交接后用户取消的极窄竞态（记录已写、app 未终止、用户再正常退出）可能产生一次提示；现有 4007 清除覆盖常规授权取消路径，未覆盖所有自定义 Sparkle 驱动。
5. F5 原有边界不变：安装阶段失败时宿主已退出，提示只可能出现在**下一次启动**，不是当次。

### 12.5 集成接线

- 无需 PKDApp/AppModel 改动；`UpdateRecovery.swift` 被 PKDApp target 自动包含，`UpdateManager` 自动在启动时评估。
- 若后续要自定义 Sparkle 用户驱动，应保留 `willInstallUpdate` 与 `willTerminate` 两个记录点，或改为等价官方回调。

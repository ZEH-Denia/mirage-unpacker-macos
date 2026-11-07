#!/bin/bash
# PKD 回归脚本：单测 + 队列 + 渲染 + 基线 + 存储安全 + 生命周期 + 证据工具
#
# 约定：
# * 只用仓库里既有的 runner/脚本，不在这里重复实现测试逻辑。
# * 失败如实计数；必需项缺失/显式跳过记为「必需项未验证」，最终以退出码 3 表示，
#   既不算通过也不掩盖真实失败。
# * 历史真实基线（extracted/3608924541 已不可恢复）不是默认门禁：日常只作为
#   「覆盖缺口」列出，不改变退出码；需要把它当验收项时用 --with-real-baseline。
# * 日常 verify 不比对 updates/appcast.xml 与本机预览版本：公开 feed 与本地预览
#   本来就允许不同版本，二者只在发布流程里单独核对。
#
# 用法：
#   bash app/scripts/verify.sh                     # 默认：全部必需的后台回归
#   bash app/scripts/verify.sh --skip-lifecycle    # 显式跳过 6 个生命周期 runner（记未验证）
#   bash app/scripts/verify.sh --with-real-baseline# 把历史真实包比对当验收项
#   bash app/scripts/verify.sh --with-matrix       # 追加真实场景矩阵（accept 模式）
#
# 退出码：0 全部必需检查通过；1 有失败；2 参数错误；3 无失败但有必需项未验证。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(dirname "$ROOT")"
REPKG="$REPO/tools/bin/repkg"
SELFTEST="$ROOT/.build/debug/pkd-selftest"
LOG_DIR="${PKD_VERIFY_LOG_DIR:-/tmp/pkd-verify-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$LOG_DIR"

RETIRED_LIFECYCLE=0
WITH_REAL_BASELINE=0
WITH_MATRIX=0
for arg in "$@"; do
  case "$arg" in
    --skip-lifecycle) RETIRED_LIFECYCLE=1 ;;
    --with-real-baseline) WITH_REAL_BASELINE=1 ;;
    --with-matrix) WITH_MATRIX=1 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

FAILED=0
REQUIRED_UNVERIFIED=0
PASSED=0
GAPS=()

pass() { echo "  ✅ $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $1"; FAILED=$((FAILED + 1)); }
unverified() { echo "  ⚠️  必需项未验证：$1"; REQUIRED_UNVERIFIED=$((REQUIRED_UNVERIFIED + 1)); }
gap() { echo "  · 覆盖缺口：$1"; GAPS+=("$1"); }

assertion_count() {
  grep -oE '（[0-9]+ 项断言）' "$1" 2>/dev/null | tail -1 | tr -d '（）' | sed 's/ 项断言//'
}

# 运行阶段：$1=标签 $2=期望断言数（空=不校验） $3=证据日志 $4...=命令
run_stage() {
  local label="$1" expected="$2" log="$3"
  shift 3
  "$@" >"$log" 2>&1
  local code=$?
  local count pass_lines
  count=$(assertion_count "$log")
  if [ -z "$count" ]; then
    # 生命周期 runner 不打印「N 项断言」，用 "  PASS " 行数作为通过项计数
    pass_lines=$(grep -cE '^  PASS' "$log" 2>/dev/null || true)
    if [ "${pass_lines:-0}" -gt 0 ] 2>/dev/null; then count="$pass_lines"; fi
  fi
  if [ "$code" -ne 0 ]; then
    fail "${label}（退出码 ${code}，见 ${log}）"
    tail -5 "$log" | sed 's/^/     /'
    return 1
  fi
  if [ -n "$expected" ] && [ -n "$count" ] && [ "$count" != "$expected" ]; then
    fail "${label}（通过项数与约定不一致：实际 ${count}，约定 ${expected}，见 ${log}）"
    return 1
  fi
  if [ -n "$count" ]; then pass "${label}（${count} 项断言）"; else pass "$label"; fi
  return 0
}

echo "==> 1 编译（native arm64，--disable-sandbox）"
cd "$ROOT" || exit 1
if /usr/bin/arch -arm64 /usr/bin/swift build --disable-sandbox >"$LOG_DIR/build.log" 2>&1; then
  pass "swift build（arm64 debug）"
else
  fail "swift build（见 $LOG_DIR/build.log）"
  tail -10 "$LOG_DIR/build.log" | sed 's/^/     /'
  exit 1
fi

echo "==> 2 单元测试"
UNIT_LOG="$LOG_DIR/unit.log"
if "$SELFTEST" >"$UNIT_LOG" 2>&1; then
  count=$(assertion_count "$UNIT_LOG")
  if [ -n "$count" ] && [ "$count" != "161" ]; then
    fail "单测（通过项数与约定不一致：实际 ${count}，约定 161，见 ${UNIT_LOG}）"
  else
    pass "单测（${count:-?} 项断言）"
  fi
else
  fail "单测未通过（见 ${UNIT_LOG}）"
  grep FAIL "$UNIT_LOG" | head -5 | sed 's/^/     /'
fi

echo "==> 3 队列全链路与图片冲突"
TESTPKG="$REPO/tools/testdata/test_scene.pkg"
[ -f "$TESTPKG" ] || python3 "$REPO/tools/testdata/make_test_pkg.py" "$REPO/tools/testdata" >/dev/null 2>&1
if [ -f "$TESTPKG" ]; then
  run_stage "JobQueue 集成" 10 "$LOG_DIR/queue.log" "$SELFTEST" --queue "$TESTPKG"
  run_stage "PNG 图集与原始 TEX 冲突" 11 "$LOG_DIR/conflict.log" "$SELFTEST" --image-conflicts "$TESTPKG"
else
  unverified "队列/冲突（缺合成测试包且生成失败）"
fi

echo "==> 4 场景合成（渲染/语义/回退）与共享纹理队列"
FIXTURE="$ROOT/.build/render-fixture"
rm -rf "$FIXTURE"
if python3 "$REPO/tools/testdata/make_render_scene.py" "$FIXTURE" >"$LOG_DIR/fixture.log" 2>&1; then
  run_stage "多层渲染与 puppet 组合" 27 "$LOG_DIR/render.log" "$SELFTEST" --render-fixtures "$FIXTURE"
  run_stage "场景语义/角度/绑定/回退/骨骼姿态" 132 "$LOG_DIR/semantics.log" "$SELFTEST" --scene-semantics "$FIXTURE"
else
  fail "合成素材生成失败（见 $LOG_DIR/fixture.log）"
fi
SHARED_DIR=$(mktemp -d)
if python3 "$REPO/tools/testdata/make_shared_texture_scene.py" "$SHARED_DIR" >/dev/null 2>&1; then
  run_stage "共享单纹理场景队列" 5 "$LOG_DIR/shared.log" "$SELFTEST" --scene-queue "$SHARED_DIR/scene.pkg" 400 320
else
  unverified "共享单纹理场景队列（素材生成失败）"
fi
rm -rf "$SHARED_DIR"

echo "==> 5 可重复合成基线"
BASELINE_LOG="$LOG_DIR/baseline.log"
bash "$REPO/tools/dev/baseline-verify.sh" >"$BASELINE_LOG" 2>&1
BASELINE_CODE=$?
BASELINE_DIR=$(grep -oE '证据目录: .*' "$BASELINE_LOG" | tail -1 | sed 's/证据目录: //')
BASELINE_CHECKS=""
if [ -n "$BASELINE_DIR" ] && [ -f "$BASELINE_DIR/report.json" ] && command -v python3 >/dev/null 2>&1; then
  BASELINE_CHECKS=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("checks", [])))' "$BASELINE_DIR/report.json" 2>/dev/null)
fi
case "$BASELINE_CODE" in
  0)
    if [ -n "$BASELINE_CHECKS" ] && [ "$BASELINE_CHECKS" != "29" ]; then
      fail "可重复合成基线（检查数与约定不一致：实际 ${BASELINE_CHECKS}，约定 29）"
    else
      pass "可重复合成基线（${BASELINE_CHECKS:-?} 项检查）"
    fi ;;
  2) unverified "可重复合成基线（前置条件缺失：需要 tools/bin/repkg，见 ${BASELINE_LOG}）" ;;
  *) fail "可重复合成基线（退出码 ${BASELINE_CODE}，见 ${BASELINE_LOG}）" ;;
esac

echo "==> 6 历史真实包逐文件比对（原真实基线已不可恢复）"
REAL="$HOME/Library/Application Support/Mirage/Workshop/content/431960/3608924541/scene.pkg"
HISTORICAL_BASELINE="$REPO/extracted/3608924541"
if [ ! -d "$HISTORICAL_BASELINE" ]; then
  if [ "$WITH_REAL_BASELINE" -eq 1 ]; then
    unverified "历史真实包比对（extracted/3608924541 缺失，--with-real-baseline 要求它）"
  else
    gap "历史真实包逐文件比对未执行：extracted/3608924541 不可恢复（不计为通过）"
  fi
elif [ ! -f "$REAL" ]; then
  if [ "$WITH_REAL_BASELINE" -eq 1 ]; then
    unverified "历史真实包比对（本机缺少该真实包）"
  else
    gap "历史真实包逐文件比对未执行：本机缺少该真实包（不计为通过）"
  fi
else
  TMP=$(mktemp -d)
  "$REPKG" extract "$REAL" -o "$TMP/out" -c --overwrite >"$LOG_DIR/historical-extract.log" 2>&1
  if diff -r --brief "$TMP/out" "$HISTORICAL_BASELINE" >"$LOG_DIR/historical-diff.log" 2>&1; then
    pass "与历史基线目录一致（$(find "$TMP/out" -type f | wc -l | tr -d ' ') 个文件）"
  else
    fail "与历史基线不一致（见 $LOG_DIR/historical-diff.log）"
  fi
  rm -rf "$TMP"
fi

echo "==> 7 存储安全（owned/temp 清理、unknown/legacy 只读、重导出不得接管）"
run_stage "存储安全回归" 129 "$LOG_DIR/storage.log" "$SELFTEST" --storage-safety

echo "==> 8 生命周期与并发（必需，可后台运行）"
if [ "$RETIRED_LIFECYCLE" -eq 1 ]; then
  unverified "生命周期 runner 被 --skip-lifecycle 显式跳过（logsink/supervisor/temp/jobqueue-temp/concurrency/update-recovery）"
else
  for spec in \
    "LogSink 生命周期|23|fault-logsink-tests.sh" \
    "更新恢复状态机|25|fault-update-recovery-tests.sh" \
    "进程 supervisor|12|fault-supervisor-tests.sh" \
    "临时目录回收|14|fault-temp-cleanup-tests.sh" \
    "JobQueue 临时租约|7|fault-jobqueue-temp-tests.sh" \
    "并发生命周期|8|fault-concurrency-tests.sh"; do
    IFS='|' read -r label expected script <<<"$spec"
    if [ ! -f "$REPO/tools/dev/$script" ]; then
      fail "$label runner 缺失（tools/dev/${script}）"
      continue
    fi
    run_stage "$label" "$expected" "$LOG_DIR/${script%.sh}.log" bash "$REPO/tools/dev/$script"
  done
fi

echo "==> 9 动画纹理"
run_stage "动画纹理验证" "" "$LOG_DIR/animation.log" bash "$REPO/tools/testdata/verify_animation.sh"

echo "==> 10 场景金标准（独立解析预期）"
if command -v python3 >/dev/null 2>&1; then
  run_stage "场景金标准" 30 "$LOG_DIR/golden.log" \
    python3 "$REPO/tools/testdata/verify_golden.py" "$ROOT/.build/golden-verify"
else
  unverified "场景金标准（缺 python3）"
fi

echo "==> 11 证据/测试工具安全策略"
if command -v python3 >/dev/null 2>&1; then
  SAFETY_LOG="$LOG_DIR/evidence-tool-safety.log"
  if python3 "$REPO/tools/testdata/test_evidence_tool_safety.py" >"$SAFETY_LOG" 2>&1; then
    RAN=$(grep -oE 'Ran [0-9]+ tests?' "$SAFETY_LOG" | grep -oE '[0-9]+' | tail -1)
    if [ -n "$RAN" ] && [ "$RAN" != "29" ]; then
      fail "证据工具安全策略（测试数与约定不一致：实际 ${RAN}，约定 29）"
    else
      pass "证据工具安全策略（${RAN:-?} 项测试）"
    fi
  else
    fail "证据工具安全策略（见 ${SAFETY_LOG}）"
    tail -5 "$SAFETY_LOG" | sed 's/^/     /'
  fi
else
  unverified "证据工具安全策略（缺 python3）"
fi

if [ "$WITH_MATRIX" -eq 1 ]; then
  echo "==> 附加 真实场景矩阵（accept；显式允许两个已证实受限类）"
  WORKSHOP="$HOME/Library/Application Support/Mirage/Workshop/content/431960"
  if [ -d "$WORKSHOP" ]; then
    run_stage "真实场景矩阵（accept）" "" "$LOG_DIR/matrix.log" \
      python3 "$REPO/tools/testdata/scene_matrix_report.py" \
        --workshop "$WORKSHOP" --out "$ROOT/.build/matrix-accept" --mode accept \
        --allow-class render_fallback_texture_missing \
        --allow-class render_fallback_video_texture
  else
    unverified "真实场景矩阵（本机无工坊目录）"
  fi
fi

echo ""
echo "通过 $PASSED 项；失败 $FAILED 项；必需项未验证 $REQUIRED_UNVERIFIED 项"
if [ "${#GAPS[@]}" -gt 0 ]; then
  echo "覆盖缺口（不计通过、不影响退出码）："
  for item in "${GAPS[@]}"; do echo "  - $item"; done
fi
echo "日志目录: $LOG_DIR"
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED 项失败"
  exit 1
fi
if [ "$REQUIRED_UNVERIFIED" -gt 0 ]; then
  echo "⚠️  已执行项全部通过，但有 $REQUIRED_UNVERIFIED 项必需检查未验证（退出码 3）"
  exit 3
fi
echo "✅ 全部必需检查通过"
exit 0

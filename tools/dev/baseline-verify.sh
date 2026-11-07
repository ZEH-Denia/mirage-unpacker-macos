#!/bin/bash
# 可重复合成基线一键验收（替代已不可恢复的 extracted/3608924541 真实基线）。
#
# 只依赖：Python 3.8+、仓库内已提交的夹具/生成器/清单、以及本地构建的 RePKG 引擎
# （tools/bin/repkg 是 Git 忽略的构建产物，先运行 ./tools/build-repkg.sh）。
#
# 用法:
#   bash tools/dev/baseline-verify.sh
#   REPKG=/path/to/repkg bash tools/dev/baseline-verify.sh   # 指定引擎
#
# 退出码: 0 通过；1 检查失败；2 前置条件缺失（不静默跳过任何一步）。
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
REPKG="${REPKG:-$REPO/tools/bin/repkg}"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="${BASELINE_WORK_DIR:-$REPO/app/.build/baseline-$STAMP}"

echo "==> 合成可重复基线验收"
echo "    仓库:   $REPO"
echo "    引擎:   $REPKG"
echo "    证据:   $WORK"

# ---- 前置检查：缺失即非零退出并说明原因（不静默 skip）---------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "❌ 前置条件缺失：找不到 python3（基线需要 Python 3.8+）" >&2
  exit 2
fi
if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)'; then
  echo "❌ 前置条件缺失：需要 Python 3.8+，当前 $(python3 -V 2>&1)" >&2
  exit 2
fi
if [ ! -f "$REPKG" ]; then
  echo "❌ 前置条件缺失：找不到 RePKG 引擎 $REPKG" >&2
  echo "   它是 Git 忽略的本地构建产物；先运行 ./tools/build-repkg.sh，" >&2
  echo "   或用 REPKG=/path/to/repkg 指定已有二进制。" >&2
  exit 2
fi
if [ ! -x "$REPKG" ]; then
  echo "❌ 前置条件缺失：RePKG 不可执行 $REPKG（chmod +x 或重建）" >&2
  exit 2
fi
for f in tools/testdata/make_baseline_pkg.py \
         tools/testdata/baseline-scene/scene.pkg \
         tools/testdata/baseline-scene/project.json \
         tools/testdata/baseline-scene.expected.json \
         tools/testdata/verify_png.py; do
  if [ ! -f "$REPO/$f" ]; then
    echo "❌ 前置条件缺失：$REPO/$f" >&2
    exit 2
  fi
done

mkdir -p "$WORK" || { echo "❌ 无法创建证据目录 $WORK" >&2; exit 2; }

# ---- 执行检查器（逐文件 SHA-256 + 独立像素断言 + 两次解包 + 篡改检测）------
python3 "$REPO/tools/dev/baseline_check.py" \
  --repo "$REPO" \
  --repkg "$REPKG" \
  --work-dir "$WORK" \
  --report "$WORK/report.json" "$@"
STATUS=$?

echo ""
echo "证据目录: $WORK"
exit "$STATUS"

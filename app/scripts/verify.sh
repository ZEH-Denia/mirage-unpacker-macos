#!/bin/bash
# PKD 回归脚本：单测 + 队列集成 + 真实包逐文件比对
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(dirname "$ROOT")"
REPKG="$REPO/tools/bin/repkg"
SELFTEST="$ROOT/.build/debug/pkd-selftest"
FAILED=0

pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAILED=$((FAILED + 1)); }

echo "==> 1/5 编译"
cd "$ROOT"
swift build --disable-sandbox >/tmp/pkd_verify_build.log 2>&1 && pass "swift build" || { fail "swift build（见 /tmp/pkd_verify_build.log）"; exit 1; }

echo "==> 2/5 单元测试（LineStream / 解析器 / 判定表 / X-Ray）"
UNIT_OUT=$("$SELFTEST" 2>&1 | tail -1)
if echo "$UNIT_OUT" | grep -q "全部通过"; then
  pass "$UNIT_OUT"
else
  fail "单测未通过"
  "$SELFTEST" 2>&1 | grep FAIL | head -5
fi

echo "==> 3/5 队列全链路（合成包）"
TESTPKG="$REPO/tools/testdata/test_scene.pkg"
if [ ! -f "$TESTPKG" ]; then
  echo "  · 生成合成测试包"
  python3 "$REPO/tools/testdata/make_test_pkg.py" "$REPO/tools/testdata" >/dev/null 2>&1 || \
    echo "  ⚠️ 生成失败（需要 python3），后续用例可能跳过"
fi
if "$SELFTEST" --queue "$TESTPKG" 2>&1 | tail -1 | grep -q "通过"; then
  pass "JobQueue 集成通过"
else
  fail "JobQueue 集成未通过"
fi

echo "==> 4/5 真实包逐文件比对"
REAL="$HOME/Library/Application Support/Mirage/Workshop/content/431960/3608924541/scene.pkg"
BASELINE="$REPO/extracted/3608924541"
if [ -f "$REAL" ] && [ -d "$BASELINE" ]; then
  TMP=$(mktemp -d)
  "$REPKG" extract "$REAL" -o "$TMP/out" -c --overwrite >/dev/null 2>&1
  if diff -r --brief "$TMP/out" "$BASELINE" >/tmp/pkd_verify_diff.log 2>&1; then
    pass "与基线目录完全一致（$(find "$TMP/out" -type f | wc -l | tr -d ' ') 个文件）"
  else
    fail "与基线不一致（见 /tmp/pkd_verify_diff.log）"
    head -5 /tmp/pkd_verify_diff.log
  fi
  rm -rf "$TMP"
else
  echo "  ⏭  跳过（缺少真实包或基线目录）"
fi

echo "==> 5/5 失败路径（不存在的输入）"
GHOST=$(mktemp -d)/nope.pkg
OUT=$("$REPKG" extract "$GHOST" -o "$(dirname "$GHOST")/out" 2>&1)
if echo "$OUT" | grep -q "Input file not found" && ! echo "$OUT" | grep -q "^Done$"; then
  pass "正确识别为失败（退出码恒 0 也不误判）"
else
  fail "失败路径判定异常"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "✅ 全部回归通过"
  exit 0
else
  echo "❌ $FAILED 项失败"
  exit 1
fi

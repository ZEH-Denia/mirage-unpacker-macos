#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "$REPO/app/.build/animation-validation.XXXXXX")"
python3 "$REPO/tools/testdata/make_animation_pkg.py" "$TEST_ROOT"
"$REPO/tools/bin/repkg" extract "$TEST_ROOT/scene.pkg" -o "$TEST_ROOT/valid" --overwrite >"$TEST_ROOT/valid.log" 2>&1
grep -q '^Done$' "$TEST_ROOT/valid.log"
if grep -q 'Failed to write texture\|Exception' "$TEST_ROOT/valid.log"; then
  echo "Animation conversion reported an error; inspect $TEST_ROOT/valid.log" >&2
  exit 1
fi
swift "$REPO/tools/testdata/verify_animations.swift" "$TEST_ROOT/valid/materials"
"$REPO/tools/bin/repkg" extract "$TEST_ROOT/oversized.pkg" -o "$TEST_ROOT/invalid" --overwrite >"$TEST_ROOT/invalid.log" 2>&1
grep -q 'PNG animation atlas dimensions are invalid' "$TEST_ROOT/invalid.log"
test -f "$TEST_ROOT/invalid/materials/oversized.tex"
test ! -e "$TEST_ROOT/invalid/materials/oversized.gif"
echo "✅ Oversized PNG rejected; original TEX preserved"
echo "Evidence: $TEST_ROOT"

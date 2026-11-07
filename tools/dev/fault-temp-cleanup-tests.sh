#!/bin/bash
# Offscreen owner-marker/flock temp-directory janitor regression.
# Usage: tools/dev/fault-temp-cleanup-tests.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${TEMP_CLEANUP_TEST_EVIDENCE:-$REPO/app/.build/temp-cleanup-tests-$STAMP}"
SRC="$REPO/app/Sources/PKDKit/Jobs/TemporaryOutputs.swift"
TESTS="$REPO/tools/dev/fault-temp-cleanup-tests.swift"
BIN="$OUT/fault-temp-cleanup-tests"

mkdir -p "$OUT" || exit 2
printf 'repo=%s\nout=%s\n' "$REPO" "$OUT" > "$OUT/env.txt"
command -v swiftc >/dev/null 2>&1 || { echo "❌ 前置条件缺失：swiftc" >&2; exit 2; }
[ -f "$SRC" ] || { echo "❌ 前置条件缺失：$SRC" >&2; exit 2; }
[ -f "$TESTS" ] || { echo "❌ 前置条件缺失：$TESTS" >&2; exit 2; }

if ! swiftc -parse-as-library "$SRC" "$TESTS" -o "$BIN" > "$OUT/compile.log" 2>&1; then
  echo "❌ temp cleanup 测试编译失败（见 $OUT/compile.log）" >&2
  tail -20 "$OUT/compile.log" >&2
  exit 2
fi

"$BIN" "$OUT/run" > "$OUT/run.log" 2>&1
STATUS=$?
cat "$OUT/run.log"
echo ""
echo "证据目录: $OUT"
exit "$STATUS"

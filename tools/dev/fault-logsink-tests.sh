#!/bin/bash
# Offscreen lifecycle/concurrency regression tests for the real PKDKit LogSink.
# No GUI, no network, no user data. Usage: tools/dev/fault-logsink-tests.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${LOGSINK_TEST_EVIDENCE:-$REPO/app/.build/logsink-tests-$STAMP}"
SRC="$REPO/app/Sources/PKDKit/Support/LogSink.swift"
TESTS="$REPO/tools/dev/fault-logsink-tests.swift"
BIN="$OUT/fault-logsink-tests"

mkdir -p "$OUT" || exit 2
printf 'repo=%s\nsource=%s\ntests=%s\nout=%s\n' "$REPO" "$SRC" "$TESTS" "$OUT" > "$OUT/env.txt"

command -v swiftc >/dev/null 2>&1 || { echo "❌ 前置条件缺失：swiftc" >&2; exit 2; }
[ -f "$SRC" ] || { echo "❌ 前置条件缺失：$SRC" >&2; exit 2; }
[ -f "$TESTS" ] || { echo "❌ 前置条件缺失：$TESTS" >&2; exit 2; }

if ! swiftc -parse-as-library "$SRC" "$TESTS" -o "$BIN" > "$OUT/compile.log" 2>&1; then
  echo "❌ LogSink 测试编译失败（见 $OUT/compile.log）" >&2
  tail -20 "$OUT/compile.log" >&2
  exit 2
fi

"$BIN" "$OUT/run" > "$OUT/run.log" 2>&1
STATUS=$?
cat "$OUT/run.log"
echo ""
echo "证据目录: $OUT"
exit "$STATUS"

#!/bin/bash
# Offscreen parent-death/cancel regression for the real ProcessRunner supervisor.
# Usage: tools/dev/fault-supervisor-tests.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${SUPERVISOR_TEST_EVIDENCE:-$REPO/app/.build/supervisor-tests-$STAMP}"
BIN="$OUT/fault-supervisor-tests"
SRC1="$REPO/app/Sources/PKDKit/Engine/LineStream.swift"
SRC2="$REPO/app/Sources/PKDKit/Engine/ProcessRunner.swift"
TESTS="$REPO/tools/dev/fault-supervisor-tests.swift"

mkdir -p "$OUT" || exit 2
printf 'repo=%s\nout=%s\n' "$REPO" "$OUT" > "$OUT/env.txt"
command -v swiftc >/dev/null 2>&1 || { echo "❌ 前置条件缺失：swiftc" >&2; exit 2; }
for f in "$SRC1" "$SRC2" "$TESTS"; do [ -f "$f" ] || { echo "❌ 前置条件缺失：$f" >&2; exit 2; }; done

if ! swiftc -parse-as-library "$SRC1" "$SRC2" "$TESTS" -o "$BIN" > "$OUT/compile.log" 2>&1; then
  echo "❌ supervisor 测试编译失败（见 $OUT/compile.log）" >&2
  tail -20 "$OUT/compile.log" >&2
  exit 2
fi

"$BIN" "$OUT/run" > "$OUT/run.log" 2>&1
STATUS=$?
cat "$OUT/run.log"
echo ""
echo "证据目录: $OUT"
exit "$STATUS"

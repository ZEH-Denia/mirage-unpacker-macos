#!/bin/bash
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${CONCURRENCY_TEST_EVIDENCE:-$REPO/app/.build/concurrency-tests-$STAMP}"
BIN="$OUT/fault-concurrency-tests"
FAKE="$OUT/engine-fastinfo-slowextract"
mkdir -p "$OUT" || exit 2
printf 'repo=%s\nout=%s\n' "$REPO" "$OUT" > "$OUT/env.txt"
[ -f "$REPO/app/.build/debug/libPKDKit.a" ] || { echo "❌ 先 swift build --disable-sandbox" >&2; exit 2; }
printf '%s\n' '#!/bin/bash' 'if [ "$1" = "extract" ]; then exec sleep 30; fi' 'echo start' 'echo Done' 'exit 0' > "$FAKE"
chmod +x "$FAKE"
if ! swiftc -parse-as-library -I "$REPO/app/.build/debug" -L "$REPO/app/.build/debug" -lPKDKit \
    "$REPO/tools/dev/fault-concurrency-tests.swift" -o "$BIN" > "$OUT/compile.log" 2>&1; then
  echo "❌ concurrency 测试编译失败（见 $OUT/compile.log）" >&2
  tail -20 "$OUT/compile.log" >&2
  exit 2
fi
"$BIN" "$OUT/run" "$REPO/tools/bin/repkg" "$REPO/tools/testdata/test_scene.pkg" "$FAKE" > "$OUT/run.log" 2>&1
STATUS=$?
cat "$OUT/run.log"
echo ""
echo "证据目录: $OUT"
exit "$STATUS"

#!/bin/bash
# Offscreen integration of JobQueue + TemporaryOutputs lease lifecycle.
# Usage: tools/dev/fault-jobqueue-temp-tests.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${JOBQUEUE_TEMP_TEST_EVIDENCE:-$REPO/app/.build/jobqueue-temp-tests-$STAMP}"
BIN="$OUT/fault-jobqueue-temp-tests"
FAKE="$OUT/engine-fastinfo-slowextract"
PKG="$REPO/tools/testdata/test_scene.pkg"
mkdir -p "$OUT" || exit 2
printf 'repo=%s\nout=%s\n' "$REPO" "$OUT" > "$OUT/env.txt"
command -v swiftc >/dev/null 2>&1 || { echo "❌ 前置条件缺失：swiftc" >&2; exit 2; }
[ -f "$REPO/app/.build/debug/libPKDKit.a" ] || { echo "❌ 前置条件缺失：先 swift build --disable-sandbox" >&2; exit 2; }
[ -f "$PKG" ] || { echo "❌ 前置条件缺失：$PKG" >&2; exit 2; }
printf '%s\n' '#!/bin/bash' 'if [ "$1" = "extract" ]; then exec sleep 30; fi' 'echo start' 'echo Done' 'exit 0' > "$FAKE"
chmod +x "$FAKE"
if ! swiftc -parse-as-library -I "$REPO/app/.build/debug" -L "$REPO/app/.build/debug" -lPKDKit \
    "$REPO/tools/dev/fault-jobqueue-temp-tests.swift" -o "$BIN" > "$OUT/compile.log" 2>&1; then
  echo "❌ JobQueue temp 测试编译失败（见 $OUT/compile.log）" >&2
  tail -20 "$OUT/compile.log" >&2
  exit 2
fi
"$BIN" "$OUT/run" "$FAKE" "$PKG" > "$OUT/run.log" 2>&1
STATUS=$?
cat "$OUT/run.log"
echo ""
echo "证据目录: $OUT"
exit "$STATUS"

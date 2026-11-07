#!/bin/bash
# update-drive-check.sh — drive the REAL product "检查更新…" menu item of one PKD
# process and record what the app actually presents (AX tree + screenshots).
#
# Usage: tools/dev/update-drive-check.sh <pid> <label> <evidence-dir> [wait-seconds]
#   <label>  short case id used in evidence file names
#
# Requires app/.build/update-e2e-*/bin/{update-ax,update-window-id} (compiled by
# tools/dev/update-e2e-build-tools.sh) or falls back to `swift` interpreter.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PID="${1:?usage: $0 <pid> <label> <evidence-dir> [wait-seconds]}"
LABEL="${2:?}"
EVID="${3:?}"
WAIT="${4:-25}"

AX="$EVID/../bin/update-ax"
WID_TOOL="$EVID/../bin/update-window-id"
AX="$(cd "$(dirname "$AX")" && pwd)/$(basename "$AX")"
WID_TOOL="$(cd "$(dirname "$WID_TOOL")" && pwd)/$(basename "$WID_TOOL")"
mkdir -p "$EVID"

before="$EVID/ax-$LABEL-before.txt"
after="$EVID/ax-$LABEL-after.txt"

"$AX" "$PID" windows > "$before" 2>&1
echo "=== windows before ($LABEL) ==="
cat "$before"

# Bring the target app forward and press the real menu item.
osascript <<EOF >/dev/null 2>&1
tell application "System Events"
  tell (first process whose unix id is $PID)
    set frontmost to true
    click menu item "检查更新…" of menu 1 of menu bar item 2 of menu bar 1
  end tell
end tell
EOF
echo "menu click exit=$?"

# Poll for a window that was not there before (sheet/dialog/update window).
deadline=$((SECONDS + WAIT))
new_win=""
while [ $SECONDS -lt $deadline ]; do
  "$AX" "$PID" windows > "$after" 2>&1
  if ! diff -q "$before" "$after" >/dev/null 2>&1; then
    new_win="yes"
    break
  fi
  sleep 1
done

echo "=== windows after ($LABEL) ==="
cat "$after"
"$AX" "$PID" dump --max-depth 8 > "$after.dump" 2>&1
echo "=== AX dump ($LABEL) ==="
cat "$after.dump"

# Screenshot every window present now (window-id targeted; no screen-region guessing).
while read -r wid; do
  [ -z "$wid" ] && continue
  screencapture -x -o -l"$wid" "$EVID/window-$LABEL-$wid.png" 2>/dev/null || true
done < <("$WID_TOOL" "$PID" | sed -n 's/^id=\([0-9]*\).*/\1/p')

if [ -n "$new_win" ]; then
  echo "RESULT: NEW_WINDOW_PRESENT"
else
  echo "RESULT: NO_NEW_WINDOW_WITHIN_${WAIT}s"
fi

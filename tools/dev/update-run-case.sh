#!/bin/bash
# update-run-case.sh — drive one real update-failure scenario through the product UI
# (menu item -> Sparkle -> UpdateManager delegate -> SwiftUI alert) and record AX evidence.
#
# Usage: tools/dev/update-run-case.sh <pid> <label> <feed-url> <evidence-dir> [mode]
#   mode=appcast   failure expected while fetching the appcast (default)
#   mode=download  appcast is valid; press "安装更新" to reach the download/verify/install stage
#
# Writes <evidence-dir>/ax-<label>-sparkle.txt, ax-<label>-app-alert.txt and screenshots.
# Prints a machine-readable summary at the end.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PID="${1:?usage: $0 <pid> <label> <feed-url> <evidence-dir> [appcast|download]}"
LABEL="${2:?}"
FEED="${3:?}"
EVID="${4:?}"
MODE="${5:-appcast}"

AXDIR="$(cd "$EVID/../bin" && pwd)"
AX="$AXDIR/update-ax"
WID_TOOL="$AXDIR/update-window-id"
mkdir -p "$EVID"

activate() {
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set frontmost to true" >/dev/null 2>&1
}

dump() { "$AX" "$PID" dump --max-depth 10 2>&1; }

has() { grep -q -- "$1" "$2" 2>/dev/null; }

press() { # press <role> <title>; retries once after activation
  local role="$1" title="$2" out
  out=$("$AX" "$PID" press "$role" "$title" 2>&1)
  if echo "$out" | grep -q "^PRESS"; then echo "$out" | head -1; return 0; fi
  activate; sleep 1
  out=$("$AX" "$PID" press "$role" "$title" 2>&1)
  echo "$out" | head -1
  echo "$out" | grep -q "^PRESS"
}

echo "=== case $LABEL: feed=$FEED mode=$MODE at $(date '+%Y-%m-%dT%H:%M:%S%z')"
defaults write com.zeh.pkd SUFeedURL -string "$FEED"
echo "SUFeedURL -> $(defaults read com.zeh.pkd SUFeedURL)"

activate; sleep 1
osascript <<EOF >/dev/null 2>&1
tell application "System Events"
  tell (first process whose unix id is $PID)
    set frontmost to true
    click menu item "检查更新…" of menu 1 of menu bar item 2 of menu bar 1
  end tell
end tell
EOF
echo "menu click done"

# Wait for Sparkle to present something.
for _ in $(seq 1 25); do
  sleep 1
  d=$(dump)
  if echo "$d" | grep -qE "AXDialog|AXSheet|软件更新|正在更新|新版本"; then break; fi
done
echo "$d" > "$EVID/ax-$LABEL-sparkle.txt"
echo "--- phase1 windows ---"
"$AX" "$PID" windows 2>&1

if [ "$MODE" = "download" ]; then
  if ! press button "安装更新"; then
    echo "SUMMARY $LABEL: could not press 安装更新"
  fi
  sleep 4
fi

# Up to 40s: dismiss Sparkle's own dialogs (取消更新/好/关闭), then look for the app alert.
app_alert=""
for _ in $(seq 1 20); do
  activate
  d=$(dump)
  echo "$d" > "$EVID/ax-$LABEL-current.txt"
  if echo "$d" | grep -q "更新未能完成"; then app_alert=yes; break; fi
  if echo "$d" | grep -q "取消更新"; then
    press button "取消更新"; sleep 2; continue
  fi
  # Download finished and Sparkle asks for the final install/relaunch confirmation
  # (install stage). Needed for the read-only-destination install-failure case.
  if echo "$d" | grep -q "安装并重启应用"; then
    press button "安装并重启应用"; sleep 3; continue
  fi
  if echo "$d" | grep -q "您使用的就是最新版"; then
    press button "好"; sleep 1; continue
  fi
  sleep 2
done

d=$(dump)
echo "$d" > "$EVID/ax-$LABEL-app-alert.txt"

# Screenshots of every window of the test app.
while read -r wid; do
  [ -z "$wid" ] && continue
  screencapture -x -o -l"$wid" "$EVID/screenshot-$LABEL-$wid.png" 2>/dev/null || true
done < <("$WID_TOOL" "$PID" 2>/dev/null | sed -n 's/^id=\([0-9]*\).*/\1/p')

echo "--- summary ---"
if [ -n "$app_alert" ]; then
  echo "SUMMARY $LABEL: APP_ALERT=yes"
  grep -A6 "更新未能完成" "$EVID/ax-$LABEL-app-alert.txt" | head -8
else
  echo "SUMMARY $LABEL: APP_ALERT=no"
  echo "--- final windows ---"
  "$AX" "$PID" windows 2>&1
fi

# Close the app alert so the next case can start clean.
press button "关闭" >/dev/null 2>&1 || true
sleep 1

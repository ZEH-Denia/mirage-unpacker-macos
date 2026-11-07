#!/bin/bash
# Prepare and launch an isolated copy of the current build for queue-fault tests.
#
# Isolation contract:
#   * app copy lives in app/.build/fault-<ts>/app, bundle id stays
#     com.zeh.pkd.development because DevelopmentEnvironment.swift hard-requires it
#     (a different id would silently fall back to the REAL library/prefs roots).
#   * data root is forced via PKD_DEVELOPMENT_ROOT in Info.plist LSEnvironment.
#   * the installed /Applications app and the real ~/Library data are never touched.
#   * launched with the bundle executable directly (LaunchServices refuses a second
#     instance of an already running bundle id, e.g. another agent's dev copy).
#
# Usage: tools/dev/fault-launch.sh [--fresh] [--ts <timestamp>] [--keep-fixtures]
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FRESH=0
TS=""
KEEP_FIXTURES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) FRESH=1 ;;
    --keep-fixtures) KEEP_FIXTURES=1 ;;
    --ts) shift; TS="$1" ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$TS" ]; then
  if [ "$FRESH" -eq 0 ] && [ -f /tmp/fault_ts.txt ]; then
    TS="$(cat /tmp/fault_ts.txt)"
  else
    TS="$(date +%Y%m%d-%H%M%S)"
    printf '%s' "$TS" > /tmp/fault_ts.txt
  fi
fi

EV="$REPO/app/.build/fault-$TS"
ROOT="$EV/root"
APP="$EV/app/PKD Fault.app"
EVID="$EV/evidence"
mkdir -p "$EV/app" "$ROOT" "$EVID" "$EV/scripts"

DIST="$REPO/app/dist/PKD.app"
[ -x "$DIST/Contents/MacOS/PKD" ] || { echo "FATAL: $DIST missing; build the app first" >&2; exit 1; }
[ -x "$REPO/tools/bin/repkg" ] || { echo "FATAL: tools/bin/repkg missing" >&2; exit 1; }

# stop a previous instance of *this* isolated copy only
OLD_PID="$(pgrep -f "$APP/Contents/MacOS/PKD" | head -1)"
if [ -n "$OLD_PID" ]; then
  kill -TERM "$OLD_PID" 2>/dev/null
  for _ in $(seq 1 20); do sleep 0.25; kill -0 "$OLD_PID" 2>/dev/null || break; done
  kill -9 "$OLD_PID" 2>/dev/null
fi

# fixtures (only when missing, so a mid-run restart keeps the same library)
if [ "$KEEP_FIXTURES" -eq 0 ]; then
  if [ "$FRESH" -eq 1 ] || [ ! -d "$ROOT/Library/900002" ]; then
    rm -rf "$ROOT/Library" "$ROOT/Extracted" "$ROOT/Images" "$ROOT/Logs" "$ROOT/History" "$ROOT/Cache"
    python3 "$REPO/tools/dev/fault-make-fixtures.py" "$ROOT" --force
  fi
fi

# fresh app copy on --fresh, otherwise reuse
if [ "$FRESH" -eq 1 ] || [ ! -x "$APP/Contents/MacOS/PKD" ]; then
  rm -rf "$APP"
  ditto "$DIST" "$APP"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.zeh.pkd.development' "$APP/Contents/Info.plist"
  # unique executable name: another agent's "tell process "PKD"" automation must never
  # land on this isolated copy (that is what was closing its window mid-test)
  mv "$APP/Contents/MacOS/PKD" "$APP/Contents/MacOS/PKDFault"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable PKDFault' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName PKD FaultTest' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Delete :LSEnvironment' "$APP/Contents/Info.plist" 2>/dev/null
  /usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:PKD_DEVELOPMENT_ROOT string $ROOT" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CFFIXED_USER_HOME string $ROOT/cfprefs" "$APP/Contents/Info.plist"
  mkdir -p "$ROOT/cfprefs"
  codesign --force --sign - --identifier com.zeh.pkd.development "$APP" >/dev/null 2>&1
  codesign --verify --deep --strict "$APP" || { echo "FATAL: code signature invalid" >&2; exit 1; }
fi

# AX driver (compiled once for fast, reliable UI automation)
if [ ! -x "$EV/scripts/fault-ax" ]; then
  swiftc -O -o "$EV/scripts/fault-ax" "$REPO/tools/dev/fault-ax.swift" || { echo "FATAL: cannot build AX driver" >&2; exit 1; }
fi

# launch the copy directly with the dev root explicit on the environment too
SMOKE_ENV=""
if [ -n "${FAULT_SMOKE_INSPECTOR:-}" ]; then SMOKE_ENV="PKD_SMOKE_INSPECTOR=1"; fi
nohup env PKD_DEVELOPMENT_ROOT="$ROOT" CFFIXED_USER_HOME="$ROOT/cfprefs" $SMOKE_ENV \
  "$APP/Contents/MacOS/PKDFault" > "$EVID/app-stdout.log" 2>&1 &
DISOWN_PID=$!

PID=""
for _ in $(seq 1 60); do
  sleep 0.25
  PID="$(pgrep -f "$APP/Contents/MacOS/PKD" | head -1)"
  [ -n "$PID" ] || continue
  if "$EV/scripts/fault-ax" "$PID" "$(basename "$EV")" tree >/dev/null 2>&1; then break; fi
done
[ -n "$PID" ] || { echo "FATAL: isolated app did not start" >&2; exit 1; }

{
  echo "timestamp=$TS"
  echo "evidence_dir=$EV"
  echo "app_copy=$APP"
  echo "bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  echo "data_root=$ROOT"
  echo "pid=$PID"
  echo "dist_pkd=$(shasum -a 256 "$APP/Contents/MacOS/PKDFault" | awk '{print $1}')"
  echo "dist_repkg=$(shasum -a 256 "$APP/Contents/MacOS/repkg" | awk '{print $1}')"
  echo "launched_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
} | tee "$EVID/launch.txt"

echo "isolated app pid=$PID root=$ROOT"

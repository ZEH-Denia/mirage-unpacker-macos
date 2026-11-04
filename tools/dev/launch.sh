#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DEV_ROOT="$REPO/app/.build/private-development"
if pgrep -f "$DEV_ROOT/PKD Development.app/Contents/MacOS/PKD" >/dev/null; then
    osascript -e 'tell application id "com.zeh.pkd.development" to quit'
fi
python3 "$REPO/tools/dev/make_fixtures.py" "$DEV_ROOT"
(cd "$REPO/app" && ./scripts/make-app.sh)
DEV_APP="$DEV_ROOT/PKD Development.app"
ditto "$REPO/app/dist/PKD.app" "$DEV_APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.zeh.pkd.development' "$DEV_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName PKD 开发预览' "$DEV_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$DEV_APP/Contents/Info.plist"
codesign --force --sign - --identifier com.zeh.pkd.development "$DEV_APP"
codesign --verify --deep --strict "$DEV_APP"
open -n --env "PKD_DEVELOPMENT_ROOT=$DEV_ROOT" "$DEV_APP"
printf '开发副本：%s\n数据目录：%s\n' "$DEV_APP" "$DEV_ROOT"

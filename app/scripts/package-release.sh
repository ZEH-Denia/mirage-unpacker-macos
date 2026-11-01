#!/bin/bash
# 打包 Release DMG（PKD.app + /Applications 快捷方式）
# 命名约定：Mirage-Unpacker-for-macOS-<版本>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/PKD.app"

if [ ! -d "$APP" ]; then
  echo "缺少 $APP，请先运行 ./scripts/make-app.sh" >&2
  exit 1
fi

VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")}"
OUT="$ROOT/dist/Mirage-Unpacker-for-macOS-$VERSION.dmg"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/pkd-release-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

rm -f "$OUT"
# 以 ditto 保留 app bundle 的资源分支、扩展属性和框架符号链接。
ditto "$APP" "$STAGING/PKD.app"
ln -s /Applications "$STAGING/Applications"

# 压缩只读磁盘映像可直接挂载安装；Sparkle 也可使用同一个 DMG 更新。
diskutil image create from \
  --volumeName "Mirage Unpacker $VERSION" \
  --format UDZO \
  "$STAGING" \
  "$OUT"

echo "产物: $OUT"
ls -lh "$OUT" | awk '{print "大小: " $5}'
echo -n "SHA256: "
shasum -a 256 "$OUT" | awk '{print $1}'

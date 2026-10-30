#!/bin/bash
# 打包 Release 资产
# 命名约定：Mirage-Unpacker-for-macOS-<版本>.zip
#   —— 用连字符而不是空格，因为 GitHub 上传资产时会把空格替换成点号
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/PKD.app"

if [ ! -d "$APP" ]; then
  echo "缺少 $APP，请先运行 ./scripts/make-app.sh" >&2
  exit 1
fi

VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")}"
OUT="$ROOT/dist/Mirage-Unpacker-for-macOS-$VERSION.zip"

rm -f "$OUT"
# 用 ditto 而不是 zip：保留资源分支与扩展属性，签名才不会被破坏
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT"

echo "产物: $OUT"
ls -lh "$OUT" | awk '{print "大小: " $5}'
echo -n "SHA256: "
shasum -a 256 "$OUT" | awk '{print $1}'

#!/bin/bash
# 组装 PKD.app（本机无 Xcode，故用 SwiftPM 编译 + 手工建 bundle）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"      # app/
REPO="$(dirname "$ROOT")"                      # 仓库根
APP="$ROOT/dist/PKD.app"
VERSION="${PKD_VERSION:-1.0.0}"
BUILD="${PKD_BUILD:-1}"

echo "==> 编译 release"
cd "$ROOT"
swift build -c release --disable-sandbox --product PKD

if [ ! -x "$REPO/tools/bin/repkg" ]; then
  echo "缺少解包引擎 $REPO/tools/bin/repkg" >&2
  echo "请先运行: ./tools/build-repkg.sh" >&2
  exit 1
fi

echo "==> 组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/PKD" "$APP/Contents/MacOS/PKD"
chmod +x "$APP/Contents/MacOS/PKD"

# 引擎放在 MacOS/ 而不是 Resources/：便于被 codesign 当作辅助可执行文件一起签名
cp "$REPO/tools/bin/repkg" "$APP/Contents/MacOS/repkg"
chmod 755 "$APP/Contents/MacOS/repkg"

echo "==> 生成图标"
ICNS="$ROOT/dist/AppIcon.icns"
if [ ! -f "$ICNS" ]; then
  mkdir -p "$ROOT/dist"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/dist/icon-1024.png"
  ICONSET="$ROOT/dist/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/dist/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ROOT/dist/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

echo "==> 写入 Info.plist"
cp "$ROOT/Resources/Info.plist.template" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 签名（分层，不用 --deep）"
codesign --force --sign - --identifier com.zeh.pkd.repkg "$APP/Contents/MacOS/repkg"
codesign --force --sign - --identifier com.zeh.pkd "$APP/Contents/MacOS/PKD"
codesign --force --sign - --identifier com.zeh.pkd "$APP"
xattr -cr "$APP" || true

echo "==> 验证"
codesign --verify --strict "$APP" && echo "签名校验通过"
echo "✅ 产物：$APP"
du -sh "$APP"

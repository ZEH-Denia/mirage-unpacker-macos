#!/bin/bash
# 组装 PKD.app（本机无 Xcode，故用 SwiftPM 编译 + 手工建 bundle）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"      # app/
REPO="$(dirname "$ROOT")"                      # 仓库根
APP="$ROOT/dist/PKD.app"
TAG_VERSION="$(git -C "$REPO" describe --tags --exact-match HEAD 2>/dev/null || true)"
TAG_VERSION="${TAG_VERSION#v}"
VERSION="${PKD_VERSION:-${TAG_VERSION:-$(tr -d '\n' < "$REPO/VERSION")}}"
BUILD="${PKD_BUILD:-$VERSION}"

if ! [[ "$BUILD" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "CFBundleVersion 必须是 1 到 3 段的数字版本，当前值：$BUILD" >&2
  exit 1
fi

echo "==> 编译 release"
cd "$ROOT"
swift build -c release --disable-sandbox --product PKD

if [ ! -x "$REPO/tools/bin/repkg" ]; then
  echo "缺少解包引擎 $REPO/tools/bin/repkg" >&2
  echo "请先运行: ./tools/build-repkg.sh" >&2
  exit 1
fi
if [ ! -f "$REPO/tools/bin/REPKG-THIRD-PARTY-NOTICES.txt" ]; then
  echo "缺少 RePKG 第三方许可证声明，请重新运行 ./tools/build-repkg.sh" >&2
  exit 1
fi

SPARKLE_ARTIFACT="$ROOT/.build/artifacts/Sparkle/Sparkle"
SPARKLE_FRAMEWORK="$(find "$SPARKLE_ARTIFACT/Sparkle.xcframework" -path '*/Sparkle.framework' -type d -print -quit 2>/dev/null || true)"
if [ -z "$SPARKLE_FRAMEWORK" ] || [ ! -d "$SPARKLE_FRAMEWORK" ]; then
  echo "缺少 Sparkle.framework：$SPARKLE_ARTIFACT" >&2
  echo "请先运行 swift package resolve --disable-sandbox" >&2
  exit 1
fi

echo "==> 组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$ROOT/.build/release/PKD" "$APP/Contents/MacOS/PKD"
chmod +x "$APP/Contents/MacOS/PKD"

# 引擎放在 MacOS/ 而不是 Resources/：便于被 codesign 当作辅助可执行文件一起签名
cp "$REPO/tools/bin/repkg" "$APP/Contents/MacOS/repkg"
chmod 755 "$APP/Contents/MacOS/repkg"

echo "==> 嵌入 Sparkle"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

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

echo "==> 打包许可证与第三方声明"
cp "$REPO/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$REPO/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp "$REPO/tools/bin/REPKG-THIRD-PARTY-NOTICES.txt" \
  "$APP/Contents/Resources/REPKG-THIRD-PARTY-NOTICES.txt"
cp "$REPO/third-party-licenses/Sparkle-LICENSE.txt" \
  "$APP/Contents/Resources/SPARKLE-LICENSE.txt"

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
codesign --verify --deep --strict "$APP" && echo "签名校验通过"
otool -L "$APP/Contents/MacOS/PKD" | rg -q 'Sparkle.framework/Versions/.*/Sparkle' || {
  echo "PKD 可执行文件未链接到内嵌的 Sparkle.framework" >&2
  exit 1
}
echo "✅ 产物：$APP"
du -sh "$APP"

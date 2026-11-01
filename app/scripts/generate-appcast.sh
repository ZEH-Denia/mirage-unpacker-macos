#!/bin/bash
# 为当前版本生成经过 EdDSA 签名的 Sparkle appcast。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(dirname "$ROOT")"
if [ "$#" -ge 1 ]; then
  VERSION="$1"
else
  VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/dist/PKD.app/Contents/Info.plist")"
fi
TAG="${2:-v$VERSION}"
ARCHIVE="$ROOT/dist/Mirage-Unpacker-for-macOS-$VERSION.dmg"
SPARKLE_TOOL="$ROOT/.build/artifacts/Sparkle/Sparkle/bin/generate_appcast"

if [ ! -x "$SPARKLE_TOOL" ]; then
  echo "缺少 Sparkle generate_appcast，请先运行 swift package resolve --disable-sandbox" >&2
  exit 1
fi
if [ ! -f "$ARCHIVE" ]; then
  echo "缺少发布 DMG：$ARCHIVE，请先运行 ./scripts/package-release.sh" >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
cp "$ARCHIVE" "$TEMP_DIR/"

DOWNLOAD_PREFIX="https://github.com/ZEH-Denia/mirage-unpacker-macos/releases/download/$TAG/"
"$SPARKLE_TOOL" --download-url-prefix "$DOWNLOAD_PREFIX" "$TEMP_DIR"

if [ ! -s "$TEMP_DIR/appcast.xml" ]; then
  echo "Sparkle 没有生成 appcast.xml" >&2
  exit 1
fi

mkdir -p "$REPO/updates"
cp "$TEMP_DIR/appcast.xml" "$REPO/updates/appcast.xml"
echo "已生成并签名：$REPO/updates/appcast.xml"
echo "发布 DMG 后，将此文件推送到 main 以部署 GitHub Pages 更新 feed。"

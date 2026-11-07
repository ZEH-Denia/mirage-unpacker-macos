#!/bin/bash
# 存储清理与输出数据保护回归（隔离 fixture；不触碰真实用户目录与真实废纸篓）。
#
# 说明：
# - 依赖 `swift build --disable-sandbox` 产出的 PKDKit（与主工程同一份源码）。
# - 测试把 trash 注入为「移动到 fixture 内的 sink 目录」，权限拒绝等故障也由注入接口模拟，
#   不会对任何真实用户目录 chmod、不会写入 ~/.Trash。
# - 可用 PKD_STORAGE_SAFETY_ROOT 指定 fixture 根目录；默认落在 app/.build/storage-safety-<时间戳>/fixture。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$REPO/app"
BUILD="$APP/.build"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$BUILD/storage-safety-$STAMP"
mkdir -p "$OUT"

echo "==> 1/3 构建 PKDKit（--disable-sandbox）"
(cd "$APP" && swift build --disable-sandbox)

echo "==> 2/3 独立编译回归检查（链接 PKDKit）"
cp -f "$REPO/tools/dev/storage-safety-main.swift" "$OUT/main.swift"
swiftc -Onone -g \
  -I "$BUILD/debug" -L "$BUILD/debug" -lPKDKit \
  -o "$OUT/storage-safety-check" \
  "$OUT/main.swift" \
  "$APP/Sources/PKDSelfTest/StorageSafetyTests.swift"

echo "==> 3/3 运行隔离回归"
PKD_STORAGE_SAFETY_ROOT="$OUT/fixture" "$OUT/storage-safety-check"
echo "证据目录：$OUT"

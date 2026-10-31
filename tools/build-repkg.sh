#!/usr/bin/env bash
# 构建 RePKG（macOS / Linux 版）
#
# 用法: ./build-repkg.sh [运行时标识符]     默认 osx-arm64，可选 osx-x64 / linux-x64
#
# 上游 notscuffed/repkg 只面向 Windows（net472）。本脚本会：
#   1. 首次运行时 clone 上游到 tools/repkg
#   2. 应用 tools/repkg-macos.patch（移植到 .NET 8、修复上游问题并限制解包路径）
#   3. 以 self-contained 单文件方式发布到 tools/bin/repkg
set -euo pipefail

RID="${1:-osx-arm64}"
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$TOOLS_DIR/repkg"
OUT_DIR="$TOOLS_DIR/bin"
PATCH_FILE="$TOOLS_DIR/repkg-macos.patch"
UPSTREAM="${REPKG_UPSTREAM:-https://github.com/notscuffed/repkg.git}"

# --- 1. 取源码 -------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
  echo "==> 未找到上游源码，正在 clone $UPSTREAM"
  git clone --depth 1 "$UPSTREAM" "$SRC_DIR"
fi

if [ ! -f "$PATCH_FILE" ]; then
  echo "!! 缺少 macOS 补丁：$PATCH_FILE" >&2
  exit 1
elif git -C "$SRC_DIR" apply --ignore-space-change --check "$PATCH_FILE" 2>/dev/null; then
  echo "==> 应用 macOS 补丁"
  git -C "$SRC_DIR" apply --ignore-space-change "$PATCH_FILE"
elif git -C "$SRC_DIR" apply --ignore-space-change --check --reverse "$PATCH_FILE" 2>/dev/null; then
  echo "==> 补丁已应用过，跳过"
else
  echo "!! 补丁无法应用（上游可能已更新）。检查 $PATCH_FILE 后再构建。" >&2
  exit 1
fi

# --- 2. 定位 .NET SDK -----------------------------------------------------
DOTNET="${DOTNET:-}"
if [ -z "$DOTNET" ]; then
  for candidate in "$HOME/.dotnet/dotnet" /opt/homebrew/bin/dotnet /usr/local/share/dotnet/dotnet; do
    if [ -x "$candidate" ]; then DOTNET="$candidate"; break; fi
  done
fi
if [ -z "$DOTNET" ]; then
  DOTNET="$(command -v dotnet || true)"
fi
if [ -z "$DOTNET" ]; then
  cat >&2 <<'EOF'
未找到 dotnet。请先安装 .NET 8 SDK（二选一）：

  1) Homebrew（需要管理员密码）
     brew install --cask dotnet-sdk

  2) 官方脚本装到用户目录（无需 sudo）
     curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
     bash /tmp/dotnet-install.sh --channel 8.0 --install-dir "$HOME/.dotnet"

装好后重新运行本脚本即可。
EOF
  exit 1
fi

echo "==> dotnet: $DOTNET ($("$DOTNET" --version))"
echo "==> RID:    $RID"

# --- 3. 发布 --------------------------------------------------------------
"$DOTNET" publish "$SRC_DIR/RePKG/RePKG.csproj" \
  -c Release \
  -r "$RID" \
  --self-contained true \
  -p:PublishSingleFile=true \
  -p:PublishTrimmed=true \
  -p:EnableCompressionInSingleFile=true \
  -o "$OUT_DIR"

chmod +x "$OUT_DIR/repkg"
if [ ! -f "$SRC_DIR/THIRD-PARTY-NOTICES.txt" ]; then
  echo "!! 上游缺少 THIRD-PARTY-NOTICES.txt，无法生成完整发布许可声明。" >&2
  exit 1
fi
cp "$SRC_DIR/THIRD-PARTY-NOTICES.txt" "$OUT_DIR/REPKG-THIRD-PARTY-NOTICES.txt"
echo
echo "==> 构建完成: $OUT_DIR/repkg"
"$OUT_DIR/repkg" version 2>&1 | head -3 || true

# --- 4. 冒烟测试 ----------------------------------------------------------
# 单文件发布必须把 ImageSharp / LZ4 等运行时依赖打进去，否则解包时会在
# TEX → PNG 这一步抛 FileNotFoundException。这里直接跑一次真实转换来验证。
TEST_PKG="$TOOLS_DIR/testdata/test_scene.pkg"
if [ ! -f "$TEST_PKG" ] && command -v python3 >/dev/null 2>&1; then
  python3 "$TOOLS_DIR/testdata/make_test_pkg.py" "$TOOLS_DIR/testdata" >/dev/null 2>&1 || true
fi

if [ -f "$TEST_PKG" ]; then
  SMOKE_DIR="$(mktemp -d)"
  "$OUT_DIR/repkg" extract -o "$SMOKE_DIR/out" "$TEST_PKG" >"$SMOKE_DIR/log.txt" 2>&1 || true
  if find "$SMOKE_DIR/out" -name "*.png" 2>/dev/null | head -1 | grep -q .; then
    echo "==> 冒烟通过：TEX → PNG 转换正常"
  else
    echo "!! 冒烟失败：纹理转换不可用，单文件很可能缺少运行时依赖" >&2
    grep -iE "exception|could not load" "$SMOKE_DIR/log.txt" | head -3 >&2
    rm -rf "$SMOKE_DIR"
    exit 1
  fi
  rm -rf "$SMOKE_DIR"
else
  echo "!! 跳过冒烟测试：缺少 $TEST_PKG（可用 tools/testdata/make_test_pkg.py 生成）" >&2
fi

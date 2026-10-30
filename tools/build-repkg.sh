#!/usr/bin/env bash
# 构建 RePKG（macOS / Linux 版）
#
# 用法: ./build-repkg.sh [运行时标识符]     默认 osx-arm64，可选 osx-x64 / linux-x64
#
# 上游 notscuffed/repkg 只面向 Windows（net472）。本脚本会：
#   1. 首次运行时 clone 上游到 tools/repkg
#   2. 应用 tools/repkg-macos.patch（改目标框架、去掉 Windows 专属依赖、修两个 bug）
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

if [ -f "$PATCH_FILE" ] && git -C "$SRC_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
  echo "==> 应用 macOS 补丁"
  git -C "$SRC_DIR" apply "$PATCH_FILE"
elif git -C "$SRC_DIR" apply --check --reverse "$PATCH_FILE" 2>/dev/null; then
  echo "==> 补丁已应用过，跳过"
else
  echo "!! 补丁无法应用（上游可能已更新）。可手动检查 $PATCH_FILE" >&2
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
  -p:PublishTrimmed=false \
  -p:EnableCompressionInSingleFile=true \
  -o "$OUT_DIR"

chmod +x "$OUT_DIR/repkg"
echo
echo "==> 构建完成: $OUT_DIR/repkg"
"$OUT_DIR/repkg" version 2>&1 | head -3 || true

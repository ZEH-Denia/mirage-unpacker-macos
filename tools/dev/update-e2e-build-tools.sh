#!/bin/bash
# update-e2e-build-tools.sh — compile the AX harness binaries used by the update E2E
# into <work-dir>/bin (kept out of git; work-dir is usually app/.build/update-e2e-*).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${1:?usage: $0 <work-dir>}"
mkdir -p "$WORK/bin"
swiftc -O -o "$WORK/bin/update-ax" "$ROOT/tools/dev/update-ax.swift"
swiftc -O -o "$WORK/bin/update-window-id" "$ROOT/tools/dev/update-window-id.swift"
echo "built: $WORK/bin/update-ax $WORK/bin/update-window-id"

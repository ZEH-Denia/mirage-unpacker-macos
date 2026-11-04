#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BACKUP_DIR="${1:-$HOME/Documents/Codex/Backups/pkd-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$BACKUP_DIR"
git -C "$REPO" bundle create "$BACKUP_DIR/source.bundle" --all
python3 - "$REPO" "$BACKUP_DIR" <<'PY'
from pathlib import Path
import subprocess,sys,zipfile
repo,backup=map(Path,sys.argv[1:])
paths=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=repo).split(b'\0')
with zipfile.ZipFile(backup/'workspace.zip','w',zipfile.ZIP_DEFLATED) as out:
 for raw in paths:
  if not raw: continue
  rel=Path(raw.decode());src=repo/rel
  if src.is_file() and '__pycache__' not in rel.parts: out.write(src,rel)
print(backup)
PY

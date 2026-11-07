#!/bin/bash
# Fault case 3d: repkg engine is MISSING.
#
# The dev build's RepkgLocator falls back to "<repo>/tools/bin/repkg" using a
# path compiled into the binary, so a missing engine can only be produced without
# touching the shared repo binary by denying that path to the isolated app.
# We do that with a per-process sandbox profile (sandbox-exec), and remove the
# bundled helper from the app copy. The real tools/bin/repkg stays untouched.
#
# Stop the running isolated app before invoking this script.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fault-lib.sh"

OUT="$EVID/engine-missing"
mkdir -p "$OUT"
ENGINE="$APP/Contents/MacOS/repkg"
BACKUP="$EV/engine-backup/repkg"
REPO_ENGINE="$REPO/tools/bin/repkg"
ORIG_SHA="$(shasum -a 256 "$BACKUP" | awk '{print $1}')"
REPO_SHA_BEFORE="$(shasum -a 256 "$REPO_ENGINE" | awk '{print $1}')"

cleanup() {
  if [ -n "${APP_PID:-}" ]; then kill -9 "$APP_PID" 2>/dev/null; fi
  if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$ENGINE"; chmod 755 "$ENGINE"
    codesign --force --sign - --identifier com.zeh.pkd.development "$APP" >/dev/null 2>&1
  fi
  echo "restored engine sha=$(shasum -a 256 "$ENGINE" | awk '{print $1}') expected=$ORIG_SHA"
}
trap cleanup EXIT

# 1. deny the compiled-in dev fallback engine to this process only
cat > "$OUT/missing-engine.sb" <<EOF
(version 1)
(allow default)
(deny file-read* (literal "$REPO_ENGINE"))
(deny file-read-metadata (literal "$REPO_ENGINE"))
(deny process-exec (literal "$REPO_ENGINE"))
EOF

# 2. remove the bundled helper from the isolated copy
rm -f "$ENGINE"
echo "bundled engine removed: $([ -f "$ENGINE" ] && echo NO || echo yes) repo_engine_untouched=$([ "$(shasum -a 256 "$REPO_ENGINE" | awk '{print $1}')" = "$REPO_SHA_BEFORE" ] && echo yes || echo NO)" > "$OUT/setup.txt"

# 3. launch under the sandbox profile
env PKD_DEVELOPMENT_ROOT="$ROOT" CFFIXED_USER_HOME="$ROOT/cfprefs" \
  sandbox-exec -p "$(cat "$OUT/missing-engine.sb")" "$APP/Contents/MacOS/PKDFault" \
  > "$OUT/app-stdout.log" 2>&1 &
APP_PID=$!
echo "sandboxed app pid=$APP_PID" >> "$OUT/setup.txt"

for _ in $(seq 1 80); do
  sleep 0.25
  "$AXB" "$APP_PID" "$MARK" tree >/dev/null 2>&1 && break
done
sleep 2
"$AXB" "$APP_PID" "$MARK" tree > "$OUT/prestart-tree.txt" 2>&1
grep -q "未找到 repkg 引擎" "$OUT/prestart-tree.txt" && NOTICE=yes || NOTICE=no
echo "engine_missing_notice_visible=$NOTICE" >> "$OUT/setup.txt"

# 4. attempt to extract: the job must fail fast and truthfully
nav all >/dev/null 2>&1 || true
sleep 0.5
rm -rf "$ROOT/Images/03 损坏包_900003"
"$AXB" "$APP_PID" "$MARK" pressbutton "03 损坏包" >/dev/null 2>&1 || true
sleep 0.4
"$AXB" "$APP_PID" "$MARK" pressbutton "解包所选" >/dev/null 2>&1 || true
sleep 1.0
"$AXB" "$APP_PID" "$MARK" pressbutton "开始解包" >/dev/null 2>&1 || true
sleep 1.0
nav queue >/dev/null 2>&1 || true
sleep 1.0
"$AXB" "$APP_PID" "$MARK" tree > "$OUT/post-tree.txt" 2>&1
{
  echo "queue_summary=$(queue_summary)"
  echo "queue_states=$(queue_states)"
  echo "queue_rows=$(job_rows | paste -sd ';' -)"
  echo "temp_dirs=$(ls -d "${TMPDIR:-/tmp}"/PKD-extract-* 2>/dev/null | wc -l | tr -d ' ')"
  echo "repkg_running=$(repkg_pids)"
  echo "missing_engine_message_visible=$(grep -q '未找到 repkg 引擎' "$OUT/post-tree.txt" && echo yes || echo no)"
  echo "failed_message_visible=$(grep -q '失败：未找到 repkg 引擎' "$OUT/post-tree.txt" && echo yes || echo no)"
  echo "log_files=$(ls "$ROOT/Logs" 2>/dev/null | wc -l | tr -d ' ')"
} > "$OUT/facts.txt"
cat "$OUT/facts.txt"
echo "== missing-engine case done"

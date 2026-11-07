#!/bin/bash
# Fault case 2: force-quit (SIGKILL) the app during extraction, then relaunch.
#
# Product facts checked:
#   * the app has no persisted queue (in-memory only) -> after relaunch the queue is
#     empty by design; what matters is that no stale "running" UI/state survives,
#   * previously exported images and history must be intact,
#   * what happens to the repkg child process and the per-job temp directory.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fault-lib.sh"

OUT="$EVID/kill"
mkdir -p "$OUT"
TMPBASE="${TMPDIR:-/tmp}"
tmp_list() { ls -d "$TMPBASE"/PKD-extract-* 2>/dev/null | sort; }
img_dir() { printf '%s/Images/%s' "$ROOT" "$1"; }
OUT01="$(img_dir '01 正常小包_900001')"
OUT02="$(img_dir '02 慢速大包_900002')"

echo "== setup"
nav all >/dev/null
inspector show >/dev/null 2>&1 || true
sleep 0.5
show_log_tab >/dev/null 2>&1 || true
clear_finished
if [ -z "$(find "$OUT01" -type f 2>/dev/null | head -1)" ]; then
  start_extraction "01 正常小包" || exit 1
  nav queue >/dev/null
  poll_until "$OUT/a-baseline.csv" '共 .*1 成功' 30 "$OUT01" || true
fi
snapshot_tree "$OUT01" "$OUT/old-output-01.sha256" > "$OUT/old-output-01.count"
sha256sum "$ROOT/History/history.json" 2>/dev/null > "$OUT/history-before.sha256"
sha256sum "$ROOT/History/collections.json" 2>/dev/null > "$OUT/collections-before.sha256" || true
tmp_list > "$OUT/tmp-before.txt"
PID_BEFORE="$(require_app)"
echo "   app pid=$PID_BEFORE old images=$(cat "$OUT/old-output-01.count")"

echo "== start slow extraction, then SIGKILL the app mid-extraction"
nav queue >/dev/null; clear_finished; sleep 0.2
start_extraction "02 慢速大包" || exit 1
nav queue >/dev/null
for _ in $(seq 1 100); do
  sleep 0.2
  [ -n "$(repkg_pids)" ] && printf '%s' "$(queue_states)" | grep -q '解包中' && [ -n "$(tmp_list)" ] && break
done
JOB_TMP="$(tmp_list | head -1)"
ax tree > "$OUT/kill-prekill-tree.txt" 2>&1
PRE_TMP_FILES="$(file_count "$JOB_TMP")"
PRE_TMP_KB="$(du -sk "$JOB_TMP" 2>/dev/null | awk '{print $1}')"
PRE_REPKG="$(repkg_pids)"
echo "   pre-kill: summary=$(queue_summary) temp=$JOB_TMP files=$PRE_TMP_FILES kb=$PRE_TMP_KB repkg=$PRE_REPKG"
ORPHAN_PID="$(printf '%s' "$PRE_REPKG" | cut -d, -f1)"
{
  echo "app_pid=$PID_BEFORE"
  echo "job_temp=$JOB_TMP"
  echo "pre_temp_files=$PRE_TMP_FILES"
  echo "pre_temp_kb=$PRE_TMP_KB"
  echo "pre_repkg=$PRE_REPKG"
} > "$OUT/kill-facts.txt"

kill -9 "$PID_BEFORE"
sleep 0.3
APP_DEAD=no
kill -0 "$PID_BEFORE" 2>/dev/null && APP_DEAD=still-alive
echo "   app after SIGKILL: $APP_DEAD"

# observe the repkg child (expected: orphaned, keeps writing)
: > "$OUT/orphan-observation.csv"
printf 't,app_alive,repkg_alive,repkg_ppid,temp_files,temp_kb\n' > "$OUT/orphan-observation.csv"
for i in $(seq 1 40); do
  sleep 0.4
  app_alive=no; kill -0 "$PID_BEFORE" 2>/dev/null && app_alive=yes
  rp="$(repkg_pids)"
  ppid=""; [ -n "$rp" ] && ppid="$(ps -o ppid= -p "$(printf '%s' "$rp" | cut -d, -f1)" 2>/dev/null | tr -d ' ')"
  printf '%s,%s,%s,%s,%s,%s\n' "$i" "$app_alive" "${rp:--}" "${ppid:--}" "$(file_count "$JOB_TMP")" "$(du -sk "$JOB_TMP" 2>/dev/null | awk '{print $1}')" >> "$OUT/orphan-observation.csv"
  [ -z "$rp" ] && [ "$i" -gt 3 ] && break
done
ORPHAN_AFTER="$(repkg_pids)"
POST_TMP_FILES="$(file_count "$JOB_TMP")"
POST_TMP_KB="$(du -sk "$JOB_TMP" 2>/dev/null | awk '{print $1}')"
echo "   after wait: repkg=${ORPHAN_AFTER:--} temp_files=$POST_TMP_FILES kb=$POST_TMP_KB"
{
  echo "orphan_repkg_pid=$ORPHAN_PID"
  echo "orphan_repkg_after_wait=${ORPHAN_AFTER:--}"
  echo "temp_dir_after=$JOB_TMP"
  echo "post_temp_files=$POST_TMP_FILES"
  echo "post_temp_kb=$POST_TMP_KB"
} >> "$OUT/kill-facts.txt"

# exact-PID cleanup of any still-running orphan from THIS test only
if [ -n "$ORPHAN_AFTER" ]; then
  for p in $(printf '%s' "$ORPHAN_AFTER" | tr ',' ' '); do
    if [ "$p" = "$ORPHAN_PID" ]; then kill -9 "$p" 2>/dev/null; fi
  done
  sleep 0.5
fi
echo "   orphan repkg still alive after cleanup: $(repkg_pids)"

echo "== relaunch the isolated copy (same data root)"
"$REPO/tools/dev/fault-launch.sh" --keep-fixtures > "$OUT/relaunch.txt" 2>&1
NEW_PID="$(require_app)"
echo "   new app pid=$NEW_PID"
nav all >/dev/null; sleep 0.8
ax tree > "$OUT/post-restart-library-tree.txt" 2>&1
nav queue >/dev/null; sleep 0.8
ax tree > "$OUT/post-restart-queue-tree.txt" 2>&1
RESTART_SUMMARY="$(queue_summary)"
echo "   post-restart queue summary: ${RESTART_SUMMARY:-<empty>}"
{
  echo "post_restart_queue_summary=$RESTART_SUMMARY"
  echo "post_restart_queue_rows=$(job_rows | paste -sd ';' -)"
  echo "post_restart_repkg=$(repkg_pids)"
  echo "post_restart_temp_dirs=$(tmp_list | paste -sd ';' -)"
  echo "post_restart_logs=$(ls "$ROOT/Logs" 2>/dev/null | wc -l | tr -d ' ')"
  echo "history_after=$(sha256sum "$ROOT/History/history.json" 2>/dev/null | awk '{print $1}')"
  echo "collections_after=$(sha256sum "$ROOT/History/collections.json" 2>/dev/null | awk '{print $1}')"
} >> "$OUT/kill-facts.txt"
verify_snapshot "$OUT01" "$OUT/old-output-01.sha256" > "$OUT/post-restart-old-output-verify.txt" 2>&1
echo "   old-output problems: $(wc -l < "$OUT/post-restart-old-output-verify.txt" | tr -d ' ')"
for f in history collections; do
  old="$(cat "$OUT/$f-before.sha256" 2>/dev/null | awk '{print $1}')"
  new="$(sha256sum "$ROOT/History/$f.json" 2>/dev/null | awk '{print $1}')"
  echo "   $f.json: before=$old after=$new same=$([ "$old" = "$new" ] && echo yes || echo no)"
done
# bounded cleanup of the temp dir this test created (it is abandoned by the product)
if [ -n "$JOB_TMP" ] && [ -d "$JOB_TMP" ]; then
  echo "   product left abandoned temp dir: $JOB_TMP ($(file_count "$JOB_TMP") files) -> removing test-owned copy"
  rm -rf "$JOB_TMP"
fi
find "$ROOT/Logs" -type f | sed "s|$ROOT/Logs/||" | sort > "$OUT/logs-after-kill.txt"
exit 0

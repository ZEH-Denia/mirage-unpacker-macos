#!/bin/bash
# Fault case 1: user cancellation mid-extraction through the real UI.
#
# Runs in the development copy's DEFAULT mode ("仅导出图片"): repkg extracts into a
# per-job temp directory under $TMPDIR, then ImageExporter copies images to
# <root>/Images/<folder>/. That mode is what the dev copy forces at launch, so it
# is the honest product configuration for UI-level evidence.
#
#   A. baseline success (creates old exported images that must survive)
#   B. single-job cancel via the queue row "取消" button
#   C. "取消全部任务" with one running + one queued job
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fault-lib.sh"

OUT="$EVID/cancel"
mkdir -p "$OUT"
TMPBASE="${TMPDIR:-/tmp}"
tmp_list() { ls -d "$TMPBASE"/PKD-extract-* 2>/dev/null | sort; }
img_dir() { printf '%s/Images/%s' "$ROOT" "$1"; }
OUT01="$(img_dir '01 正常小包_900001')"
OUT02="$(img_dir '02 慢速大包_900002')"
OUT04="$(img_dir '04 后续正常_900004')"

echo "== setup: log inspector visible (log tab) so product log files are exercised"
nav all >/dev/null
inspector show >/dev/null 2>&1 || true
sleep 0.6
show_log_tab >/dev/null 2>&1 || true
sleep 0.4
tmp_list > "$OUT/tmp-before.txt"

echo "== A. baseline success for 01"
clear_finished
if [ -z "$(find "$OUT01" -type f 2>/dev/null | head -1)" ]; then
  start_extraction "01 正常小包" || exit 1
  nav queue >/dev/null
  poll_until "$OUT/a-baseline.csv" '共 .*1 成功' 30 "$OUT01" || true
fi
files01="$(snapshot_tree "$OUT01" "$OUT/old-output-01.sha256")"
echo "   old exported images: $files01"
[ -d "$OUT01" ] || { echo "FATAL: baseline did not produce exported images" >&2; exit 1; }
ax tree > "$OUT/a-baseline-tree.txt" 2>&1

echo "== B. single-job cancel (running job)"
nav queue >/dev/null; clear_finished; sleep 0.3
tmp_list > "$OUT/tmp-before-b.txt"
start_extraction "02 慢速大包" || exit 1
nav queue >/dev/null
for _ in $(seq 1 80); do
  sleep 0.25
  state="$(queue_states)"
  printf '%s' "$state" | grep -q '解包中' && break
done
# require the engine to be genuinely working on the big fixture
for _ in $(seq 1 80); do
  sleep 0.25
  n="$(ls -d "$TMPBASE"/PKD-extract-* 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -gt 0 ] && [ "$(repkg_pids)" != "" ] && break
done
ax tree > "$OUT/b-single-precancel-tree.txt" 2>&1
pre_tmp="$(tmp_list)"
pre_repkg="$(repkg_pids)"
pre_size="$(du -sk "$TMPBASE"/PKD-extract-* 2>/dev/null | awk '{s+=$1} END {print s+0}')"
echo "   pre-cancel: summary=$(queue_summary) states=$(queue_states) temp=${pre_tmp:-none} size=${pre_size}KB repkg=${pre_repkg:--}"
cancel_path="$(grep -E 'AXButton \| 取消 \|' "$OUT/b-single-precancel-tree.txt" | awk '{print $1}' | head -1)"
if [ -z "$cancel_path" ]; then
  echo "FATAL: no per-job cancel button found" >&2
  exit 1
fi
echo "   pressing cancel at $cancel_path"
ax press "$cancel_path" >/dev/null
poll_until "$OUT/b-single.csv" '共 .*1 取消' 40 "$OUT02" || true
sleep 0.5
ax tree > "$OUT/b-single-postcancel-tree.txt" 2>&1
post_tmp="$(tmp_list)"
echo "   post-cancel: summary=$(queue_summary) states=$(queue_states) temp=${post_tmp:-none} repkg=$(repkg_pids)"
{
  echo "pre_temp_dirs=$pre_tmp"
  echo "pre_temp_kb=$pre_size"
  echo "pre_repkg=$pre_repkg"
  echo "post_temp_dirs=$post_tmp"
  echo "post_repkg=$(repkg_pids)"
  echo "queued_output_exists=$([ -d "$OUT02" ] && echo yes || echo no)"
  echo "queued_output_files=$(file_count "$OUT02")"
} > "$OUT/b-single-facts.txt"
verify_snapshot "$OUT01" "$OUT/old-output-01.sha256" > "$OUT/b-single-old-output-verify.txt" 2>&1
echo "   old-output problems: $(wc -l < "$OUT/b-single-old-output-verify.txt" | tr -d ' ')"

echo "== C. cancel all (one running + one queued)"
nav queue >/dev/null; clear_finished; sleep 0.3
tmp_list > "$OUT/tmp-before-c.txt"
start_extraction "02 慢速大包" || exit 1
nav queue >/dev/null
for _ in $(seq 1 80); do sleep 0.25; printf '%s' "$(queue_states)" | grep -q '解包中' && break; done
# enqueue a second batch while the first job is still running
start_extraction "04 后续正常" || exit 1
nav queue >/dev/null
sleep 0.5
ax tree > "$OUT/c-all-precancel-tree.txt" 2>&1
echo "   pre-cancel-all: summary=$(queue_summary) states=$(queue_states)"
if ! queue_summary | grep -q '2 项'; then echo "WARN: expected 2 queued jobs" >&2; fi
menu_click "任务" "取消全部任务" >/dev/null 2>&1 || true
poll_until "$OUT/c-all.csv" '共 .*2 取消' 45 "$OUT02" || true
sleep 1.2
ax tree > "$OUT/c-all-postcancel-tree.txt" 2>&1
post_tmp_c="$(tmp_list)"
echo "   post-cancel-all: summary=$(queue_summary) states=$(queue_states) temp=${post_tmp_c:-none} repkg=$(repkg_pids)"
{
  echo "summary=$(queue_summary)"
  echo "states=$(queue_states)"
  echo "running_output_exists=$([ -d "$OUT02" ] && echo yes || echo no)"
  echo "running_output_files=$(file_count "$OUT02")"
  echo "queued_output_exists=$([ -d "$OUT04" ] && echo yes || echo no)"
  echo "queued_output_files=$(file_count "$OUT04")"
  echo "temp_dirs=$post_tmp_c"
  echo "repkg_after=$(repkg_pids)"
} > "$OUT/c-all-facts.txt"
verify_snapshot "$OUT01" "$OUT/old-output-01.sha256" > "$OUT/c-all-old-output-verify.txt" 2>&1
echo "   old-output problems: $(wc -l < "$OUT/c-all-old-output-verify.txt" | tr -d ' ')"
ls -la "$ROOT/Logs" > "$OUT/logs-listing.txt" 2>&1
exit 0

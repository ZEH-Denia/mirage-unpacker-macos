#!/bin/bash
# Fault case 4: does the product's log record (in-app inspector + the per-job file
# under <root>/Logs, the dev equivalent of ~/Library/Logs/PKD) tell the truth?
#
# L1  job finishes while the log inspector is closed  -> is a file written at all?
# L2  open the inspector afterwards                    -> delayed file? complete?
# L3  cancel with the inspector visible                -> terminal "已取消" recorded?
# L4  hide the inspector mid-job, end the job, show it again
#     -> is the already-written part of the log preserved, or destroyed?
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fault-lib.sh"

OUT="$EVID/logprobe"
mkdir -p "$OUT"
TMPBASE="${TMPDIR:-/tmp}"
tmp_list() { ls -d "$TMPBASE"/PKD-extract-* 2>/dev/null | sort; }
: > "$OUT/transcript.txt"
event() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT/transcript.txt"; }
new_logs() { find "$ROOT/Logs" -name '*.log' -newer "$1" -type f 2>/dev/null | sort; }
has() { grep -qF "$2" "$1" 2>/dev/null && echo yes || echo no; }
head1() { head -1 "$1" 2>/dev/null | cut -c1-90; }
tail1() { tail -1 "$1" 2>/dev/null | cut -c1-90; }
cancel_all() { menu_click "任务" "取消全部任务" >/dev/null 2>&1 || true; }

echo "== L1: finished job, log inspector closed"
inspector hide >/dev/null 2>&1 || true
sleep 0.5
nav queue >/dev/null; clear_finished; sleep 0.3
rm -rf "$ROOT/Images/04 后续正常_900004"
touch "$OUT/marker-l1"
start_extraction "04 后续正常" || exit 1
nav queue >/dev/null
poll_until "$OUT/l1-queue.csv" '共 .*1 成功' 30 || true
sleep 3
L1="$(new_logs "$OUT/marker-l1")"
event "L1 hidden_inspector queue=$(queue_summary) new_log_files=${L1:-none}"
{ echo "inspector_hidden=true"; echo "queue=$(queue_summary)"; echo "new_log_files=${L1:-none}"; } > "$OUT/l1-facts.txt"

echo "== L2: open log inspector after the job already ended"
inspector show >/dev/null 2>&1 || true
sleep 0.6
show_log_tab >/dev/null 2>&1 || true
sleep 2.5
L2="$(new_logs "$OUT/marker-l1" | head -1)"
event "L2 reopened_inspector new_file=${L2:-none} terminal_success=$( [ -n "$L2" ] && has "$L2" '结束：成功' || echo n/a)"
{ echo "new_file=${L2:-none}"
  [ -n "$L2" ] && { echo "size=$(stat -f %z "$L2")"; echo "has_terminal_success=$(has "$L2" '结束：成功')"; echo "has_done_sentinel=$(has "$L2" '完成标记')"; echo "head=$(head1 "$L2")"; echo "tail=$(tail1 "$L2")"; }
} > "$OUT/l2-facts.txt"

echo "== L3: cancel with the log inspector visible"
nav queue >/dev/null; clear_finished; sleep 0.3
rm -rf "$ROOT/Images/02 慢速大包_900002"
touch "$OUT/marker-l3"
start_extraction "02 慢速大包" || exit 1
nav queue >/dev/null
for _ in $(seq 1 100); do sleep 0.2; printf '%s' "$(queue_states)" | grep -q '解包中' && [ -n "$(tmp_list)" ] && break; done
sleep 1.5
cancel_all
poll_until "$OUT/l3-queue.csv" '共 .*1 取消' 40 || true
sleep 2.5
L3="$(new_logs "$OUT/marker-l3" | head -1)"
event "L3 cancelled queue=$(queue_summary) file=${L3:-none} terminal_cancel=$( [ -n "$L3" ] && has "$L3" '结束：已取消' || echo n/a)"
{ echo "queue=$(queue_summary)"
  echo "file=${L3:-none}"
  [ -n "$L3" ] && { echo "size=$(stat -f %z "$L3")"; echo "has_terminal_cancel=$(has "$L3" '结束：已取消')"; echo "has_terminating=$(has "$L3" '收到中断信号')"; echo "head=$(head1 "$L3")"; echo "tail=$(tail1 "$L3")"; }
} > "$OUT/l3-facts.txt"

echo "== L4: hide inspector mid-job, end job, show inspector again"
nav queue >/dev/null; clear_finished; sleep 0.3
rm -rf "$ROOT/Images/02 慢速大包_900002"
touch "$OUT/marker-l4"
start_extraction "02 慢速大包" || exit 1
nav queue >/dev/null
for _ in $(seq 1 100); do sleep 0.2; printf '%s' "$(queue_states)" | grep -q '解包中' && [ -n "$(tmp_list)" ] && break; done
sleep 2.0
L4="$(new_logs "$OUT/marker-l4" | head -1)"
SIZE_BEFORE="$(stat -f %z "$L4" 2>/dev/null)"
HEAD_BEFORE="$(head1 "$L4")"
event "L4 partial_file=${L4:-none} size_before=$SIZE_BEFORE head_before=$HEAD_BEFORE"
inspector hide >/dev/null 2>&1 || true
sleep 0.6
cancel_all
for _ in $(seq 1 100); do sleep 0.2; printf '%s' "$(queue_summary)" | grep -qE '取消|失败|成功' && break; done
sleep 1.5
SIZE_HIDDEN="$(stat -f %z "$L4" 2>/dev/null)"
event "L4 job_ended_while_hidden size=$SIZE_HIDDEN"
inspector show >/dev/null 2>&1 || true
sleep 0.6
show_log_tab >/dev/null 2>&1 || true
sleep 3
SIZE_AFTER="$(stat -f %z "$L4" 2>/dev/null)"
HEAD_AFTER="$(head1 "$L4")"
event "L4 inspector_reopened size=$SIZE_AFTER head=$HEAD_AFTER tail=$(tail1 "$L4")"
{ echo "file=${L4:-none}"
  echo "size_before_hide=$SIZE_BEFORE"; echo "head_before_hide=$HEAD_BEFORE"
  echo "size_job_ended_hidden=$SIZE_HIDDEN"
  echo "size_after_reopen=$SIZE_AFTER"; echo "head_after_reopen=$HEAD_AFTER"
  echo "tail_after_reopen=$(tail1 "$L4")"
  echo "header_changed=$([ "$HEAD_BEFORE" != "$HEAD_AFTER" ] && echo yes || echo no)"
  echo "file_shrank=$([ "${SIZE_AFTER:-0}" -lt "${SIZE_BEFORE:-0}" ] 2>/dev/null && echo yes || echo no)"
} > "$OUT/l4-facts.txt"
exit 0

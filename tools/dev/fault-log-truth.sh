#!/bin/bash
# Fault case 4: truthfulness of the log record (in-app 日志 inspector + per-job file
# under <root>/Logs, the dev equivalent of ~/Library/Logs/PKD).
#
# Run against an isolated copy launched with the product's own debug hooks:
#   PKD_SMOKE_INSPECTOR=1 (inspector expanded) and defaults pkd.debug.inspectorTab=logs
# so the log inspector (which owns the drain ticker) is actually rendering.
#
#   L1  inspector hidden       -> no log file at all for a finished job
#   L2  inspector shown later  -> file appears late; terminal line?
#   L3  engine failure, shown  -> retry + terminal failure recorded?
#   L4  cancel, shown          -> interruption + terminal cancel recorded?
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fault-lib.sh"

OUT="$EVID/logtruth"
mkdir -p "$OUT"
ENGINE="$APP/Contents/MacOS/repkg"
BACKUP="$EV/engine-backup/repkg"
ORIG_SHA="$(shasum -a 256 "$BACKUP" | awk '{print $1}')"
TMPBASE="${TMPDIR:-/tmp}"
tmp_list() { ls -d "$TMPBASE"/PKD-extract-* 2>/dev/null | sort; }
: > "$OUT/transcript.txt"
event() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT/transcript.txt"; }
new_logs() { find "$ROOT/Logs" -name '*.log' -newer "$1" -type f 2>/dev/null | sort; }
has() { grep -qF "$2" "$1" 2>/dev/null && echo yes || echo no; }
first() { head -1 "$1" 2>/dev/null | cut -c1-80; }
last() { tail -1 "$1" 2>/dev/null | cut -c1-90; }
cancel_all() { menu_click "任务" "取消全部任务" >/dev/null 2>&1 || true; }

restore_engine() {
  cp "$BACKUP" "$ENGINE"; chmod 755 "$ENGINE"
  codesign --force --sign - --identifier com.zeh.pkd.development "$APP" >/dev/null 2>&1
  local now; now="$(shasum -a 256 "$ENGINE" | awk '{print $1}')"
  echo "restore_engine ok=$([ "$now" = "$ORIG_SHA" ] && echo yes || echo NO)" >> "$OUT/transcript.txt"
}
trap restore_engine EXIT

echo "== preflight: inspector must be showing the 日志 tab"
nav all >/dev/null 2>&1 || true
inspector show >/dev/null 2>&1 || true
sleep 0.8
TAB="$(ax tree 2>/dev/null | grep -E 'AXRadioButton \| 日志 \|' | head -1)"
event "preflight log_tab_radio=${TAB:-missing}"
[ -n "$TAB" ] || exit 2

echo "== L1: finished job with inspector hidden"
inspector hide >/dev/null 2>&1 || true
sleep 0.6
nav queue >/dev/null; clear_finished; sleep 0.3
rm -rf "$ROOT/Images/04 后续正常_900004"
touch "$OUT/marker-l1"
start_extraction "04 后续正常" || exit 1
nav queue >/dev/null
poll_until "$OUT/l1.csv" '共 .*1 成功' 30 || true
sleep 3
L1="$(new_logs "$OUT/marker-l1")"
event "L1 hidden queue=$(queue_summary) new_log_files=${L1:-none}"
{ echo "queue=$(queue_summary)"; echo "new_log_files=${L1:-none}"; } > "$OUT/l1-facts.txt"

echo "== L2: show inspector after the job ended"
inspector show >/dev/null 2>&1 || true
sleep 3
L2="$(new_logs "$OUT/marker-l1" | head -1)"
event "L2 shown_late file=${L2:-none} terminal=$( [ -n "$L2" ] && has "$L2" '结束：成功' || echo n/a)"
{ echo "file=${L2:-none}"
  [ -n "$L2" ] && { echo "size=$(stat -f %z "$L2")"; echo "has_terminal_success=$(has "$L2" '结束：成功')"; echo "has_done_sentinel=$(has "$L2" '完成标记')"; echo "head=$(first "$L2")"; echo "tail=$(last "$L2")"; }
} > "$OUT/l2-facts.txt"

echo "== L3: engine failure with the log inspector visible"
nav queue >/dev/null; clear_finished; sleep 0.3
printf '#!/bin/bash\necho "[fault-wrapper] synthetic engine crash" >&2\nsleep 1\nexit 1\n' > "$ENGINE"
chmod 755 "$ENGINE"; codesign --force --sign - --identifier com.zeh.pkd.development "$APP" >/dev/null 2>&1
touch "$OUT/marker-l3"
nav all >/dev/null; sleep 0.5
start_extraction "04 后续正常" || exit 1
nav queue >/dev/null
poll_until "$OUT/l3.csv" '共 .*1 失败' 40 || true
sleep 2.5
L3="$(new_logs "$OUT/marker-l3" | head -1)"
event "L3 engine_failure queue=$(queue_summary) file=${L3:-none} retry=$( [ -n "$L3" ] && grep -cF '自动重试一次' "$L3" || echo n/a)"
{ echo "queue=$(queue_summary)"
  echo "ui_failure=$(ax tree 2>/dev/null | grep -oE '失败：[^|]*' | head -1)"
  echo "file=${L3:-none}"
  [ -n "$L3" ] && { echo "size=$(stat -f %z "$L3")"; echo "retry_lines=$(grep -cF '自动重试一次' "$L3")"; echo "has_failure_terminal=$(has "$L3" '结束：失败')"; echo "has_success_terminal=$(has "$L3" '结束：成功')"; echo "tail=$(last "$L3")"; }
} > "$OUT/l3-facts.txt"
restore_engine

echo "== L4: cancellation with the log inspector visible"
nav queue >/dev/null; clear_finished; sleep 0.3
rm -rf "$ROOT/Images/02 慢速大包_900002"
touch "$OUT/marker-l4"
start_extraction "02 慢速大包" || exit 1
nav queue >/dev/null
for _ in $(seq 1 100); do sleep 0.2; printf '%s' "$(queue_states)" | grep -q '解包中' && [ -n "$(tmp_list)" ] && break; done
sleep 1.5
cancel_all
poll_until "$OUT/l4.csv" '共 .*1 取消' 40 || true
sleep 2.5
L4="$(new_logs "$OUT/marker-l4" | head -1)"
event "L4 cancel queue=$(queue_summary) file=${L4:-none} terminal_cancel=$( [ -n "$L4" ] && has "$L4" '结束：已取消' || echo n/a)"
{ echo "queue=$(queue_summary)"; echo "file=${L4:-none}"
  [ -n "$L4" ] && { echo "size=$(stat -f %z "$L4")"; echo "has_terminating=$(has "$L4" '收到中断信号')"; echo "has_terminal_cancel=$(has "$L4" '结束：已取消')"; echo "tail=$(last "$L4")"; }
} > "$OUT/l4-facts.txt"
restore_engine
exit 0

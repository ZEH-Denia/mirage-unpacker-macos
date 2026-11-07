#!/bin/bash
# Shared helpers for the isolated queue-fault acceptance run.
#
# Every script here must be invoked with FAULT_EV pointing at the evidence
# directory created by tools/dev/fault-launch.sh (app/.build/fault-<ts>).
# Nothing in here touches the installed app, the real library, or /Applications.
set -uo pipefail

: "${FAULT_EV:?FAULT_EV must point at app/.build/fault-<timestamp>}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EV="$FAULT_EV"
case "$EV" in
  /*) ;;
  *) EV="$REPO/$EV" ;;
esac
APP="$EV/app/PKD Fault.app"
AXB="$EV/scripts/fault-ax"
MARK="$(basename "$EV")"
ROOT="$EV/root"
EVID="$EV/evidence"
mkdir -p "$EVID"

truthy() { "$@" >/dev/null 2>&1; }

app_pid() {
  pgrep -f "$APP/Contents/MacOS/PKDFault" | head -1
}

require_app() {
  local pid
  pid="$(app_pid)"
  [ -n "$pid" ] || { echo "FATAL: isolated app is not running ($APP)" >&2; exit 1; }
  printf '%s' "$pid"
}

ax() {
  local pid
  pid="$(require_app)"
  "$AXB" "$pid" "$MARK" "$@"
}

# click a menu item of a top-level menu in the isolated app only
menu_click() {
  local menu="$1" item="$2" pid
  pid="$(require_app)"
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to click menu item \"$item\" of menu 1 of menu bar item \"$menu\" of menu bar 1"
}

nav() {
  case "$1" in
    all) menu_click "视图" "全部壁纸" ;;
    queue) menu_click "视图" "队列" ;;
    *) echo "unknown nav $1" >&2; return 1 ;;
  esac
}

inspector_present() {
  ax tree 2>/dev/null | grep -q 'AXRadioButton | 日志'
}

inspector() {
  if inspector_present; then
    [ "$1" = "hide" ] && menu_click "视图" "隐藏检查器"
  else
    [ "$1" = "show" ] && menu_click "视图" "显示检查器"
  fi
  return 0
}

show_log_tab() {
  local path
  path="$(ax tree 2>/dev/null | grep -E 'AXRadioButton \| 日志 \|' | awk '{print $1}' | head -1)"
  [ -n "$path" ] || { echo "WARN: log tab radio not found (inspector closed?)" >&2; return 1; }
  ax press "$path"
}

clear_finished() {
  ax pressbutton "清除已结束" >/dev/null 2>&1 || true
}

queue_summary() {
  ax tree 2>/dev/null | grep -E 'AXStaticText \|  \| 共 ' | grep -oE '共 .*' | head -1
}

queue_states() {
  ax tree 2>/dev/null | grep -E 'AXStaticText \|  \| (排队中|读取包结构|解包中|正在停止|成功|部分成功|失败|已取消)' \
    | grep -oE '(排队中|读取包结构|解包中|正在停止|成功|部分成功|失败|已取消)' | paste -sd ',' -
}

job_rows() {
  ax tree 2>/dev/null | grep -E 'AXStaticText \|  \| [0-9]{6} ' | sed 's/.*|  //'
}

output_dir_for() {
  case "$1" in
    01) printf '%s/Extracted/01 正常小包_900001' "$ROOT" ;;
    02) printf '%s/Extracted/02 慢速大包_900002' "$ROOT" ;;
    04) printf '%s/Extracted/04 后续正常_900004' "$ROOT" ;;
    *) echo "unknown fixture $1" >&2; return 1 ;;
  esac
}

file_count() {
  local dir="$1"
  if [ -d "$dir" ]; then find "$dir" -type f 2>/dev/null | wc -l | tr -d ' '; else printf '0'; fi
}

# sha256 manifest of a directory tree (sorted, relative paths)
snapshot_tree() {
  local dir="$1" out="$2"
  : > "$out"
  if [ -d "$dir" ]; then
    (cd "$dir" && find . -type f | sort | while IFS= read -r f; do shasum -a 256 "$f"; done) > "$out"
  fi
  wc -l < "$out" | tr -d ' '
}

verify_snapshot() {
  local dir="$1" manifest="$2"
  (cd "$dir" && shasum -a 256 -c "$manifest" 2>&1 | grep -v ': OK$' | head -20)
}

tmp_files_in() {
  find "$1" -type f \( -name '*.tmp' -o -name '*.part' -o -name '*.download' -o -name '.*tmp*' \) 2>/dev/null | head -20
}

repkg_pids() {
  pgrep -f "$REPO/tools/bin/repkg|$APP/Contents/MacOS/repkg" 2>/dev/null | paste -sd ',' -
}

new_log_files_since() {
  local marker_file="$1"
  find "$ROOT/Logs" -name '*.log' -newer "$marker_file" -type f 2>/dev/null | sort
}

touch_marker() { local m="$1"; touch "$m"; }

# run an extraction of one fixture through the real UI:
# select card -> toolbar 解包所选 -> confirm sheet 开始解包
start_extraction() {
  local item="$1"                 # e.g. "02 慢速大包"
  nav all >/dev/null
  sleep 0.6
  ax pressbutton "$item" >/dev/null || { echo "FATAL: cannot select $item" >&2; return 1; }
  sleep 0.4
  ax pressbutton "解包所选" >/dev/null || { echo "FATAL: extract button unavailable" >&2; return 1; }
  sleep 0.9
  # the confirmation sheet only exists when "开始前确认" is enabled
  ax pressbutton "开始解包" >/dev/null 2>&1 || true
  sleep 0.3
}

# poll queue/output/process state into a CSV until the queue text matches a pattern or timeout
poll_until() {
  local out_csv="$1" stop_pattern="$2" timeout_s="${3:-25}" dir="${4:-}"
  local start now line
  start=$(date +%s)
  printf 'ts,summary,states,files,repkg_pids\n' > "$out_csv"
  while :; do
    now=$(date +%s)
    local summary states files rpids
    summary="$(queue_summary)"
    states="$(queue_states)"
    files="$(file_count "$dir")"
    rpids="$(repkg_pids)"
    printf '%s,%s,%s,%s,%s\n' "$(date +%H:%M:%S.%3N 2>/dev/null || date +%H:%M:%S)" "$summary" "$states" "$files" "${rpids:--}" >> "$out_csv"
    if [ -n "$stop_pattern" ] && printf '%s' "$summary" | grep -Eq "$stop_pattern"; then
      return 0
    fi
    if [ $((now - start)) -ge "$timeout_s" ]; then
      echo "TIMEOUT after ${timeout_s}s waiting for /$stop_pattern/ (last summary: $summary)" >&2
      return 1
    fi
    sleep 0.25
  done
}

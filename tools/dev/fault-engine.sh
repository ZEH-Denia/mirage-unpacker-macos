#!/bin/bash
# Fault case 3: engine failure paths through the real product.
#
#   E1  engine exits non-zero          -> job must end failed, tell the truth, retry once, no false success
#   E1b queue continues after failure  -> next job with a working engine succeeds
#   E2  engine exits 0 but never prints the Done sentinel (RePKG's real exit-code
#       behaviour) -> must NOT be reported as success
#   E3  genuinely corrupt scene.pkg with the real engine -> real crash path
#
# The engine inside the isolated app copy is replaced with a synthetic wrapper and
# restored afterwards; the original hash is recorded in evidence/engine-original-sha256.txt.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fault-lib.sh"

OUT="$EVID/engine"
mkdir -p "$OUT"
ENGINE="$APP/Contents/MacOS/repkg"
BACKUP="$EV/engine-backup/repkg"
mkdir -p "$EV/engine-backup"
TMPBASE="${TMPDIR:-/tmp}"
tmp_count() { ls -d "$TMPBASE"/PKD-extract-* 2>/dev/null | wc -l | tr -d ' '; }
ORIG_SHA="$(awk '/Contents\/MacOS\/repkg$/ {print $1}' "$EVID/engine-original-sha256.txt" 2>/dev/null | head -1)"
[ -n "$ORIG_SHA" ] || ORIG_SHA="$(shasum -a 256 "$ENGINE" | awk '{print $1}')"

# the file log only gets flushed while the log inspector is visible: keep it open
# on the 日志 tab for this case so the product log record can be judged at all
nav all >/dev/null 2>&1 || true
inspector show >/dev/null 2>&1 || true
sleep 0.6
show_log_tab >/dev/null 2>&1 || true
sleep 0.4

restore_engine() {
  cp "$BACKUP" "$ENGINE"
  chmod 755 "$ENGINE"
  codesign --force --sign - --identifier com.zeh.pkd.development "$APP" >/dev/null 2>&1
  local now; now="$(shasum -a 256 "$ENGINE" | awk '{print $1}')"
  echo "restore_engine sha=$now expected=$ORIG_SHA ok=$([ "$now" = "$ORIG_SHA" ] && echo yes || echo NO)" | tee -a "$OUT/engine-restore.txt"
}

if [ ! -f "$BACKUP" ]; then cp "$ENGINE" "$BACKUP"; fi
echo "original engine sha256: $ORIG_SHA" > "$OUT/engine-original.txt"

write_wrapper() {
  # $1 = mode: crash1 | nodone
  local mode="$1"
  cat > "$ENGINE" <<EOF
#!/bin/bash
# synthetic fault-injection engine wrapper (test only)
echo "### Extracting package: \$2" >&2
if [ "$mode" = "nodone" ]; then
  echo "### Extracting package: \$2"
  echo "* Extracting: fake/entry.bin"
  sleep 1
  exit 0
fi
echo "[fault-wrapper] synthetic engine crash" >&2
sleep 1
exit 1
EOF
  chmod 755 "$ENGINE"
  echo "wrapper installed: $mode sha=$(shasum -a 256 "$ENGINE" | awk '{print $1}')"
}

newest_log_since() {
  local marker="$1"
  local f out=""
  for f in "$ROOT"/Logs/*.log; do
    [ -f "$f" ] || continue
    if [ "$f" -nt "$marker" ]; then out="$f"; break; fi
  done
  printf '%s' "$out"
}

run_failing_job() {
  # $1 = case tag, $2 = fixture title, $3 = expected failure substring
  local tag="$1" item="$2" expect="$3"
  nav queue >/dev/null; clear_finished; sleep 0.3
  local marker="$OUT/marker-$tag"; touch "$marker"

  start_extraction "$item" || return 1
  nav queue >/dev/null
  poll_until "$OUT/$tag-queue.csv" '共 .*(失败|成功)' 45 || true
  sleep 1.5
  ax tree > "$OUT/$tag-post-tree.txt" 2>&1
  local summary states job_log
  summary="$(queue_summary)"; states="$(queue_states)"
  job_log="$(newest_log_since "$marker")"
  {
    echo "tag=$tag"
    echo "item=$item"
    echo "queue_summary=$summary"
    echo "queue_states=$states"
    echo "expected_substring=$expect"
    echo "state_matches_expected=$(printf '%s' "$states" | grep -qF "$expect" && echo yes || echo no)"
    echo "retry_button_present=$(grep -qE 'AXButton \| 重试' "$OUT/$tag-post-tree.txt" && echo yes || echo no)"
    echo "temp_dirs_after=$(tmp_count)"
    echo "repkg_after=$(repkg_pids)"
    if [ -n "$job_log" ]; then
      echo "log_file=$job_log"
      echo "log_size=$(stat -f %z "$job_log" 2>/dev/null)"
      echo "log_has_retry=$(grep -qF '自动重试一次' "$job_log" && echo yes || echo no)"
      echo "log_attempt_markers=$(grep -cE '=== .* ===' "$job_log" 2>/dev/null || echo 0)"
      echo "log_has_failure_terminal=$(grep -qF '结束：失败' "$job_log" && echo yes || echo no)"
      echo "log_has_success_terminal=$(grep -qF '结束：成功' "$job_log" && echo yes || echo no)"
      echo "log_tail=$(tail -1 "$job_log" | cut -c1-120)"
    fi
    echo "queue_row_text=$(ax tree 2>/dev/null | grep -E 'AXStaticText \|  \| .*·' | sed 's/.*|  //' | paste -sd ';' -)"
    echo "failure_message_in_ui=$(ax tree 2>/dev/null | grep -oE '失败：[^|]*' | head -1)"
  } > "$OUT/$tag-facts.txt"
  echo "   [$tag] summary=$summary states=$states"
  echo "   [$tag] log=$job_log retry=$(grep -cF '自动重试一次' "$job_log" 2>/dev/null) temp=$(tmp_count)"
}

echo "== E1: engine exits non-zero"
write_wrapper crash1
run_failing_job e1-crash "04 后续正常" "失败"
echo "== E1b: restore real engine, queue continues with the next job"
restore_engine >/dev/null
nav queue >/dev/null; clear_finished; sleep 0.3
rm -rf "$ROOT/Images/02 慢速大包_900002"
start_extraction "01 正常小包" || exit 1
nav queue >/dev/null
poll_until "$OUT/e1b-continue.csv" '共 .*1 成功' 30 || true
ax tree > "$OUT/e1b-post-tree.txt" 2>&1
{ echo "queue_summary=$(queue_summary)"; echo "queue_states=$(queue_states)"; } > "$OUT/e1b-facts.txt"
echo "   [e1b] $(queue_summary) / $(queue_states)"

echo "== E2: engine exits 0 but prints no Done sentinel (real RePKG exit-code behaviour)"
write_wrapper nodone
run_failing_job e2-nodone "04 后续正常" "失败"
restore_engine >/dev/null

echo "== E3: corrupt scene.pkg with the real engine"
rm -rf "$ROOT/Images/03 损坏包_900003"
write_wrapper_done=0
restore_engine >/dev/null
run_failing_job e3-corrupt "03 损坏包" "失败"

echo "== final: engine restored?"
restore_engine >/dev/null
NOW_SHA="$(shasum -a 256 "$ENGINE" | awk '{print $1}')"
echo "engine_sha_final=$NOW_SHA expected=$ORIG_SHA ok=$([ "$NOW_SHA" = "$ORIG_SHA" ] && echo yes || echo NO)" | tee -a "$OUT/engine-final.txt"
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 && echo "codesign_ok=yes" >> "$OUT/engine-final.txt" || echo "codesign_ok=no" >> "$OUT/engine-final.txt"
snapshot_tree "$ROOT/Images/01 正常小包_900001" "$OUT/old-output-01.sha256" > "$OUT/old-output-01.count"
echo "old images files: $(cat "$OUT/old-output-01.count")"
exit 0

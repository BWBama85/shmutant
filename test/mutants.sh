# shellcheck shell=bash
# shmutant, mutation-tested by itself. Every row breaks one guard in shmutant.sh and names the
# unit of test/run.sh that claims to cover it. Run from the repository root:
#
#   bash shmutant.sh run test/mutants.sh
#
# The harness driving this plan is the working tree's shmutant.sh; each row mutates a clone.

prepare() {
  mkdir -p "$1/test" || return 1
  cp -- "$SHMUTANT_PLAN_DIR/../shmutant.sh" "$1/" || return 1
  cp -- "$SHMUTANT_PLAN_DIR/run.sh" "$1/test/" || return 1
}

run() { bash "$1/test/run.sh"; }

shmutant_target shmutant.sh

# --- the bash floor ---
shmutant_mut 'the floor accepts any 5.x' \
  '[ "$1" -gt 5 ] || { [ "$1" -eq 5 ] && [ "$2" -ge 3 ]; }' \
  '[ "$1" -gt 5 ] || { [ "$1" -eq 5 ] && [ "$2" -ge 0 ]; }' \
  't_bash_floor'
shmutant_mut 'the floor accepts bash 4' \
  '[ "$1" -gt 5 ] || {' \
  '[ "$1" -gt 3 ] || {' \
  't_bash_floor'

# --- selection ---
shmutant_mut 'selection matches by substring, not equality' \
  '[ "$SHMUTANT_SELECT" = "$1" ]' \
  '[ "${1#*"$SHMUTANT_SELECT"}" != "$1" ]' \
  't_selected_predicate'
shmutant_mut 'selected units are not counted' \
  'SHMUTANT_SELECTED_N=$((SHMUTANT_SELECTED_N + 1))' \
  'SHMUTANT_SELECTED_N=$((SHMUTANT_SELECTED_N + 0))' \
  't_selected_predicate'

# --- copy_tree ---
shmutant_mut 'copy_tree copies .git' \
  '[ "$name" = .git ] && continue' \
  '[ "$name" = .git-never ] && continue' \
  't_copy_tree_excludes_git'
shmutant_mut 'copy_tree follows symlinks' \
  'cp -RP -- "$entry" "$dst/"' \
  'cp -RL -- "$entry" "$dst/"' \
  't_copy_tree_excludes_git'

# --- mutate ---
shmutant_mut 'mutate replaces every occurrence' \
  '!hit { i = index($0, old)' \
  '{ i = index($0, old)' \
  't_mutate_applies_first_occurrence_only'
shmutant_mut 'an unchanged file is reported as applied' \
  'if cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 2; fi' \
  'if cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi' \
  't_mutate_reports_unapplied'
shmutant_mut 'an empty old literal is accepted' \
  '[ -n "$2" ] || return 2' \
  '[ -n "$2" ] || return 0' \
  't_mutate_reports_unapplied'
shmutant_mut 'the new literal goes through -v and loses its backslashes' \
  'new = ENVIRON["SHMUTANT_MUT_NEW"]' \
  'new = ENVIRON["SHMUTANT_MUT_NEW"]; gsub(/\\/, "", new)' \
  't_mutate_keeps_backslashes'

# --- the table ---
shmutant_mut 'an absolute target is accepted' \
  'case "$1" in /*)' \
  'case "$1" in //*)' \
  't_mut_validates_rows'
shmutant_mut 'identical literals are accepted' \
  '[ "$2" != "$3" ] || {' \
  'true || {' \
  't_mut_validates_rows'
shmutant_mut 'select defaults to the name instead of the witness' \
  'SHMUTANT_ROWS_SEL+=("${5:-$4}")' \
  'SHMUTANT_ROWS_SEL+=("${5:-$1}")' \
  't_mut_validates_rows'
shmutant_mut 'reset keeps the target' \
  '  SHMUTANT_TARGET=""' \
  '  SHMUTANT_TARGET="$SHMUTANT_TARGET"' \
  't_reset_clears_table'

# --- pool preconditions ---
shmutant_mut 'an empty table is a pass' \
  'if [ "$n" -eq 0 ]; then' \
  'if [ "$n" -lt 0 ]; then' \
  't_pool_rejects_empty_table'
shmutant_mut 'a root outside the workdir is mutated' \
  '"$wd/pristine"|"$wd/pristine/"*) ;;' \
  '"$wd/pristine"|*) ;;' \
  't_pool_refuses_root_outside_workdir'
shmutant_mut 'a missing target is discovered per row instead of refused up front' \
  'if [ ! -f "$root/${SHMUTANT_ROWS_FILE[$i]}" ]; then' \
  'if false; then' \
  't_pool_refuses_missing_target'
shmutant_mut 'a bad SHMUTANT_TIMEOUT is accepted' \
  '*[!0-9]*|'"''"') _shmutant_err "$label: SHMUTANT_TIMEOUT' \
  'never-matches) _shmutant_err "$label: SHMUTANT_TIMEOUT' \
  't_pool_validates_timeout'

# --- verdicts ---
shmutant_mut 'the witness is checked against the selector' \
  '"${SHMUTANT_RED_PREFIX:-FAIL: }" "${SHMUTANT_ROWS_WIT[$i]}"' \
  '"${SHMUTANT_RED_PREFIX:-FAIL: }" "${SHMUTANT_ROWS_SEL[$i]}"' \
  't_verdict_accidental'
shmutant_mut 'a witness on a non-red line counts' \
  '"$2"*) case "$line" in *"$3"*) return 0 ;; esac ;;' \
  '*) case "$line" in *"$3"*) return 0 ;; esac ;;' \
  't_verdict_accidental'
shmutant_mut 'exit 1 without a red line is scored accidental' \
  'elif _shmutant_has_red_line' \
  'elif true || _shmutant_has_red_line' \
  't_verdict_aborted_no_red_line'
shmutant_mut 'any non-zero status counts as red' \
  'elif [ "$status" -eq "${SHMUTANT_RED_STATUS:-1}" ]; then' \
  'elif [ "$status" -ne 0 ]; then' \
  't_verdict_aborted_status'
shmutant_mut 'a green run is scored killed' \
  '    verdict=survived' \
  '    verdict=killed' \
  't_verdict_survived'
shmutant_mut 'the baseline pass is skipped by default' \
  'if [ "${SHMUTANT_BASELINE:-1}" != 0 ]; then' \
  'if [ "${SHMUTANT_BASELINE:-1}" = 0 ]; then' \
  't_verdict_baseline_red'
shmutant_mut 'rows on a red baseline run anyway' \
  '&& [ "${base_verdict[$k]}" != green ]; then' \
  '&& false; then' \
  't_verdict_baseline_red'
shmutant_mut 'the skip flag is ignored when starting workers' \
  'if [ "$kind" = mut ] && [ "${SHMUTANT_SKIP[$i]:-0}" != 0 ]; then continue; fi' \
  'if false; then continue; fi' \
  't_verdict_baseline_red'
shmutant_mut 'a timeout is reported as an abort' \
  ': > "$dir/timeout"' \
  ': > "$dir/timeout-never"' \
  't_verdict_timeout'
shmutant_mut 'a timeout kills the run but not its process tree' \
  'kill -TERM -- -"$pid" 2>/dev/null' \
  'kill -TERM -- "$pid" 2>/dev/null' \
  't_verdict_timeout'
shmutant_mut 'a blank verdict file reads as a verdict' \
  '[ -n "$SHMUTANT_V_VERDICT" ] || SHMUTANT_V_VERDICT=lost' \
  '[ -n "$SHMUTANT_V_VERDICT" ] || true' \
  't_read_verdict_fails_closed'

# --- mechanics ---
shmutant_mut 'run does not receive the selector' \
  '"$run" "$root" "$sel" )' \
  '"$run" "$root" )' \
  't_pool_passes_select_to_run'
shmutant_mut 'SHMUTANT_SELECT is exported with the wrong value' \
  'export SHMUTANT_SELECT="$sel";' \
  'export SHMUTANT_SELECT="$root";' \
  't_pool_passes_select_to_run'
shmutant_mut 'the pool admits one worker more than its width' \
  'if [ "${#pids[@]}" -ge "$jobs" ]; then' \
  'if [ "${#pids[@]}" -gt "$jobs" ]; then' \
  't_pool_honours_jobs'
shmutant_mut 'the cap no longer bounds SHMUTANT_JOBS' \
  '[ "$n" -le "$cap" ] || n="$cap"' \
  '[ "$n" -ge "$cap" ] || n="$cap"' \
  't_pool_honours_jobs'
shmutant_mut 'the pool reaps any job, including the caller'"'"'s' \
  'wait -n -p done_pid "${pids[@]}" || true' \
  'wait -n -p done_pid || true' \
  't_pool_does_not_reap_callers_jobs'
shmutant_mut 'baseline runs once per row instead of once per selector' \
  '[ "$k" = "$sel" ] && continue 2; done' \
  '[ "$k" = "$sel" ] && continue; done' \
  't_pool_runs_baseline_once_per_selector'
shmutant_mut 'SHMUTANT_KEEP=1 removes the clone' \
  '[ "${SHMUTANT_KEEP:-0}" = 1 ] || rm -rf -- "$dir/tree"' \
  '[ "${SHMUTANT_KEEP:-0}" = 0 ] || rm -rf -- "$dir/tree"' \
  't_pool_keep_retains_clones'
shmutant_mut 'a nested root is not carried into the clone' \
  'root="$dir/tree$suffix"' \
  'root="$dir/tree"' \
  't_pool_root_may_be_a_subdirectory'

# --- the stream ---
shmutant_mut 'a tab in a field is not escaped' \
  's="${s//$'"'"'\t'"'"'/\\t}"' \
  's="${s//$'"'"'\t'"'"'/ }"' \
  't_stream_format'
shmutant_mut 'durations truncate instead of rounding' \
  'ms=$(( (us + 500) / 1000 ))' \
  'ms=$(( us / 1000 ))' \
  't_stream_format'
shmutant_mut 'SHMUTANT_STREAM is ignored' \
  'if [ -n "${SHMUTANT_STREAM:-}" ]; then' \
  'if false; then' \
  't_stream_to_file'

# --- the CLI ---
shmutant_mut '--jobs accepts zero' \
  '_shmutant_pos_int "$2" > /dev/null || { _shmutant_err "--jobs' \
  'true || { _shmutant_err "--jobs' \
  't_cli_run'
shmutant_mut 'the label is not the plan name' \
  'shmutant_pool "$(basename -- "$plan")"' \
  'shmutant_pool "plan"' \
  't_cli_run'
shmutant_mut '--keep deletes the workdir' \
  'if [ "$keep" = 1 ]; then' \
  'if [ "$keep" = 0 ]; then' \
  't_cli_run'
shmutant_mut 'version prints the wrong marker' \
  '"$SHMUTANT_VERSION"' \
  '"$SHMUTANT_VERSION-mutant"' \
  't_cli_run'
shmutant_mut 'checksum prints the file name instead of the digest' \
  "sha256sum -- \"\$1\" | awk '{print \$1}'" \
  "sha256sum -- \"\$1\" | awk '{print \$2}'" \
  't_cli_run'

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
  'cp -RPp -- "$entry" "$dst/"' \
  'cp -RLp -- "$entry" "$dst/"' \
  't_copy_tree_excludes_git'

# --- mutate ---
shmutant_mut 'mutate replaces every occurrence' \
  '!hit { i = index($0, old)' \
  '{ i = index($0, old)' \
  't_mutate_applies_first_occurrence_only'
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
  'if ! _shmutant_inside "$wd/pristine" "$root"; then' \
  'if false; then' \
  't_pool_refuses_root_outside_workdir'
shmutant_mut 'a missing target is discovered per row instead of refused up front' \
  'if ! _shmutant_target_ok "$root" "${SHMUTANT_ROWS_FILE[$i]}"; then' \
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
  '        : > "$mark"' \
  '        :' \
  't_verdict_timeout'
shmutant_mut 'a timeout never escalates to KILL' \
  '        _shmutant_kill_tree KILL "$pid"' \
  '        :' \
  't_verdict_timeout_kills_a_term_ignoring_descendant'
shmutant_mut 'a blank verdict file reads as a verdict' \
  '[ -n "$SHMUTANT_V_VERDICT" ] || SHMUTANT_V_VERDICT=lost' \
  '[ -n "$SHMUTANT_V_VERDICT" ] || true' \
  't_read_verdict_fails_closed'

# --- mechanics ---
shmutant_mut 'run does not receive the selector' \
  '"$run" "$root" "$sel"; rrc=$?' \
  '"$run" "$root"; rrc=$?' \
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
  '[ "${SHMUTANT_KEEP:-0}" = 1 ] || rm -rf -- "$1/tree"' \
  '[ "${SHMUTANT_KEEP:-0}" = 0 ] || rm -rf -- "$1/tree"' \
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
shmutant_mut 'the label is not the plan name' \
  'shmutant_pool "$(basename -- "$plan")"' \
  'shmutant_pool "plan"' \
  't_cli_run'
shmutant_mut 'version prints the wrong marker' \
  '"$SHMUTANT_VERSION"' \
  '"$SHMUTANT_VERSION-mutant"' \
  't_cli_run'
shmutant_mut 'checksum prints the file name instead of the digest' \
  "sha256sum -- \"\$1\" | awk '{print \$1}'" \
  "sha256sum -- \"\$1\" | awk '{print \$2}'" \
  't_cli_run'

# --- guards added for the first review round ---
shmutant_mut 'a refused declaration is not counted' \
  'SHMUTANT_DECL_ERRORS=$((SHMUTANT_DECL_ERRORS + 1)); return 2' \
  'SHMUTANT_DECL_ERRORS=$((SHMUTANT_DECL_ERRORS + 0)); return 2' \
  't_refused_declarations_fail_the_pool'
shmutant_mut 'a stream write failure is swallowed' \
  '2>/dev/null || SHMUTANT_EMIT_FAILED=1' \
  '2>/dev/null || SHMUTANT_EMIT_FAILED=0' \
  't_stream_write_failure_is_a_harness_error'
shmutant_mut 'the rewrite drops the target mode' \
  'mode="$(ls -ld -- "$f" 2>/dev/null)"; mode="${mode%% *}"' \
  'mode="-rw-r--r--"' \
  't_mutate_preserves_mode'
shmutant_mut 'the rewrite always appends a final newline' \
  'ENVIRON["SHMUTANT_MUT_NL"] == 1) printf' \
  'ENVIRON["SHMUTANT_MUT_NL"] != 2) printf' \
  't_mutate_preserves_missing_final_newline'
shmutant_mut 'the temp file is a predictable sibling name again' \
  'tmp="$(mktemp "$(dirname -- "$f")/.shmutant.XXXXXX" 2>/dev/null)" || return 1' \
  'tmp="$f.shmutant-tmp"' \
  't_mutate_never_follows_a_stale_temp_link'
shmutant_mut 'the watchdog is cancelled before it can escalate to KILL' \
  '[ -e "$mark" ] || kill -TERM "$dog" 2>/dev/null' \
  'kill -TERM "$dog" 2>/dev/null' \
  't_verdict_timeout_kills_a_term_ignoring_descendant'
shmutant_mut 'worker directories are reused with their stale contents' \
  '  rm -rf -- "$1" 2>/dev/null' \
  '  :' \
  't_pool_recreates_worker_dirs'
shmutant_mut 'an unapplied row keeps its clone' \
  '2) _shmutant_worker_finish "$dir" unapplied 0 0; return 0 ;;' \
  '2) printf '"'"'unapplied\n0\n0\n'"'"' > "$dir/verdict"; return 0 ;;' \
  't_verdict_unapplied'

# --- guards added for the second review round ---
shmutant_mut 'a .. component in a target is accepted' \
  'case "/$1/" in */../*)' \
  'case "/$1/" in */.../*)' \
  't_mut_validates_rows'
shmutant_mut 'mutate rewrites through a symlink' \
  '[ -f "$f" ] && [ ! -L "$f" ] || return 1' \
  '[ -f "$f" ] || return 1' \
  't_mutate_refuses_a_symlink_target'
shmutant_mut 'the temp redirect honours noclobber' \
  ''"'"' "$f" >| "$tmp"; }' \
  ''"'"' "$f" > "$tmp"; }' \
  't_mutate_works_under_noclobber'
shmutant_mut 'a symlink target passes the pool precheck' \
  'if ! _shmutant_target_ok "$root" "${SHMUTANT_ROWS_FILE[$i]}"; then' \
  'if false; then' \
  't_pool_refuses_symlink_target'

# --- guards added for the third review round ---
shmutant_mut 'a symlinked parent directory passes the target check' \
  '  _shmutant_inside "$root" "$dir"' \
  '  true' \
  't_pool_refuses_target_under_symlinked_dir'
shmutant_mut 'the caller'"'"'s nocasematch reaches witness matching' \
  '  shopt -u nocasematch' \
  '  shopt -s nocasematch' \
  't_pool_witness_match_is_case_sensitive'
shmutant_mut 'CDPATH reaches the path resolver' \
  '( unset CDPATH; cd -P -- "$1"' \
  '( cd -P -- "$1"' \
  't_abs_ignores_cdpath'
shmutant_mut 'a destination inside the source is copied into itself' \
  'if _shmutant_inside "$asrc" "$adst"; then' \
  'if false; then' \
  't_copy_tree_excludes_git'
shmutant_mut 'awk no longer reports a missed literal' \
  'exit (hit ? 0 : 3) }' \
  'exit 0 }' \
  't_mutate_reports_unapplied'
shmutant_mut 'identical literals are rewritten as applied' \
  '[ -n "$2" ] && [ "$2" != "$3" ] || return 2' \
  '[ -n "$2" ] || return 2' \
  't_mutate_reports_unapplied'

# --- guards added for the fourth review round ---
shmutant_mut 'the full mode is not reapplied after the rewrite' \
  'chmod -- "$(_shmutant_mode_spec "$mode")" "$tmp" 2>/dev/null ||' \
  'true ||' \
  't_mutate_rewrites_a_read_only_target'
shmutant_mut 'copy_tree runs under the caller glob settings' \
  'set +f; shopt -u failglob dotglob; shopt -s nullglob; unset GLOBIGNORE' \
  ':' \
  't_copy_tree_ignores_caller_glob_settings'
shmutant_mut 'a red status of 0 is accepted' \
  'if [ "$v_red" -lt 1 ] ||' \
  'if [ "$v_red" -lt 0 ] ||' \
  't_pool_validates_red_status_and_prefix'
shmutant_mut 'an empty red prefix is accepted' \
  'if [ -n "${SHMUTANT_RED_PREFIX+x}" ] && [ -z "$SHMUTANT_RED_PREFIX" ]; then' \
  'if false; then' \
  't_pool_validates_red_status_and_prefix'
shmutant_mut 'a stream inside the workdir is accepted' \
  'if _shmutant_inside "$wd" "$sdir"; then' \
  'if false; then' \
  't_stream_write_failure_is_a_harness_error'

# --- guards added for the fifth review round ---
shmutant_mut 'a symlink stream is accepted' \
  '    if [ -L "$SHMUTANT_STREAM" ]; then' \
  '    if false; then' \
  't_stream_write_failure_is_a_harness_error'
shmutant_mut 'an overflow-length red status passes' \
  '[ "${#v_red}" -le 3 ] ||' \
  '[ "${#v_red}" -le 300 ] ||' \
  't_pool_validates_red_status_and_prefix'
shmutant_mut 'an overflow-length timeout passes' \
  '[ "${#v_timeout}" -le 9 ] ||' \
  '[ "${#v_timeout}" -le 300 ] ||' \
  't_pool_validates_red_status_and_prefix'

# --- guards added for the sixth review round ---
shmutant_mut 'the KILL escalation forgets the descendants found before TERM' \
  '_shmutant_kill_tree KILL "$pid" "${victims[@]}"' \
  '_shmutant_kill_tree KILL "$pid"' \
  't_verdict_timeout_kills_a_reparented_term_ignoring_descendant'
shmutant_mut 'the timeout is read bare, so nounset aborts the pool' \
  'local v_timeout="${SHMUTANT_TIMEOUT:-300}"' \
  'local v_timeout="$SHMUTANT_TIMEOUT"' \
  't_pool_survives_nounset'
shmutant_mut 'a hard-linked target is accepted' \
  '| awk '"'"'{ print $2 }'"'"')" -gt 1 ]; then' \
  '| awk '"'"'{ print $2 }'"'"')" -gt 99 ]; then' \
  't_pool_refuses_hard_linked_target'
shmutant_mut 'SHMUTANT_JOBS=0 falls back to the CPU count' \
  'if [ "${#v_jobs}" -gt 4 ] || [ "$v_jobs" -lt 1 ]; then' \
  'if [ "${#v_jobs}" -gt 4 ] || [ "$v_jobs" -lt 0 ]; then' \
  't_pool_validates_red_status_and_prefix'
shmutant_mut 'a FIFO stream is accepted' \
  'if [ -e "$SHMUTANT_STREAM" ] && [ ! -f "$SHMUTANT_STREAM" ]; then' \
  'if false; then' \
  't_stream_write_failure_is_a_harness_error'
shmutant_mut 'the setuid bit is dropped by the rewrite' \
  's) out+=xs ;; S) out+=s ;;' \
  's) out+=x ;; S) out+= ;;' \
  't_mutate_preserves_setuid'

# --- guards added for the seventh review round ---
shmutant_mut 'the descendant list is split by the caller IFS again' \
  '_shmutant_kill_tree KILL "$pid" "${victims[@]}"' \
  '_shmutant_kill_tree KILL "$pid" $(printf "%s\n" "${victims[@]}")' \
  't_verdict_timeout_kills_a_reparented_term_ignoring_descendant'
shmutant_mut 'prepare runs in a subshell' \
  '"$prep" "$wd/pristine" >| "$pout"; prc=$?' \
  '( "$prep" "$wd/pristine" >| "$pout" ); prc=$?' \
  't_pool_runs_prepare_in_its_own_shell'
shmutant_mut 'surplus mutation arguments are accepted' \
  'if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then' \
  'if [ "$#" -lt 4 ]; then' \
  't_mut_validates_rows'
shmutant_mut 'a worker directory that cannot be recreated is used anyway' \
  '  [ ! -e "$1" ] || return 1' \
  '  :' \
  't_pool_refuses_unremovable_worker_dir'

# --- guards added for the eighth review round ---
shmutant_mut 'a relative library stream is left relative for prepare to move' \
  '    SHMUTANT_STREAM="$sdir/$(basename -- "$SHMUTANT_STREAM")"' \
  '    :' \
  't_stream_relative_survives_a_prepare_that_cds'
shmutant_mut 'pristine is reused when it cannot be recreated' \
  '_shmutant_fresh_dir "$wd/pristine" ||' \
  'true ||' \
  't_pool_refuses_unremovable_pristine'
shmutant_mut 'the prepare capture is a predictable name again' \
  'pout="$(mktemp "$wd/.prepare.XXXXXX" 2>/dev/null)" ||' \
  'pout="$wd/prepare.out" ||' \
  't_pool_prepare_capture_never_follows_a_link'
shmutant_mut 'prepare runs as a condition, muting its errexit' \
  '"$prep" "$wd/pristine" >| "$pout"; prc=$?' \
  'if "$prep" "$wd/pristine" >| "$pout"; then prc=0; else prc=$?; fi' \
  't_pool_prepare_keeps_its_own_errexit'
shmutant_mut 'the errexit prepare turned on is left on' \
  'if [ "$errexit_before" = 1 ]; then set -e; else set +e; fi' \
  ':' \
  't_pool_prepare_keeps_its_own_errexit'
shmutant_mut 'a newline in a witness is accepted' \
  'case "$4${5:-}" in *$'"'"'\n'"'"'*)' \
  'case "$4${5:-}" in never-matches)' \
  't_mut_validates_rows'
shmutant_mut 'descendants are snapshotted only at the deadline' \
  '          done < <(_shmutant_snapshot "$pid")' \
  '          done < /dev/null' \
  't_verdict_timeout_kills_a_descendant_seen_before_it_detached'
shmutant_mut 'clones drop metadata' \
  'cp -RPp -- "$wd/pristine" "$dir/tree"' \
  'cp -RP -- "$wd/pristine" "$dir/tree"' \
  't_pool_clone_keeps_metadata'
shmutant_mut 'copy_tree drops metadata' \
  'cp -RPp -- "$entry" "$dst/"' \
  'cp -RP -- "$entry" "$dst/"' \
  't_pool_clone_keeps_metadata'

# --- the CLI, as restructured in the ninth round: plan and pool in a subshell, marker-decided ---
shmutant_mut '--keep deletes the workdir' \
  'if [ "$keep" = 1 ]; then _shmutant_err "workdir kept: $wd"' \
  'if [ "$keep" = 0 ]; then _shmutant_err "workdir kept: $wd"' \
  't_cli_run'
shmutant_mut 'a caller-supplied workdir is removed' \
  '  elif [ "$made" = 1 ]; then rm -rf -- "$wd"' \
  '  elif true; then rm -rf -- "$wd"' \
  't_cli_run'
shmutant_mut 'the plan is sourced by its bare name' \
  '_shmutant_cli_load "$SHMUTANT_PLAN_DIR/$(basename -- "$plan")"' \
  '_shmutant_cli_load "$plan"' \
  't_cli_run'
shmutant_mut 'a relative --workdir is resolved after the plan may have moved' \
  '  wd="$(_shmutant_abs "$wd")" || { _shmutant_err "run: cannot resolve workdir"; return 2; }' \
  '  :' \
  't_cli_run'
shmutant_mut 'inherited prepare/run functions are accepted' \
  '  unset -f prepare run' \
  '  :' \
  't_cli_run'
shmutant_mut 'the plan errexit is left on across the pool call' \
  '  set +o errexit' \
  '  :' \
  't_cli_run'
shmutant_mut 'a relative SHMUTANT_STREAM is resolved after the plan may have moved' \
  '      *)  SHMUTANT_STREAM="$(_shmutant_abs "$(dirname -- "$SHMUTANT_STREAM")")/$(basename -- "$SHMUTANT_STREAM")" \' \
  '      *)  SHMUTANT_STREAM="$SHMUTANT_STREAM" \' \
  't_cli_run'
shmutant_mut 'the subshell status is trusted without the completion marker' \
  'if [ -f "$done_file" ] && marker="$(cat "$done_file" 2>/dev/null)" && [ "${marker%% *}" = "$rc" ]; then' \
  'if marker="$(cat "$done_file" 2>/dev/null)" || true; then' \
  't_cli_run'

# --- guards added for the ninth review round ---
shmutant_mut 'settings are not revalidated after prepare' \
  '_shmutant_validate_settings "$label" "$wd" || { _shmutant_err "$label: a setting changed by prepare is invalid"; return 2; }' \
  ':' \
  't_pool_revalidates_settings_after_prepare'
shmutant_mut 'a pool cap of 0 falls back to the default' \
  '*) if [ "${#cap}" -gt 4 ] || [ "$cap" -lt 1 ]; then' \
  '*) if [ "${#cap}" -gt 4 ] || [ "$cap" -lt 0 ]; then' \
  't_pool_revalidates_settings_after_prepare'
shmutant_mut 'a multiline red prefix is accepted' \
  'case "${SHMUTANT_RED_PREFIX:-}" in *$'"'"'\n'"'"'*)' \
  'case "${SHMUTANT_RED_PREFIX:-}" in never-matches)' \
  't_pool_revalidates_settings_after_prepare'
shmutant_mut 'a non-red baseline exit is scored red' \
  '    elif [ "$status" -eq "$red" ]; then verdict=red' \
  '    elif true; then verdict=red' \
  't_baseline_non_red_exit_is_aborted'
shmutant_mut 'a reused pid is signalled anyway' \
  '  [ "$d" -ge -1 ] && [ "$d" -le 1 ]' \
  '  true' \
  't_kill_tree_skips_a_reused_pid'

# --- guards added for the tenth review round ---
shmutant_mut 'jobs ignores what prepare assigned to SHMUTANT_JOBS' \
  '  jobs="$(_shmutant_jobs "$cap")"' \
  '  jobs="$(SHMUTANT_JOBS= _shmutant_jobs "$cap")"' \
  't_pool_bookkeeping_survives_prepare_assignments'
shmutant_mut 'the pool bookkeeping is not restored after prepare' \
  'n="$_shmutant_pool_n"; t0="$_shmutant_pool_t0"; pout="$_shmutant_pool_pout"; errexit_before="$_shmutant_pool_errexit"' \
  't0="$_shmutant_pool_t0"; errexit_before="$_shmutant_pool_errexit"' \
  't_pool_bookkeeping_survives_prepare_assignments'
shmutant_mut 'SHMUTANT_KEEP is not validated' \
  'case "${SHMUTANT_KEEP:-0}" in 0|1) ;; *)' \
  'case "${SHMUTANT_KEEP:-0}" in *) ;; never)' \
  't_pool_validates_boolean_settings'
shmutant_mut 'SHMUTANT_BASELINE is not validated' \
  'case "${SHMUTANT_BASELINE:-1}" in 0|1) ;; *)' \
  'case "${SHMUTANT_BASELINE:-1}" in *) ;; never)' \
  't_pool_validates_boolean_settings'
shmutant_mut 'a leading-zero timeout reaches arithmetic as octal' \
  't_end=$(( $(_shmutant_now) + 10#$timeout * 1000000 ))' \
  't_end=$(( $(_shmutant_now) + timeout * 1000000 ))' \
  't_verdict_timeout_with_a_leading_zero'
shmutant_mut 'a refused nested copy leaves its directory behind' \
  '    [ -n "$made" ] && rm -rf -- "$made"' \
  '    :' \
  't_copy_tree_excludes_git'
shmutant_mut 'an interrupted pool leaves its workers running' \
  "  trap '_shmutant_abort_workers TERM' TERM" \
  '  :' \
  't_pool_interrupted_kills_its_workers'
shmutant_mut 'no-trap is restored as ignore, so the caller cannot be interrupted afterwards' \
  'else trap - TERM; fi' \
  'else trap -- "" TERM; fi' \
  't_pool_restores_caller_traps'

# --- guards added for the eleventh review round ---
shmutant_mut 'the CLI has no signal handler around its plan subshell' \
  "  trap '_shmutant_cli_abort TERM' TERM" \
  '  :' \
  't_cli_run'
shmutant_mut 'a saved trap declaration is re-spelled instead of restored verbatim' \
  'if [ -n "${SHMUTANT_TRAP_TERM:-}" ]; then eval "$SHMUTANT_TRAP_TERM"; else trap - TERM; fi' \
  'if [ -n "${SHMUTANT_TRAP_TERM:-}" ]; then trap -- "${SHMUTANT_TRAP_TERM#trap -- }" TERM; else trap - TERM; fi' \
  't_pool_restores_caller_traps'
shmutant_mut 'a target with surplus arguments is accepted' \
  '[ "$#" -eq 1 ] || { _shmutant_refuse "target: exactly one file' \
  '[ "$#" -ge 1 ] || { _shmutant_refuse "target: exactly one file' \
  't_mut_validates_rows'
shmutant_mut 'KEEP set inside the plan is not carried back to the CLI' \
  '    [ "${marker#* }" = 1 ] && keep=1' \
  '    :' \
  't_cli_run'
shmutant_mut 'containment honours the caller nocasematch' \
  '  ( shopt -u nocasematch' \
  '  ( :' \
  't_inside_ignores_nocasematch'
shmutant_mut 'the timeout marker is the predictable name timeout again' \
  '  mark="$(mktemp "$dir/.fired.XXXXXX")" || { SHMUTANT_RUN_STATUS=127; return; }' \
  '  mark="$dir/timeout"' \
  't_verdict_timeout_marker_cannot_be_forged'
shmutant_mut 'an old literal with a newline is accepted' \
  '  case "$2" in *$'"'"'\n'"'"'*) _shmutant_refuse "mut' \
  '  case "$2" in never-matches) _shmutant_refuse "mut' \
  't_mut_validates_rows'

# --- guards added for the twelfth review round ---
shmutant_mut 'the abort handlers do not retain TERM victims for KILL' \
  '  _shmutant_kill_tree KILL "$pid" "$@" "${victims[@]}"' \
  '  _shmutant_kill_tree KILL "$pid" "$@"' \
  't_pool_interrupted_kills_its_workers'
shmutant_mut 'a callback that returned normally leaves its helpers running' \
  '      _shmutant_kill_tree_twice "$pid" "${leftovers[@]}"' \
  '      :' \
  't_run_leftovers_are_killed_after_a_normal_return'
shmutant_mut 'the verdict is written straight to its fixed name' \
  'printf '"'"'%s\n%s\n%s\n'"'"' "$2" "$3" "$4" >| "$tmp" && mv -f -- "$tmp" "$1/verdict"' \
  'printf '"'"'%s\n%s\n%s\n'"'"' "$2" "$3" "$4" > "$1/verdict"; rm -f -- "$tmp"' \
  't_worker_verdict_cannot_be_forged_through_a_link'
shmutant_mut 'the filesystem root contains nothing' \
  '    if [ "$1" = / ]; then case "$2" in /*) exit 0 ;; esac; exit 1; fi' \
  '    :' \
  't_inside_ignores_nocasematch'
shmutant_mut 'copy_tree copies a hard-linked source' \
  '  if [ -n "$linked" ]; then' \
  '  if false; then' \
  't_copy_tree_excludes_git'
shmutant_mut 'rc and killed are not reset after prepare' \
  '  killed=0; rc=0' \
  '  :' \
  't_pool_bookkeeping_survives_prepare_assignments'
shmutant_mut 'the settled KEEP is not recorded for the CLI abort path' \
  '[ -n "${SHMUTANT_CLI_KEEPFILE:-}" ] && printf '"'"'%s\n'"'"' "${SHMUTANT_KEEP:-0}" >| "$SHMUTANT_CLI_KEEPFILE"' \
  ':' \
  't_cli_run'
shmutant_mut 'the row pool runs as a condition, muting callback errexit' \
  '  _shmutant_run_jobs mut "$n" "$wd" "$run" "$suffix" "$jobs"; rjrc=$?' \
  '  _shmutant_run_jobs mut "$n" "$wd" "$run" "$suffix" "$jobs" || rjrc=2; rjrc=${rjrc:-0}' \
  't_run_errexit_is_honoured_in_workers'

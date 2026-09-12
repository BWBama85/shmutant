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
  '[[ "$1" -gt 5 ]] || { [[ "$1" -eq 5 ]] && [[ "$2" -ge 3 ]]; }' \
  '[[ "$1" -gt 5 ]] || { [[ "$1" -eq 5 ]] && [[ "$2" -ge 0 ]]; }' \
  't_bash_floor'
shmutant_mut 'the floor accepts bash 4' \
  '[[ "$1" -gt 5 ]] || {' \
  '[[ "$1" -gt 3 ]] || {' \
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
  '"$run" "$root" "$sel" "${SHMUTANT_ROWS_WIT[$i]}"' \
  '"$run" "$root" "$sel" "${SHMUTANT_ROWS_SEL[$i]}"' \
  't_verdict_accidental'
shmutant_mut 'a witness on a non-red line counts' \
  '    index($0, p) == 1 { red = 1; if (w != "" && witnessed($0, w)) { wit = 1; exit } }' \
  '    index($0, p) == 1 { red = 1 } w != "" && witnessed($0, w) { wit = 1 }' \
  't_verdict_accidental'
shmutant_mut 'exit 1 without a red line is scored accidental' \
  '    elif [ "$SHMUTANT_RUN_RED" = 1 ]; then' \
  '    elif true; then' \
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
  '  read -t 0 -u "$fired" && SHMUTANT_RUN_FIRED=1' \
  '  :' \
  't_verdict_timeout'
shmutant_mut 'a blank verdict file reads as a verdict' \
  '[ -n "$SHMUTANT_V_VERDICT" ] || SHMUTANT_V_VERDICT=lost' \
  '[ -n "$SHMUTANT_V_VERDICT" ] || true' \
  't_collect_fails_closed'

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
  '  wait -n -p done_pid "${pids[@]}"; wrc=$?' \
  '  wait -n -p done_pid; wrc=$?' \
  't_pool_does_not_reap_callers_jobs'
shmutant_mut 'baseline runs once per row instead of once per selector' \
  '[ "$k" = "$sel" ] && continue 2; done' \
  '[ "$k" = "$sel" ] && continue; done' \
  't_pool_runs_baseline_once_per_selector'
shmutant_mut 'SHMUTANT_KEEP=1 removes the clone' \
  '  if [ "${SHMUTANT_KEEP:-0}" != 1 ]; then' \
  '  if true; then' \
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
  '{ printf '"'"'%s\n'"'"' "$out" >&"$SHMUTANT_STREAM_FD"; } 2>/dev/null || SHMUTANT_EMIT_FAILED=1' \
  'printf '"'"'%s\n'"'"' "$out"' \
  't_stream_to_file'

# --- the CLI ---
shmutant_mut 'the label is not the plan name' \
  'shmutant_pool "$(command -p basename -- "$plan")"' \
  'shmutant_pool "plan"' \
  't_cli_run'
shmutant_mut 'version prints the wrong marker' \
  '"$SHMUTANT_VERSION"' \
  '"$SHMUTANT_VERSION-mutant"' \
  't_cli_run'
shmutant_mut 'checksum prints the file name instead of the digest' \
  '  printf '"'"'%s\n'"'"' "${out%% *}"' \
  '  printf '"'"'%s\n'"'"' "${out#* }"' \
  't_cli_run'

# --- guards added for the first review round ---
shmutant_mut 'a refused declaration is not counted' \
  'SHMUTANT_DECL_ERRORS=$((SHMUTANT_DECL_ERRORS + 1)); return 2' \
  'SHMUTANT_DECL_ERRORS=$((SHMUTANT_DECL_ERRORS + 0)); return 2' \
  't_refused_declarations_fail_the_pool'
shmutant_mut 'a stream write failure is swallowed' \
  '{ printf '"'"'%s\n'"'"' "$out" >&"$SHMUTANT_STREAM_FD"; } 2>/dev/null || SHMUTANT_EMIT_FAILED=1' \
  '{ printf '"'"'%s\n'"'"' "$out" >&"$SHMUTANT_STREAM_FD"; } 2>/dev/null || SHMUTANT_EMIT_FAILED=0' \
  't_stream_write_failure_is_a_harness_error'
shmutant_mut 'the rewrite drops the target mode' \
  'mode="$(command -p ls -ld -- "$f" 2>/dev/null)"; mode="${mode%% *}"' \
  'mode="-rw-r--r--"' \
  't_mutate_preserves_mode'
shmutant_mut 'the rewrite always appends a final newline' \
  'ENVIRON["SHMUTANT_MUT_NL"] == 1) printf' \
  'ENVIRON["SHMUTANT_MUT_NL"] != 2) printf' \
  't_mutate_preserves_missing_final_newline'
shmutant_mut 'the temp file is a predictable sibling name again' \
  'tmp="$(command -p mktemp "$dir/.shmutant.XXXXXX" 2>/dev/null)" || { _shmutant_mutate_restore "$dir" "$dirmode"; return 1; }' \
  'tmp="$f.shmutant-tmp"' \
  't_mutate_never_follows_a_stale_temp_link'
shmutant_mut 'worker directories are reused with their stale contents' \
  '  _shmutant_remove "$1" "${2:-}" || return 1' \
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
# The physical-containment row on _shmutant_target_ok is subsumed: the lexical link walk
# refuses every escape from the root first, so no staged input reaches that check.
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
shmutant_mut 'the timeout is read bare, so nounset aborts the pool' \
  'local v_timeout="${SHMUTANT_TIMEOUT:-300}"' \
  'local v_timeout="$SHMUTANT_TIMEOUT"' \
  't_pool_survives_nounset'
shmutant_mut 'a hard-linked target is accepted' \
  '| command -p awk '"'"'{ print $2 }'"'"')" -gt 1 ]; then' \
  '| command -p awk '"'"'{ print $2 }'"'"')" -gt 99 ]; then' \
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
  '        _shmutant_held_group "$pid"; _shmutant_kill_tree_twice "${SHMUTANT_HELD[@]}" "$pid:$rootid" "${victims[@]}"' \
  '        _shmutant_held_group "$pid"; _shmutant_kill_tree_twice "${SHMUTANT_HELD[@]}" "$pid:$rootid" $(printf "%s\n" "${victims[@]}")' \
  't_verdict_timeout_kills_a_descendant_seen_then_reparented'
shmutant_mut 'prepare runs in a subshell' \
  '"$prep" "$wd/pristine" >&"$pout_w"; prc=$?' \
  '( "$prep" "$wd/pristine" >&"$pout_w" ); prc=$?' \
  't_pool_runs_prepare_in_its_own_shell'
shmutant_mut 'surplus mutation arguments are accepted' \
  'if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then' \
  'if [ "$#" -lt 4 ]; then' \
  't_mut_validates_rows'

# --- guards added for the eighth review round ---
shmutant_mut 'a relative library stream is left relative for prepare to move' \
  '    _shmutant_canon "$label" SHMUTANT_STREAM "$sdir/$(command -p basename -- "$SHMUTANT_STREAM")" || return 2' \
  '    :' \
  't_stream_relative_survives_a_prepare_that_cds'
shmutant_mut 'pristine is reused when it cannot be recreated' \
  '_shmutant_fresh_dir "$wd/pristine" "$wd" ||' \
  'true ||' \
  't_pool_refuses_unremovable_pristine'
shmutant_mut 'the prepare capture is a predictable name again' \
  'pout="$(command -p mktemp "$wd/.prepare.XXXXXX" 2>/dev/null)" ||' \
  'pout="$wd/prepare.out" ||' \
  't_pool_prepare_capture_never_follows_a_link'
shmutant_mut 'prepare runs as a condition, muting its errexit' \
  '"$prep" "$wd/pristine" >&"$pout_w"; prc=$?' \
  'if "$prep" "$wd/pristine" >&"$pout_w"; then prc=0; else prc=$?; fi' \
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
  'cp -RPp -- "$wd/pristine/." "$dir/tree/"' \
  'cp -RP -- "$wd/pristine/." "$dir/tree/"' \
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
  '  elif [ "$made" = 1 ]; then _shmutant_remove "$wd" "${SHMUTANT_CLI_WD_PARENT:-}" || {' \
  '  elif true; then _shmutant_remove "$wd" "${SHMUTANT_CLI_WD_PARENT:-}" || {' \
  't_cli_run'
shmutant_mut 'the plan is sourced by its bare name' \
  '_shmutant_cli_load "$SHMUTANT_PLAN_DIR/$(command -p basename -- "$plan")"' \
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
  '    _shmutant_canon "$label" SHMUTANT_STREAM "$sdir/$(command -p basename -- "$SHMUTANT_STREAM")" || return 2' \
  '    :' \
  't_cli_run'
shmutant_mut 'the subshell status is trusted without the completion marker' \
  '  if [ -n "$marker" ] && [ "${marker%% *}" = "$rc" ]; then' \
  '  if true; then' \
  't_cli_run'

# --- guards added for the ninth review round ---
shmutant_mut 'settings are not revalidated after prepare' \
  '_shmutant_validate_settings "$label" "$wd" || { _shmutant_err "$label: a setting changed by prepare is invalid"; _shmutant_pool_fail "$label" "$wd"; return 2; }' \
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
  '  label="$_shmutant_pool_label"; wd="$_shmutant_pool_wd"; run="$_shmutant_pool_run"; cap="$_shmutant_pool_cap"' \
  '  label="$_shmutant_pool_label"; run="$_shmutant_pool_run"; cap="$_shmutant_pool_cap"' \
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
  '  if [ -n "${SHMUTANT_TIMEOUT+x}" ]; then _shmutant_canon "$label" SHMUTANT_TIMEOUT "$(( 10#$v_timeout ))" || return 2; fi' \
  '  :' \
  't_verdict_timeout_with_a_leading_zero'
shmutant_mut 'a refused nested copy leaves its directory behind' \
  '    [ -n "$made" ] && command -p rm -rf -- "$made"' \
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
  '    if [ "${marker#* }" = 1 ]; then keep=1; else keep=0; fi' \
  '    :' \
  't_cli_run'
shmutant_mut 'containment honours the caller nocasematch' \
  '  ( shopt -u nocasematch' \
  '  ( :' \
  't_inside_ignores_nocasematch'
shmutant_mut 'an old literal with a newline is accepted' \
  '  case "$2" in *$'"'"'\n'"'"'*) _shmutant_refuse "mut' \
  '  case "$2" in never-matches) _shmutant_refuse "mut' \
  't_mut_validates_rows'

# --- guards added for the twelfth review round ---
shmutant_mut 'a callback that returned normally leaves its helpers running' \
  '      _shmutant_kill_tree_twice "${SHMUTANT_HELD[@]}" "$pid:$rootid" "${leftovers[@]}"' \
  '      :' \
  't_run_leftovers_are_killed_after_a_normal_return'
shmutant_mut 'the verdict is written straight to its fixed name' \
  '  { printf '"'"'verdict %s %s %s\n'"'"' "$2" "$3" "$4" >&"$SHMUTANT_VERDICT_FD"; } 2>/dev/null' \
  '  { printf '"'"'verdict %s %s %s\n'"'"' "$2" "$3" "$4" >&"$SHMUTANT_VERDICT_FD"; } 2>/dev/null; printf '"'"'%s\n'"'"' "$2" > "$1/verdict"' \
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
  '  _shmutant_report_keep after-prepare' \
  '  :' \
  't_cli_run'
shmutant_mut 'the row pool runs as a condition, muting callback errexit' \
  '  set +e; _shmutant_run_jobs mut "$n" "$wd" "$run" "$suffix" "$jobs"; rjrc=$?' \
  '  set +e; rjrc=0; _shmutant_run_jobs mut "$n" "$wd" "$run" "$suffix" "$jobs" || rjrc=$?' \
  't_run_errexit_is_honoured_in_workers'

# --- guards added for the thirteenth review round ---
shmutant_mut 'the leftover record descriptor is read after the callback could assign it' \
  '      _shmutant_snapshot "$BASHPID" >&"$_shmutant_wrap_left"; trap - EXIT; builtin exit "$rrc" )' \
  '      _shmutant_snapshot "$BASHPID" >&"$left_w"; trap - EXIT; builtin exit "$rrc" )' \
  't_run_cannot_redirect_the_leftover_record'
shmutant_mut 'the hard-link preflight scans the top-level .git the copy skips' \
  'find . -path ./.git -prune -o -type f -links +1 -print' \
  'find . -type f -links +1 -print' \
  't_copy_tree_excludes_git'
shmutant_mut 'the abort handler waits for every job, the caller included' \
  '  [ "${#helpers[@]}" -eq 0 ] || wait "${helpers[@]}" 2>/dev/null' \
  '  wait' \
  't_pool_abort_waits_only_for_its_helpers'
shmutant_mut 'plan-load output reaches the verdict stream' \
  '  . "$plan" >&2' \
  '  . "$plan"' \
  't_cli_run'

# --- guards added for the fourteenth review round ---
shmutant_mut 'the root pid is signalled by number even after it was reaped' \
  '  [ "${#targets[@]}" -gt 0 ] || return 0' \
  '  [ -n "$pid" ] && targets+=("$pid")' \
  't_post_run_cleanup_never_signals_a_reaped_root_by_number'
shmutant_mut 'the stream is reopened by path for every record' \
  '{ printf '"'"'%s\n'"'"' "$out" >&"$SHMUTANT_STREAM_FD"; } 2>/dev/null || SHMUTANT_EMIT_FAILED=1' \
  '{ printf '"'"'%s\n'"'"' "$out" >> "$SHMUTANT_STREAM"; } 2>/dev/null || SHMUTANT_EMIT_FAILED=1' \
  't_stream_descriptor_survives_a_callback_swapping_the_path'
shmutant_mut 'a validation failure after prepare keeps the pristine tree' \
  '      _shmutant_pool_fail "$label" "$wd"; return 2' \
  '      return 2' \
  't_pool_failure_after_prepare_removes_pristine'
shmutant_mut 'the destination root does not get the source root mode' \
  '  command -p chmod -- "$(_shmutant_mode_spec "${rootls%% *}")" "$2" 2>/dev/null || rc=1' \
  '  :' \
  't_pool_clone_keeps_metadata'

# --- guards added for the fifteenth review round ---
shmutant_mut 'a stream prepare assigned is not opened' \
  '  _shmutant_open_stream "$label" || { _shmutant_pool_fail "$label" "$wd"; return 2; }' \
  '  :' \
  't_stream_assigned_by_prepare_is_honoured'
shmutant_mut 'a symlinked source root is scanned and copied differently' \
  '  src="$(_shmutant_abs "$src")" || { _shmutant_err "copy_tree: cannot resolve $1"; return 1; }' \
  '  :' \
  't_copy_tree_excludes_git'
shmutant_mut 'a symlink destination is written through' \
  '  if [ -L "$dst" ]; then _shmutant_err "copy_tree: destination $dst is a symlink' \
  '  if false; then _shmutant_err "copy_tree: destination $dst is a symlink' \
  't_copy_tree_excludes_git'
shmutant_mut 'a failed root metadata restore is a silent success' \
  '  _shmutant_apply_root_meta "$src" "$dst" || { _shmutant_err "copy_tree: could not reproduce the root directory'"'"'s owner, mode or timestamp on $dst"; return 1; }' \
  '  _shmutant_apply_root_meta "$src" "$dst" || true' \
  't_pool_clone_keeps_metadata'
shmutant_mut 'a directory that cannot be recreated waits on running workers' \
  '        _shmutant_end_workers "${pids[@]}"' \
  '        :' \
  't_pool_aborts_running_workers_when_a_dir_cannot_be_recreated'
shmutant_mut 'the CLI ignores SHMUTANT_KEEP=1 before the pool settles it' \
  '  [ "${SHMUTANT_KEEP:-0}" = 1 ] && keep=1' \
  '  [ "${SHMUTANT_KEEP:-0}" = 2 ] && keep=1' \
  't_cli_run'

# --- guards added for the sixteenth review round ---
shmutant_mut 'the leftover record is written by path after the callback' \
  '      _shmutant_snapshot "$BASHPID" >&"$_shmutant_wrap_left"; trap - EXIT; builtin exit "$rrc" )' \
  '      _shmutant_snapshot "$BASHPID" > "$dir/.left"; trap - EXIT; builtin exit "$rrc" )' \
  't_run_cannot_lose_the_leftover_record_by_locking_its_dir'
shmutant_mut 'a read-only tree of ours is not made removable' \
  '      command -p find "$path" -type d ! -perm -u+rwx -exec chmod u+rwx {} + 2>/dev/null' \
  '      :' \
  't_pool_removes_a_read_only_pristine_root'
shmutant_mut 'retained victims are neither frozen nor searched from' \
  '    have["${p%%:*}"]=1; stillours+=("${p%%:*} ${p#*:}")' \
  '    :' \
  't_verdict_timeout_kills_a_descendant_seen_then_reparented'
shmutant_mut 'mutate does not loosen a read-only directory' \
  '    command -p chmod -- u+w "$dir" 2>/dev/null || return 1' \
  '    return 1' \
  't_pool_removes_a_read_only_pristine_root'

# --- guards added for the seventeenth review round ---
shmutant_mut 'the channel opens are not forced past noclobber' \
  'exec {left_w}>|"$left" {left_r}<"$left" {seen_w}>|"$seen" {seen_r}<"$seen" {fired}<>"$fifo" {out_w}>|"$outf" {out_r}<"$outf"' \
  'exec {left_w}>"$left" {left_r}<"$left" {seen_w}>"$seen" {seen_r}<"$seen" {fired}<>"$fifo" {out_w}>"$outf" {out_r}<"$outf"' \
  't_run_cannot_forge_its_output_or_the_marker'
shmutant_mut 'the verdict is scored from the output path, not the descriptor' \
  '  _shmutant_scan_output "$out_r" "${SHMUTANT_RED_PREFIX:-FAIL: }" "$wit"' \
  '  exec {out_r}<"$dir/output"; _shmutant_scan_output "$out_r" "${SHMUTANT_RED_PREFIX:-FAIL: }" "$wit"' \
  't_run_cannot_forge_its_output_or_the_marker'
shmutant_mut 'a swapped worker directory is cleaned and written beneath' \
  '  if [ -L "$1" ] || [ "$(_shmutant_dir_id "$1")" != "${SHMUTANT_DIR_ID:-}" ]; then' \
  '  if false; then' \
  't_worker_cleanup_refuses_a_swapped_directory'
shmutant_mut 'a root given with an identity is stopped without checking it' \
  '  else rootid="${spec#*:}"; [ -n "$rootid" ] && _shmutant_alive_since "$pid" "$rootid" && root_ok=1' \
  '  else rootid="${spec#*:}"; [ -n "$rootid" ] && root_ok=1' \
  't_post_run_cleanup_never_signals_a_reaped_root_by_number'
shmutant_mut 'the baseline arrays are not reset after prepare' \
  '  killed=0; rc=0; base_sel=(); base_verdict=()' \
  '  killed=0; rc=0' \
  't_pool_bookkeeping_survives_prepare_assignments'

# --- guards added for the eighteenth review round ---
shmutant_mut 'the wrapper snapshot runs after the callback, not from an EXIT trap' \
  '>&"$_shmutant_wrap_left"'"'"' EXIT' \
  '>&"$_shmutant_wrap_left"'"'"' USR2' \
  't_run_errexit_failure_still_snapshots_leftovers'
shmutant_mut 'a verdict is read from whatever directory has the name' \
  '  if [ -L "$dir" ] || [ "$(_shmutant_dir_id "$dir")" != "${SHMUTANT_DIR_IDS[$key]:-}" ]; then' \
  '  if false; then' \
  't_pool_never_trusts_a_verdict_from_a_replaced_directory'
shmutant_mut 'the stream cache is set before the open succeeds' \
  '  unset SHMUTANT_STREAM_OPENED' \
  '  SHMUTANT_STREAM_OPENED="${SHMUTANT_STREAM:-}"' \
  't_stream_write_failure_is_a_harness_error'

# --- guards added for the nineteenth review round ---
shmutant_mut 'the completion marker keeps its path while the plan loads' \
  '  command -p rm -f -- "$SHMUTANT_CLI_DONE_PATH"' \
  '  :' \
  't_cli_run'
shmutant_mut 'the snapshot on return is dropped, leaving only the trap' \
  '      _shmutant_snapshot "$BASHPID" >&"$_shmutant_wrap_left"; trap - EXIT; builtin exit "$rrc" )' \
  '      trap - EXIT; builtin exit "$rrc" )' \
  't_run_cannot_lose_the_leftover_record_by_locking_its_dir'
shmutant_mut 'a rejected root is still searched from while freezing' \
  '  if [ "$root_ok" = 1 ]; then' \
  '  roots=("$pid"); if [ "$root_ok" = 1 ]; then' \
  't_post_run_cleanup_never_signals_a_reaped_root_by_number'
shmutant_mut 'a rejected root is still searched from by the final kill' \
  '  else _shmutant_kill_tree KILL "" "${frozen[@]}"' \
  '  else _shmutant_kill_tree KILL "$pid" "${frozen[@]}"' \
  't_post_run_cleanup_never_signals_a_reaped_root_by_number'
shmutant_mut 'a bare live root needs an identity to be stopped' \
  '  if [ "$spec" = "$pid" ]; then root_ok=1' \
  '  if [ "$spec" = "$pid" ]; then rootid="$(_shmutant_identity "$pid")" && root_ok=1' \
  't_post_run_cleanup_never_signals_a_reaped_root_by_number'
shmutant_mut 'a signal during a worker spawn is acted on before registration' \
  '  if [ "${SHMUTANT_SPAWNING:-0}" = 1 ]; then SHMUTANT_ABORT_PENDING="$sig"; return 0; fi' \
  '  :' \
  't_abort_during_spawn_is_deferred'
shmutant_mut 'the pool reads its positionals before checking their count' \
  '  if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then _shmutant_err "pool: usage' \
  '  if false; then _shmutant_err "pool: usage' \
  't_pool_checks_its_arity_first'

# --- guards added for the twentieth review round ---
shmutant_mut 'a callback that leaves by exit skips the snapshot' \
  '      exit() { local s=$?; _shmutant_snapshot "$BASHPID" >&"$_shmutant_wrap_left"; if [ "$#" -eq 0 ]; then builtin exit "$s"; else builtin exit "$@"; fi; }' \
  '      :' \
  't_run_cannot_lose_the_leftover_record_by_locking_its_dir'
shmutant_mut 'a verified holder yields no group to signal' \
  '  SHMUTANT_HELD=(-g "$1")' \
  '  SHMUTANT_HELD=()' \
  't_verdict_timeout_without_an_identity'
shmutant_mut 'the .git prune takes the source name as a pattern' \
  '  linked="$(builtin cd -- "$src" 2>/dev/null && command -p find . -path ./.git -prune' \
  '  linked="$(builtin cd -- "$src" 2>/dev/null && command -p find "$src" -path "$src/.git" -prune' \
  't_copy_tree_excludes_git'
shmutant_mut 'a relative stream in a missing directory is re-based onto the root' \
  '    if ! sdir="$(_shmutant_abs "$(command -p dirname -- "$SHMUTANT_STREAM")")"; then' \
  '    if ! sdir="$(command -p dirname -- "$SHMUTANT_STREAM")"; then' \
  't_cli_run'
shmutant_mut 'the automatic workdir is removed raw after an incomplete run' \
  '  elif [ "$made" = 1 ]; then _shmutant_remove "$wd" "${SHMUTANT_CLI_WD_PARENT:-}" || { _shmutant_err "run: could not remove the workdir $wd"; rc=2; }' \
  '  elif [ "$made" = 1 ]; then command -p rm -rf -- "$wd" 2>/dev/null' \
  't_cli_run'

# --- guards added for the twenty-first review round ---
shmutant_mut 'a pid listed but gone before the stop is recorded as frozen' \
  '      _shmutant_frozen_only "${found[@]}"' \
  '      SHMUTANT_FROZEN_NOW=("${pids[@]}")' \
  't_freeze_records_only_what_it_stopped'
shmutant_mut 'a clone left behind by a worker is not a harness error' \
  '    _shmutant_err "$dir/tree was not removed"; SHMUTANT_CLEANUP_FAILED=1' \
  '    :' \
  't_pool_reports_a_clone_it_could_not_remove'
shmutant_mut 'copy_tree reads its positionals before checking their count' \
  '  if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then _shmutant_err "copy_tree: usage' \
  '  if [ -z "$1" ] || [ -z "$2" ]; then _shmutant_err "copy_tree: usage' \
  't_copy_tree_excludes_git'
shmutant_mut 'no holder keeps the group in being after the wrapper' \
  '      ( ( read -r _ <&"$hold" ) < /dev/null > /dev/null 2>&1 & printf '"'"'%s\n'"'"' "$!" >&"$hp" )' \
  '      printf '"'"'\n'"'"' >&"$hp"' \
  't_returned_run_without_an_identity_is_still_cleaned_up'
shmutant_mut 'the post-return cleanup does not use the held group' \
  '      _shmutant_kill_tree_twice "${SHMUTANT_HELD[@]}" "$pid:$rootid" "${leftovers[@]}"' \
  '      _shmutant_kill_tree_twice "$pid:$rootid" "${leftovers[@]}"' \
  't_returned_run_without_an_identity_is_still_cleaned_up'
shmutant_mut 'a held group is neither stopped nor signalled by number' \
  '  if [ -n "$held" ]; then' \
  '  if false; then' \
  't_returned_run_without_an_identity_is_still_cleaned_up'
shmutant_mut 'a group is signalled by number after its holder is gone' \
  '  kill -0 "$holder" 2>/dev/null || return 0' \
  '  :' \
  't_run_group_is_not_signalled_by_number_without_its_holder'
shmutant_mut 'a bare exit takes the snapshot status' \
  '      exit() { local s=$?; _shmutant_snapshot "$BASHPID" >&"$_shmutant_wrap_left"; if [ "$#" -eq 0 ]; then builtin exit "$s"; else builtin exit "$@"; fi; }' \
  '      exit() { _shmutant_snapshot "$BASHPID" >&"$_shmutant_wrap_left"; builtin exit "$@"; }' \
  't_verdict_aborted_status'
shmutant_mut 'dot components in the destination are created as typed' \
  '  rest="$norm"' \
  '  :' \
  't_copy_tree_excludes_git'
shmutant_mut 'the holder is a job of the wrapper' \
  '      ( ( read -r _ <&"$hold" ) < /dev/null > /dev/null 2>&1 & printf '"'"'%s\n'"'"' "$!" >&"$hp" )' \
  '      ( read -r _ <&"$hold" ) < /dev/null > /dev/null 2>&1 & printf '"'"'%s\n'"'"' "$!" >&"$hp"' \
  't_callback_bare_wait_does_not_block_on_the_holder'

# --- guards added for the twenty-second review round ---
shmutant_mut 'the prepared root is read back by path after prepare' \
  '  root="$(command -p cat <&"$pout_r"; builtin printf x)"; root="${root%x}"; exec {pout_w}>&- {pout_r}<&-' \
  '  root="$(command -p cat "$wd"/.prepare.* 2>/dev/null; builtin printf x)"; root="${root%x}"; exec {pout_w}>&- {pout_r}<&-' \
  't_prepare_cannot_redirect_its_own_capture'
shmutant_mut 'a stream removed or replaced during the run is not noticed' \
  '  elif [ "$intact" -eq 0 ]; then' \
  '  elif false; then' \
  't_stream_descriptor_survives_a_callback_swapping_the_path'
shmutant_mut 'an empty copy destination is accepted' \
  '  if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then' \
  '  if [ "$#" -ne 2 ]; then' \
  't_copy_tree_excludes_git'
shmutant_mut 'the red prefix is matched anywhere in the line' \
  '    index($0, p) == 1 { red = 1; if (w != "" && witnessed($0, w)) { wit = 1; exit } }' \
  '    index($0, p) { red = 1; if (w != "" && witnessed($0, w)) { wit = 1; exit } }' \
  't_verdict_aborted_no_red_line'
shmutant_mut 'a freeze that never settles is endured in silence' \
  '    if [ "$rounds" -ge 32 ]; then SHMUTANT_FREEZE_UNSETTLED=1; break; fi' \
  '    if [ "$rounds" -ge 32 ]; then break; fi' \
  't_freeze_that_never_settles_is_reported'
shmutant_mut 'an unsettled run is scored as a timeout' \
  '  elif [ "$SHMUTANT_RUN_UNSETTLED" = 1 ]; then' \
  '  elif false; then' \
  't_freeze_that_never_settles_is_reported'
shmutant_mut 'a missing path is accepted before its parent is checked' \
  '  parent="$(command -p dirname -- "$path")"' \
  '  parent="$(command -p dirname -- "$path")"; { [ -e "$path" ] || [ -L "$path" ]; } || return 0' \
  't_pool_refuses_a_worker_dir_under_a_swapped_workdir'
shmutant_mut 'opening the stream silences stderr for the rest of the run' \
  '  if ! { exec {SHMUTANT_STREAM_FD}>>"$SHMUTANT_STREAM"; } 2>/dev/null; then' \
  '  if ! exec {SHMUTANT_STREAM_FD}>>"$SHMUTANT_STREAM" 2>/dev/null; then' \
  't_stream_descriptor_survives_a_callback_swapping_the_path'

# --- guards found by the promoted-checklist sweep (round 22) ---
shmutant_mut 'a flag where a value was expected is taken as the value' \
  '    -*) _shmutant_err "$1 needs a value, got the option $2"; return 2 ;;' \
  '    -*) ;;' \
  't_cli_run'
shmutant_mut 'a digest tool that fails yields an empty digest and success' \
  '  [ -n "$out" ] || { _shmutant_err "cannot compute the digest of $1"; return 2; }' \
  '  :' \
  't_cli_run'
shmutant_mut 'rows prepare declared are not read' \
  '  if [ "$n" -eq 0 ]; then _shmutant_err "$label: the mutation table is EMPTY — this harness proves nothing"; _shmutant_pool_fail' \
  '  n="$_shmutant_pool_n"; if [ "$n" -eq 0 ]; then _shmutant_err "$label: the mutation table is EMPTY — this harness proves nothing"; _shmutant_pool_fail' \
  't_pool_reads_the_table_prepare_declared'
shmutant_mut 'a declaration refused inside prepare is lost' \
  '    _shmutant_err "$label: $SHMUTANT_DECL_ERRORS declaration(s) were refused — a table missing rows it was meant to carry proves nothing"; _shmutant_pool_fail "$label" "$wd"; return 2' \
  '    :' \
  't_pool_reads_the_table_prepare_declared'
shmutant_mut 'the caller errexit reaches the run callbacks and the pool status' \
  '  set +e; _shmutant_run_jobs mut "$n" "$wd" "$run" "$suffix" "$jobs"; rjrc=$?' \
  '  _shmutant_run_jobs mut "$n" "$wd" "$run" "$suffix" "$jobs"; rjrc=$?' \
  't_pool_reads_the_table_prepare_declared'
shmutant_mut 'a directory named - resolves as cd -' \
  '  case "$d" in /*) ;; *) d="./$d" ;; esac' \
  '  :' \
  't_abs_ignores_cdpath'
shmutant_mut 'a name ending in a newline resolves to its sibling' \
  '  case "$1" in *$'"'"'\n'"'"') return 1 ;; esac' \
  '  :' \
  't_abs_ignores_cdpath'
shmutant_mut 'a caller function named cd stands in for the builtin' \
  '  ( builtin cd -P -- "$d" 2>/dev/null && builtin pwd -P )' \
  '  ( cd -P -- "$d" 2>/dev/null && pwd -P )' \
  't_abs_ignores_cdpath'
shmutant_mut 'a caller workdir holding entries shmutant did not make is emptied' \
  '  if [ -f "$wd/.shmutant" ] && [ ! -L "$wd/.shmutant" ]; then return 0; fi' \
  '  return 0' \
  't_pool_refuses_a_workdir_it_did_not_create_entries_in'
shmutant_mut 'the workdir ownership check runs under the caller glob options' \
  '  ( set +f; shopt -u failglob; shopt -s nullglob; unset GLOBIGNORE' \
  '  ( ' \
  't_pool_refuses_a_workdir_it_did_not_create_entries_in'
shmutant_mut 'a function shadowing kill is not refused' \
  "  for n in kill wait read trap printf mapfile exec builtin command cd pwd exit return declare local unset set shopt eval readonly export shift true false '[' : . type test; do" \
  '  for n in; do' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'
shmutant_mut 'POSIX mode is not refused' \
  '  if [ -o posix ]; then _shmutant_err "$label: shmutant does not run with POSIX mode on (set +o posix)"; return 2; fi' \
  '  :' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'
shmutant_mut 'the output scan runs whatever awk the caller resolves' \
  '  got="$(SHMUTANT_SCAN_P="$2" SHMUTANT_SCAN_W="$3" command -p awk '"'"'' \
  '  got="$(SHMUTANT_SCAN_P="$2" SHMUTANT_SCAN_W="$3" awk '"'"'' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'
shmutant_mut 'a red status of 08 stays 08' \
  '  if [ -n "${SHMUTANT_RED_STATUS+x}" ]; then _shmutant_canon "$label" SHMUTANT_RED_STATUS "$(( 10#$v_red ))" || return 2; fi' \
  '  :' \
  't_settings_take_a_canonical_form'
shmutant_mut 'the jobs setting keeps its leading zeros' \
  '  if [ -n "$v_jobs" ]; then _shmutant_canon "$label" SHMUTANT_JOBS "$(( 10#$v_jobs ))" || return 2; fi' \
  '  :' \
  't_settings_take_a_canonical_form'
shmutant_mut 'the mode spec is computed under the caller nocasematch' \
  '  ( shopt -u nocasematch; printf '"'"'%s,%s,%s'"'"'' \
  '  ( printf '"'"'%s,%s,%s'"'"'' \
  't_mode_spec_is_immune_to_nocasematch'
shmutant_mut 'errtrace is mistaken for errexit under nocasematch' \
  '  [ -o errexit ] && errexit_before=1' \
  '  case "$-" in *[eE]*) errexit_before=1 ;; esac' \
  't_mode_spec_is_immune_to_nocasematch'
shmutant_mut 'aliases in the sourcing shell are baked into the library' \
  'shopt -u expand_aliases' \
  ':' \
  't_library_is_immune_to_aliases_at_parse_time'
shmutant_mut 'the alias setting of the sourcing shell is not put back' \
  'eval "$_shmutant_alias_state"; unset -v _shmutant_alias_state' \
  'unset -v _shmutant_alias_state' \
  't_library_is_immune_to_aliases_at_parse_time'
shmutant_mut 'the clone directory is made with -p and follows a planted link' \
  '    || ! command -p mkdir -- "$dir/tree" 2>/dev/null; then' \
  '    || ! command -p mkdir -p -- "$dir/tree" 2>/dev/null; then' \
  't_sibling_cannot_plant_in_another_workers_directory'
shmutant_mut 'the run output is written by its documented name' \
  '      _shmutant_snapshot "$BASHPID" >&"$_shmutant_wrap_left"; trap - EXIT; builtin exit "$rrc" ) < /dev/null >&"$out_w" 2>&1 &' \
  '      _shmutant_snapshot "$BASHPID" >&"$_shmutant_wrap_left"; trap - EXIT; builtin exit "$rrc" ) < /dev/null >> "$dir/output" 2>&1 &' \
  't_sibling_cannot_plant_in_another_workers_directory'
shmutant_mut 'a verdict from a worker that was killed is believed' \
  '  if [ "$wstatus" != 0 ]; then' \
  '  if false; then' \
  't_collect_fails_closed'
shmutant_mut 'a replaced worker directory is not a cleanup failure' \
  '    _shmutant_err "$dir is no longer the directory this run created"; SHMUTANT_CLEANUP_FAILED=1' \
  '    :' \
  't_collect_fails_closed'
shmutant_mut 'the runner status is trusted without the channel' \
  '      "status "*) case "${line#status }" in '"'"''"'"'|*[!0-9]*) ;; *) SHMUTANT_RUN_STATUS="${line#status }"; SHMUTANT_RUN_SETUP_FAILED=0 ;; esac ;;' \
  '      "status "*) ;;' \
  't_verdict_survived'
shmutant_mut 'the settled keep is only ever raised by the marker' \
  '    if [ "${marker#* }" = 1 ]; then keep=1; else keep=0; fi' \
  '    [ "${marker#* }" = 1 ] && keep=1' \
  't_cli_run'
shmutant_mut 'the plan subshell keeps the phantom trap trap -p reports' \
  '    readonly SHMUTANT_CLI_WD="$wd" SHMUTANT_CLI_KEEP_FD="$keep_w"' \
  '    trap "_shmutant_cli_abort TERM" TERM; readonly SHMUTANT_CLI_WD="$wd" SHMUTANT_CLI_KEEP_FD="$keep_w"' \
  't_cli_run'

# --- guards added for the twenty-third review round ---
shmutant_mut 'the scan literals go through -v and lose their backslashes' \
  '    BEGIN { p = ENVIRON["SHMUTANT_SCAN_P"]; w = ENVIRON["SHMUTANT_SCAN_W"] }' \
  '    BEGIN { p = "RED\t: "; w = "add\nworks" }' \
  't_verdict_scan_takes_literals_as_bytes'
shmutant_mut 'the callback runs before its group is published' \
  '      read -t 30 -r _ <&"$go" || builtin exit 127' \
  '      :' \
  't_run_publishes_its_group_before_the_callback_runs'
shmutant_mut 'a stream path with a newline passes validation' \
  '    case "$SHMUTANT_STREAM" in *$'"'"'\n'"'"'*) _shmutant_err "$label: SHMUTANT_STREAM contains a newline"; return 2 ;; esac' \
  '    :' \
  't_abs_ignores_cdpath'
shmutant_mut 'a copy path with a newline is accepted' \
  '  case "$1$2" in *$'"'"'\n'"'"'*) _shmutant_err "copy_tree: a path containing a newline is refused"; return 1 ;; esac' \
  '  :' \
  't_abs_ignores_cdpath'
shmutant_mut 'a plan path with a newline is accepted' \
  '  case "$plan$wd" in *$'"'"'\n'"'"'*) _shmutant_err "run: a path containing a newline is refused"; return 2 ;; esac' \
  '  :' \
  't_cli_run'
shmutant_mut 'mutate reads its positionals before checking their count' \
  '  if [ "$#" -ne 3 ]; then _shmutant_err "mutate: usage: shmutant_mutate <file> <old> <new>"; return 1; fi' \
  '  :' \
  't_copy_tree_excludes_git'
shmutant_mut 'the caller CHLD trap is not put back after the pool' \
  '  if [ -n "${SHMUTANT_TRAP_CHLD:-}" ]; then eval "$SHMUTANT_TRAP_CHLD"; else trap - CHLD; fi' \
  '  :' \
  't_pool_survives_a_caller_chld_trap'
shmutant_mut 'a worker reaped by someone else is spun on' \
  '    pids=(); SHMUTANT_ACTIVE=()' \
  '    :' \
  't_pool_survives_a_caller_chld_trap'
shmutant_mut 'a directory planted at output is published into' \
  '  [ -d "$dir/output" ] && [ ! -L "$dir/output" ] && command -p rm -rf -- "$dir/output" 2>/dev/null' \
  '  :' \
  't_run_output_is_published_over_a_planted_directory'
shmutant_mut 'mutate cleanup runs whatever rm the caller defined' \
  '    3) command -p rm -f "$tmp"; _shmutant_mutate_restore "$dir" "$dirmode"; return 2 ;;' \
  '    3) rm -f "$tmp"; _shmutant_mutate_restore "$dir" "$dirmode"; return 2 ;;' \
  't_mutate_applies_first_occurrence_only'

# --- guards added for the twenty-fourth review round ---
shmutant_mut 'a target path with a newline is declared' \
  '  case "$1" in *$'"'"'\n'"'"'*) _shmutant_refuse "target: a path containing a newline is refused: the check of its directory would see the sibling"; return 2 ;; esac' \
  '  :' \
  't_target_refuses_a_newline'
shmutant_mut 'an output that could not be published is accepted' \
  '  [ "${SHMUTANT_RUN_PUBLISHED:-1}" = 1 ] || { printf '"'"'unpublished\n'"'"' >&"$SHMUTANT_VERDICT_FD"; } 2>/dev/null' \
  '  :' \
  't_run_output_publication_failure_is_a_harness_error'
shmutant_mut 'a locked worker directory keeps the capture from its name' \
  '  [ -w "$dir" ] || command -p chmod -- u+rwx "$dir" 2>/dev/null' \
  '  :' \
  't_run_output_publication_failure_is_a_harness_error'
shmutant_mut 'selected reads its unit before checking it was given' \
  '  if [ "$#" -ne 1 ]; then _shmutant_err "selected: usage: shmutant_selected <unit>"; return 2; fi' \
  '  :' \
  't_copy_tree_excludes_git'
shmutant_mut 'a shadow prepare introduced is not rechecked' \
  '  _shmutant_no_shadows "$label" || { _shmutant_pool_fail "$label" "$wd"; return 2; }' \
  '  :' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'
shmutant_mut 'sourcing the library fails a caller under errexit' \
  '_shmutant_alias_state="$(builtin shopt -p expand_aliases; :)"' \
  '_shmutant_alias_state="$(builtin shopt -p expand_aliases)"' \
  't_library_sources_under_errexit'

# --- guards added for the twenty-fifth review round ---
shmutant_mut 'the capture is published beneath a replaced worker directory' \
  '  if [ -L "$dir" ] || { [ -n "${SHMUTANT_DIR_ID:-}" ] && [ "$(_shmutant_dir_id "$dir")" != "$SHMUTANT_DIR_ID" ]; }; then' \
  '  if false; then' \
  't_worker_cleanup_refuses_a_swapped_directory'
shmutant_mut 'only the immediate parent is checked before a removal' \
  '  if [ -n "${2:-}" ] && [ "$(_shmutant_abs "$parent")" != "$2" ]; then' \
  '  if false; then' \
  't_pool_refuses_a_worker_dir_under_a_swapped_workdir'
shmutant_mut 'a run that could not be set up is scored on the row' \
  '    { printf '"'"'setup-failed\n'"'"' >&"$SHMUTANT_VERDICT_FD"; } 2>/dev/null' \
  '    :' \
  't_run_partial_channel_open_is_a_setup_failure'
shmutant_mut 'anything named .shmutant marks a workdir as ours' \
  '  if [ -f "$wd/.shmutant" ] && [ ! -L "$wd/.shmutant" ]; then return 0; fi' \
  '  if [ -e "$wd/.shmutant" ]; then return 0; fi' \
  't_pool_refuses_a_workdir_it_did_not_create_entries_in'
shmutant_mut 'the alias setting is not put back when an old bash is refused' \
  '  if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then builtin exit 2; fi' \
  '  if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then builtin exit 2; else builtin return 2; fi' \
  't_library_restores_alias_state_when_refusing_an_old_bash'
shmutant_mut 'a workdir created under an initial keep is never tracked for removal' \
  '  [ "$made" = 1 ] && SHMUTANT_CLI_WD_TO_RM="$wd"' \
  '  [ "$made" = 1 ] && [ "$keep" != 1 ] && SHMUTANT_CLI_WD_TO_RM="$wd"' \
  't_cli_run'
shmutant_mut 'a function named exit is not a refused shadow' \
  "  for n in kill wait read trap printf mapfile exec builtin command cd pwd exit return declare local unset set shopt eval readonly export shift true false '[' : . type test; do" \
  '  for n in kill wait read trap printf mapfile exec builtin command cd pwd; do' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'
shmutant_mut 'a relative copy destination is rebased on the PWD variable' \
  '  case "$probe" in /*) ;; *) probe="$(builtin pwd -P)/$probe" ;; esac' \
  '  case "$probe" in /*) ;; *) probe="$PWD/$probe" ;; esac' \
  't_copy_tree_excludes_git'

# --- guards added for the twenty-sixth review round ---
shmutant_mut 'the prologue runs whatever shopt the caller aliased' \
  'builtin shopt -u expand_aliases' \
  'shopt -u expand_aliases' \
  't_library_is_immune_to_aliases_at_parse_time'
shmutant_mut 'a builtin disabled with enable passes the shadow check' \
  '    kinds="$(builtin type -at -- "$n" 2>/dev/null)"' \
  '    kinds=builtin; declare -F -- "$n" > /dev/null 2>&1 && kinds=""' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'
shmutant_mut 'workers ended on a startup failure are neither collected nor cleaned' \
  '        while [ "${#pids[@]}" -gt 0 ]; do _shmutant_reap_one "$wd"; done' \
  '        wait "${pids[@]}" 2>/dev/null' \
  't_pool_aborts_running_workers_when_a_dir_cannot_be_recreated'
shmutant_mut 'a killed worker leaves its clone' \
  '      _shmutant_remove "$dir/tree" "$dir" 2>/dev/null || true' \
  '      :' \
  't_pool_aborts_running_workers_when_a_dir_cannot_be_recreated'
shmutant_mut 'a target under an absolute in-tree link passes the preflight' \
  '  _shmutant_no_absolute_link "$1" "$2"' \
  '  :' \
  't_pool_refuses_target_under_symlinked_dir'
shmutant_mut 'a run callback prepare removed is not noticed' \
  '  _shmutant_callable "$run" || { _shmutant_err "$label: run callback not found after prepare: $run"; _shmutant_pool_fail "$label" "$wd"; return 2; }' \
  '  :' \
  't_pool_reads_the_table_prepare_declared'
shmutant_mut 'the capture keeps its name while run executes' \
  '  command -p rm -f -- "$outf" "$mark" "$left" "$seen" "$fifo" "$mark.hold" "$mark.hp" "$mark.go"' \
  '  command -p rm -f -- "$mark" "$left" "$seen" "$fifo" "$mark.hold" "$mark.hp" "$mark.go"' \
  't_run_capture_has_no_name_while_run_executes'
shmutant_mut 'a baseline-skipped row keeps an earlier pool directory' \
  '        _shmutant_fresh_dir "$wd/mut-$i" "$wd" || { _shmutant_err "$label: cannot recreate $wd/mut-$i"; _shmutant_pool_fail "$label" "$wd"; return 2; }' \
  '        :' \
  't_pool_recreates_worker_dirs'

# --- guards added for the twenty-seventh review round ---
# The CLI workdir parent-pin row (round 27) is subsumed: the workdir's identity (inode and
# physical path) is checked before removal, which refuses the same ancestor swap first.
shmutant_mut 'a mutate path with a newline is accepted' \
  '  case "$1" in *$'"'"'\n'"'"'*) _shmutant_err "mutate: a path containing a newline is refused"; return 1 ;; esac' \
  '  :' \
  't_copy_tree_excludes_git'
shmutant_mut 'a listing entry with no start time is left stopped and unreported' \
  '    case "${p#* }" in '"'"''"'"'|*[!0-9]*) kill -CONT "${p%% *}" 2>/dev/null; SHMUTANT_FREEZE_UNSETTLED=1; continue ;; esac' \
  '    :' \
  't_freeze_records_only_what_it_stopped'

# --- guards added for the twenty-eighth review round ---
shmutant_mut 'the CHLD trap is not held once prepare returns' \
  '  SHMUTANT_TRAPS_HELD=1; trap - CHLD DEBUG RETURN ERR' \
  '  SHMUTANT_TRAPS_HELD=1; trap - DEBUG RETURN ERR' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'
shmutant_mut 'the punctuation builtins are not in the shadow list' \
  "  for n in kill wait read trap printf mapfile exec builtin command cd pwd exit return declare local unset set shopt eval readonly export shift true false '[' : . type test; do" \
  '  for n in kill wait read trap printf mapfile exec builtin command cd pwd exit return declare local unset set shopt eval readonly export shift true false; do' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'
shmutant_mut 'a non-empty destination is written into' \
  '      { [ -e "$entry" ] || [ -L "$entry" ]; } && { _shmutant_err "copy_tree: destination $dst is not empty — it is never written into; give an empty or absent directory"; exit 1; }' \
  '      :' \
  't_copy_tree_excludes_git'
shmutant_mut 'the hard-link scan uses a caller cd' \
  '  linked="$(builtin cd -- "$src" 2>/dev/null && command -p find . -path ./.git -prune -o -type f -links +1 -print 2>/dev/null)" || frc=$?' \
  '  linked="$(cd -- "$src" 2>/dev/null && command -p find . -path ./.git -prune -o -type f -links +1 -print 2>/dev/null)" || frc=$?' \
  't_copy_tree_excludes_git'
shmutant_mut 'a directory identity is inode only, without the physical path' \
  '  printf '"'"'%s:%s'"'"' "$id" "$phys"' \
  '  printf '"'"'%s'"'"' "$id"' \
  't_worker_cleanup_refuses_a_swapped_directory'
shmutant_mut 'a failed directory mode restore is a silent success' \
  '  command -p chmod -- "$(_shmutant_mode_spec "$2")" "$1" 2>/dev/null && return 0' \
  '  command -p chmod -- "$(_shmutant_mode_spec "$2")" "$1" 2>/dev/null; return 0' \
  't_mutate_preserves_mode'
shmutant_mut 'the mutate success path ignores a failed restore' \
  '  _shmutant_mutate_restore "$dir" "$dirmode" || return 1' \
  '  _shmutant_mutate_restore "$dir" "$dirmode" || true' \
  't_mutate_preserves_mode'
shmutant_mut 'a prepare root ending in a newline is trimmed to its sibling' \
  "  case \"\$root\" in *\$'\\n'*) _shmutant_err \"\$label: prepare printed a root whose name contains a newline\"; _shmutant_pool_fail \"\$label\" \"\$wd\"; return 2 ;; esac" \
  '  :' \
  't_pool_reads_the_table_prepare_declared'

# --- guards added for the twenty-ninth review round ---
shmutant_mut 'the witness matches as a substring, not a whole token' \
  '        if (pre !~ /[A-Za-z0-9_.-]/ && post !~ /[A-Za-z0-9_.-]/) return 1' \
  '        return 1' \
  't_witness_matches_a_whole_token'
shmutant_mut 'a scan that produced nothing is scored green' \
  '    *) SHMUTANT_RUN_SCAN_FAILED=1 ;;' \
  '    *) ;;' \
  't_witness_matches_a_whole_token'
shmutant_mut 'an unscanned run keeps its callback verdict' \
  '  [ "${SHMUTANT_RUN_SCAN_FAILED:-0}" = 0 ] || SHMUTANT_RUN_SETUP_FAILED=1' \
  '  :' \
  't_witness_matches_a_whole_token'

# --- guards added for the thirtieth review round ---
shmutant_mut 'a pristine tree modified after prepare is cloned anyway' \
  '  if ! state="$(_shmutant_pristine_state "$wd/pristine")" || [ "$state" != "${SHMUTANT_PRISTINE_STATE-}" ]; then' \
  '  if false; then' \
  't_pool_refuses_a_modified_pristine_tree'
shmutant_mut 'a readonly setting is assigned to' \
  '  case "$d" in *r*) return 0 ;; esac' \
  '  :' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'an alias passes as a callback' \
  '  case "$(builtin type -t -- "$1" 2>/dev/null)" in function|file) return 0 ;; esac' \
  '  return 0' \
  't_pool_refuses_alias_only_callbacks'
shmutant_mut 'a function named bash is taken for the PATH interpreter' \
  '  builtin type -P bash 2>/dev/null' \
  '  builtin command -v bash 2>/dev/null' \
  't_bash_floor'

# --- guards added for the thirty-first review round ---
shmutant_mut 'the pristine fingerprint ignores file content' \
  '        && command -p find . -type f -exec "$cksum_bin" {} + ; } 2>/dev/null \' \
  '        && : ; } 2>/dev/null \' \
  't_pool_refuses_a_modified_pristine_tree'
shmutant_mut 'the pristine fingerprint ignores metadata' \
  '    { command -p find . -exec "$ls_bin" -ldn -- {} + \' \
  '    { : \' \
  't_pool_refuses_a_modified_pristine_tree'
shmutant_mut 'a DEBUG trap prepare left keeps running through the pool' \
  '  SHMUTANT_TRAPS_HELD=1; trap - CHLD DEBUG RETURN ERR' \
  '  SHMUTANT_TRAPS_HELD=1; trap - CHLD RETURN ERR' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'
shmutant_mut 'the floor test calls a caller function named [' \
  '  [[ "$1" -gt 5 ]] || { [[ "$1" -eq 5 ]] && [[ "$2" -ge 3 ]]; }' \
  '  [ "$1" -gt 5 ] || { [ "$1" -eq 5 ] && [ "$2" -ge 3 ]; }' \
  't_bash_floor'
shmutant_mut 'the rewrite is not re-checked to be inside the tree from its pinned directory' \
  '      _shmutant_inside "$wroot/tree" "$(builtin pwd -P)" || exit 4' \
  '      :' \
  't_rewrite_is_pinned_against_a_sibling_swap'
shmutant_mut 'a readonly stream setting is assigned to' \
  '    _shmutant_canon "$label" SHMUTANT_STREAM "$sdir/$(command -p basename -- "$SHMUTANT_STREAM")" || return 2' \
  '    SHMUTANT_STREAM="$sdir/$(command -p basename -- "$SHMUTANT_STREAM")"' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'a signal during the CLI spawn window is acted on at once' \
  '  if [ "${SHMUTANT_CLI_SPAWNING:-0}" = 1 ]; then SHMUTANT_CLI_ABORT_PENDING="$sig"; return 0; fi' \
  '  :' \
  't_cli_abort_waits_for_the_child_and_names_its_identity'
shmutant_mut 'the CLI child is escalated on by number alone' \
  '    _shmutant_kill_tree_twice "$SHMUTANT_CLI_CHILD:${SHMUTANT_CLI_CHILD_ID:-}"' \
  '    _shmutant_kill_tree_twice "$SHMUTANT_CLI_CHILD"' \
  't_cli_abort_waits_for_the_child_and_names_its_identity'

# --- guards added for the thirty-second review round ---
shmutant_mut 'the CLI removes its automatic workdir whatever now sits at its path' \
  '  elif [ "$made" = 1 ] && ! _shmutant_cli_wd_is_ours "$wd"; then _shmutant_err "run: refusing to remove $wd — it is no longer the workdir this run created"; rc=2' \
  '  elif false; then :' \
  't_cli_removes_only_the_workdir_it_created_by_identity'
shmutant_mut 'the interrupted CLI removes whatever sits at its workdir path' \
  '    elif ! _shmutant_cli_wd_is_ours "$SHMUTANT_CLI_WD_TO_RM"; then _shmutant_err "run: refusing to remove $SHMUTANT_CLI_WD_TO_RM — it is no longer the workdir this run created"' \
  '    elif false; then :' \
  't_cli_removes_only_the_workdir_it_created_by_identity'
shmutant_mut 'the pool goes on in a workdir prepare replaced' \
  '  if [ -L "$wd" ] || [ "$(_shmutant_dir_id "$wd")" != "${SHMUTANT_WD_ID:-}" ]; then _shmutant_err "$label: $wd is no longer the directory this pool marked as its own — prepare moved or replaced it"; _shmutant_pool_fail "$label" "$wd"; return 2; fi' \
  '  :' \
  't_cli_removes_only_the_workdir_it_created_by_identity'
shmutant_mut 'a clone is not checked against the prepared tree after the copy' \
  '  if ! state="$(_shmutant_pristine_state "$dir/tree")" || [ "$state" != "${SHMUTANT_PRISTINE_STATE-}" ]; then' \
  '  if false; then' \
  't_pool_refuses_a_modified_pristine_tree'
shmutant_mut 'a bare relative target reaches awk as an operand' \
  '  case "$f" in /*|./*|../*) ;; *) f="./$f" ;; esac' \
  '  :' \
  't_mutate_takes_a_bare_relative_target_as_a_path'
shmutant_mut 'a file the fingerprint cannot read is passed over' \
  '    set -o pipefail' \
  '    :' \
  't_pool_refuses_a_modified_pristine_tree'
shmutant_mut 'the verdict stream contents are not checked at the end' \
  '  [ "$(command -p tail -c "+$(( ${SHMUTANT_STREAM_BASE:-0} + 1 ))" -- "$SHMUTANT_STREAM" 2>/dev/null | command -p cksum)" = "$(command -p cksum <&"$SHMUTANT_STREAM_COPY_R")" ]' \
  '  true' \
  't_stream_altered_in_place_is_reported'

# --- guards added for the thirty-third review round ---
shmutant_mut 'the prepared tree is removed from whatever directory sits at the workdir path' \
  '  if [ "${SHMUTANT_KEEP:-0}" != 1 ] && [ ! -L "$2" ] && [ "$(_shmutant_dir_id "$2")" = "${SHMUTANT_WD_ID:-}" ]; then' \
  '  if [ "${SHMUTANT_KEEP:-0}" != 1 ]; then' \
  't_pool_leaves_a_replaced_workdir_alone'
shmutant_mut 'the root entry is left out of the pristine fingerprint' \
  '    { command -p find . -exec "$ls_bin" -ldn -- {} + \' \
  '    { command -p find . ! -name . -exec "$ls_bin" -ldn -- {} + \' \
  't_pool_refuses_a_modified_pristine_tree'
shmutant_mut 'the rewrite trusts the worker directory at its path' \
  '      [ "$(_shmutant_dir_id .)" = "${SHMUTANT_DIR_IDS[$kind-$i]:-}" ] || exit 4' \
  '      :' \
  't_rewrite_refuses_a_worker_directory_swapped_after_the_clone'
shmutant_mut 'the final dispatch guard calls a caller function named test' \
  'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' \
  'if test "${BASH_SOURCE[0]}" = "$0"; then' \
  't_bash_floor'
shmutant_mut 'DEBUG is handed back before the other traps' \
  '  if [ -n "${SHMUTANT_TRAP_CHLD:-}" ]; then eval "$SHMUTANT_TRAP_CHLD"; else trap - CHLD; fi' \
  '  if [ -n "${SHMUTANT_TRAP_DEBUG:-}" ]; then eval "$SHMUTANT_TRAP_DEBUG"; fi; if [ -n "${SHMUTANT_TRAP_CHLD:-}" ]; then eval "$SHMUTANT_TRAP_CHLD"; else trap - CHLD; fi' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'
shmutant_mut 'a readonly selector is accepted' \
  '  if _shmutant_readonly SHMUTANT_SELECT; then _shmutant_err "$label: SHMUTANT_SELECT is readonly — the pool sets it for every run; leave it writable"; return 2; fi' \
  '  :' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'a link chain is followed one hop only' \
  '        pending="${base:+$base/}$target${rel:+/$rel}"' \
  '        pending=""' \
  't_target_through_a_link_chain_to_an_absolute_link_is_refused'
shmutant_mut 'the pool runs with the caller aliases expanding at run time' \
  '  local rc pool_aliases; _shmutant_aliases_off pool_aliases' \
  '  local rc pool_aliases' \
  't_library_is_immune_to_aliases_at_parse_time'
shmutant_mut 'copy_tree runs with the caller aliases expanding at run time' \
  '  local rc copy_tree_aliases; _shmutant_aliases_off copy_tree_aliases' \
  '  local rc copy_tree_aliases' \
  't_public_helpers_are_immune_to_aliases_at_run_time'
shmutant_mut 'mutate runs with the caller aliases expanding at run time' \
  '  local rc mutate_aliases; _shmutant_aliases_off mutate_aliases' \
  '  local rc mutate_aliases' \
  't_public_helpers_are_immune_to_aliases_at_run_time'
shmutant_mut 'saving the alias setting ends a caller that has errexit on' \
  '  local st; st="$(\builtin shopt -p expand_aliases; :)"' \
  '  local st; st="$(\builtin shopt -p expand_aliases)"' \
  't_pool_reads_the_table_prepare_declared'

# --- guards added for the thirty-fourth review round ---
shmutant_mut 'exact timestamps are left out of the fingerprint' \
  '        && { [ -z "$stat_bin" ] || command -p find . -exec "$stat_bin" "$fmt" {} + ; } \' \
  '        && : \' \
  't_pool_refuses_a_modified_pristine_tree'
shmutant_mut 'the stat form is never detected' \
  '  local st; st="$(_shmutant_std_bin stat)" || { SHMUTANT_STAT_STYLE=none; return 0; }' \
  '  SHMUTANT_STAT_STYLE=none; return 0' \
  't_pool_refuses_a_modified_pristine_tree'
shmutant_mut 'the alias state is never put back' \
  '  [[ -z "$1" ]] || \builtin eval "$1"' \
  '  :' \
  't_public_helpers_are_immune_to_aliases_at_run_time'
shmutant_mut 'the alias state put back is always off' \
  '  \builtin printf -v "$1" '"'"'%s'"'"' "$st"' \
  '  \builtin printf -v "$1" '"'"'%s'"'"' "shopt -u expand_aliases"' \
  't_public_helpers_are_immune_to_aliases_at_run_time'
shmutant_mut 'a worker directory is made in whatever sits at the workdir path' \
  '    if ! _shmutant_wd_is_marked "$wd" || ! _shmutant_fresh_dir "$wd/$kind-$i" "$wd" || ! SHMUTANT_DIR_IDS["$kind-$i"]="$(_shmutant_dir_id "$wd/$kind-$i")" \' \
  '    if ! _shmutant_fresh_dir "$wd/$kind-$i" "$wd" || ! SHMUTANT_DIR_IDS["$kind-$i"]="$(_shmutant_dir_id "$wd/$kind-$i")" \' \
  't_pool_refuses_a_workdir_swapped_between_rows'
shmutant_mut 'a half-opened stream is left cached' \
  '  copy="$(command -p mktemp "${TMPDIR:-/tmp}/shmutant-stream.XXXXXX" 2>/dev/null)" || { _shmutant_stream_rollback; _shmutant_err "$label: cannot create the private copy of the verdict stream (in ${TMPDIR:-/tmp})"; return 2; }' \
  '  copy="$(command -p mktemp "${TMPDIR:-/tmp}/shmutant-stream.XXXXXX" 2>/dev/null)" || { _shmutant_err "$label: cannot create the private copy of the verdict stream (in ${TMPDIR:-/tmp})"; return 2; }' \
  't_stream_open_failure_is_rolled_back'
shmutant_mut 'a function named builtin survives the bootstrap' \
  'unset -f builtin 2>/dev/null' \
  ':' \
  't_bash_floor'

# --- guards added for the thirty-fifth review round ---
shmutant_mut 'the stat form is probed through whatever the name resolves to' \
  '  local st; st="$(_shmutant_std_bin stat)" || { SHMUTANT_STAT_STYLE=none; return 0; }' \
  '  local st; st="$(command -pv stat 2>/dev/null)" || { SHMUTANT_STAT_STYLE=none; return 0; }' \
  't_pool_refuses_a_modified_pristine_tree'
shmutant_mut 'the alias setting is saved through a caller printf' \
  '  \builtin printf -v "$1" '"'"'%s'"'"' "$st"' \
  '  printf -v "$1" '"'"'%s'"'"' "$st"' \
  't_public_helpers_are_immune_to_aliases_at_run_time'
shmutant_mut 'the alias setting is put back through a caller [' \
  '  [[ -z "$1" ]] || \builtin eval "$1"' \
  '  [ -z "$1" ] || \builtin eval "$1"' \
  't_public_helpers_are_immune_to_aliases_at_run_time'
shmutant_mut 'RETURN is handed back inside the release' \
  '  if [ -n "${SHMUTANT_TRAP_ERR:-}" ]; then eval "$SHMUTANT_TRAP_ERR"; else trap - ERR; fi' \
  '  if [ -n "${SHMUTANT_TRAP_ERR:-}" ]; then eval "$SHMUTANT_TRAP_ERR"; else trap - ERR; fi; if [ -n "${SHMUTANT_TRAP_RETURN:-}" ]; then eval "$SHMUTANT_TRAP_RETURN"; fi' \
  't_pool_status_survives_a_handler_that_shadows_return'
shmutant_mut 'the held traps are never handed back' \
  '  [[ -z "${SHMUTANT_TRAPS_PENDING:-}" ]] || builtin trap '"'"'_shmutant_traps_last'"'"' RETURN' \
  '  :' \
  't_pool_status_survives_a_handler_that_shadows_return'

# --- guards added for the thirty-sixth review round ---
shmutant_mut 'a target rewritten during its run is scored as it ran' \
  '    [ "$after_ck" = "$target_ck" ] && [ "${SHMUTANT_RUN_TAMPERED:-0}" = 0 ] || { SHMUTANT_RUN_SETUP_FAILED=1; SHMUTANT_RUN_TARGET_REWRITTEN=1; }' \
  '    :' \
  't_a_target_rewritten_during_the_run_is_not_trusted'
shmutant_mut 'a link chain that leaves the root is accepted when it comes back' \
  '      case "$comp" in '"'"''"'"'|.) continue ;; ..) here="${here%/*}"; case "$here" in "$root"|"$root"/*) ;; *) return 1 ;; esac; continue ;; esac' \
  '      case "$comp" in '"'"''"'"'|.) continue ;; ..) here="${here%/*}"; case "$here" in "$root"|"$root"/*) ;; *) return 0 ;; esac; continue ;; esac' \
  't_target_through_a_link_chain_to_an_absolute_link_is_refused'
shmutant_mut 'a function named builtin prepare defined answers the shadow check' \
  '  _shmutant_drop_builtin_fn' \
  '  :' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'
shmutant_mut 'a builtin passes as a callback' \
  '  case "$(builtin type -t -- "$1" 2>/dev/null)" in function|file) return 0 ;; esac' \
  '  case "$(builtin type -t -- "$1" 2>/dev/null)" in function|builtin|file) return 0 ;; esac' \
  't_pool_refuses_alias_only_callbacks'
shmutant_mut 'the digest tool is taken by name' \
  '  if tool="$(_shmutant_std_bin sha256sum)"; then out="$("$tool" -- "$1" 2>/dev/null)"' \
  '  if command -pv sha256sum > /dev/null 2>&1; then out="$(sha256sum -- "$1" 2>/dev/null)"' \
  't_checksum_uses_the_digest_file_not_a_function'
shmutant_mut 'the CLI trusts the names it inherited' \
  '  builtin unset -f kill wait read trap printf mapfile exec command cd pwd exit return declare local unset set shopt eval readonly export shift true false '"'"'['"'"' : . type test 2>/dev/null' \
  '  :' \
  't_cli_removes_shadows_planted_before_it_ran'
shmutant_mut 'leaving posix mode leaves the shell options as it reset them' \
  '  POSIXLY_CORRECT=1; unset -f builtin 2>/dev/null; unset POSIXLY_CORRECT' \
  '  POSIXLY_CORRECT=1; unset -f builtin 2>/dev/null; unset POSIXLY_CORRECT; return 0' \
  't_pool_reads_the_table_prepare_declared'

# --- guards added for the thirty-seventh review round ---
shmutant_mut 'a transient rewrite of the target is not sampled while the run is alive' \
  '            [ "$(_shmutant_target_ck "$dir" "$SHMUTANT_TARGET_REL" "$SHMUTANT_TARGET_KEY")" = "$SHMUTANT_TARGET_CK" ] || { tampered=1; printf '"'"'tampered\n'"'"' >&"$seen_w"; }' \
  '            :' \
  't_a_target_rewritten_during_the_run_is_not_trusted'
shmutant_mut 'the target check covers content alone' \
  '    { "$ls_bin" -ldn -- "$2" | command -p awk '"'"'{ sub(/[@+.]$/, "", $1); $2 = "-"; print $1, $3, $4, $5 }'"'"'' \
  '    { :' \
  't_a_target_rewritten_during_the_run_is_not_trusted'
shmutant_mut 'a refused destination is given the source root metadata' \
  '  ) || return 1' \
  '  ) || rc=1' \
  't_copy_tree_excludes_git'
shmutant_mut 'the completion path is unlinked whatever now sits at the workdir' \
  '  if _shmutant_cli_wd_is_ours "$wd"; then command -p rm -f -- "$done_file"; fi' \
  '  command -p rm -f -- "$done_file"' \
  't_cli_removes_only_the_workdir_it_created_by_identity'
shmutant_mut 'a clone swapped by its run is removed by path' \
  '    elif [ -L "$1/tree" ] || [ "$(_shmutant_dir_id "$1/tree")" != "${SHMUTANT_CLONE_ID:-}" ]; then _shmutant_err "refusing to remove $1/tree: it is no longer the clone this run made"' \
  '    elif false; then :' \
  't_a_clone_swapped_by_its_run_is_not_removed'
shmutant_mut 'an unverified CLI child is escalated on by bare number' \
  '    _shmutant_kill_tree_twice "$SHMUTANT_CLI_CHILD:${SHMUTANT_CLI_CHILD_ID:-}"' \
  '    _shmutant_kill_tree_twice "$SHMUTANT_CLI_CHILD${SHMUTANT_CLI_CHILD_ID:+:$SHMUTANT_CLI_CHILD_ID}"' \
  't_cli_abort_waits_for_the_child_and_names_its_identity'

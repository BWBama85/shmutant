# shellcheck shell=bash
# shmutant, mutation-tested by itself. Every row breaks one guard in shmutant.sh and names the
# unit of test/run.sh that claims to cover it. Run from the repository root:
#
#   bash shmutant.sh run test/mutants.sh
#
# The harness driving this plan is the working tree's shmutant.sh; each row mutates a clone.

prepare() {
  mkdir -p "$1/test" "$1/docs" || return 1
  cp -- "$SHMUTANT_PLAN_DIR/../shmutant.sh" "$1/" || return 1
  cp -- "$SHMUTANT_PLAN_DIR/run.sh" "$1/test/" || return 1
  # t_doc_witness_check_refuses_a_row runs a block of the guide as written
  cp -- "$SHMUTANT_PLAN_DIR/../docs/integrating.md" "$1/docs/" || return 1
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
  '    index($0, p) == 1 { red = 1; if (w != "" && witnessed(substr($0, length(p) + 1), w)) { wit = 1; exit } }' \
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
  '  elif [ "${SHMUTANT_KEEP:-0}" != 1 ] && [ -e "$1/tree" ]; then' \
  '  elif [ -e "$1/tree" ]; then' \
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
  't_cli_labels_its_stream_and_refuses_bad_arguments'
shmutant_mut 'version prints the wrong marker' \
  '"$SHMUTANT_VERSION"' \
  '"$SHMUTANT_VERSION-mutant"' \
  't_cli_prints_usage_version_and_checksum'
shmutant_mut 'checksum prints the whole line instead of the digest' \
  'printf '"'"'%s'"'"' "${BASH_REMATCH[-1]}"' \
  'printf '"'"'%s'"'"' "${BASH_REMATCH[0]}"' \
  't_cli_prints_usage_version_and_checksum'

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
  '"$prep" "$wd/pristine" >&"$pout_w"; _shmutant_pool_stash "$?"' \
  '( "$prep" "$wd/pristine" >&"$pout_w" ); _shmutant_pool_stash "$?"' \
  't_pool_runs_prepare_in_its_own_shell'
shmutant_mut 'surplus mutation arguments are accepted' \
  'if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then _shmutant_refuse "mut: usage' \
  'if [ "$#" -lt 4 ]; then _shmutant_refuse "mut: usage' \
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
  '"$prep" "$wd/pristine" >&"$pout_w"; _shmutant_pool_stash "$?"' \
  'if "$prep" "$wd/pristine" >&"$pout_w"; then _shmutant_pool_stash 0; else _shmutant_pool_stash "$?"; fi' \
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
  't_cli_removes_only_the_workdir_it_made_unless_kept'
shmutant_mut 'a caller-supplied workdir is removed' \
  '  elif [ "$made" = 1 ]; then _shmutant_remove "$wd" "${SHMUTANT_CLI_WD_PARENT:-}" || {' \
  '  elif true; then _shmutant_remove "$wd" "${SHMUTANT_CLI_WD_PARENT:-}" || {' \
  't_cli_removes_only_the_workdir_it_made_unless_kept'
shmutant_mut 'the plan is sourced by its bare name' \
  '_shmutant_cli_load "$SHMUTANT_PLAN_DIR/$(command -p basename -- "$plan")"' \
  '_shmutant_cli_load "$plan"' \
  't_cli_loads_the_plan_by_its_path_in_a_shell_of_its_own'
shmutant_mut 'a relative --workdir is resolved after the plan may have moved' \
  '  wd="$(_shmutant_abs "$wd")" || { _shmutant_err "run: cannot resolve workdir"; return 2; }' \
  '  :' \
  't_cli_loads_the_plan_by_its_path_in_a_shell_of_its_own'
shmutant_mut 'inherited prepare/run functions are accepted' \
  '  unset -f prepare run' \
  '  :' \
  't_cli_loads_the_plan_by_its_path_in_a_shell_of_its_own'
shmutant_mut 'the plan errexit is left on across the pool call' \
  '  set +o errexit' \
  '  :' \
  't_cli_loads_the_plan_by_its_path_in_a_shell_of_its_own'
shmutant_mut 'a relative SHMUTANT_STREAM is resolved after the plan may have moved' \
  '    _shmutant_canon "$label" SHMUTANT_STREAM "$sdir/$(command -p basename -- "$SHMUTANT_STREAM")" || return 2' \
  '    :' \
  't_cli_keeps_plan_output_off_the_stream_and_paths_where_invoked'
shmutant_mut 'the subshell status is trusted without the completion marker' \
  '  if [ -n "$marker" ] && [ "${marker%% *}" = "$rc" ]; then' \
  '  if true; then' \
  't_cli_counts_a_plan_that_ends_early_as_a_load_failure'

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
  '    elif [ "$status" -eq "$red" ] && [ "$SHMUTANT_RUN_RED" = 1 ]; then verdict=red' \
  '    elif true; then verdict=red' \
  't_baseline_non_red_exit_is_aborted'
shmutant_mut 'a reused pid is signalled anyway' \
  '  _shmutant_same_start "$now" "$2"' \
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
  't_cli_interrupted_ends_its_workers_and_removes_its_workdir'
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
  't_cli_removes_only_the_workdir_it_made_unless_kept'
shmutant_mut 'containment honours the caller nocasematch' \
  '  ( shopt -u nocasematch; if [ "$1" = / ]' \
  '  ( :; if [ "$1" = / ]' \
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
  '; if [ "$1" = / ]; then case "$2" in /*) exit 0 ;; esac; exit 1; fi' \
  '; :' \
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
  't_cli_interrupted_honours_the_keep_prepare_settled'
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
  't_cli_keeps_plan_output_off_the_stream_and_paths_where_invoked'

# --- guards added for the fourteenth review round ---
shmutant_mut 'the root pid is signalled by number even after it was reaped' \
  '  [ "${#targets[@]}" -eq 0 ] || kill "-$sig"' \
  '  [ -n "$pid" ] && targets+=("$pid"); [ "${#targets[@]}" -eq 0 ] || kill "-$sig"' \
  't_post_run_cleanup_never_signals_a_reaped_root_by_number'
shmutant_mut 'the stream is reopened by path for every record' \
  '{ printf '"'"'%s\n'"'"' "$out" >&"$SHMUTANT_STREAM_FD"; } 2>/dev/null || SHMUTANT_EMIT_FAILED=1' \
  '{ printf '"'"'%s\n'"'"' "$out" >> "$SHMUTANT_STREAM"; } 2>/dev/null || SHMUTANT_EMIT_FAILED=1' \
  't_stream_descriptor_survives_a_callback_swapping_the_path'
shmutant_mut 'a validation failure after prepare keeps the pristine tree' \
  'a clone could not keep inside itself)"; _shmutant_pool_fail "$label" "$wd"; return 2' \
  'a clone could not keep inside itself)"; return 2' \
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
  't_cli_abort_keeps_the_workdir_the_environment_asked_to_keep'

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
  '  killed=0; rc=0; ambiguous=0; base_sel=(); base_verdict=(); base_why=(); row_why=()' \
  '  killed=0; rc=0; ambiguous=0; base_why=(); row_why=()' \
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
  '  unset SHMUTANT_STREAM_OPENED; [ -n' \
  '  SHMUTANT_STREAM_OPENED="${SHMUTANT_STREAM:-}"; [ -n' \
  't_stream_write_failure_is_a_harness_error'

# --- guards added for the nineteenth review round ---
shmutant_mut 'the completion marker keeps its path while the plan loads' \
  '  command -p rm -f -- "$SHMUTANT_CLI_DONE_PATH"' \
  '  :' \
  't_cli_counts_a_plan_that_ends_early_as_a_load_failure'
shmutant_mut 'the snapshot on return is dropped, leaving only the trap' \
  '      _shmutant_snapshot "$BASHPID" >&"$_shmutant_wrap_left"; trap - EXIT; builtin exit "$rrc" )' \
  '      trap - EXIT; builtin exit "$rrc" )' \
  't_run_cannot_lose_the_leftover_record_by_locking_its_dir'
shmutant_mut 'a rejected root is still searched from while freezing' \
  '  if [ "$root_ok" = 1 ]; then roots=("$pid")' \
  '  roots=("$pid"); if [ "$root_ok" = 1 ]; then :' \
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
  't_cli_keeps_plan_output_off_the_stream_and_paths_where_invoked'
shmutant_mut 'the automatic workdir is removed raw after an incomplete run' \
  '  elif [ "$made" = 1 ]; then _shmutant_remove "$wd" "${SHMUTANT_CLI_WD_PARENT:-}" || { _shmutant_err "run: could not remove the workdir $wd"; rc=2; }' \
  '  elif [ "$made" = 1 ]; then command -p rm -rf -- "$wd" 2>/dev/null' \
  't_cli_counts_a_plan_that_ends_early_as_a_load_failure'

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
  '      ( ( read -r _ <&"$hold_r" ) < /dev/null > /dev/null 2>&1 {hold}>&- & printf '"'"'%s\n'"'"' "$!" >&"$hp" )' \
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
  '  _shmutant_holder_state "$holder" "${holderid:-}" || [ "$?" = 2 ] || return 0' \
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
  '      ( ( read -r _ <&"$hold_r" ) < /dev/null > /dev/null 2>&1 {hold}>&- & printf '"'"'%s\n'"'"' "$!" >&"$hp" )' \
  '      ( read -r _ <&"$hold_r" ) < /dev/null > /dev/null 2>&1 {hold}>&- & printf '"'"'%s\n'"'"' "$!" >&"$hp"' \
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
  '    index($0, p) == 1 { red = 1; if (w != "" && witnessed(substr($0, length(p) + 1), w)) { wit = 1; exit } }' \
  '    index($0, p) { red = 1; if (w != "" && witnessed(substr($0, length(p) + 1), w)) { wit = 1; exit } }' \
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
  't_cli_labels_its_stream_and_refuses_bad_arguments'
shmutant_mut 'a digest tool that prints no digest yields success' \
  '  [ -n "$out" ] || { _shmutant_err "$tool printed no SHA-256 for $1"; return 2; }' \
  '  :' \
  't_checksum_takes_the_tool_status_and_one_digest'
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
# (row 'a name ending in a newline resolves to its sibling' dropped: subsumed by the physical-name check that follows the cd, which refuses the same input and has a row of its own)
shmutant_mut 'a caller function named cd stands in for the builtin' \
  '  ( builtin cd -P -- "$d" 2>/dev/null || exit 1' \
  '  ( cd -P -- "$d" 2>/dev/null || exit 1' \
  't_abs_ignores_cdpath'
shmutant_mut 'a caller workdir holding entries shmutant did not make is emptied' \
  '    for e in "$wd"/pristine "$wd"/base-* "$wd"/mut-*; do' \
  '    for e in; do' \
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
  '  ( shopt -u nocasematch; builtin printf '"'"'%s,%s,%s'"'"'' \
  '  ( printf '"'"'%s,%s,%s'"'"'' \
  't_mode_spec_is_immune_to_nocasematch'
shmutant_mut 'errtrace is mistaken for errexit under nocasematch' \
  '  [ -o errexit ] && errexit_before=1' \
  '  case "$-" in *[eE]*) errexit_before=1 ;; esac' \
  't_mode_spec_is_immune_to_nocasematch'
shmutant_mut 'aliases in the sourcing shell are baked into the library' \
  '; :)"; \builtin shopt -u expand_aliases' \
  '; :)"; \builtin :' \
  't_library_is_immune_to_aliases_at_parse_time'
shmutant_mut 'the alias setting of the sourcing shell is not put back' \
  '\builtin eval "$_shmutant_alias_state"; \builtin unset -v _shmutant_alias_state' \
  '\builtin unset -v _shmutant_alias_state' \
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
  't_cli_removes_only_the_workdir_it_made_unless_kept'
shmutant_mut 'the plan subshell keeps the phantom trap trap -p reports' \
  '    readonly SHMUTANT_CLI_WD="$wd" SHMUTANT_CLI_KEEP_FD="$keep_w"' \
  '    trap "_shmutant_cli_abort TERM" TERM; readonly SHMUTANT_CLI_WD="$wd" SHMUTANT_CLI_KEEP_FD="$keep_w"' \
  't_cli_plan_subshell_drops_the_abort_trap'

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
  't_cli_labels_its_stream_and_refuses_bad_arguments'
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
  '  _shmutant_no_shadows "$label" || { _shmutant_pool_fail "$label" "$wd"; builtin return 2; }' \
  '  :' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'
shmutant_mut 'sourcing the library fails a caller under errexit' \
  '_shmutant_alias_state="$(\builtin shopt -p expand_aliases; :)"' \
  '_shmutant_alias_state="$(\builtin shopt -p expand_aliases)"' \
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
  '  if [ -f "$wd/.shmutant" ] && [ ! -L "$wd/.shmutant" ]; then' \
  '  if [ -e "$wd/.shmutant" ] || [ -L "$wd/.shmutant" ]; then return 0; elif false; then' \
  't_pool_refuses_a_workdir_it_did_not_create_entries_in'
shmutant_mut 'the alias setting is not put back when an old bash is refused' \
  '  if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then builtin exit 2; fi' \
  '  if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then builtin exit 2; else builtin return 2; fi' \
  't_library_restores_alias_state_when_refusing_an_old_bash'
shmutant_mut 'a workdir created under an initial keep is never tracked for removal' \
  '  [ "$made" = 1 ] && SHMUTANT_CLI_WD_TO_RM="$wd"' \
  '  [ "$made" = 1 ] && [ "$keep" != 1 ] && SHMUTANT_CLI_WD_TO_RM="$wd"' \
  't_cli_interrupted_honours_the_keep_prepare_settled'
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
  '; :)"; \builtin shopt -u expand_aliases' \
  '; :)"; shopt -u expand_aliases' \
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
  '      else _shmutant_remove "$dir/tree" "$dir" 2>/dev/null || true' \
  '      else :' \
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
  'if ! command -p rm -f -- "$outf" ${counts:+"$counts"} "$mark" "$left" "$seen" "$fifo" "$mark.hold" "$mark.hp" "$mark.go" 2>/dev/null; then' \
  'if ! command -p rm -f -- ${counts:+"$counts"} "$mark" "$left" "$seen" "$fifo" "$mark.hold" "$mark.hp" "$mark.go" 2>/dev/null; then' \
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
  '    case "$p" in *'"'"' '"'"'?*) ;; *) kill -CONT "${p%% *}" 2>/dev/null; SHMUTANT_FREEZE_UNSETTLED=1; continue ;; esac' \
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
# The hard-link-scan cd row is subsumed: shmutant_copy_tree makes the shadow check on entry
# and refuses a shell with a function named cd before the scan can run.
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
  '        if (boundary(pre) && boundary(post)) return 1' \
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
  '_shmutant_attr_field_has_r() { case "${1%% *}" in *r*) [[ 1 -eq 1 ]] ;; *) [[ 1 -eq 0 ]] ;; esac; }' \
  '_shmutant_attr_field_has_r() { case "${1%% *}" in *r*) [[ 1 -eq 0 ]] ;; *) [[ 1 -eq 0 ]] ;; esac; }' \
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
  '    if [ -n "${SHMUTANT_CLI_CHILD_ID:-}" ]; then _shmutant_kill_tree_twice "$SHMUTANT_CLI_CHILD:$SHMUTANT_CLI_CHILD_ID"; else _shmutant_kill_tree_twice "$SHMUTANT_CLI_CHILD"; fi' \
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
  '  tmpd="$(_shmutant_abs "${TMPDIR:-/tmp}")" || { _shmutant_stream_rollback; _shmutant_err "$label: TMPDIR does not name a directory that resolves from here (${TMPDIR:-/tmp}) — the private copy of the verdict stream goes there"; return 2; }' \
  '  tmpd="$(_shmutant_abs "${TMPDIR:-/tmp}")" || { _shmutant_err "$label: TMPDIR does not name a directory that resolves from here (${TMPDIR:-/tmp}) — the private copy of the verdict stream goes there"; return 2; }' \
  't_stream_open_failure_is_rolled_back'
shmutant_mut 'a stream whose private copy cannot be made is left cached' \
  '  copy="$(command -p mktemp "$tmpd/shmutant-stream.XXXXXX" 2>/dev/null)" || { _shmutant_stream_rollback; _shmutant_err "$label: cannot create the private copy of the verdict stream (in ${TMPDIR:-/tmp})"; return 2; }' \
  '  copy="$(command -p mktemp "$tmpd/shmutant-stream.XXXXXX" 2>/dev/null)" || { _shmutant_err "$label: cannot create the private copy of the verdict stream (in ${TMPDIR:-/tmp})"; return 2; }' \
  't_stream_open_failure_is_rolled_back'
shmutant_mut 'a function named builtin survives the bootstrap' \
  '\unset -f builtin 2>/dev/null' \
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
  '  local n kinds; _shmutant_drop_builtin_fn' \
  '  local n kinds; :' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'
shmutant_mut 'a builtin passes as a callback' \
  '  case "$(builtin type -t -- "$1" 2>/dev/null)" in function|file) return 0 ;; esac' \
  '  case "$(builtin type -t -- "$1" 2>/dev/null)" in function|builtin|file) return 0 ;; esac' \
  't_pool_refuses_alias_only_callbacks'
shmutant_mut 'the digest tool is taken by name' \
  '  if tool="$(_shmutant_std_bin sha256sum)"; then cmd=("$tool"); re="$sum_re"' \
  '  if command -pv sha256sum > /dev/null 2>&1; then cmd=(sha256sum); re="$sum_re"' \
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
  '            { seen_ck="$(_shmutant_target_ck "$dir" "$SHMUTANT_TARGET_REL" "$SHMUTANT_TARGET_KEY")" && [ "$seen_ck" = "$SHMUTANT_TARGET_CK" ]; } \' \
  '            { :; } \' \
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
  '  if [ -L "$1/tree" ] || { [ -e "$1/tree" ] && [ "$(_shmutant_dir_id "$1/tree")" != "${SHMUTANT_CLONE_ID:-}" ]; }; then' \
  '  if [ -L "$1/tree" ]; then' \
  't_a_clone_swapped_by_its_run_is_not_removed'
# (row 'an unverified CLI child is escalated on by bare number' dropped: a bare pid for the CLI's own unreaped child is now the intended behaviour, per the later review finding)

# --- guards added for the thirty-eighth review round ---
shmutant_mut 'a standalone mutate trusts the names the caller left' \
  '  _shmutant_no_shadows mutate || { _shmutant_aliases_back "$mutate_aliases"; builtin return 1; }' \
  '  :' \
  't_public_helpers_refuse_a_shadowed_builtin'
shmutant_mut 'a pool name prepare made readonly is assigned to' \
  '  if ! _shmutant_pool_locals_writable "$_shmutant_pool_label" "prepare made"; then' \
  '  if false; then' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'the pinned relative cd consults CDPATH' \
  '      builtin cd -P -- "./tree$suffix/$(command -p dirname -- "${SHMUTANT_ROWS_FILE[$i]}")" 2>/dev/null || exit 4' \
  '      builtin cd -P -- "tree$suffix/$(command -p dirname -- "${SHMUTANT_ROWS_FILE[$i]}")" 2>/dev/null || exit 4' \
  't_rewrite_is_pinned_against_a_sibling_swap'

# --- guards added for the thirty-ninth review round ---
shmutant_mut 'the baseline arrays are not in the readonly guard' \
  '    _shmutant_pool_t0 _shmutant_pool_wd after_ck ambiguous base base_sel base_verdict base_why cap cksum_bin clone_id comp copy counts counts_bad counts_end counts_got counts_r counts_w cwhy d \' \
  '    _shmutant_pool_t0 _shmutant_pool_wd after_ck ambiguous base base_why cap cksum_bin clone_id comp copy counts counts_bad counts_end counts_got counts_r counts_w cwhy d \' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'a readonly refusal leaves the prepare capture open' \
  '    exec {_shmutant_pool_pout_w}>&- {_shmutant_pool_pout_r}<&-' \
  '    :' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'a skipped row is recreated in whatever sits at the workdir path' \
  '        _shmutant_wd_is_marked "$wd" || { _shmutant_pool_fail "$label" "$wd"; return 2; }' \
  '        :' \
  't_pool_refuses_a_workdir_swapped_between_rows'
shmutant_mut 'a dying worker clone is removed by path' \
  '      elif [ -L "$dir/tree" ] || [ -z "$clone_id" ] || [ "$(_shmutant_dir_id "$dir/tree")" != "$clone_id" ]; then _shmutant_err "refusing to remove $dir/tree: it is not the clone its worker made"' \
  '      elif false; then :' \
  't_a_clone_swapped_by_its_run_is_not_removed'
shmutant_mut 'a function named return swallows the shadow check refusal' \
  '    case "$kinds" in *builtin*) ;; *) _shmutant_err "$1: $n is not the builtin this harness relies on (a function of that name, or disabled with enable)"; builtin return 2 ;; esac' \
  '    case "$kinds" in *builtin*) ;; *) _shmutant_err "$1: $n is not the builtin this harness relies on (a function of that name, or disabled with enable)"; return 2 ;; esac' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'

# --- guards added for the fortieth review round ---
shmutant_mut 'the prepare status is captured into a name prepare can make readonly' \
  '  "$prep" "$wd/pristine" >&"$pout_w"; _shmutant_pool_stash "$?"' \
  '  "$prep" "$wd/pristine" >&"$pout_w"; prc=$?; _shmutant_pool_stash "$prc"' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'an unbounded run has no descendant watchdog' \
  '        while [ "$timeout" -eq 0 ] || [ "$elapsed" -lt "$budget" ]; do' \
  '        while [ "$timeout" -ne 0 ] && [ "$elapsed" -lt "$budget" ]; do' \
  't_unbounded_run_still_tracks_descendants'
shmutant_mut 'POSIX mode prepare turned on is not rechecked' \
  '  if [[ -o posix ]]; then' \
  '  if false; then' \
  't_pool_refuses_shadowed_builtins_and_posix_mode'

# --- guards added for the forty-first review round ---
shmutant_mut 'the pool declares its locals before the readonly check' \
  '  _shmutant_pool_locals_writable pool "the calling shell made" || \builtin return 2' \
  '  :' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'copy_tree declares its locals before the readonly check' \
  '  _shmutant_locals_writable copy_tree "the calling shell made" adst asrc comp copy_tree_aliases d dst entry frc kinds linked m made n name norm out probe probe2 rc rest rootls src st t who || \builtin return 1' \
  '  :' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'mutate declares its locals before the readonly check' \
  '  _shmutant_locals_writable mutate "the calling shell made" dir dirmode f kinds m mode mutate_aliases n nl out rc st t tmp who || \builtin return 1' \
  '  :' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'the readonly check skips the last name' \
  '  if [[ $# -le 3 ]]; then :' \
  '  if [[ $# -le 4 ]]; then :' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'a missing completion report ignores the keep channel' \
  '    if [ -z "$keep_last" ] || [ "$keep_last" = 1 ]; then keep=1; fi' \
  '    :' \
  't_cli_removes_only_the_workdir_it_created_by_identity'
shmutant_mut 'the prepared tree is removed by path at cleanup' \
  '    elif [ -L "$2/pristine" ] || [ "$(_shmutant_dir_id "$2/pristine")" != "${SHMUTANT_PRISTINE_ID:-}" ]; then _shmutant_err "$1: refusing to remove $2/pristine: it is not the tree this pool prepared"; SHMUTANT_CLEANUP_FAILED=1' \
  '    elif false; then :' \
  't_a_clone_swapped_by_its_run_is_not_removed'
shmutant_mut 'the watchdog deadline is a wall-clock instant' \
  '        while [ "$timeout" -eq 0 ] || [ "$elapsed" -lt "$budget" ]; do' \
  '        while [ "$timeout" -eq 0 ] || [ "$(_shmutant_now)" -lt "$(( last + budget - elapsed ))" ]; do' \
  't_watchdog_deadline_survives_clock_steps'
shmutant_mut 'a poll that read no time counts nothing' \
  '          [ "$d" -lt 500000 ] && d=500000' \
  '          :' \
  't_watchdog_deadline_survives_clock_steps'
shmutant_mut 'a poll counts a whole clock step' \
  '          [ "$d" -gt 5000000 ] && d=5000000' \
  '          :' \
  't_watchdog_deadline_survives_clock_steps'

# --- guards added for the forty-second review round ---
shmutant_mut 'the readonly probe reads its answer through a shadowable set' \
  '_shmutant_readonly() { _shmutant_attrs_readonly "$(declare -p -- "$1" 2>/dev/null)"; }' \
  '_shmutant_readonly() { set -- "$(declare -p -- "$1" 2>/dev/null)"; _shmutant_attrs_readonly "$1"; }' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'the readonly probe keeps its answer in a name of its own' \
  '_shmutant_readonly() { _shmutant_attrs_readonly "$(declare -p -- "$1" 2>/dev/null)"; }' \
  '_shmutant_readonly() { local d; d="$(declare -p -- "$1" 2>/dev/null)"; _shmutant_attrs_readonly "$d"; }' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'the prepare status stash skips its readonly check' \
  '  if _shmutant_readonly _shmutant_pool_prc; then' \
  '  if false; then' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'a kept clone is not identity-checked before its verdict' \
  '  if [ -L "$1/tree" ] || { [ -e "$1/tree" ] && [ "$(_shmutant_dir_id "$1/tree")" != "${SHMUTANT_CLONE_ID:-}" ]; }; then' \
  '  if [ "${SHMUTANT_KEEP:-0}" != 1 ] && { [ -L "$1/tree" ] || { [ -e "$1/tree" ] && [ "$(_shmutant_dir_id "$1/tree")" != "${SHMUTANT_CLONE_ID:-}" ]; }; }; then' \
  't_a_clone_swapped_by_its_run_is_not_removed'
shmutant_mut 'a swapped clone still publishes the run verdict' \
  '    set -- "$1" unprepared "$3" swapped' \
  '    :' \
  't_a_clone_swapped_by_its_run_is_not_removed'
shmutant_mut 'a swapped kept clone is not a harness error' \
  '        swapped)     swapped=1 ;;' \
  '        swapped)     : ;;' \
  't_a_clone_swapped_by_its_run_is_not_removed'

# --- guards added for the forty-third review round ---
shmutant_mut 'a non-ASCII letter is a witness boundary' \
  '        if (boundary(pre) && boundary(post)) return 1' \
  '        if (pre !~ /[A-Za-z0-9_.-]/ && post !~ /[A-Za-z0-9_.-]/) return 1' \
  't_witness_matches_a_whole_token'
shmutant_mut 'the bootstrap turns aliases off through an alias-expandable word' \
  '; :)"; \builtin shopt -u expand_aliases' \
  '; :)"; builtin shopt -u expand_aliases' \
  't_bootstrap_is_immune_to_a_builtin_alias'
shmutant_mut 'the bootstrap drops a builtin function through an alias-expandable word' \
  '\unset -f builtin 2>/dev/null' \
  'unset -f builtin 2>/dev/null' \
  't_bootstrap_is_immune_to_a_builtin_alias'
shmutant_mut 'POSIXLY_CORRECT is left as set -o posix wrote it' \
  '  case "$_shmutant_pc" in set:*) POSIXLY_CORRECT="${_shmutant_pc#set:}" ;; *) [[ -z "${POSIXLY_CORRECT+set}" ]] || builtin unset -v POSIXLY_CORRECT ;; esac' \
  '  :' \
  't_helpers_restore_posixly_correct'
# (no row on the POSIXLY_CORRECT unset guard: its only effect, expand_aliases turned off, is put
# back by every entry point's own alias restore, so no unit can see it)
shmutant_mut 'the readonly preflight probes nothing readonly -p did not mention' \
  '_shmutant_locals_writable() { _shmutant_locals_writable_in "$1" "$2" "$(readonly -p 2>/dev/null)" "${@:3}"; }' \
  '_shmutant_locals_writable() { _shmutant_locals_writable_in "$1" "$2" "" "${@:3}"; }' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'a worker local is missing from the pool preflight' \
  '    table target target_ck targets timeout tmp unpublished us v v_jobs v_red v_timeout \' \
  '    table target_ck targets timeout tmp unpublished us v v_jobs v_red v_timeout \' \
  't_readonly_preflight_names_every_local'

# --- guards added for the forty-fourth review round ---
shmutant_mut 'a relative run callback is looked up again after prepare' \
  '  run="$(_shmutant_pin_callback "$run")" || { _shmutant_err "$label: run callback cannot be resolved to a program: $run"; return 2; }' \
  '  :' \
  't_pool_pins_relative_executable_callbacks'
shmutant_mut 'a caller file named .shmutant marks the workdir' \
  '    [ "$line" = $'"'"'shmutant workdir\n'"'"' ] && [ "$size" -eq 17 ] 2>/dev/null && return 0' \
  '    return 0' \
  't_pool_refuses_a_workdir_it_did_not_create_entries_in'
shmutant_mut 'the marker shmutant writes is empty' \
  '    printf '"'"'shmutant workdir\n'"'"' >| "$wd/.shmutant" 2>/dev/null || { _shmutant_err "$label: cannot mark $wd as a shmutant workdir"; exit 2; } )' \
  '    : >| "$wd/.shmutant" 2>/dev/null || { _shmutant_err "$label: cannot mark $wd as a shmutant workdir"; exit 2; } )' \
  't_pool_refuses_a_workdir_it_did_not_create_entries_in'
shmutant_mut 'what the plan left running outlives the CLI' \
  '  _shmutant_cli_end_group "$SHMUTANT_CLI_CHILD" "$plan_holder"' \
  '  :' \
  't_cli_ends_what_the_plan_left_running'
shmutant_mut 'the plan subshell shares the CLI process group' \
  '  builtin set -m' \
  '  builtin set +m' \
  't_cli_ends_what_the_plan_left_running'

# --- guards added for the forty-fifth review round ---
shmutant_mut 'a name with a newline is fingerprinted anyway' \
  '    command -p find . -name "*$nl*" 2>/dev/null | command -p awk '"'"'END { exit NR > 0 }'"'"' || exit 1' \
  '    :' \
  't_pool_refuses_a_prepared_tree_with_a_newline_name'
shmutant_mut 'the bookkeeping arrays are not in the readonly preflight' \
  '    SHMUTANT_CLEANUP_FAILED SHMUTANT_CLONE_ID SHMUTANT_DIR_ID SHMUTANT_DIR_IDS SHMUTANT_EMIT_FAILED \' \
  '    SHMUTANT_CLEANUP_FAILED SHMUTANT_CLONE_ID SHMUTANT_DIR_ID SHMUTANT_EMIT_FAILED \' \
  't_readonly_settings_do_not_kill_the_caller'
shmutant_mut 'a row is declared into a readonly table' \
  '  _shmutant_decl_writable mut || return 2' \
  '  :' \
  't_readonly_settings_do_not_kill_the_caller'
# (no rows on the /proc record reader: its witness runs on Linux only, and a row that survives
# wherever /proc is absent would read as a defect endured)
shmutant_mut 'a readonly name is assigned when the file is sourced' \
  '  if _shmutant_boot_readonly "$_shmutant_v"; then' \
  '  if false; then' \
  't_library_refuses_a_readonly_name_it_assigns_when_sourced'
# (row 'the source-time readonly probe fails a caller under errexit' dropped: the probe's substitution is now a function argument, which a caller's errexit does not act on; nothing is left to observe)

# --- guards added for the forty-sixth review round ---
shmutant_mut 'the CLI freezes a group whose holder does not verify' \
  '  _shmutant_holder_state "$holder" "$holderid" || [ "$?" = 2 ] || return 0' \
  '  kill -0 "$holder" 2>/dev/null || return 0' \
  't_cli_end_group_checks_the_holder_identity'
shmutant_mut 'the line terminator prepare printed is part of the root' \
  '  root="${root%$'"'"'\n'"'"'}"' \
  '  :' \
  't_pool_reads_the_table_prepare_declared'
shmutant_mut 'the bytes the stream already held are not checked' \
  '    [ "$(command -p dd if="$SHMUTANT_STREAM" bs="$SHMUTANT_STREAM_BASE" count=1 2>/dev/null | command -p cksum)" = "${SHMUTANT_STREAM_PREFIX_CK:-}" ] || return 1' \
  '    :' \
  't_stream_prefix_overwritten_in_place_is_noticed'

# --- guards added for the forty-seventh review round ---
shmutant_mut 'a hard link elsewhere in the prepared tree is cloned apart' \
  '  case "$linked" in ?*)' \
  '  case "$linked" in "")' \
  't_pool_refuses_a_prepared_tree_with_a_hard_link'
shmutant_mut 'the witness is looked for in the prefix too' \
  '    index($0, p) == 1 { red = 1; if (w != "" && witnessed(substr($0, length(p) + 1), w)) { wit = 1; exit } }' \
  '    index($0, p) == 1 { red = 1; if (w != "" && witnessed($0, w)) { wit = 1; exit } }' \
  't_witness_matches_a_whole_token'
shmutant_mut 'a run callback inherits the selection count' \
  '      SHMUTANT_SELECTED_N=0; export SHMUTANT_SELECT="$sel"; "$run" "$root" "$sel"; rrc=$?' \
  '      export SHMUTANT_SELECT="$sel"; "$run" "$root" "$sel"; rrc=$?' \
  't_run_callback_sees_a_fresh_selection_counter'
shmutant_mut 'a negative span renders as a malformed number' \
  '  [ "$us" -ge 0 ] 2>/dev/null || us=0' \
  '  :' \
  't_stream_format'

# --- guards added for the forty-eighth review round ---
shmutant_mut 'a baseline red status without a red line is scored red' \
  '    elif [ "$status" -eq "$red" ] && [ "$SHMUTANT_RUN_RED" = 1 ]; then verdict=red' \
  '    elif [ "$status" -eq "$red" ]; then verdict=red' \
  't_baseline_red_status_without_a_red_line_is_aborted'
# (row 'a plan that leaves while loading reports no keep' dropped: subsumed by the DEBUG guard, which puts the report back before the plan's first command and has a row of its own)
shmutant_mut 'hard links under .git in the prepared tree are exempt' \
  '  linked="$(builtin cd -- "$wd/pristine" 2>/dev/null && command -p find . -type f -links +1 -print 2>/dev/null)" || linked="?"' \
  '  linked="$(builtin cd -- "$wd/pristine" 2>/dev/null && command -p find . -path ./.git -prune -o -type f -links +1 -print 2>/dev/null)" || linked="?"' \
  't_pool_refuses_a_hard_link_under_git_in_the_prepared_tree'
shmutant_mut 'a carriage return is a witness character' \
  '    BEGIN { SEP = " \t\r\f\v!\"#$%&" sprintf("%c", 39) "()*+,/:;<=>?@[\\]^`{|}~" }' \
  '    BEGIN { SEP = " \t!\"#$%&" sprintf("%c", 39) "()*+,/:;<=>?@[\\]^`{|}~" }' \
  't_witness_matches_a_whole_token'

# --- guards added for the forty-ninth review round ---
shmutant_mut 'a plan EXIT trap replaces the keep report' \
  '  trap '"'"'_shmutant_cli_keep_exit_trap'"'"' DEBUG' \
  '  :' \
  't_cli_keeps_the_workdir_a_plan_asked_to_keep_before_leaving'
shmutant_mut 'a physical name ending in a newline is answered as its sibling' \
  '    case "$PWD" in *$'"'"'\n'"'"'*) exit 1 ;; esac' \
  '    :' \
  't_abs_refuses_a_physical_name_ending_in_a_newline'
shmutant_mut 'a helper that left the plan group outlives the CLI' \
  '  _shmutant_kill_tree_twice "$1" "${sampled[@]}"' \
  '  :' \
  't_cli_ends_a_helper_that_left_the_plan_group'
shmutant_mut 'the watchdog scratch names are not in the readonly preflight' \
  '    a budget dog e elapsed last leftovers linked lstart old rrc s tampered tmpd tnow victims wroot \' \
  '    a budget dog e elapsed leftovers linked lstart old rrc s tampered tmpd tnow victims wroot \' \
  't_readonly_preflight_covers_every_name_the_pool_assigns'
shmutant_mut 'a callback directory ending in a newline is pinned to its sibling' \
  '  d="$(_shmutant_abs "$(command -p dirname -- "$f")")" || return 1' \
  '  d="$(builtin cd -P -- "$(command -p dirname -- "$f")" 2>/dev/null && command -p pwd -P)" || return 1' \
  't_abs_refuses_a_physical_name_ending_in_a_newline'

# --- guards added for the fiftieth review round ---
shmutant_mut 'a relative TMPDIR is read after the plan changed directory' \
  '  case "${TMPDIR:-}" in '"'"''"'"'|/*) ;; *) TMPDIR="$(_shmutant_abs "$TMPDIR")" || { _shmutant_err "run: TMPDIR does not name a directory ($TMPDIR)"; return 2; }; export TMPDIR ;; esac' \
  '  :' \
  't_cli_resolves_a_relative_tmpdir_before_the_plan_runs'
shmutant_mut 'a readonly bootstrap name is assigned and its stale value evaluated' \
  'if _shmutant_boot_readonly _shmutant_alias_state || _shmutant_boot_readonly _shmutant_candidate || _shmutant_boot_readonly _shmutant_v; then' \
  'if false; then' \
  't_library_refuses_a_readonly_bootstrap_name'
shmutant_mut 'the alias state is put back through a shadowable eval' \
  '\builtin eval "$_shmutant_alias_state"; \builtin unset -v _shmutant_alias_state' \
  'eval "$_shmutant_alias_state"; unset -v _shmutant_alias_state' \
  't_library_restores_alias_state_through_the_builtins'
# (no row on the lstart identity: its witness runs only where /proc is absent, and a row that
# survives on Linux would read as a defect endured)
shmutant_mut 'a timed-out run leaves no record of what was still running' \
  '        { printf '"'"'shmutant: %s: still running at the deadline (pid ppid stat args):\n'"'"' "$dir"' \
  '        { :' \
  't_verdict_timeout'

# --- guards added for the fifty-first review round ---
shmutant_mut 'a plan that execs while loading reports no keep' \
  '  case "$BASH_COMMAND" in exec|exec\ [!'"'"'{<>&'"'"'0-9]*) _shmutant_cli_leave before-exec ;; esac' \
  '  :' \
  't_cli_keeps_the_workdir_a_plan_asked_to_keep_before_leaving'
shmutant_mut 'a recorded start matches the next tick too' \
  '    *)  [ "$1" = "$2" ] ;;' \
  '    *)  case "$1$2" in *[!0-9]*) [ "$1" = "$2" ] ;; *) d=$(( $1 - $2 )); [ "$d" -ge -1 ] && [ "$d" -le 1 ] ;; esac ;;' \
  't_same_start_compares_recorded_starts_exactly'
shmutant_mut 'the CLI child with no identity is passed as unverified' \
  '    if [ -n "${SHMUTANT_CLI_CHILD_ID:-}" ]; then _shmutant_kill_tree_twice "$SHMUTANT_CLI_CHILD:$SHMUTANT_CLI_CHILD_ID"; else _shmutant_kill_tree_twice "$SHMUTANT_CLI_CHILD"; fi' \
  '    _shmutant_kill_tree_twice "$SHMUTANT_CLI_CHILD:${SHMUTANT_CLI_CHILD_ID:-}"' \
  't_cli_abort_waits_for_the_child_and_names_its_identity'
shmutant_mut 'the stat-less fingerprint collapses spaces in names' \
  '      | command -p awk '"'"'/^[0-9]/ || /^\.$/ || /^\.\// { print; next } { m = $1; sub(/[@+.]$/, "", m); o = $3; g = $4; sz = ($1 ~ /^d/) ? "-" : $5; sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, ""); print m, "-", o, g, sz, $0 }'"'"' \' \
  '      | command -p awk '"'"'/^[0-9]/ || /^\.$/ || /^\.\// { print; next } { sub(/[@+.]$/, "", $1); $2 = "-"; if ($1 ~ /^d/) $5 = "-"; print }'"'"' \' \
  't_stat_less_fingerprint_keeps_names_byte_for_byte'
# (no row on the plan subshell's leave snapshot: whether its absence shows depends on whether the
# half-second sampler happened to see the helper, so a row would be a coin flip; the unit
# t_cli_ends_a_helper_that_left_the_plan_group went red without it, 2 runs of 3, on an idle host)

# --- the run holder ends with its run (#2) ---
shmutant_mut 'the run holder reads its own read-write descriptor' \
  '( read -r _ <&"$hold_r" ) < /dev/null > /dev/null 2>&1 {hold}>&- &' \
  '( read -r _ <&"$hold" ) < /dev/null > /dev/null 2>&1 &' \
  't_run_holder_ends_with_a_killed_runner'
shmutant_mut 'the run holder keeps the writing end it inherits' \
  '( read -r _ <&"$hold_r" ) < /dev/null > /dev/null 2>&1 {hold}>&- &' \
  '( read -r _ <&"$hold_r" ) < /dev/null > /dev/null 2>&1 &' \
  't_run_holder_ends_with_a_killed_runner'
# (no row on the CLI sampler ending its sleep when stopped: without the trap the sleep outlives the
# run by at most half a second, and the per-unit sweep sees it only when the unit ends first, so a
# row would be a coin flip; t_cli_keeps_the_workdir_a_plan_asked_to_keep_before_leaving went red
# without it 2 runs of 5)
shmutant_mut 'an interrupted freeze leaves the run holder stopped' \
  '    [ -z "${holder:-}" ] || kill -CONT "$holder" 2>/dev/null' \
  '      :' \
  't_interrupted_freeze_does_not_leave_the_holder_stopped'
shmutant_mut 'the CLI sampler keeps the pid of a sleep it already reaped' \
  'wait "$s"; s=""; done )' \
  'wait "$s"; done )' \
  't_cli_sampler_never_signals_a_reaped_sleep'
# (no row on the run watchdog clearing its sleep pid after the wait: that loop lives inside
# _shmutant_run_bounded, and no unit can land a TERM between two of its polls deterministically)
shmutant_mut 'the group is signalled after its holder has gone' \
  '  kill -0 "$1" 2>/dev/null || return 1' \
  '  :' \
  't_cli_end_group_checks_the_holder_identity'
shmutant_mut 'an unreadable listing in a freeze passes for a settled one' \
  '        _shmutant_can_list && SHMUTANT_FREEZE_UNSETTLED=1' \
  '        :' \
  't_freeze_treats_an_unreadable_table_as_unsettled'
shmutant_mut 'a host with no process listing counts every freeze as unsettled' \
  '        _shmutant_can_list && SHMUTANT_FREEZE_UNSETTLED=1' \
  '        SHMUTANT_FREEZE_UNSETTLED=1' \
  't_freeze_without_any_listing_is_not_unsettled'
shmutant_mut 'the group kill takes any live pid at the holder number for the holder' \
  '  if ! _shmutant_same_start "$now" "$2"; then return 1; fi' \
  '  :' \
  't_cli_end_group_checks_the_holder_identity'
shmutant_mut 'an unreadable /proc table lists no descendants and succeeds' \
  '    table="$(_shmutant_proc_table)"; [ -n "$table" ] || return 1' \
  '    table="$(_shmutant_proc_table)"' \
  't_descendants_started_reports_an_unreadable_table'
shmutant_mut 'a failed lstart table read lists no descendants and succeeds' \
  '    table="$(command -p ps -A -o pid= -o ppid= -o lstart= 2>/dev/null)" && [ -n "$table" ] || return 1' \
  '    table="$(command -p ps -A -o pid= -o ppid= -o lstart= 2>/dev/null)" || return 0' \
  't_descendants_started_reports_an_unreadable_table'
shmutant_mut 'a failed etime table read lists no descendants and succeeds' \
  '  table="$(command -p ps -A -o pid= -o ppid= -o etime= 2>/dev/null)" && [ -n "$table" ] || return 1' \
  '  table="$(command -p ps -A -o pid= -o ppid= -o etime= 2>/dev/null)" || return 0' \
  't_descendants_started_reports_an_unreadable_table'

# --- an old literal occurs once in its target (#15) ---
shmutant_mut 'a literal that occurs twice is accepted' \
  'if [ "$starts" -gt 1 ]; then' \
  'if [ "$starts" -gt 2 ]; then' \
  't_pool_refuses_a_literal_that_occurs_more_than_once'
shmutant_mut 'overlapping starts are not counted' \
  's = substr(s, i + 1)' \
  's = substr(s, i + length(old))' \
  't_pool_refuses_a_literal_that_occurs_more_than_once'
shmutant_mut 'rows refused for a repeated literal still run' \
  'if [ "$ambiguous" -ne 0 ]; then' \
  'if false; then' \
  't_pool_refuses_a_literal_that_occurs_more_than_once'
shmutant_mut 'only the first row with a repeated literal is named' \
  '      ambiguous=$((ambiguous + 1))' \
  '      ambiguous=$((ambiguous + 1)); break' \
  't_pool_refuses_a_literal_that_occurs_more_than_once'

# --- a plan refuses its own declarations (#16) ---
shmutant_mut 'a plan refusal is not counted' \
  '  _shmutant_refuse "refused: $1"' \
  '  _shmutant_err "refused: $1"' \
  't_refuse_fails_the_pool'
shmutant_mut 'a refusal without one reason is not counted' \
  'then _shmutant_refuse "refuse: usage:' \
  'then _shmutant_err "refuse: usage:' \
  't_refuse_fails_the_pool'
shmutant_mut 'a readonly refusal count is assigned anyway' \
  '  _shmutant_decl_writable refuse || return 2' \
  '  true || return 2' \
  't_refuse_fails_the_pool'

# --- a selection is counted against the whole suite (#17) ---
shmutant_mut 'SHMUTANT_COUNTS accepts any value' \
  'case "${SHMUTANT_COUNTS-0}" in 0|1) ;;' \
  'case "${SHMUTANT_COUNTS-0}" in *) ;;' \
  't_counts_need_the_baseline'
shmutant_mut 'the counts run without the baseline' \
  'if [ "${SHMUTANT_COUNTS:-0}" = 1 ] && [ "${SHMUTANT_BASELINE:-1}" = 0 ]; then' \
  'if false; then' \
  't_counts_need_the_baseline'
shmutant_mut 'no unselected run is made' \
  '[ "${SHMUTANT_COUNTS:-0}" != 1 ] || base_sel=("")' \
  '[ "${SHMUTANT_COUNTS:-0}" != 1 ] || base_sel=()' \
  't_counts_pass_a_complete_selection'
shmutant_mut 'the run gets no count descriptor' \
  'export SHMUTANT_COUNTS_FD="$counts_w"' \
  'export SHMUTANT_COUNTS_FD=""' \
  't_counts_pass_a_complete_selection'
shmutant_mut 'an inherited count descriptor reaches the run' \
  'else unset SHMUTANT_COUNTS_FD; fi' \
  'else :; fi' \
  't_counts_pass_a_complete_selection'
shmutant_mut 'the count lines are never read' \
  '[ "${SHMUTANT_COUNTS:-0}" != 1 ] || _shmutant_read_counts "$counts_r"' \
  '[ "${SHMUTANT_COUNTS:-0}" != 1 ] || :' \
  't_counts_pass_a_complete_selection'
shmutant_mut 'a count line with a third field passes' \
  'NF != 2 ||' \
  'NF < 2 ||' \
  't_counts_refuse_a_malformed_line'
shmutant_mut 'a count line with no unit passes' \
  '|| $1 == "" ||' \
  '||' \
  't_counts_refuse_a_malformed_line'
shmutant_mut 'a count past nine digits passes' \
  'length($2) > 9 {' \
  'length($2) > 10 {' \
  't_counts_refuse_a_malformed_line'
shmutant_mut 'a unit reported twice keeps its last count' \
  'c[$1] += $2' \
  'c[$1] = $2' \
  't_counts_pass_a_complete_selection'
shmutant_mut 'why the count lines are unusable is not passed on' \
  '{ printf '"'"'counts-bad %s\n'"'"' "$SHMUTANT_RUN_COUNTS_BAD"' \
  '{ : '"'"'counts-bad %s\n'"'"' "$SHMUTANT_RUN_COUNTS_BAD"' \
  't_counts_refuse_a_malformed_line'
shmutant_mut 'the collector drops the count lines' \
  '"count "*)   counts+="${line#count }"$'"'"'\n'"'"'; counts_got=$((counts_got + 1)) ;;' \
  '"count "*)   : ;;' \
  't_counts_pass_a_complete_selection'
shmutant_mut 'a run that reports no unit passes' \
  'if [ -z "${SHMUTANT_RES_COUNTS[base-$k]:-}" ]; then' \
  'if false; then' \
  't_counts_need_a_unit_and_a_reference'
shmutant_mut 'the unselected run is compared with itself' \
  '[ "$k" -ne 0 ] || return 0' \
  '[ "$k" -ne 99 ] || return 0' \
  't_counts_pass_a_complete_selection'
shmutant_mut 'an unusable reference is compared anyway' \
  'if [ "$2" != green ]; then builtin printf' \
  'if false; then builtin printf' \
  't_counts_need_a_unit_and_a_reference'
shmutant_mut 'a count mismatch passes' \
  '!($1 in ref) || ref[$1] != $2 {' \
  '!($1 in ref) {' \
  't_counts_score_an_incomplete_selection_baseline'
shmutant_mut 'a unit the reference lacks passes' \
  '!($1 in ref) || ref[$1] != $2 {' \
  '($1 in ref) && ref[$1] != $2 {' \
  't_counts_score_an_incomplete_selection_baseline'
shmutant_mut 'an incomplete selection reads green' \
  '          SHMUTANT_V_VERDICT=incomplete' \
  '          SHMUTANT_V_VERDICT=green' \
  't_counts_score_an_incomplete_selection_baseline'
shmutant_mut 'the row of an incomplete selection is not told why' \
  '|| row_why[i]="the baseline of [' \
  '|| true "the baseline of [' \
  't_counts_score_an_incomplete_selection_baseline'
shmutant_mut 'the row keeps the generic baseline detail' \
  'if [ -n "${row_why[$i]:-}" ]; then detail="${row_why[$i]}"' \
  'if false; then detail="${row_why[$i]}"' \
  't_counts_score_an_incomplete_selection_baseline'
shmutant_mut 'an empty SHMUTANT_COUNTS reads as off' \
  'case "${SHMUTANT_COUNTS-0}" in 0|1) ;;' \
  'case "${SHMUTANT_COUNTS:-0}" in 0|1) ;;' \
  't_counts_need_the_baseline'
shmutant_mut 'a NUL byte in the count lines is let through' \
  '*) SHMUTANT_RUN_COUNTS_BAD="its count lines hold a NUL byte' \
  '*) : "its count lines hold a NUL byte' \
  't_counts_reading_fails_closed'
shmutant_mut 'a unit'"'"'s total past nine digits is accepted' \
  'c[$1] > 999999999 {' \
  'c[$1] > 9999999999 {' \
  't_counts_refuse_a_malformed_line'
shmutant_mut 'counts that did not all reach the pool are compared anyway' \
  '[ -z "$counts_bad" ] && [ "$counts_end" != "$counts_got" ]; then' \
  '[ -z "$counts_bad" ] && false; then' \
  't_counts_need_their_end_marker'
shmutant_mut 'a NUL count that failed partway reads as none' \
  'nul="$(set -o pipefail; command -p tr' \
  'nul="$(command -p tr' \
  't_counts_reading_fails_closed'
shmutant_mut 'counting runs on past the second start' \
  '{ if (++n > 1) exit; s = substr(s, i + 1) }' \
  '{ ++n; s = substr(s, i + 1) }' \
  't_pool_refuses_a_literal_that_occurs_more_than_once'
shmutant_mut 'the count comparison drops its first difference' \
  '!($1 in ref) || ref[$1] != $2 { if (!d) { fu = $1;' \
  '!($1 in ref) || ref[$1] != $2 { if (d) { fu = $1;' \
  't_counts_diff_names_the_first_difference'
shmutant_mut 'the count channel is opened with the counts off' \
  '[ "${SHMUTANT_COUNTS:-0}" != 1 ] || counts="$(command -p mktemp' \
  'counts="$(command -p mktemp' \
  't_counts_off_cost_a_run_no_descriptor'

# --- a scan whose awk failed is not a result (#26) ---
shmutant_mut 'an awk that failed after printing its pair is a clean scan' \
  '<&"$1" 2>/dev/null || printf '"'"'failed'"'"')"' \
  '<&"$1" 2>/dev/null)"' \
  't_scan_fails_when_awk_fails'

# --- the workdir marker is the whole file shmutant writes (#27) ---
shmutant_mut 'only the first line of the marker is read' \
  "    IFS= read -r -d '' -n 64 line < \"\$wd/.shmutant\" 2>/dev/null || :" \
  "    IFS= read -r -n 64 line < \"\$wd/.shmutant\" 2>/dev/null; line+=\$'\\n'" \
  't_pool_marker_is_the_whole_file_it_writes'
shmutant_mut 'the marker'"'"'s size is not checked' \
  '&& [ "$size" -eq 17 ] 2>/dev/null && return 0' \
  '&& return 0' \
  't_pool_marker_is_the_whole_file_it_writes'
shmutant_mut 'a marker size that cannot be read passes' \
  '    size="$(command -p wc -c < "$wd/.shmutant" 2>/dev/null)" || size=""' \
  '    size="$(command -p wc -c < "$wd/.shmutant" 2>/dev/null)" || size=17' \
  't_pool_marker_is_the_whole_file_it_writes'

# --- a digest tool's status and output are both checked (#30) ---
shmutant_mut 'a digest tool that exits non-zero is believed' \
  '  [ "$st" = 0 ] || { _shmutant_err "cannot compute the digest of $1 (status ${st:-unknown})"; return 2; }' \
  '  :' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'the digest tool'"'"'s status is not passed on' \
  'else printf '"'"'\0%s'"'"' "$?"; fi)' \
  'else printf '"'"'\0%s'"'"' 0; fi)' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'a caller'"'"'s errexit ends the digest tool'"'"'s writer before it reports' \
  '<(if "${cmd[@]}" 2>/dev/null < "$1"; then printf '"'"'\0%s'"'"' 0; else printf '"'"'\0%s'"'"' "$?"; fi)' \
  '<("${cmd[@]}" 2>/dev/null < "$1"; printf '"'"'\0%s'"'"' "$?")' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'a NUL byte in the digest output is dropped' \
  'if [ "${#got[@]}" -ne 2 ] || [' \
  'if [ "${#got[@]}" -lt 2 ] || [' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'the digest line'"'"'s newline is not required' \
  '|| [ "${out%$'"'"'\n'"'"'}" = "$out" ]; then' \
  '|| false; then' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'everything after the first newline of the digest output is dropped' \
  'out="${out%$'"'"'\n'"'"'}"; shopt' \
  'out="${out%%$'"'"'\n'"'"'*}"; shopt' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'a rejected digest layout ends an errexit caller' \
  'printf '"'"'%s'"'"' "${BASH_REMATCH[-1]}" )" || out=""' \
  'printf '"'"'%s'"'"' "${BASH_REMATCH[-1]}" )"' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'a digest of any length is accepted' \
  '{64})  -$'"'"'' \
  '{1,})  -$'"'"'' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'a record followed by more is accepted' \
  '{64})  -$'"'"'' \
  '{64})  -'"'"'' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'a record after other text is accepted' \
  'sum_re='"'"'^(' \
  'sum_re='"'"'(' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'an openssl digest of any length is accepted' \
  '{64})$'"'"'' \
  '{1,})$'"'"'' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'an openssl record followed by more is accepted' \
  '{64})$'"'"'' \
  '{64})'"'"'' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'an openssl record after other text is accepted' \
  'ssl_re='"'"'^(' \
  'ssl_re='"'"'(' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'any algorithm name passes for openssl'"'"'s' \
  '(SHA2-256|SHA256)?\(stdin\)' \
  '(.*)?\(stdin\)' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'the caller'"'"'s nocasematch lets an uppercase digest through' \
  'shopt -u nocasematch; [[ "$out" =~ $re ]]' \
  '[[ "$out" =~ $re ]]' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'a rejected digest prints an empty line' \
  '  [ -n "$out" ] || { _shmutant_err "$tool printed no SHA-256 for $1"; return 2; }' \
  '  [ -n "$out" ] || { echo; _shmutant_err "$tool printed no SHA-256 for $1"; return 2; }' \
  't_checksum_takes_the_tool_status_and_one_digest'
shmutant_mut 'a failed digest tool prints an empty line' \
  '  [ "$st" = 0 ] || { _shmutant_err "cannot compute the digest of $1 (status ${st:-unknown})"; return 2; }' \
  '  [ "$st" = 0 ] || { echo; _shmutant_err "cannot compute the digest of $1 (status ${st:-unknown})"; return 2; }' \
  't_checksum_takes_the_tool_status_and_one_digest'

# --- the CLI checks its settings before the plan loads (#36) ---
shmutant_mut 'the CLI loads the plan before checking its settings' \
  '  if ! _shmutant_validate_settings run "$wd"; then' \
  '  if false; then' \
  't_cli_labels_its_stream_and_refuses_bad_arguments'

# --- a failed stage of the target read is never a fingerprint (#29) ---
shmutant_mut 'the target read does not fail on a failed pipeline stage' \
  '  ( set -o pipefail' \
  '  ( :' \
  't_target_ck_fails_when_any_stage_fails'
shmutant_mut 'a failed ls or awk does not fail the target read' \
  '        && { [ -z "$stat_bin" ] || "$stat_bin" "$fmt" "$2"; } \' \
  '        ; { [ -z "$stat_bin" ] || "$stat_bin" "$fmt" "$2"; } \' \
  't_target_ck_fails_when_any_stage_fails'
shmutant_mut 'a failed stat does not fail the target read' \
  '        && command -p cksum < "$2"; } 2>/dev/null )' \
  '        ; command -p cksum < "$2"; } 2>/dev/null )' \
  't_target_ck_fails_when_any_stage_fails'
shmutant_mut 'a watchdog sample whose read failed counts as a match' \
  '"$SHMUTANT_TARGET_KEY")" && [ "$seen_ck" =' \
  '"$SHMUTANT_TARGET_KEY")"; [ "$seen_ck" =' \
  't_target_sample_that_could_not_be_read_is_not_a_match'
shmutant_mut 'a read after the run that failed counts as a match' \
  '"$kind-$i")" || after_ck=""' \
  '"$kind-$i")" || :' \
  't_target_sample_that_could_not_be_read_is_not_a_match'

# --- a freezing shell killed before its KILL leaves nothing stopped (#47) ---
shmutant_mut 'a freeze pass does not tell the guard what it stops' \
  '      _shmutant_guard_tell "${recs[@]}" || return 0' \
  '      :' \
  't_freeze_killed_before_its_kill_leaves_nothing_stopped'
shmutant_mut 'a freeze pass stops what it could not tell a guard that went' \
  '_shmutant_guard_tell "${recs[@]}" || return 0' \
  '_shmutant_guard_tell "${recs[@]}" || :' \
  't_freeze_whose_guard_went_stops_nothing_more'
shmutant_mut 'the guard is not told of the root' \
  '    _shmutant_guard_tell "p $pid $rid" && \' \
  '    : && \' \
  't_freeze_killed_before_its_kill_leaves_nothing_stopped'
shmutant_mut 'the guard is not told of the held group' \
  '    _shmutant_guard_tell "g $held ${holder:--} ${holderid:-}" && \' \
  '    : && \' \
  't_freeze_of_a_run_group_killed_partway_ends_the_group'
shmutant_mut 'the guard is not told of the victims' \
  '&& _shmutant_guard_tell "${stillours[@]/#/p }"; then' \
  '&& :; then' \
  't_freeze_killed_before_its_kill_leaves_nothing_stopped'
shmutant_mut 'a freeze runs with no guard' \
  '  if [ "$guard_up" != 0 ]; then' \
  '  if false; then' \
  't_freeze_without_a_guard_stops_nothing'
shmutant_mut 'the held group is taken as checked before the guard started' \
  '    _shmutant_holder_state "$holder" "${holderid:-}" || [ "$?" = 2 ] || held=""' \
  '    :' \
  't_freeze_checks_its_root_and_holder_after_its_guard_starts'
shmutant_mut 'a tree killed with no guard is not reported unsettled' \
  '    [ -z "${SHMUTANT_UNSETTLED_FD:-}" ] || printf '"'"'unsettled\n'"'"' >&"$SHMUTANT_UNSETTLED_FD"' \
  '    :' \
  't_freeze_without_a_guard_stops_nothing'
shmutant_mut 'a tree with no guard is not killed' \
  '    if [ "$root_ok" = 1 ]; then _shmutant_kill_tree KILL "$pid" "$pid:${rootid:-}" "$@"' \
  '    if false; then :' \
  't_freeze_without_a_guard_stops_nothing'
shmutant_mut 'a guard that went partway leaves the freeze settled' \
  '  [ "$guard_lost" = 0 ] || SHMUTANT_FREEZE_UNSETTLED=1' \
  '  :' \
  't_freeze_whose_guard_went_stops_nothing_more'
shmutant_mut 'a guard that went partway leaves the victims it was never told of running' \
  '  [ "$guard_lost" = 0 ] || unfrozen=("$@")' \
  '  :' \
  't_freeze_whose_guard_went_stops_nothing_more'
shmutant_mut 'a write to a guard that went ends the freezing shell' \
  '  trap '"'"''"'"' PIPE' \
  '  :' \
  't_freeze_whose_guard_went_stops_nothing_more'
shmutant_mut 'the guard does nothing when its freezing shell is killed' \
  '  [ "${#recs[@]}" -gt 0 ] || [ -n "$pg" ] || return 0' \
  '  return 0' \
  't_freeze_killed_before_its_kill_leaves_nothing_stopped'
shmutant_mut 'the guard continues the processes it verified' \
  'killing["$pid"]=1; kills+=("$pid"); }' \
  'killing["$pid"]=1; conts+=("$pid"); }' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard kills a pid whose start no longer matches' \
  '&& _shmutant_same_start "${SHMUTANT_START[$pid]}" "$st"; then' \
  '; then' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard kills the group without checking its holder' \
  '    if [ "$hs" = 0 ]; then' \
  '    if :; then' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard kills a group whose holder cannot be checked' \
  '    if [ "$hs" = 0 ]; then' \
  '    if [ "$hs" != 1 ]; then' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard leaves a group whose holder cannot be checked stopped' \
  '    elif [ "$hs" = 2 ] ||' \
  '    elif false ||' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard takes a holder it cannot check for the holder, though its stop did not reach it' \
  '{ _shmutant_proc_stopped "$ph" && _shmutant_group_has "$pg" "$ph"; } || hs=1' \
  '{ _shmutant_group_has "$pg" "$ph"; } || hs=1' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard takes a stopped process in another group for a holder it cannot check' \
  '{ _shmutant_proc_stopped "$ph" && _shmutant_group_has "$pg" "$ph"; } || hs=1' \
  '{ _shmutant_proc_stopped "$ph"; } || hs=1' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard does not kill the group' \
  'kills=("${left[@]}" -"$pg")' \
  'kills=("${left[@]}")' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard leaves a group shown to be the run'"'"'s stopped' \
  '  [ -z "$gcont" ] || kill -CONT -- -"$gcont" 2>/dev/null' \
  '  :' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard continues the group before killing what it verified' \
  '  [ "${#kills[@]}" -eq 0 ] || kill -KILL -- "${kills[@]}" 2>/dev/null' \
  '  [ -z "$gcont" ] || kill -CONT -- -"$gcont" 2>/dev/null; [ "${#kills[@]}" -eq 0 ] || kill -KILL -- "${kills[@]}" 2>/dev/null' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard continues a group with no verified pid in it' \
  '|| _shmutant_group_has "$pg" "${kills[@]}"; then gcont=' \
  '|| :; then gcont=' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the group membership test joins pids with the caller'"'"'s IFS' \
  '  for p in "$@"; do want="$want$p "; done' \
  '  want=" $* "' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'a group is taken for the run'"'"'s whatever pid is in it' \
  '$2 == g && index(want, " " $1 " ") { f = 1 }' \
  'index(want, " " $1 " ") { f = 1 }' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard leaves a pid it cannot show is the run'"'"'s stopped' \
  '    else conts+=("$pid")' \
  '    else :' \
  't_guard_lets_go_a_pid_it_cannot_show_is_the_runs'
shmutant_mut 'the guard waits only for its records to end' \
  '      _shmutant_guard_freezer_there || break' \
  '      :' \
  't_guard_acts_while_a_helper_of_its_freezer_holds_the_records'
shmutant_mut 'the guard is not told whose shell it guards' \
  '  local guard_of="$BASHPID" guard_of_id' \
  '  local guard_of="" guard_of_id' \
  't_guard_acts_while_a_helper_of_its_freezer_holds_the_records'
shmutant_mut 'the guard takes a zombie for its freezer' \
  '  ! _shmutant_guard_reaped "$guard_of" || return 1' \
  '  :' \
  't_guard_takes_neither_a_reused_pid_nor_a_zombie_for_its_freezer'
shmutant_mut 'the guard takes a reused pid for its freezer' \
  '  _shmutant_holder_state "$guard_of" "${guard_of_id:-}" || [ "$?" = 2 ]' \
  '  kill -0 "$guard_of" 2>/dev/null' \
  't_guard_takes_neither_a_reused_pid_nor_a_zombie_for_its_freezer'
shmutant_mut 'the guard is not told the members of the stopped group' \
  '    elif _shmutant_guard_members "$held"; then' \
  '    elif :; then' \
  't_guard_ends_a_group_member_whose_holder_went_first'
shmutant_mut 'the holder is let go when the members could not be told' \
  '    [ -n "${SHMUTANT_START[$p]:-}" ] || return 1' \
  '    [ -n "${SHMUTANT_START[$p]:-}" ] || continue' \
  't_freeze_keeps_the_holder_stopped_when_its_members_cannot_be_told'
shmutant_mut 'the members of a stopped group are not searched from' \
  'do roots+=("$p"); have["$p"]=1; frozen+=("$p:"); done' \
  'do have["$p"]=1; frozen+=("$p:"); done' \
  't_freeze_takes_group_members_as_roots_but_not_the_holder'
shmutant_mut 'the holder is taken as frozen with the members' \
  '    [ "${p%% *}" != "${holder:-}" ] || continue' \
  '    :' \
  't_freeze_takes_group_members_as_roots_but_not_the_holder'
shmutant_mut 'a member whose stop did not take is taken as frozen' \
  '  _shmutant_frozen_only "${pairs[@]}"' \
  '  SHMUTANT_FROZEN_NOW=(); for p in "${pairs[@]}"; do SHMUTANT_FROZEN_NOW+=("${p%% *}"); done' \
  't_freeze_takes_group_members_as_roots_but_not_the_holder'
shmutant_mut 'the guard is given the start of the substitution that read it' \
  '  guard_of_id="$(_shmutant_identity "$guard_of")" || guard_of_id=""' \
  '  guard_of_id="$(_shmutant_identity "$BASHPID")" || guard_of_id=""' \
  't_freeze_tells_its_guard_its_own_start'
shmutant_mut 'a group whose holder went is left stopped' \
  '  [ -z "$gone_group" ] || kill -CONT -- -"$gone_group" 2>/dev/null' \
  '  :' \
  't_group_kill_checks_the_holder_identity'
shmutant_mut 'a group whose holder went is continued before its target is signalled' \
  '  [ "${#targets[@]}" -eq 0 ] || kill "-$sig" -- "${targets[@]}" 2>/dev/null' \
  '  [ -z "$gone_group" ] || kill -CONT -- -"$gone_group" 2>/dev/null; [ "${#targets[@]}" -eq 0 ] || kill "-$sig" -- "${targets[@]}" 2>/dev/null' \
  't_group_kill_checks_the_holder_identity'
shmutant_mut 'a group whose holder went is continued with no target in it' \
  '      for p in "${targets[@]}"; do case "$members" in *" $p "*) gone_group="$SHMUTANT_KILL_GROUP"; break ;; esac; done' \
  '      gone_group="$SHMUTANT_KILL_GROUP"' \
  't_group_kill_checks_the_holder_identity'
shmutant_mut 'the guard leaves what it could not verify stopped' \
  '  [ -n "$cfirst" ] || [ "${#conts[@]}" -eq 0 ] || kill -CONT -- "${conts[@]}" 2>/dev/null' \
  '  :' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'done does not stand the guard down' \
  '      done) return 0 ;;' \
  '      done) ;;' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the freeze returns with its guard still running' \
  '      kill -KILL -- -"$guard_pid" 2>/dev/null' \
  '      :' \
  't_freeze_guard_not_seen_to_end_is_killed'
shmutant_mut 'a guard is killed without what it waits on' \
  '      kill -KILL -- -"$guard_pid" 2>/dev/null' \
  '      kill -KILL -- "$guard_pid" 2>/dev/null' \
  't_freeze_guard_not_seen_to_end_is_killed'
shmutant_mut 'the guard'"'"'s identity is not kept for the end of the freeze' \
  '      guard_id="$(_shmutant_identity "$guard_pid")" || guard_id=""' \
  '      guard_id=""' \
  't_freeze_guard_not_seen_to_end_is_killed'
shmutant_mut 'a wait for the guard that ran out is not reported' \
  'elif [ "$rc" -gt 128 ]; then _shmutant_freeze_err' \
  'elif false; then _shmutant_freeze_err' \
  't_freeze_guard_not_seen_to_end_is_killed'
shmutant_mut 'a guard that cannot be identified is killed by number' \
  '    if _shmutant_alive_since "$guard_pid" "${guard_id:-}"; then' \
  '    if :; then' \
  't_freeze_guard_not_seen_to_end_is_killed'
shmutant_mut 'a guard that could not be confirmed ended is not reported' \
  '      if kill -0 "$guard_pid" 2>/dev/null; then _shmutant_freeze_err' \
  '      if false; then _shmutant_freeze_err' \
  't_freeze_guard_not_seen_to_end_is_killed'
shmutant_mut 'a guard that does not say its pid is trusted' \
  '    if [ "$b" = up ] && [ "$guard_pid" != "$a" ] && [ -n "$guard_pid" ] && [ -n "${guard_pid##*[!0-9]*}" ]; then' \
  '    if [ "$b" = up ]; then' \
  't_freeze_guard_that_does_not_answer_is_not_trusted'
shmutant_mut 'the guard shares the process group of the shell that froze' \
  '( set -m; trap '"'"''"'"' INT TERM HUP; _shmutant_guard' \
  '( trap '"'"''"'"' INT TERM HUP; _shmutant_guard' \
  't_freeze_guard_is_out_of_reach_and_gone_at_the_end'
shmutant_mut 'the guard is ended by INT, TERM or HUP' \
  'trap '"'"''"'"' INT TERM HUP; _shmutant_guard' \
  '_shmutant_guard' \
  't_freeze_guard_is_out_of_reach_and_gone_at_the_end'
# (no row on the handshake's bound: a wait that runs out reads nothing, so whatever accepted the words
# after it still refuses them, and a row would pass)
# (no row on the wait for the guard to go: a guard not waited for is killed by the check after it,
# with the same end, so the row would pass)
# (no row on the guard reparented before `up`: the subshell that started it ends a moment after, and
# a row would be killed only if a check fell inside that moment)
# (no row on the errexit resets in the freeze's subshell and its guard: no command a witness runs
# through them fails while errexit is on, so a row would pass or fail by chance)
# (no row on the guard keeping a read cut short by its one-second look: every record is one short
# write, so no witness can split one across that second, and a row would pass)
shmutant_mut 'the guard reads starts before it stops what it may kill' \
  '  [ "${#stops[@]}" -eq 0 ] || kill -STOP -- "${stops[@]}" 2>/dev/null' \
  '  :' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard does not stop the holder before checking it' \
  '  for p in "${recs[@]}" "$ph"; do' \
  '  for p in "${recs[@]}"; do' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'a holder the guard stopped and did not take for the holder is left stopped' \
  '      conts+=("$ph")' \
  '      :' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'a pid the guard kills is continued after, when another record named it' \
  '      want=1; for pid in "${kills[@]}"; do [ "$pid" != "$p" ] || want=""; done' \
  '      want=1' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'a root stopped is checked against no start when none was read before the guard' \
  '    if [ -n "$rid" ] && [ -n "${have[$pid]:-}" ]' \
  '    if [ -n "${rootid:-}" ] && [ -n "${have[$pid]:-}" ]' \
  't_freeze_checks_its_root_and_holder_after_its_guard_starts'
shmutant_mut 'a holder shown gone once the group is stopped still lets its members be taken' \
  '    if [ -n "${holder:-}" ] && { _shmutant_holder_state "$holder" "${holderid:-}"; [ "$?" = 1 ]; }; then' \
  '    if false; then' \
  't_freeze_checks_its_root_and_holder_after_its_guard_starts'
shmutant_mut 'a member the group KILL of the guard takes is continued after it' \
  '    for p in "${conts[@]}"; do case "$members" in *" $p "*) ;; *) left+=("$p") ;; esac; done' \
  '    left=("${conts[@]}")' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'a ps that failed is read as a stopped state' \
  '" && case "$st" in *T*) return 0 ;; esac' \
  '"; case "$st" in *T*) return 0 ;; esac' \
  't_process_state_reads_take_a_failed_ps_as_no_state'
shmutant_mut 'a ps that failed is read as a zombie' \
  '" && case "$st" in *Z*) return 0 ;; esac' \
  '"; case "$st" in *Z*) return 0 ;; esac' \
  't_process_state_reads_take_a_failed_ps_as_no_state'
shmutant_mut 'a group listing that failed keeps the guard from continuing a pid' \
  '    if members=" $(set -o pipefail; _shmutant_ps -A -o pid= -o pgid=' \
  '    if members=" $(_shmutant_ps -A -o pid= -o pgid=' \
  't_guard_ends_only_what_it_can_verify'
# (no row on the end of a freeze looking, for a moment, for a guard that stood down to be gone or a
# zombie before deciding to kill it: that moment is the guard's own exit, which no unit can time)
# (no row on the second read of a group's members keeping awk's status: `command -p awk` over a table
# already read cannot be made to fail from a unit)
# (no row on confirming a killed guard has ended: a KILL of the guard's own group cannot be made to
# fail from a unit, so the report of one that did is never reached)
shmutant_mut 'a root shown changed once stopped is still taken as frozen' \
  '    if [ -n "$rid" ] && [ -n "${have[$pid]:-}" ] && { _shmutant_holder_state "$pid" "$rid"; [ "$?" = 1 ]; }; then' \
  '    if false; then' \
  't_freeze_checks_its_root_and_holder_after_its_guard_starts'
shmutant_mut 'a holder the freeze kept stopped does not let the guard end its group' \
  '    [ -z "$kept" ] || [ "$hs" != 2 ] || hs=0' \
  '    :' \
  't_freeze_keeps_the_holder_stopped_when_its_members_cannot_be_told'
shmutant_mut 'the guard is not told the holder was kept stopped' \
  '      _shmutant_guard_tell k' \
  '      :' \
  't_freeze_keeps_the_holder_stopped_when_its_members_cannot_be_told'
shmutant_mut 'a process in only one read of the group is taken for a member' \
  '    case "$out" in *" $p "*) ;; *) continue ;; esac' \
  '    :' \
  't_freeze_takes_group_members_as_roots_but_not_the_holder'
shmutant_mut 'a bare root is not checked after the guard starts' \
  '    rootid="$rootid_pre"; _shmutant_alive_since "$pid" "$rootid" || root_ok=0' \
  '    :' \
  't_freeze_checks_its_root_and_holder_after_its_guard_starts'
# (no row on the root being checked after the guard starts rather than before: the fix is the order of
# two blocks, which a row cannot move; t_freeze_checks_its_root_and_holder_after_its_guard_starts goes
# red on the commit before it)
# (no row on the identity probe asking about $BASHPID rather than $$: its witness can fail only where
# /proc is absent, and a row that survives on Linux would read as a defect endured)

# --- guards added for #48, #49, #51 and #53 ---
shmutant_mut 'the guard takes a holder whose elapsed start a clock step moved for another process' \
  '    [ "$hs" != 1 ] || case "$phid" in e*) ! kill -0 "$ph" 2>/dev/null || hs=2 ;; esac' \
  '    :' \
  't_guard_reads_a_moved_elapsed_start_as_a_holder_it_cannot_check'
shmutant_mut 'the guard kills a holder its group record rejects through its member record' \
  '      for p in "${kills[@]}"; do [ "$p" = "$ph" ] || left+=("$p"); done' \
  '      for p in "${kills[@]}"; do left+=("$p"); done' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard takes a freezer whose start moved with the clock for gone' \
  '[ "$?" = 2 ] || _shmutant_guard_clock_moved' \
  '[ "$?" = 2 ]' \
  't_guard_waits_for_a_freezer_whose_elapsed_start_moved'
shmutant_mut 'the guard takes a freezer start that moved alone for one the clock moved' \
  '  [ $(( gap - guard_gap_ref )) -ge -1 ] && [ $(( gap - guard_gap_ref )) -le 1 ]' \
  '  :' \
  't_guard_waits_for_a_freezer_whose_elapsed_start_moved'
shmutant_mut 'the guard takes the start its freezer tells it for nothing' \
  '        '"'"'f '"'"'*) case "${line#f }" in e*'"'"' '"'"'*) guard_gap_ref="${line##* }"; case "${guard_gap_ref#-}" in '"'"''"'"'|*[!0-9]*) guard_gap_ref="" ;; esac ;; esac ;;' \
  '        '"'"'f '"'"'*) : ;;' \
  't_guard_waits_for_a_freezer_whose_elapsed_start_moved'
shmutant_mut 'the gap between two elapsed times is read from a ps that failed' \
  '  out="$(_shmutant_ps -o pid= -o etime= -p "$1,$2" 2>/dev/null)" || return 1' \
  '  out="$(_shmutant_ps -o pid= -o etime= -p "$1,$2" 2>/dev/null)"' \
  't_process_state_reads_take_a_failed_ps_as_no_state'
shmutant_mut 'a table of starts is taken from a ps that failed' \
  '    }'"'"')" || return 0' \
  '    }'"'"')"' \
  't_process_state_reads_take_a_failed_ps_as_no_state'
shmutant_mut 'the freezer does not tell its guard its own start' \
  '    [ -z "$fid_now" ] || _shmutant_guard_tell "f $fid_now${fgap:+ $fgap}"' \
  '    :' \
  't_freeze_tells_its_guard_its_own_start'
shmutant_mut 'the kill counts a stop that did not take' \
  '    for p in "${cands[@]}"; do ! kill -STOP "${p%% *}" 2>/dev/null || stopped["${p%% *}"]=1; done' \
  '    for p in "${cands[@]}"; do kill -STOP "${p%% *}" 2>/dev/null; stopped["${p%% *}"]=1; done' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill leaves what it stopped and could not show stopped' \
  '  [ -n "$cont_first" ] || [ "${#conts[@]}" = 0 ] || kill -CONT -- "${conts[@]}" 2>/dev/null' \
  '  :' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill continues a pid its stop never reached' \
  '    elif [ -n "${stopped[${p%%:*}]:-}" ]; then conts+=("${p%%:*}")' \
  '    elif [ -n "$guarded" ]; then conts+=("${p%%:*}")' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill continues a target another record named' \
  '      want=1; for out in "${targets[@]}"; do [ "$out" != "$p" ] || want=""; done' \
  '      want=1' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill kills a holder it rejects through another record of it' \
  '      for p in "${targets[@]}"; do [ "$p" = "${holder:-}" ] || left+=("$p"); done' \
  '      for p in "${targets[@]}"; do left+=("$p"); done' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'a caller function named sleep keeps the bound' \
  '    t="$(_shmutant_std_bin sleep)" && \' \
  '    t="$(builtin command -p -v sleep)" && \' \
  't_guard_gives_up_on_a_process_table_that_stalls'
shmutant_mut 'a caller function named jobs keeps a stall from being ended' \
  '  done <<< "$(builtin jobs -l)"' \
  '  done <<< "$(jobs -l)"' \
  't_guard_gives_up_on_a_process_table_that_stalls'
shmutant_mut 'the guard reads its process table without a bound' \
  '  local SHMUTANT_PS_BOUND=10' \
  '  local SHMUTANT_PS_BOUND=' \
  't_guard_gives_up_on_a_process_table_that_stalls'
shmutant_mut 'a bounded ps that stalls is left running' \
  '    builtin kill -KILL "%$js" 2>/dev/null' \
  '    :' \
  't_guard_gives_up_on_a_process_table_that_stalls'
shmutant_mut 'a bounded ps that stalls is waited out' \
  '      case "$t" in /*) "$t" "$b" < /dev/null > /dev/null 2>&1 & t=$! ;; *) t="" ;; esac' \
  '      case "$t" in /*) "$t" 3600 < /dev/null > /dev/null 2>&1 & t=$! ;; *) t="" ;; esac' \
  't_guard_gives_up_on_a_process_table_that_stalls'
shmutant_mut 'a bounded ps takes a bound that is not a number' \
  '  case "${SHMUTANT_PS_BOUND:-}" in [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) command -p ps "$@"; return ;; esac' \
  '  case "${SHMUTANT_PS_BOUND:-}" in Q) ;; *) command -p ps "$@"; return ;; esac' \
  't_guard_gives_up_on_a_process_table_that_stalls'
shmutant_mut 'a bounded ps ends a caller with errexit on at the end of its output' \
  '  IFS= read -r -d '"'"''"'"' -t "$(( b + 5 ))" -u "$fd" out || st=$?' \
  '  IFS= read -r -d '"'"''"'"' -t "$(( b + 5 ))" -u "$fd" out; st=$?' \
  't_guard_gives_up_on_a_process_table_that_stalls'
shmutant_mut 'a bounded ps loses the status of the ps' \
  '  st=0; wait "$p" || st=$?' \
  '  st=0; wait "$p" || :' \
  't_guard_gives_up_on_a_process_table_that_stalls'
shmutant_mut 'a bounded ps swallows a failed write of its output' \
  '  printf '"'"'%s'"'"' "$out" || return 1' \
  '  printf '"'"'%s'"'"' "$out"' \
  't_guard_gives_up_on_a_process_table_that_stalls'
# (no row on the bounded ps giving up five seconds after its bound: that only ends a wait on a process
# substitution that has not answered, one stopped from outside or one whose ps the kernel will not let
# die. The substitution is then left as it is, never signalled by number; a unit that stopped it would
# witness only that the wait ends, which the stall cases above already do.)
shmutant_mut 'the kill checks a victim by a read of its own before the walk' \
  '    elif [ -n "${SHMUTANT_START[${p%%:*}]:-}" ] && _shmutant_same_start "${SHMUTANT_START[${p%%:*}]}" "${p#*:}"' \
  '    elif _shmutant_alive_since "${p%%:*}" "${p#*:}"' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill checks the holder by a read of its own after the table' \
  '    [ -z "${holder:-}" ] || _shmutant_table_state "$holder" "${holderid:-}" || hs=$?' \
  '    [ -z "${holder:-}" ] || _shmutant_holder_state "$holder" "${holderid:-}" || hs=$?' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill ends a caller with errexit on at a holder it rejects' \
  '    [ -z "${holder:-}" ] || _shmutant_table_state "$holder" "${holderid:-}" || hs=$?' \
  '    [ -z "${holder:-}" ] || { _shmutant_table_state "$holder" "${holderid:-}"; hs=$?; }' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill signals a find of the walk whatever start the table shows' \
  '    if [ -n "${SHMUTANT_START[${p%% *}]:-}" ] && _shmutant_same_start "${SHMUTANT_START[${p%% *}]}" "${p#* }"' \
  '    if [ -n "$p" ]' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill stops nothing under a guard' \
  '  [ -z "${guard_w:-}" ] || [ "${guard_lost:-0}" != 0 ] || guarded=1' \
  '  :' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill stops what it checks without telling the guard first' \
  '    if [ "${#cands[@]}" -gt 0 ] && ! _shmutant_guard_tell "${cands[@]/#/p }"; then guarded=""; fi' \
  '    :' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill leaves the holder running under a guard' \
  '    [ -z "${SHMUTANT_KILL_GROUP:-}" ] || [ -z "${holder:-}" ] || ! kill -STOP "$holder" 2>/dev/null || stopped["$holder"]=1' \
  '    :' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill leaves a find it stopped and could not show stopped' \
  '    elif [ -n "${stopped[${p%% *}]:-}" ]; then conts+=("${p%% *}")' \
  '    elif false; then :' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill leaves a holder it stopped and rejects stopped' \
  '      [ -z "${holder:-}" ] || [ -z "${stopped[$holder]:-}" ] || conts+=("$holder")' \
  '      :' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill takes a holder gone since its table for the holder' \
  '  if ! kill -0 "$1" 2>/dev/null; then return 1; fi' \
  '  :' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill takes a holder missing from the table it read for one it cannot check' \
  '    [ "${#SHMUTANT_START[@]}" -gt 0 ] || return 2' \
  '    return 2' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill takes a holder with another start for the holder' \
  '  _shmutant_same_start "${SHMUTANT_START[$1]}" "$2" || return 1' \
  '  :' \
  't_group_kill_checks_the_holder_identity'
shmutant_mut 'the CLI holder is killed by number after its group' \
  '  _shmutant_kill_tree_twice -g "$1" "$1:"' \
  '  _shmutant_kill_tree_twice -g "$1" "$1:"; kill -KILL "$holder" 2>/dev/null' \
  't_cli_end_group_checks_the_holder_identity'
shmutant_mut 'the bounded ps ends an answered read through a function named exit' \
  '    if [ -n "$w" ] && [ "$w" = "$c" ]; then _shmutant_ps_end "$t"; wait "$t"; builtin exit "$s"; fi' \
  '    if [ -n "$w" ] && [ "$w" = "$c" ]; then _shmutant_ps_end "$t"; wait "$t"; exit "$s"; fi' \
  't_guard_gives_up_on_a_process_table_that_stalls'
shmutant_mut 'the bounded ps ends a stalled read through a function named exit' \
  '    _shmutant_ps_end "$c"; wait "$c"; builtin exit 124' \
  '    _shmutant_ps_end "$c"; wait "$c"; exit 124' \
  't_guard_gives_up_on_a_process_table_that_stalls'
# (no row on the bounded ps's exit where no timer can be found: a sleep missing from the system's
# default PATH cannot be arranged from a unit, and that exit is the same builtin as the two above.)
shmutant_mut 'a member the group KILL takes is continued by number after it' \
  '      for p in "${conts[@]}"; do case "$members" in *" $p "*) continue ;; esac; [ "$p" = "${holder:-}" ] || left+=("$p"); done' \
  '      for p in "${conts[@]}"; do [ "$p" = "${holder:-}" ] || left+=("$p"); done' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the guard reads its freezer gap of whatever holds the number instead of the one told' \
  '        '"'"'f '"'"'*) case "${line#f }" in e*'"'"' '"'"'*) guard_gap_ref="${line##* }"; case "${guard_gap_ref#-}" in '"'"''"'"'|*[!0-9]*) guard_gap_ref="" ;; esac ;; esac ;;' \
  '        '"'"'f '"'"'*) case "${line#f }" in e*'"'"' '"'"'*) guard_gap_ref="$(_shmutant_elapsed_gap "$guard_of" "$guard_self")" || guard_gap_ref="" ;; esac ;;' \
  't_guard_waits_for_a_freezer_whose_elapsed_start_moved'
shmutant_mut 'the freezing shell tells its elapsed-time start without the gap it read' \
  '    [ -z "$fid_now" ] || _shmutant_guard_tell "f $fid_now${fgap:+ $fgap}"' \
  '    [ -z "$fid_now" ] || _shmutant_guard_tell "f $fid_now"' \
  't_freeze_tells_its_guard_its_own_start'
# (no row on the told gap being checked for a number: the records come from the freezing shell alone,
# which tells a number read by _shmutant_elapsed_gap or none.)
shmutant_mut 'what the kill lets go is let go after a group KILL whose members it could not read' \
  '      if [ -z "$members" ]; then cont_first=1; fi' \
  '      :' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'an empty elapsed-time table read fails its caller' \
  '    [ -z "$line" ] || SHMUTANT_START["${line%% *}"]="${line#* }"' \
  '    [ -n "$line" ] && SHMUTANT_START["${line%% *}"]="${line#* }"' \
  't_process_state_reads_take_a_failed_ps_as_no_state'
shmutant_mut 'the guard lets go after the group KILL what it could not list the members for' \
  '    else cfirst=1; fi' \
  '    else :; fi' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the kill lets go before its group KILL a holder it verified' \
  '      for p in "${conts[@]}"; do case "$members" in *" $p "*) continue ;; esac; [ "$p" = "${holder:-}" ] || left+=("$p"); done' \
  '      for p in "${conts[@]}"; do case "$members" in *" $p "*) continue ;; esac; left+=("$p"); done' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the guard lets go a holder it verified through its member record' \
  '      for p in "${conts[@]}"; do [ "$p" = "$ph" ] || left+=("$p"); done' \
  '      for p in "${conts[@]}"; do left+=("$p"); done' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard takes a freezer gap it cannot read after a step for proof the freezer went' \
  '  _shmutant_holder_state "$guard_of" "${guard_of_id:-}" || [ "$?" = 2 ] || _shmutant_guard_clock_moved || [ "$?" = 2 ]' \
  '  _shmutant_holder_state "$guard_of" "${guard_of_id:-}" || [ "$?" = 2 ] || _shmutant_guard_clock_moved' \
  't_guard_waits_for_a_freezer_whose_elapsed_start_moved'
shmutant_mut 'the guard cannot tell a freezer number no longer in use from a step' \
  '  kill -0 "$guard_of" 2>/dev/null || return 1' \
  '  :' \
  't_guard_waits_for_a_freezer_whose_elapsed_start_moved'
shmutant_mut 'the guard cannot tell a reused freezer number from a step outside the elapsed-time form' \
  '  case "${guard_of_id:-}" in e*) ;; *) return 1 ;; esac' \
  '  :' \
  't_guard_takes_neither_a_reused_pid_nor_a_zombie_for_its_freezer'

# --- a check and its signal kept together (#49 and #53, the rest) ---
shmutant_mut 'the guard names a pid verified twice twice' \
  '      [ -n "${killing[$pid]:-}" ] || { killing' \
  '      true && { killing' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard names its group before the pids' \
  'kills=("${left[@]}" -"$pg")' \
  'kills=(-"$pg" "${left[@]}")' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the guard kills the holder by number before its group' \
  'kills=("${left[@]}" -"$pg")' \
  'kills=("${kills[@]}" -"$pg")' \
  't_guard_ends_only_what_it_can_verify'
shmutant_mut 'the kill names a pid two records chose twice' \
  'do [ -n "${named[$p]:-}" ] || { named["$p"]=1; left+=("$p"); }; done' \
  'do left+=("$p"); done' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill names its group before the pids' \
  '      targets=("${left[@]}" -"$SHMUTANT_KILL_GROUP")' \
  '      targets=(-"$SHMUTANT_KILL_GROUP" "${left[@]}")' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the kill names the holder by number before its group' \
  '      targets=("${left[@]}" -"$SHMUTANT_KILL_GROUP")' \
  '      targets=("${targets[@]}" -"$SHMUTANT_KILL_GROUP")' \
  't_kill_tree_reads_its_checks_last_from_one_table'
shmutant_mut 'the guard is killed by number after its group' \
  '      kill -KILL -- -"$guard_pid" 2>/dev/null' \
  '      kill -KILL -- -"$guard_pid" "$guard_pid" 2>/dev/null' \
  't_freeze_guard_not_seen_to_end_is_killed'
shmutant_mut 'the CLI kills its group on a check with nothing stopped' \
  '  _shmutant_kill_tree_twice -g "$1" "$1:"' \
  '  kill -KILL -- -"$1" 2>/dev/null' \
  't_cli_end_group_checks_the_holder_identity'
shmutant_mut 'the bounded ps ends its job by number' \
  '    builtin kill -KILL "%$js" 2>/dev/null' \
  '    builtin kill -KILL "$1" 2>/dev/null' \
  't_ps_end_signals_a_job_only_through_bash_s_record'
shmutant_mut 'the bounded read keeps the process group its substitution inherited' \
  'set +e; builtin set -m; builtin set +m; c=""' \
  'set +e; c=""' \
  't_guard_gives_up_on_a_process_table_that_stalls'

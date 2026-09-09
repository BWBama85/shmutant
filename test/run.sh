#!/usr/bin/env bash
# shmutant's own suite. Every unit is a `t_*` function; SHMUTANT_SELECT narrows the run to one
# of them, which is how test/mutants.sh targets each row at the unit that claims to cover it.
#
# Exit: 0 every selected unit passed; 1 a unit failed (each failure prints `FAIL: <unit>: …`);
# 2 no unit matched the selection.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../shmutant.sh
. "$here/../shmutant.sh" || exit 2
SHMUTANT="$here/../shmutant.sh"

unset SHMUTANT_TIMEOUT SHMUTANT_JOBS SHMUTANT_KEEP SHMUTANT_STREAM SHMUTANT_BASELINE \
  SHMUTANT_RED_PREFIX SHMUTANT_RED_STATUS

# --- assertions: every failure names the unit, so a witness is a unit name ----------------------

_unit=""; _failed=0
fail_() { printf 'FAIL: %s: %s\n' "$_unit" "$*"; _failed=1; }
eq()    { [ "$1" = "$2" ] || fail_ "$3: got [$1] want [$2]"; }
has()   { case "$1" in *"$2"*) ;; *) fail_ "$3: missing [$2] in [$1]" ;; esac; }
hasnt() { case "$1" in *"$2"*) fail_ "$3: unexpectedly contains [$2]" ;; *) ;; esac; }
rc_is() { [ "$1" -eq "$2" ] || fail_ "$3: rc $1, want $2"; }

# --- fixtures ----------------------------------------------------------------------------------

# mk_toy <dir> — a two-function library and a selectable test script with three units.
mk_toy() {
  mkdir -p "$1"
  cat > "$1/lib.sh" <<'EOF'
add() { echo $(( $1 + $2 )); }
is_even() { [ $(( $1 % 2 )) -eq 0 ]; }
EOF
  cat > "$1/test.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"
sel="${SHMUTANT_SELECT:-}"; n=0; rc=0
want() { if [ -z "$sel" ] || [ "$sel" = "$1" ]; then n=$((n + 1)); return 0; fi; return 1; }
if want add-works; then [ "$(add 2 3)" = 5 ] || { echo "FAIL: add-works: got $(add 2 3)"; rc=1; }; fi
if want even-works; then is_even 4 || { echo "FAIL: even-works: 4 is even"; rc=1; }; fi
if want uncovered; then :; fi
[ "$n" -gt 0 ] || exit 2
exit $rc
EOF
}
toy_prepare() { shmutant_copy_tree "$TOY" "$1"; }
toy_run() { bash "$1/test.sh"; }

# pool <args…> — run shmutant_pool with the stream in OUT, stderr in ERR, status in RC.
pool() {
  OUT="$(shmutant_pool "$@" 2> "$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
# verdict_of <row-name> — the verdict field of that row's stream record.
verdict_of() { printf '%s\n' "$OUT" | awk -F'\t' -v n="$1" '$3 == "row" && $5 == n { print $4 }'; }
# field <record-type> <n> — field <n> of the first record of that type.
field() { printf '%s\n' "$OUT" | awk -F'\t' -v t="$1" -v n="$2" '$3 == t { print $n; exit }'; }

# --- units: shmutant_mutate ----------------------------------------------------------------------

t_mutate_applies_first_occurrence_only() {
  printf 'a=1\nb=1\na=1\n' > "$T/f"
  shmutant_mutate "$T/f" 'a=1' 'a=2'; rc_is $? 0 'applies'
  eq "$(cat "$T/f")" $'a=2\nb=1\na=1' 'only the first occurrence changed'
}

t_mutate_within_one_line_only() {
  printf 'one\ntwo\n' > "$T/f"
  shmutant_mutate "$T/f" $'one\ntwo' 'x'; rc_is $? 2 'a literal spanning two lines never matches'
  eq "$(cat "$T/f")" $'one\ntwo' 'file untouched'
}

t_mutate_reports_unapplied() {
  printf 'keep me\n' > "$T/f"
  shmutant_mutate "$T/f" 'absent' 'x'; rc_is $? 2 'no match is rc 2'
  eq "$(cat "$T/f")" 'keep me' 'file untouched on no match'
  [ -e "$T/f.shmutant-tmp" ] && fail_ 'temp file left behind'
  shmutant_mutate "$T/f" '' 'x'; rc_is $? 2 'an empty old literal is rc 2, not a rewrite'
}

t_mutate_keeps_backslashes() {
  printf 'echo "\\$x" \\n done\n' > "$T/f"
  shmutant_mutate "$T/f" '\$x" \n' 'Y'; rc_is $? 0 'a literal carrying \$ and \n is matched byte for byte'
  eq "$(cat "$T/f")" 'echo "Y done' 'the replacement is spliced in place'
  printf 'p\n' > "$T/g"
  shmutant_mutate "$T/g" 'p' '\n\t\\'; rc_is $? 0 'new literal with escapes'
  eq "$(cat "$T/g")" '\n\t\\' 'the new literal arrives unprocessed'
}

t_mutate_reports_rewrite_failure() {
  shmutant_mutate "$T/nope/f" 'a' 'b'; rc_is $? 1 'unreadable file is rc 1'
}

t_mutate_preserves_mode() {
  printf '#!/bin/sh\necho old\n' > "$T/f"; chmod 755 "$T/f"
  shmutant_mutate "$T/f" 'old' 'new'; rc_is $? 0 'applies'
  [ -x "$T/f" ] || fail_ 'the executable bit was lost by the rewrite'
  chmod 600 "$T/f"
  shmutant_mutate "$T/f" 'new' 'newer'; rc_is $? 0 'applies again'
  [ -x "$T/f" ] && fail_ 'a mode the file did not have was added'
  eq "$(cat "$T/f")" $'#!/bin/sh\necho newer' 'content rewritten'
}

t_mutate_preserves_missing_final_newline() {
  printf 'a=1\nb=1' > "$T/f"
  shmutant_mutate "$T/f" 'b=1' 'b=2'; rc_is $? 0 'applies'
  eq "$(od -An -c "$T/f" | tr -s ' \n' ' ')" ' a = 1 \n b = 2 ' 'no newline was appended'
  printf 'a=1\n' > "$T/g"
  shmutant_mutate "$T/g" 'a=1' 'a=2'; rc_is $? 0 'applies'
  eq "$(od -An -c "$T/g" | tr -s ' \n' ' ')" ' a = 2 \n ' 'a final newline is kept'
}

t_mutate_never_follows_a_stale_temp_link() {
  mkdir -p "$T/out" "$T/tree"
  printf 'precious\n' > "$T/out/victim"
  printf 'x=1\n' > "$T/tree/f"
  ln -s "$T/out/victim" "$T/tree/f.shmutant-tmp"
  shmutant_mutate "$T/tree/f" 'x=1' 'x=2'; rc_is $? 0 'applies'
  eq "$(cat "$T/out/victim")" 'precious' 'a symlink at the old predictable temp name is never written through'
  eq "$(cat "$T/tree/f")" 'x=2' 'the target was rewritten'
  local left; left=("$T/tree"/.shmutant.*)
  [ -e "${left[0]}" ] && fail_ 'a temp file was left behind'
  eq "$(cat "$T/tree/f.shmutant-tmp")" 'precious' 'the stale link itself is untouched'
}

# --- units: the table -----------------------------------------------------------------------------

t_mut_validates_rows() {
  shmutant_reset
  shmutant_mut 'no target' 'a' 'b' 'w' 2>/dev/null; rc_is $? 2 'a row without a target is refused'
  shmutant_target /abs 2>/dev/null; rc_is $? 2 'an absolute target is refused'
  shmutant_target lib.sh; rc_is $? 0 'a relative target is accepted'
  shmutant_mut 'empty old' '' 'b' 'w' 2>/dev/null; rc_is $? 2 'empty old literal refused'
  shmutant_mut 'same' 'a' 'a' 'w' 2>/dev/null; rc_is $? 2 'identical literals refused'
  shmutant_mut 'no witness' 'a' 'b' '' 2>/dev/null; rc_is $? 2 'empty witness refused'
  shmutant_mut '' 'a' 'b' 'w' 2>/dev/null; rc_is $? 2 'empty name refused'
  shmutant_mut 'three args' 'a' 'b' 2>/dev/null; rc_is $? 2 'too few arguments refused'
  eq "${#SHMUTANT_ROWS_NAME[@]}" 0 'nothing was appended by a refused row'
  shmutant_mut 'ok' 'a' 'b' 'wit'; rc_is $? 0 'a valid row is appended'
  shmutant_mut 'ok2' 'a' 'b' 'wit' 'unit'; rc_is $? 0 'a row with a select is appended'
  eq "${SHMUTANT_ROWS_SEL[0]}" 'wit' 'select defaults to the witness'
  eq "${SHMUTANT_ROWS_SEL[1]}" 'unit' 'an explicit select is kept'
  eq "${SHMUTANT_ROWS_FILE[1]}" 'lib.sh' 'the row carries the current target'
}

t_refused_declarations_fail_the_pool() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'typo' '' 'b' 'add-works' 2>/dev/null
  shmutant_mut 'good' '$1 + $2' '$1 - $2' 'add-works'
  eq "$SHMUTANT_DECL_ERRORS" 1 'the refusal was counted'
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a table with a refused row does not run'
  has "$ERR" 'refused' 'says why'
  shmutant_reset
  eq "$SHMUTANT_DECL_ERRORS" 0 'reset clears the count'
}

t_reset_clears_table() {
  shmutant_target lib.sh
  shmutant_mut 'r' 'a' 'b' 'w'
  shmutant_reset
  eq "${#SHMUTANT_ROWS_NAME[@]}" 0 'table emptied'
  eq "$SHMUTANT_TARGET" '' 'target forgotten'
}

# --- units: pool preconditions ----------------------------------------------------------------------

t_pool_rejects_empty_table() {
  shmutant_reset
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'an empty table is a harness error'
  has "$ERR" 'EMPTY' 'says the table is empty'
  eq "$OUT" '' 'no stream records for a run that never started'
}

t_pool_rejects_missing_callbacks() {
  shmutant_reset; shmutant_target lib.sh; shmutant_mut 'r' 'a' 'b' 'w'
  pool lbl "$T/wd" no_such_prepare toy_run
  rc_is "$RC" 2 'a missing prepare callback is refused'
  has "$ERR" 'prepare callback not found' 'names the missing callback'
  pool lbl "$T/wd" toy_prepare no_such_run
  rc_is "$RC" 2 'a missing run callback is refused'
}

t_pool_refuses_root_outside_workdir() {
  shmutant_reset; shmutant_target lib.sh; shmutant_mut 'r' '$1 + $2' '$1 - $2' 'add-works'
  mk_toy "$T/real"
  evil_prepare() { printf '%s' "$T/real"; }
  pool lbl "$T/wd" evil_prepare toy_run
  rc_is "$RC" 2 'a root outside the workdir is refused'
  has "$ERR" 'outside the workdir' 'says why'
  eq "$(cat "$T/real/lib.sh")" "$(mk_toy "$T/ref"; cat "$T/ref/lib.sh")" 'the real tree is untouched'
}

t_pool_refuses_missing_target() {
  shmutant_reset; shmutant_target absent.sh; shmutant_mut 'r' 'a' 'b' 'add-works'
  mk_toy "$T/toy"; TOY="$T/toy"
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a target the prepared tree lacks is refused before any run'
  has "$ERR" 'absent.sh' 'names the target'
}

t_pool_reports_failed_prepare() {
  shmutant_reset; shmutant_target lib.sh; shmutant_mut 'r' 'a' 'b' 'w'
  bad_prepare() { return 1; }
  pool lbl "$T/wd" bad_prepare toy_run
  rc_is "$RC" 2 'a failing prepare is a harness error'
  has "$ERR" 'prepare failed' 'says so'
}

t_pool_validates_timeout() {
  shmutant_reset; shmutant_target lib.sh; shmutant_mut 'r' '$1 + $2' '$1 - $2' 'add-works'
  mk_toy "$T/toy"; TOY="$T/toy"
  SHMUTANT_TIMEOUT=abc pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a non-integer timeout is refused'
  has "$ERR" 'SHMUTANT_TIMEOUT' 'names the variable'
}

# --- units: one verdict each -----------------------------------------------------------------------------

t_verdict_killed() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'add subtracts' '$1 + $2' '$1 - $2' 'add-works'
  shmutant_mut 'even is odd' '-eq 0' '-ne 0' 'even-works'
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 0 'every row killed is success'
  eq "$(verdict_of 'add subtracts')" killed 'first row killed'
  eq "$(verdict_of 'even is odd')" killed 'second row killed'
  eq "$(field summary 5)" 2 'summary rows'
  eq "$(field summary 6)" 2 'summary killed'
  has "$ERR" '2/2 mutation(s) killed' 'human summary'
}

t_verdict_survived() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'nobody asserts' '$1 % 2' '$1 % 4' 'uncovered'
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 1 'a survivor fails the pool'
  eq "$(verdict_of 'nobody asserts')" survived 'verdict is survived'
  has "$ERR" 'stayed GREEN' 'says it stayed green'
}

t_verdict_accidental() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'wrong witness' '$1 + $2' '$1 * $2' 'even-works' 'add-works'
  chatty_run() { echo "note: even-works is not selected here"; bash "$1/test.sh"; }
  pool lbl "$T/wd" toy_prepare chatty_run
  rc_is "$RC" 1 'red on the wrong assertion fails the pool'
  eq "$(verdict_of 'wrong witness')" accidental 'verdict is accidental'
  has "$ERR" 'NOT on its witness [even-works]' 'names the witness it missed'
}

t_verdict_aborted_status() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'crashes' 'is_even() {' 'is_even() { echo "FAIL: even-works: boom"; exit 3;' 'even-works'
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 1 'an abort fails the pool'
  eq "$(verdict_of 'crashes')" aborted 'verdict is aborted'
  has "$ERR" 'exited 3, not 1' 'reports the status'
}

t_verdict_aborted_no_red_line() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'exits 1 silently' 'is_even() {' 'is_even() { exit 1;' 'even-works'
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 1 'exit 1 without a red line fails the pool'
  eq "$(verdict_of 'exits 1 silently')" aborted 'verdict is aborted'
  has "$ERR" 'no [FAIL: ] line' 'says no red line was printed'
}

t_verdict_unapplied() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'literal absent' 'not in the file' 'x' 'add-works'
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 1 'an unapplied row fails the pool'
  eq "$(verdict_of 'literal absent')" unapplied 'verdict is unapplied'
  has "$ERR" 'tests NOTHING' 'says the row tests nothing'
  [ -e "$T/wd/mut-0/tree" ] && fail_ 'an unapplied row left its clone behind'
}

t_verdict_baseline_red() {
  mk_toy "$T/toy"; TOY="$T/toy"
  printf 'add() { echo 0; }\nis_even() { [ $(( $1 %% 2 )) -eq 0 ]; }\n' > "$T/toy/lib.sh"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'already red' 'echo 0' 'echo 1' 'add-works'
  shmutant_mut 'still green' '-eq 0' '-ne 0' 'even-works'
  counting_run() { printf '%s\n' "$2" >> "$T/runs"; bash "$1/test.sh"; }
  pool lbl "$T/wd" toy_prepare counting_run
  rc_is "$RC" 1 'a red baseline fails the pool'
  eq "$(field baseline 5)" red 'baseline record is red'
  eq "$(verdict_of 'already red')" baseline 'the row is scored baseline, not killed'
  eq "$(verdict_of 'still green')" killed 'a row on a green selector still runs'
  eq "$(grep -c '^add-works$' "$T/runs")" 1 'the red selector ran once (baseline) and never for the row'
  has "$ERR" 'BEFORE any defect' 'explains the verdict'
}

t_verdict_timeout() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'hangs' '$1 + $2' '$1 - $2' 'add-works'
  slow_run() { bash -c "sleep 3; touch '$T/finished'"; }
  SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=1 pool lbl "$T/wd" toy_prepare slow_run
  rc_is "$RC" 1 'a timeout fails the pool'
  eq "$(verdict_of 'hangs')" timeout 'verdict is timeout'
  has "$ERR" 'within 1s' 'reports the bound'
  sleep 3
  [ -e "$T/finished" ] && fail_ 'the run outlived its timeout — the process tree was not killed'
}

t_verdict_timeout_kills_a_term_ignoring_descendant() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'hangs' '$1 + $2' '$1 - $2' 'add-works'
  stubborn_run() { bash -c "trap '' TERM; sleep 4; touch '$T/finished'"; }
  SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=1 pool lbl "$T/wd" toy_prepare stubborn_run
  eq "$(verdict_of 'hangs')" timeout 'verdict is timeout'
  sleep 4
  [ -e "$T/finished" ] && fail_ 'a descendant that ignores TERM outlived the timeout — the watchdog never reached KILL'
}

t_pool_recreates_worker_dirs() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  mkdir -p "$T/wd/mut-0/tree/stale" "$T/wd/base-0"
  : > "$T/wd/mut-0/timeout"; : > "$T/wd/base-0/timeout"
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 0 'a stale timeout marker from an earlier pool does not poison the verdict'
  eq "$(verdict_of a)" killed 'killed, not timeout'
  eq "$(field baseline 5)" green 'baseline green, not timeout'
  [ -e "$T/wd/mut-0/tree/stale" ] && fail_ 'stale clone content survived into the new run'
}

t_read_verdict_fails_closed() {
  _shmutant_read_verdict "$T/none"
  eq "$SHMUTANT_V_VERDICT" lost 'missing verdict file reads as lost'
  mkdir -p "$T/d"; printf '\n0\n1\n' > "$T/d/verdict"
  _shmutant_read_verdict "$T/d"
  eq "$SHMUTANT_V_VERDICT" lost 'blank verdict reads as lost'
  printf 'killed\nabc\n1\n' > "$T/d/verdict"
  _shmutant_read_verdict "$T/d"
  eq "$SHMUTANT_V_VERDICT" killed 'verdict word read'
  eq "$SHMUTANT_V_US" 0 'a damaged duration reads as zero'
  has "$(_shmutant_detail lost '' '' '')" 'NO verdict' 'lost has a human sentence'
}

# --- units: the pool's mechanics ------------------------------------------------------------------------

t_pool_passes_select_to_run() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  shmutant_mut 'b' '-eq 0' '-ne 0' 'even-works' 'even-works'
  spy_run() { printf '%s|%s\n' "$2" "${SHMUTANT_SELECT:-unset}" >> "$T/seen"; bash "$1/test.sh"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare spy_run
  rc_is "$RC" 0 'both killed'
  eq "$(sort "$T/seen" | tr '\n' ' ')" 'add-works|add-works even-works|even-works ' 'run got the select as $2 and as SHMUTANT_SELECT'
}

t_pool_prepares_once_and_clones_per_row() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  shmutant_mut 'b' '-eq 0' '-ne 0' 'even-works'
  counting_prepare() { printf 'x\n' >> "$T/prepared"; shmutant_copy_tree "$TOY" "$1"; }
  spy_run() { cp "$1/lib.sh" "$T/seen-$2"; bash "$1/test.sh"; }
  pool lbl "$T/wd" counting_prepare spy_run
  rc_is "$RC" 0 'both killed'
  eq "$(wc -l < "$T/prepared" | tr -d ' ')" 1 'prepare ran exactly once'
  has "$(cat "$T/seen-add-works")" '$1 - $2' 'row a saw its own defect'
  hasnt "$(cat "$T/seen-add-works")" '-ne 0' 'row a did not see row b'
  has "$(cat "$T/seen-even-works")" '-ne 0' 'row b saw its own defect'
  hasnt "$(cat "$T/seen-even-works")" '$1 - $2' 'row b did not see row a'
  eq "$(cat "$T/toy/lib.sh" | grep -c -- '-ne 0')" 0 'the source tree was never mutated'
  [ -e "$T/wd/mut-0/tree" ] && fail_ 'the clone was not removed after its run'
  [ -e "$T/wd/pristine" ] && fail_ 'the pristine tree was not removed'
  [ -f "$T/wd/mut-0/output" ] || fail_ 'the run output was not kept'
}

t_pool_root_may_be_a_subdirectory() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  nested_prepare() { shmutant_copy_tree "$TOY" "$1/repo/src" && printf '%s' "$1/repo/src"; }
  pool lbl "$T/wd" nested_prepare toy_run
  rc_is "$RC" 0 'a nested root is mutated and run in the clone'
  eq "$(verdict_of a)" killed 'killed through the nested root'
}

t_pool_keep_retains_clones() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  SHMUTANT_KEEP=1 SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 0 'killed'
  [ -f "$T/wd/mut-0/tree/lib.sh" ] || fail_ 'SHMUTANT_KEEP=1 did not keep the clone'
  has "$(cat "$T/wd/mut-0/tree/lib.sh")" '$1 - $2' 'the kept clone carries the defect'
  [ -d "$T/wd/pristine" ] || fail_ 'SHMUTANT_KEEP=1 did not keep the pristine tree'
}

t_pool_honours_jobs() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  shmutant_mut 'b' '$1 + $2' '$1 * $2' 'add-works'
  shmutant_mut 'c' '$1 + $2' '$1 / $2' 'add-works'
  trace_run() { echo start >> "$T/trace"; sleep 0.2; echo end >> "$T/trace"; bash "$1/test.sh"; }
  SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare trace_run
  rc_is "$RC" 0 'all killed'
  eq "$(field summary 7)" 1 'summary reports jobs=1'
  eq "$(tr '\n' ' ' < "$T/trace")" 'start end start end start end ' 'with one job the runs never overlap'
  SHMUTANT_JOBS=50 SHMUTANT_BASELINE=0 pool lbl "$T/wd2" toy_prepare toy_run 3
  eq "$(field summary 7)" 3 'the cap bounds SHMUTANT_JOBS'
  eq "$(_shmutant_jobs 4 | tr -d ' ')" "$(_shmutant_jobs 4)" 'jobs is a bare number'
}

t_pool_skips_baseline_on_request() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  counting_run() { printf 'x\n' >> "$T/runs"; bash "$1/test.sh"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare counting_run
  rc_is "$RC" 0 'killed'
  eq "$(field baseline 3)" '' 'no baseline record'
  eq "$(wc -l < "$T/runs" | tr -d ' ')" 1 'the run happened once: no uninjected pass'
}

t_pool_red_prefix_and_status_are_configurable() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  tap_run() { local out; out="$(bash "$1/test.sh")"; case "$out" in *FAIL:*) echo "not ok 1 add-works"; exit 3 ;; *) echo "ok 1 add-works"; exit 0 ;; esac; }
  SHMUTANT_RED_PREFIX='not ok ' SHMUTANT_RED_STATUS=3 pool lbl "$T/wd" toy_prepare tap_run
  rc_is "$RC" 0 'a TAP-shaped suite is scored through its own prefix and status'
  eq "$(verdict_of a)" killed 'killed'
  pool lbl "$T/wd2" toy_prepare tap_run
  eq "$(verdict_of a)" aborted 'with the defaults, exit 3 is an abort'
}

t_pool_does_not_reap_callers_jobs() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  shmutant_mut 'b' '$1 + $2' '$1 * $2' 'add-works'
  shmutant_mut 'c' '$1 + $2' '$1 / $2' 'add-works'
  trace_run() { echo start >> "$T/trace"; sleep 0.2; echo end >> "$T/trace"; bash "$1/test.sh"; }
  ( exit 7 ) & ( exit 7 ) & ( exit 7 ) &
  sleep 0.2
  SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" toy_prepare trace_run > /dev/null 2>&1; rc_is $? 0 'killed'
  eq "$(tr '\n' ' ' < "$T/trace")" 'start end start end start end ' "the caller's finished jobs do not free a pool slot"
}

t_pool_runs_baseline_once_per_selector() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  shmutant_mut 'b' '$1 + $2' '$1 * $2' 'add-works'
  shmutant_mut 'c' '-eq 0' '-ne 0' 'even-works'
  counting_run() { printf '%s\n' "$2" >> "$T/runs"; bash "$1/test.sh"; }
  pool lbl "$T/wd" toy_prepare counting_run
  rc_is "$RC" 0 'all killed'
  eq "$(printf '%s\n' "$OUT" | grep -c $'\tbaseline\t')" 2 'one baseline record per distinct selector'
  eq "$(wc -l < "$T/runs" | tr -d ' ')" 5 'two baseline runs plus three rows'
}

# --- units: the stream ------------------------------------------------------------------------------------

t_stream_format() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut $'tab\there' '$1 + $2' '$1 - $2' 'add-works'
  pool "my label" "$T/wd" toy_prepare toy_run
  eq "$(printf '%s\n' "$OUT" | awk -F'\t' '$3 == "row" { print NF }')" 9 'a row record has nine fields'
  eq "$(printf '%s\n' "$OUT" | awk -F'\t' '$3 == "summary" { print NF }')" 8 'a summary record has eight fields'
  eq "$(printf '%s\n' "$OUT" | awk -F'\t' '$3 == "baseline" { print NF }')" 7 'a baseline record has seven fields'
  eq "$(field row 1)" shmutant 'records start with shmutant'
  eq "$(field row 2)" 1 'records carry the stream version'
  eq "$(field row 5)" 'tab\there' 'a tab in a field is escaped'
  eq "$(field row 6)" 'lib.sh' 'row record carries the target'
  eq "$(field summary 4)" 'my label' 'summary carries the label'
  case "$(field row 8)" in [0-9]*.[0-9][0-9][0-9]) ;; *) fail_ "duration is not seconds with three decimals: $(field row 8)" ;; esac
  eq "$(_shmutant_esc $'a\\b\tc\nd')" 'a\\b\tc\nd' 'escaping covers backslash, tab and newline'
  eq "$(_shmutant_secs 1500)" '0.002' 'microseconds round to milliseconds'
  eq "$(_shmutant_secs 2500000)" '2.500' 'seconds render with three decimals'
}

t_stream_write_failure_is_a_harness_error() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  SHMUTANT_STREAM="$T/no/such/dir/stream" pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'an unwritable stream is exit 2 even though every row was killed'
  has "$ERR" 'could not be written' 'says the stream was lost'
  has "$ERR" '1/1 mutation(s) killed' 'the human summary still reports the verdicts'
}

t_stream_to_file() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  SHMUTANT_STREAM="$T/stream" pool lbl "$T/wd" toy_prepare toy_run
  eq "$OUT" '' 'nothing on stdout when SHMUTANT_STREAM is set'
  eq "$(grep -c '^shmutant' "$T/stream")" 3 'baseline, row and summary landed in the file'
}

# --- units: helpers ---------------------------------------------------------------------------------------

t_selected_predicate() {
  SHMUTANT_SELECTED_N=0
  SHMUTANT_SELECT='' shmutant_selected anything; rc_is $? 0 'no selection selects everything'
  SHMUTANT_SELECT=x shmutant_selected x; rc_is $? 0 'an exact match is selected'
  SHMUTANT_SELECT=x shmutant_selected xy; rc_is $? 1 'a superstring is not selected'
  SHMUTANT_SELECT=xy shmutant_selected x; rc_is $? 1 'a substring is not selected'
  eq "$SHMUTANT_SELECTED_N" 2 'only selected units are counted'
}

t_copy_tree_excludes_git() {
  mkdir -p "$T/src/.git/objects" "$T/src/sub" "$T/src/.hidden"
  printf 'x' > "$T/src/.git/HEAD"; printf 'y' > "$T/src/sub/f"; printf 'z' > "$T/src/.hidden/g"; printf 'w' > "$T/src/.dotfile"
  ln -s sub/f "$T/src/link"
  shmutant_copy_tree "$T/src" "$T/dst"; rc_is $? 0 'copy succeeds'
  [ -e "$T/dst/.git" ] && fail_ '.git was copied'
  eq "$(cat "$T/dst/sub/f")" y 'nested file copied'
  eq "$(cat "$T/dst/.hidden/g")" z 'hidden directory copied'
  eq "$(cat "$T/dst/.dotfile")" w 'dotfile copied'
  [ -L "$T/dst/link" ] || fail_ 'symlink was not kept as a symlink'
  shmutant_copy_tree "$T/missing" "$T/dst2" 2>/dev/null; rc_is $? 1 'a missing source is an error'
}

t_bash_floor() {
  _shmutant_bash_ok 5 3; rc_is $? 0 '5.3 is at the floor'
  _shmutant_bash_ok 5 9; rc_is $? 0 '5.9 is above the floor'
  _shmutant_bash_ok 6 0; rc_is $? 0 '6.0 is above the floor'
  _shmutant_bash_ok 5 2; rc_is $? 1 '5.2 is below the floor'
  _shmutant_bash_ok 4 4; rc_is $? 1 '4.4 is below the floor'
  _shmutant_bash_ok 3 2; rc_is $? 1 '3.2 is below the floor'
  has "$(_shmutant_install_hint)" 'bash' 'the install hint names bash'
  local old
  for old in /bin/bash /usr/bin/bash; do
    [ -x "$old" ] || continue
    "$old" -c '[ "${BASH_VERSINFO[0]}" -lt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }' || continue
    local msg
    msg="$(PATH=/nonexistent SHMUTANT_REEXEC=1 "$old" "$SHMUTANT" version 2>&1)"; rc_is $? 2 "executing under $old exits 2"
    has "$msg" 'below the 5.3 floor' 'executing under an old bash says so'
    msg="$("$old" -c ". '$SHMUTANT' || exit \$?; echo reached" 2>&1)"; rc_is $? 2 "sourcing under $old returns 2"
    hasnt "$msg" 'reached' 'a caller that checks the source status stops'
    has "$msg" 'below the 5.3 floor' 'sourcing under an old bash says so'
    echo "note: $_unit exercised the real floor guard under $old"
    return
  done
  echo "note: $_unit found no pre-5.3 bash to exercise the guard against; only the predicate was tested"
}

# --- units: the CLI -------------------------------------------------------------------------------------------

t_cli_run() {
  mk_toy "$T/toy"; TOY="$T/toy"
  cat > "$T/toy/plan.sh" <<'EOF'
prepare() { shmutant_copy_tree "$SHMUTANT_PLAN_DIR" "$1"; }
run() { bash "$1/test.sh"; }
shmutant_target lib.sh
shmutant_mut 'add subtracts' '$1 + $2' '$1 - $2' 'add-works'
EOF
  local out
  out="$(bash "$SHMUTANT" run "$T/toy/plan.sh" 2> "$T/err")"; rc_is $? 0 'a plan whose rows are all killed exits 0'
  has "$out" $'shmutant\t1\trow\tkilled' 'the stream reaches stdout'
  has "$(cat "$T/err")" 'plan.sh: 1/1' 'the label is the plan file name'
  printf "shmutant_mut 'survivor' '%%' '+' 'uncovered'\n" >> "$T/toy/plan.sh"
  bash "$SHMUTANT" run "$T/toy/plan.sh" > /dev/null 2>&1; rc_is $? 1 'a survivor exits 1'
  bash "$SHMUTANT" run "$T/toy/plan.sh" --jobs 1 --no-baseline --timeout 30 --workdir "$T/w" --keep > /dev/null 2>&1; rc_is $? 1 'options are accepted'
  [ -d "$T/w/mut-1/tree" ] || fail_ '--keep --workdir left the clone in place'
  bash "$SHMUTANT" run "$T/toy/plan.sh" --jobs 0 > /dev/null 2>&1; rc_is $? 2 '--jobs 0 is refused'
  mkdir -p "$T/mine"; printf 'keep\n' > "$T/mine/precious"
  bash "$SHMUTANT" run "$T/toy/plan.sh" --workdir "$T/mine" > /dev/null 2>&1; rc_is $? 1 'runs in a caller-supplied workdir'
  eq "$(cat "$T/mine/precious" 2>/dev/null)" keep 'a caller-supplied --workdir is never removed'
  [ -f "$T/mine/mut-0/output" ] || fail_ 'the pool artifacts landed in the supplied workdir'
  local kept
  kept="$(bash "$SHMUTANT" run "$T/toy/plan.sh" --keep 2>&1 >/dev/null | sed -n 's/^shmutant: workdir kept: //p')"
  [ -n "$kept" ] && [ -f "$kept/mut-0/tree/lib.sh" ] || fail_ '--keep did not keep a workdir the run created'
  [ -n "$kept" ] && rm -rf -- "$kept"
  printf "shmutant_mut 'broken' '' 'x' 'add-works'\nshmutant_mut 'fine' '+' '-' 'add-works'\n" >> "$T/toy/plan.sh"
  bash "$SHMUTANT" run "$T/toy/plan.sh" > /dev/null 2>&1; rc_is $? 2 'a refused row followed by a valid one fails the plan'
  bash "$SHMUTANT" run "$T/toy/plan.sh" --bogus > /dev/null 2>&1; rc_is $? 2 'an unknown option is refused'
  bash "$SHMUTANT" run > /dev/null 2>&1; rc_is $? 2 'run without a plan is usage'
  bash "$SHMUTANT" run "$T/nope.sh" > /dev/null 2>&1; rc_is $? 2 'a missing plan is refused'
  printf 'shmutant_target lib.sh\nshmutant_mut a b c d\n' > "$T/norun.sh"
  bash "$SHMUTANT" run "$T/norun.sh" > /dev/null 2>&1; rc_is $? 2 'a plan without callbacks is refused'
  printf 'if\n' > "$T/broken.sh"
  bash "$SHMUTANT" run "$T/broken.sh" > /dev/null 2>&1; rc_is $? 2 'a plan that fails to load is refused'
  bash "$SHMUTANT" > /dev/null 2>&1; rc_is $? 2 'no command is usage'
  bash "$SHMUTANT" bogus > /dev/null 2>&1; rc_is $? 2 'an unknown command is usage'
  has "$(bash "$SHMUTANT" help)" 'usage:' 'help prints usage'
  eq "$(bash "$SHMUTANT" version)" "shmutant $SHMUTANT_VERSION" 'version prints the marker'
  eq "$(bash "$SHMUTANT" checksum)" "$(_shmutant_checksum "$SHMUTANT")" 'checksum hashes the file it runs from'
  case "$(bash "$SHMUTANT" checksum)" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) fail_ 'checksum is not a hex digest' ;;
  esac
  eq "$(_shmutant_checksum "$SHMUTANT")" "$(shasum -a 256 "$SHMUTANT" 2>/dev/null | awk '{print $1}' || sha256sum "$SHMUTANT" | awk '{print $1}')" 'checksum agrees with the platform tool'
}

# --- runner -----------------------------------------------------------------------------------------------

main() {
  local units u ran=0 failed=0
  units="$(declare -F | awk '$3 ~ /^t_/ { print $3 }')"
  for u in $units; do
    shmutant_selected "$u" || continue
    ran=$((ran + 1))
    (
      _unit="$u"; _failed=0
      T="$(mktemp -d "${TMPDIR:-/tmp}/shmutant-test.XXXXXX")" || exit 1
      trap 'rm -rf -- "$T"' EXIT
      cd "$T" || exit 1
      "$u"
      exit "$_failed"
    ) || failed=$((failed + 1))
  done
  if [ "$ran" -eq 0 ]; then
    printf 'run.sh: no unit matched the selection [%s]\n' "${SHMUTANT_SELECT:-}" >&2
    exit 2
  fi
  printf 'run.sh: %d unit(s) ran, %d failed\n' "$ran" "$failed"
  [ "$failed" -eq 0 ]
}

main "$@"

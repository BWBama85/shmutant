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

# wait_for <file> — block until <file> exists, at most ten seconds; false on expiry.
wait_for() {
  local i=0
  until [ -e "$1" ]; do i=$((i + 1)); [ "$i" -lt 100 ] || return 1; sleep 0.1; done
}

# make_unremovable <dir> — make <dir> (with a file inside) something this user cannot delete:
# the immutable flag where the platform has one, else root ownership through a non-interactive
# sudo (the CI runners allow it). False when neither is available; undo with unmake_unremovable.
make_unremovable() {
  mkdir -p "$1"; : > "$1/held"
  if chflags uchg "$1" 2>/dev/null; then UNREMOVABLE_HOW=chflags; return 0; fi
  if sudo -n chown root:root "$1" 2>/dev/null && sudo -n chmod 755 "$1" 2>/dev/null; then UNREMOVABLE_HOW=sudo; return 0; fi
  return 1
}
unmake_unremovable() {
  case "${UNREMOVABLE_HOW:-}" in
    chflags) chflags nouchg "$1" 2>/dev/null ;;
    sudo)    sudo -n /bin/rm -rf "$1" 2>/dev/null ;;
  esac
}

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
  # an unapplied rewrite cleans up through the real rm, whatever function the caller defined
  printf 'abc\n' > "$T/shadow-f"
  # shellcheck disable=SC2033
  rm() { echo SHADOWED-RM; }
  local got; got="$(shmutant_mutate "$T/shadow-f" zzz y; echo "rc=$?")"
  unset -f rm
  eq "$got" 'rc=2' 'a miss returns 2 and prints nothing from a caller-defined rm'
  eq "$(find "$T" -maxdepth 1 -name '.shmutant.*' | wc -l | tr -d ' ')" 0 'the temporary rewrite was removed by the real rm'
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
  shmutant_mutate "$T/f" 'keep' 'keep'; rc_is $? 2 'identical literals are rc 2, not a rewrite'
  eq "$(cat "$T/f")" 'keep me' 'file untouched by identical literals'
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

t_mutate_refuses_a_symlink_target() {
  printf 'x=1\n' > "$T/real"
  ln -s real "$T/link"
  shmutant_mutate "$T/link" 'x=1' 'x=2'; rc_is $? 1 'a symlink target is refused'
  [ -L "$T/link" ] || fail_ 'the symlink was replaced by a regular file'
  eq "$(cat "$T/real")" 'x=1' 'the referent is untouched'
}

t_mutate_works_under_noclobber() {
  printf 'x=1\n' > "$T/f"
  ( set -C; shmutant_mutate "$T/f" 'x=1' 'x=2' ); rc_is $? 0 'set -C in the sourcing shell does not break the rewrite'
  eq "$(cat "$T/f")" 'x=2' 'rewritten'
}

t_mutate_preserves_mode() {
  printf '#!/bin/sh\necho old\n' > "$T/f"; chmod 755 "$T/f"
  shmutant_mutate "$T/f" 'old' 'new'; rc_is $? 0 'applies'
  [ -x "$T/f" ] || fail_ 'the executable bit was lost by the rewrite'
  chmod 600 "$T/f"
  shmutant_mutate "$T/f" 'new' 'newer'; rc_is $? 0 'applies again'
  [ -x "$T/f" ] && fail_ 'a mode the file did not have was added'
  eq "$(cat "$T/f")" $'#!/bin/sh\necho newer' 'content rewritten'
  # restoring a directory mode that cannot be applied (here the directory is gone) is a failure
  _shmutant_mutate_restore "$T/gone-dir" 'drwxr-xr-x'; rc_is $? 1 'restoring a mode that chmod cannot apply returns failure'
  _shmutant_mutate_restore "$T/gone-dir" ''; rc_is $? 0 'restoring nothing is a no-op success'
  # and the mutate success path propagates a restore failure
  printf 'x=1\n' > "$T/pf"
  ( _shmutant_mutate_restore() { return 1; }; shmutant_mutate "$T/pf" 'x=1' 'x=2' ); rc_is $? 1 'a mutate whose directory-mode restore failed reports failure'
}

t_mutate_rewrites_a_read_only_target() {
  printf 'x=1\n' > "$T/f"; chmod 444 "$T/f"
  shmutant_mutate "$T/f" 'x=1' 'x=2'; rc_is $? 0 'a 0444 target is rewritten'
  eq "$(cat "$T/f")" 'x=2' 'content changed'
  case "$(ls -l "$T/f")" in -r--r--r--*) ;; *) fail_ "mode not preserved: $(ls -l "$T/f")" ;; esac
  printf '#!/bin/sh\necho old\n' > "$T/g"; chmod 555 "$T/g"
  shmutant_mutate "$T/g" 'old' 'new'; rc_is $? 0 'a 0555 target is rewritten'
  case "$(ls -l "$T/g")" in -r-xr-xr-x*) ;; *) fail_ "mode not preserved: $(ls -l "$T/g")" ;; esac
  chmod 644 "$T/f" "$T/g"
}

t_mutate_preserves_setuid() {
  printf '#!/bin/sh\necho old\n' > "$T/f"; chmod 4755 "$T/f"
  case "$(ls -l "$T/f")" in -rwsr-xr-x*) ;; *) echo "note: $_unit: this filesystem does not keep setuid ($(ls -l "$T/f" | cut -c1-10)); checking the spec only"; esac
  shmutant_mutate "$T/f" 'old' 'new'; rc_is $? 0 'a setuid target is rewritten'
  eq "$(ls -l "$T/f" | cut -c1-10)" "$(chmod 4755 "$T/f"; ls -l "$T/f" | cut -c1-10)" 'the mode after the rewrite equals the mode chmod 4755 gives on this filesystem'
  eq "$(_shmutant_mode_spec '-rwsr-xr-x')" 'u=rwxs,g=rx,o=rx' 'setuid spec'
  eq "$(_shmutant_mode_spec '-rw-r-Sr-T')" 'u=rw,g=rs,o=rt' 'setgid and sticky without x'
  eq "$(_shmutant_mode_spec '-r--------')" 'u=r,g=,o=' 'owner-only read'
  chmod 644 "$T/f"
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
  shmutant_target ../escape.sh 2>/dev/null; rc_is $? 2 'a leading .. component is refused'
  shmutant_target sub/../../escape.sh 2>/dev/null; rc_is $? 2 'an inner .. component is refused'
  shmutant_target 'sub/..hidden/f' 2>/dev/null; rc_is $? 0 'a name that merely starts with .. is a name'
  shmutant_target lib.sh extra 2>/dev/null; rc_is $? 2 'a target with surplus arguments is refused (an unquoted path with spaces)'
  shmutant_target lib.sh; rc_is $? 0 'a relative target is accepted'
  shmutant_mut 'empty old' '' 'b' 'w' 2>/dev/null; rc_is $? 2 'empty old literal refused'
  shmutant_mut 'same' 'a' 'a' 'w' 2>/dev/null; rc_is $? 2 'identical literals refused'
  shmutant_mut 'no witness' 'a' 'b' '' 2>/dev/null; rc_is $? 2 'empty witness refused'
  shmutant_mut '' 'a' 'b' 'w' 2>/dev/null; rc_is $? 2 'empty name refused'
  shmutant_mut 'three args' 'a' 'b' 2>/dev/null; rc_is $? 2 'too few arguments refused'
  shmutant_mut 'six args' 'a' 'b' 'w' 'sel' 'extra' 2>/dev/null; rc_is $? 2 'surplus arguments refused (an unquoted witness would land here)'
  shmutant_mut 'nl witness' 'a' 'b' $'two\nlines' 2>/dev/null; rc_is $? 2 'a witness with a newline can never match one red line'
  shmutant_mut 'nl select' 'a' 'b' 'w' $'two\nlines' 2>/dev/null; rc_is $? 2 'a selector with a newline is refused too'
  shmutant_mut 'nl old' $'a\nb' 'c' 'w' 2>/dev/null; rc_is $? 2 'an old literal with a newline can never match one record and is refused'
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
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'an empty table is a harness error'
  has "$ERR" 'EMPTY' 'says the table is empty'
  eq "$OUT" '' 'no stream records for a run that never started'
  [ -e "$T/wd/pristine" ] && fail_ 'the prepared tree was left behind'
  # a table declared entirely by prepare is not empty
  shmutant_reset
  declaring_prepare() { toy_prepare "$1"; shmutant_target lib.sh; shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" declaring_prepare toy_run
  rc_is "$RC" 0 'a plan whose every row is declared by prepare runs'
  eq "$(verdict_of a)" killed 'and its row is scored'
}

t_pool_checks_its_arity_first() {
  shmutant_reset; shmutant_target lib.sh; shmutant_mut 'r' 'a' 'b' 'w'
  ( set -u; shmutant_pool lbl 2>"$T/e" ); rc_is $? 2 'too few arguments is a harness error even under set -u'
  has "$(cat "$T/e")" 'usage' 'says so'
  ( set -u; shmutant_pool a b c d e f 2>/dev/null ); rc_is $? 2 'too many arguments is refused'
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

t_pool_refuses_symlink_target() {
  shmutant_reset; shmutant_target link.sh; shmutant_mut 'r' '$1 + $2' '$1 - $2' 'add-works'
  mk_toy "$T/toy"; TOY="$T/toy"; ln -s lib.sh "$T/toy/link.sh"
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a symlink target is refused before any run'
  has "$ERR" 'a symlink' 'says why'
}

t_pool_refuses_target_under_symlinked_dir() {
  mkdir -p "$T/outside"; printf 'add() { echo 5; }\n' > "$T/outside/lib.sh"
  mk_toy "$T/toy"; TOY="$T/toy"; ln -s "$T/outside" "$T/toy/linked"
  shmutant_reset; shmutant_target linked/lib.sh; shmutant_mut 'r' 'echo 5' 'echo 6' 'add-works'
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a target under a symlinked directory is refused before any run'
  has "$ERR" 'reached through one' 'says why'
  # the same through a RELATIVE link that leaves the tree: the clone keeps the link, and only
  # the containment check can tell
  rm -f "$T/toy/linked"; ln -s ../../outside "$T/toy/linked"
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a target under a relative symlink that leaves the tree is refused before any run'
  has "$ERR" 'reached through one' 'says why'
  rm -f "$T/toy/linked"; ln -s "$T/outside" "$T/toy/linked"
  # an absolute symlink that stays inside the tree cannot be cloned: refused before any worker
  mk_toy "$T/toy2"; mkdir -p "$T/toy2/real"; printf 'add() { echo $(( $1 + $2 )); }\n' > "$T/toy2/real/lib.sh"
  # the link is absolute and points inside the PREPARED tree itself
  abs_prepare() { shmutant_copy_tree "$T/toy2" "$1"; ln -s "$1/real" "$1/abs"; }
  shmutant_reset; shmutant_target abs/lib.sh; shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  pool lbl "$T/wd3" abs_prepare toy_run
  rc_is "$RC" 2 'a target under an absolute in-tree symlink is refused before any worker starts'
  has "$ERR" 'absolute one' 'says why'
  eq "$(cat "$T/outside/lib.sh")" 'add() { echo 5; }' 'the file outside the tree was never touched'
  _shmutant_target_ok "$T/toy" lib.sh; rc_is $? 0 'a plain in-tree file is fine'
  mkdir -p "$T/toy/sub"; ln -s ../lib.sh "$T/toy/sub/rel"; ln -s .. "$T/toy/sub/up"
  _shmutant_target_ok "$T/toy" sub/up/lib.sh; rc_is $? 0 'a relative symlink that stays inside the tree is fine'
  _shmutant_target_ok "$T/toy" linked/lib.sh; rc_is $? 1 'an absolute symlink out of the tree is not'
  _shmutant_target_ok "$T/toy" sub/rel; rc_is $? 1 'a symlink target itself is not'
}

t_pool_witness_match_is_case_sensitive() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'ADD-WORKS' 'add-works'
  shopt -s nocasematch
  pool lbl "$T/wd" toy_prepare toy_run
  shopt -u nocasematch
  eq "$(verdict_of a)" accidental 'a caller with nocasematch on does not make FAIL: add-works satisfy witness ADD-WORKS'
}

t_abs_ignores_cdpath() {
  mkdir -p "$T/here/sub" "$T/elsewhere/sub"
  local got
  got="$(cd "$T/here" && CDPATH="$T/elsewhere" _shmutant_abs sub)"
  eq "$got" "$(cd "$T/here/sub" && pwd -P)" 'a relative directory resolves against the cwd, on one line, whatever CDPATH says'
  mkdir -p "$T/dash/-"
  got="$(cd "$T/dash" && OLDPWD="$T/elsewhere" _shmutant_abs -)"
  eq "$got" "$(cd "$T/dash/-" && pwd -P)" 'a directory named - is that directory, never cd -'
  mkdir -p "$T/nl/x" "$T/nl/x
"
  ( cd "$T/nl" && _shmutant_abs "x
" ); rc_is $? 1 'a name ending in a newline is refused rather than resolved to its sibling'
  # the sibling destination is left EMPTY: were the newline trimmed, the copy would land there
  # and be accepted, which is what the check below would see
  mkdir -p "$T/nl/src"; printf 'x\n' > "$T/nl/src/f"; mkdir -p "$T/nl/dst"
  shmutant_copy_tree "$T/nl/src" "$T/nl/dst
" 2>/dev/null; rc_is $? 1 'a copy destination ending in a newline is refused'
  [ -e "$T/nl/dst/f" ] && fail_ 'the copy landed on the sibling without the newline'
  shmutant_copy_tree "$T/nl/src
" "$T/nl/dst2" 2>/dev/null; rc_is $? 1 'a copy source ending in a newline is refused'
  mk_toy "$T/toy"; TOY="$T/toy"; shmutant_reset; shmutant_target lib.sh; shmutant_mut 'a' 'a' 'b' 'w'
  printf 'sibling\n' > "$T/stream"
  ( SHMUTANT_STREAM="$T/stream
" shmutant_pool lbl "$T/wd" toy_prepare toy_run > /dev/null 2>"$T/e" ); rc_is $? 2 'a stream path ending in a newline is refused'
  has "$(cat "$T/e")" 'newline' 'says why'
  eq "$(cat "$T/stream")" sibling 'and the sibling stream was not written to'
  cd() { builtin cd "$@" && echo LISTING; }; pwd() { echo SHADOW; }
  got="$(_shmutant_abs "$T/here/sub")"; unset -f cd pwd
  eq "$got" "$(cd "$T/here/sub" && pwd -P)" 'a caller'"'"'s cd or pwd function does not stand in for the builtins'
}

t_pool_refuses_a_workdir_it_did_not_create_entries_in() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # a caller's own pristine directory under the workdir, with no shmutant marker
  mkdir -p "$T/wd/pristine"; printf 'mine\n' > "$T/wd/pristine/precious"
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a workdir holding a pristine that shmutant did not create is refused'
  has "$ERR" 'not created by shmutant' 'says why'
  eq "$(cat "$T/wd/pristine/precious")" mine 'and the caller'"'"'s directory was not emptied'
  mkdir -p "$T/wd2/mut-3"; printf 'x\n' > "$T/wd2/mut-3/keep"
  ( set -f; shopt -s failglob; shmutant_pool lbl "$T/wd2" toy_prepare toy_run > /dev/null 2>&1 ); rc_is $? 2 'a mut-N of the caller'"'"'s is refused too, whatever the caller'"'"'s glob options'
  [ -e "$T/wd2/mut-3/keep" ] || fail_ 'the caller'"'"'s entry was removed'
  pool lbl "$T/wd3" toy_prepare toy_run
  rc_is "$RC" 0 'an empty workdir is marked and used'
  [ -e "$T/wd3/.shmutant" ] || fail_ 'the marker was not written'
  pool lbl "$T/wd3" toy_prepare toy_run
  rc_is "$RC" 0 'and a marked workdir is reused'
  mkdir -p "$T/wd4/.shmutant" "$T/wd4/pristine"; printf 'mine\n' > "$T/wd4/pristine/precious"
  pool lbl "$T/wd4" toy_prepare toy_run
  rc_is "$RC" 2 'a directory named .shmutant is not the marker'
  eq "$(cat "$T/wd4/pristine/precious")" mine 'and the caller'"'"'s pristine stayed'
  mkdir -p "$T/wd5/pristine"; ln -s "$T/nowhere" "$T/wd5/.shmutant"
  pool lbl "$T/wd5" toy_prepare toy_run
  rc_is "$RC" 2 'a symlink named .shmutant is not the marker'
}

t_target_refuses_a_newline() {
  shmutant_reset; SHMUTANT_DECL_ERRORS=0
  shmutant_target "d
/lib.sh" 2>/dev/null; rc_is $? 2 'a target path with a newline is refused at declaration'
  eq "$SHMUTANT_DECL_ERRORS" 1 'and counted as a refused declaration'
}

t_pool_refuses_shadowed_builtins_and_posix_mode() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # bounded: a pool that ran with kill neutralised could never end its own helpers
  set -m; ( kill() { :; }; shmutant_pool lbl "$T/wd" toy_prepare toy_run > /dev/null 2>"$T/e"; echo "$?" > "$T/rc" ) 2>/dev/null & local bg=$! i=0; set +m
  until [ -e "$T/rc" ]; do i=$((i + 1)); [ "$i" -lt 100 ] || break; sleep 0.1; done
  [ -e "$T/rc" ] || { kill -KILL -- -"$bg" 2>/dev/null; wait "$bg" 2>/dev/null; fail_ 'a pool with a shadowed kill ran instead of being refused'; return; }
  wait "$bg" 2>/dev/null
  eq "$(cat "$T/rc")" 2 'a function named kill is refused'
  has "$(cat "$T/e")" 'is not the builtin' 'says why'
  ( set -o posix; shmutant_pool lbl "$T/wd" toy_prepare toy_run > /dev/null 2>"$T/e" ); rc_is $? 2 'POSIX mode is refused'
  ( exit() { :; }; shmutant_pool lbl "$T/wd" toy_prepare toy_run > /dev/null 2>"$T/e5" ); rc_is $? 2 'a function named exit is refused'
  # bounded: a pool that ran with wait disabled could spin or hang
  set -m; ( enable -n wait; shmutant_pool lbl "$T/wd" toy_prepare toy_run > /dev/null 2>"$T/e6"; echo "$?" > "$T/rc6" ) 2>/dev/null & bg=$!; set +m; i=0
  until [ -e "$T/rc6" ]; do i=$((i + 1)); [ "$i" -lt 100 ] || break; sleep 0.1; done
  [ -e "$T/rc6" ] || { kill -KILL -- -"$bg" 2>/dev/null; wait "$bg" 2>/dev/null; fail_ 'a pool with wait disabled ran instead of being refused'; return; }
  wait "$bg" 2>/dev/null
  eq "$(cat "$T/rc6")" 2 'a wait disabled with enable is refused'
  has "$(cat "$T/e6")" 'is not the builtin' 'says why'
  has "$(cat "$T/e5")" 'is not the builtin' 'says why'
  # a shadow prepare introduces is caught before any worker relies on the builtin
  shadowing_kill_prepare() { toy_prepare "$1"; kill() { :; }; }
  set -m; ( shmutant_pool lbl "$T/wd" shadowing_kill_prepare toy_run > /dev/null 2>"$T/e4"; echo "$?" > "$T/rc2" ) 2>/dev/null & bg=$!; set +m; i=0
  until [ -e "$T/rc2" ]; do i=$((i + 1)); [ "$i" -lt 100 ] || break; sleep 0.1; done
  [ -e "$T/rc2" ] || { kill -KILL -- -"$bg" 2>/dev/null; wait "$bg" 2>/dev/null; fail_ 'a pool whose prepare shadowed kill ran instead of being refused'; return; }
  wait "$bg" 2>/dev/null
  eq "$(cat "$T/rc2")" 2 'a kill function defined by prepare is refused after prepare'
  has "$(cat "$T/e4")" 'is not the builtin' 'says why'
  has "$(cat "$T/e")" 'POSIX mode' 'says why'
  # a punctuation builtin the harness relies on: the shadow check names it (the pool's own
  # arity guard, which uses [, would refuse a [ shadow first, so the check is exercised directly)
  ( eval '[() { :; }'; _shmutant_no_shadows lbl 2>"$T/e7" ); rc_is $? 2 'a function named [ is refused by the shadow check'
  has "$(cat "$T/e7")" 'is not the builtin' 'says why'
  # a CHLD trap prepare installs fires at most four times after prepare returns (the forks that
  # save the four held traps): every later fork the pool makes, through the shadow recheck and
  # the workers, runs with it held, so a handler cannot define a shadow after the recheck
  # cleared the name. A count is deterministic where catching the race is not.
  : > "$T/chld"
  counting_chld_prepare() { toy_prepare "$1"; trap 'echo x >> "$T/chld"' CHLD; }
  ( SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" counting_chld_prepare toy_run > "$T/chld-out" 2>&1; rc=$?; trap - CHLD
    fires="$(grep -c x "$T/chld" 2>/dev/null || echo 0)"
    [ "$rc" -eq 0 ] || { echo "FAIL: $_unit: the pool failed ($rc) under a CHLD trap prepare installed: $(cat "$T/chld-out")"; exit 1; }
    [ "$fires" -le 4 ] || { echo "FAIL: $_unit: a CHLD trap prepare installed fired $fires times after prepare returned"; exit 1; }
    exit 0 ) || _failed=1
  # a DEBUG trap prepare leaves (with functrace, so it reaches every function and subshell)
  # runs before each of the few commands that save the traps and nothing past them: with it
  # armed it would run before every command of the pool and its workers (thousands)
  : > "$T/dbg"
  debug_prepare() { toy_prepare "$1"; set -T; trap 'echo "$BASH_COMMAND" >> "$T/dbg"' DEBUG; }
  ( SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd-dbg" debug_prepare toy_run > "$T/dbg-out" 2>&1; rc=$?; trap - DEBUG; set +T
    fires="$(grep -c . "$T/dbg" 2>/dev/null || echo 0)"
    [ "$rc" -eq 0 ] || { echo "FAIL: $_unit: the pool failed ($rc) under a DEBUG trap prepare left: $(cat "$T/dbg-out")"; exit 1; }
    [ "$fires" -le 40 ] || { echo "FAIL: $_unit: a DEBUG trap prepare left ran $fires times after prepare returned"; exit 1; }
    # and once handed back, the first command it sees is the pool's return: every other command
    # of the pool, the other traps' restoration included, ran before it was handed back
    after="$(awk 'found { print; exit } /^trap - CHLD DEBUG RETURN ERR$/ { found = 1 }' "$T/dbg")"
    [ "$after" = 'return "$rc"' ] || { echo "FAIL: $_unit: the first command a DEBUG trap saw once handed back was [$after], not the pool's return"; exit 1; }
    exit 0 ) || _failed=1
  # utilities are reached through command -p: a plan's function or a PATH prepare set to the
  # tree's bin does not stand in for ps, awk or ls
  shadowing_prepare() { toy_prepare "$1"; mkdir -p "$1/bin"; printf '#!/bin/sh\necho "1 1"\n' > "$1/bin/awk"; printf '#!/bin/sh\nexit 0\n' > "$1/bin/ps"; chmod +x "$1/bin/awk" "$1/bin/ps"; PATH="$1/bin:$PATH"; }
  awk() { echo "1 1"; }; ls() { :; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" shadowing_prepare toy_run
  unset -f awk ls
  rc_is "$RC" 0 'killed'
  eq "$(verdict_of a)" killed 'the verdict came from the real awk and ls'
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'b' '$1 + $2' '$1 * $2' 'even-works' 'add-works'
  awk() { echo "1 1"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" shadowing_prepare toy_run
  unset -f awk
  eq "$(verdict_of b)" accidental 'a shadowing awk that claims every witness was not consulted: red without its witness stays accidental'
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

t_verdict_scan_takes_literals_as_bytes() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  # a witness and a prefix that carry backslash escapes must match the bytes, not the escape
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add\nworks'
  escaping_run() { bash "$1/test.sh" > /dev/null 2>&1; echo 'RED\t: add\nworks here'; return 1; }
  SHMUTANT_BASELINE=0 SHMUTANT_RED_PREFIX='RED\t: ' pool lbl "$T/wd" toy_prepare escaping_run
  eq "$(verdict_of a)" killed 'a prefix and witness holding a literal backslash-t and backslash-n match the same bytes in the output'
}

t_witness_matches_a_whole_token() {
  # a witness is carried only as a whole token: a label that extends it is another assertion
  local fd
  scan() { exec {fd}< <(printf '%s\n' "$1"); _shmutant_scan_output "$fd" 'FAIL: ' "$2"; exec {fd}<&-; }
  scan 'FAIL: t_parse: parse-empty-list: got []' parse-empty
  eq "$SHMUTANT_RUN_RED$SHMUTANT_RUN_WITNESSED" 10 'a label that extends the witness with a hyphen does not carry it'
  scan 'FAIL: t_x: foobar' foo
  eq "$SHMUTANT_RUN_RED$SHMUTANT_RUN_WITNESSED" 10 'a label that extends the witness with a letter does not carry it'
  scan 'FAIL: t_x: xfoo' foo
  eq "$SHMUTANT_RUN_RED$SHMUTANT_RUN_WITNESSED" 10 'a label the witness ends does not carry it'
  scan 'FAIL: t_x: foo.sub: y' foo
  eq "$SHMUTANT_RUN_RED$SHMUTANT_RUN_WITNESSED" 10 'a dotted extension does not carry it'
  scan 'FAIL: t_parse: parse-empty: got []' parse-empty
  eq "$SHMUTANT_RUN_RED$SHMUTANT_RUN_WITNESSED" 11 'the witness followed by a colon is carried'
  scan 'FAIL: parse-empty' parse-empty
  eq "$SHMUTANT_RUN_RED$SHMUTANT_RUN_WITNESSED" 11 'the witness at the end of the line is carried'
  scan 'FAIL: t_x: foobar then foo here' foo
  eq "$SHMUTANT_RUN_RED$SHMUTANT_RUN_WITNESSED" 11 'a later whole-token occurrence is found past an extended one'
  scan 'FAIL: t_x: [foo]' '[foo]'
  eq "$SHMUTANT_RUN_RED$SHMUTANT_RUN_WITNESSED" 11 'a witness with its own punctuation is carried'
  # a scan that produced nothing (its descriptor cannot be read) is not a green run
  _shmutant_scan_output 199 'FAIL: ' foo 2>/dev/null
  eq "${SHMUTANT_RUN_SCAN_FAILED:-unset}" 1 'a scan whose descriptor cannot be read reports failure, not green'
  eq "$SHMUTANT_RUN_RED$SHMUTANT_RUN_WITNESSED" 00 'and asserts nothing'
  # and the pool makes it a harness error, not a survivor
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  ( _shmutant_scan_output() { SHMUTANT_RUN_RED=0; SHMUTANT_RUN_WITNESSED=0; SHMUTANT_RUN_SCAN_FAILED=1; }
    SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" toy_prepare toy_run > "$T/out" 2> "$T/err" ); rc_is $? 2 'a run whose output could not be scanned is a harness error'
  has "$(cat "$T/err")" 'could not be scanned' 'says why'
  case "$(cat "$T/out")" in *survived*) fail_ 'an unscanned run was scored a survivor' ;; esac
}

t_pool_refuses_a_modified_pristine_tree() {
  # a callback that writes into the pristine tree after prepare (through ../../pristine from its
  # clone) is not cloned from again: every later row is unprepared and says why
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  shmutant_mut 'b' '$1 + $2' '$1 * $2' 'add-works'
  writing_run() { printf '\n# scribble\n' >> "$1/../../pristine/lib.sh"; bash "$1/test.sh"; }
  SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare writing_run
  eq "$(verdict_of a)" killed 'the first row ran before the tree was touched'
  eq "$(verdict_of b)" unprepared 'a row after a callback wrote into pristine is not cloned'
  has "$ERR" 'modified after prepare' 'says why'
  deleting_run() { rm -f "$1/../../pristine/test.sh"; bash "$1/test.sh"; }
  SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 pool lbl "$T/wd2" toy_prepare deleting_run
  eq "$(verdict_of b)" unprepared 'a row after a callback removed from pristine is not cloned'
  # reading pristine, and a prepared file dated in the future, are not modifications
  touch -t 203001010000 "$T/toy/lib.sh"
  reading_run() { cat "$1/../../pristine/lib.sh" > /dev/null; bash "$1/test.sh"; }
  SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 pool lbl "$T/wd3" toy_prepare reading_run
  rc_is "$RC" 0 'a callback that only reads pristine, with a future-dated file in it, is fine'
  eq "$(verdict_of b)" killed 'and every row is cloned'
  # a write to a file that was ALREADY newer than the stamp (future-dated) is still seen: the
  # fingerprint is content and metadata, not the set of newer paths
  SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 pool lbl "$T/wd4" toy_prepare writing_run
  eq "$(verdict_of b)" unprepared 'a write to a future-dated pristine file is seen'
  chmodding_run() { chmod 600 "$1/../../pristine/lib.sh"; bash "$1/test.sh"; }
  SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 pool lbl "$T/wd5" toy_prepare chmodding_run
  eq "$(verdict_of b)" unprepared 'a mode change in pristine (content and mtime unchanged) is seen'
  # a same-size content change written in place (no entry made or removed in pristine, so its
  # directory's mtime stands) with the file's timestamp put back: only the content sees it
  forging_run() { local f="$1/../../pristine/lib.sh"; sed 's/\$1 + \$2/$1 - $2/' "$f" > "$T/forged" && cat "$T/forged" > "$f"; touch -t 203001010000 "$f"; bash "$1/test.sh"; }
  SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 pool lbl "$T/wd6" toy_prepare forging_run
  eq "$(verdict_of b)" unprepared 'a same-size write with its timestamp forged back is seen by content'
  # a write between a worker's check of pristine and its copy (a concurrent callback), put back
  # before the next check: the CLONE is checked against the recorded state after the copy
  ( eval "$(declare -f _shmutant_pristine_state | sed '1s/_shmutant_pristine_state/_shmutant_pristine_state_real/')"
    # the write lands on the SECOND look at pristine: the first is the pool's own record of it
    _shmutant_pristine_state() { local out; out="$(_shmutant_pristine_state_real "$@")" || return 1; case "$1" in */pristine) echo x >> "$T/looks"; [ "$(grep -c x "$T/looks")" -eq 2 ] && printf '\n# raced\n' >> "$1/lib.sh" ;; esac; printf '%s' "$out"; }
    SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd7" toy_prepare toy_run > "$T/out7" 2>"$T/err7" )
  has "$(cat "$T/out7")" $'\trow\tunprepared\ta\t' 'a clone taken while a callback wrote into pristine is not run'
  has "$(cat "$T/err7")" 'during the copy' 'says why'
  # the prepared root's own mode and mtime are in the fingerprint: a callback that changes
  # them (no inode, no descendant touched) is seen
  root_chmod_run() { chmod 700 "$1/../../pristine"; bash "$1/test.sh"; }
  SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 pool lbl "$T/wd10" toy_prepare root_chmod_run
  eq "$(verdict_of b)" unprepared 'a mode change on the prepared root is seen'
  root_touch_run() { touch -t 203001010000 "$1/../../pristine"; bash "$1/test.sh"; }
  SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 pool lbl "$T/wd11" toy_prepare root_touch_run
  eq "$(verdict_of b)" unprepared 'a timestamp change on the prepared root is seen'
  # a regular file the pool cannot read makes the fingerprint fail, and the pool refuse
  if [ "$(id -u)" -ne 0 ]; then
    unreadable_prepare() { toy_prepare "$1"; printf 'secret\n' > "$1/unreadable"; chmod 000 "$1/unreadable"; }
    SHMUTANT_BASELINE=0 pool lbl "$T/wd8" toy_prepare toy_run
    rc_is "$RC" 0 'fixture: the pool runs before the unreadable file is added'
    SHMUTANT_BASELINE=0 pool lbl "$T/wd9" unreadable_prepare toy_run
    rc_is "$RC" 2 'a prepared tree holding a file whose content cannot be fingerprinted is refused, not passed over'
    has "$ERR" 'cannot fingerprint' 'says why'
    chmod 600 "$T/wd9/pristine/unreadable" 2>/dev/null
  fi
}

t_readonly_settings_do_not_kill_the_caller() {
  # a caller that made a setting readonly: accepted when already canonical, refused otherwise —
  # never assigned, which would end a non-interactive caller's shell
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  ( readonly SHMUTANT_TIMEOUT=5; SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" toy_prepare toy_run > "$T/o" 2>/dev/null; echo "rc=$?" >> "$T/o" )
  has "$(cat "$T/o")" 'rc=0' 'a readonly setting already in canonical form is accepted and the caller shell survives'
  has "$(cat "$T/o")" $'\trow\tkilled\ta\t' 'and the pool ran'
  ( readonly SHMUTANT_TIMEOUT=05; SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd2" toy_prepare toy_run > /dev/null 2>"$T/e"; echo "rc=$?" > "$T/o2" )
  has "$(cat "$T/o2")" 'rc=2' 'a readonly setting not in canonical form is refused with status 2, and the caller shell survives'
  has "$(cat "$T/e")" 'readonly' 'says why'
  # shellcheck disable=SC2034
  ( readonly SHMUTANT_JOBS=2 SHMUTANT_RED_STATUS=1; SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd3" toy_prepare toy_run > "$T/o3" 2>/dev/null; echo "rc=$?" >> "$T/o3" )
  has "$(cat "$T/o3")" 'rc=0' 'readonly jobs and red status in canonical form are accepted'
  ( readonly SHMUTANT_SELECT=stale; SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd-sel" toy_prepare toy_run > /dev/null 2>"$T/e-sel"; echo "rc=$?" > "$T/o-sel" )
  has "$(cat "$T/o-sel")" 'rc=2' 'a readonly SHMUTANT_SELECT is refused before any worker starts'
  has "$(cat "$T/e-sel")" 'SHMUTANT_SELECT is readonly' 'says why'
  local phys; phys="$(cd "$T" && pwd -P)"
  ( readonly SHMUTANT_STREAM="$phys/ro.tsv"; SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd4" toy_prepare toy_run > /dev/null 2>/dev/null; echo "rc=$?" > "$T/o4" )
  has "$(cat "$T/o4")" 'rc=0' 'a readonly absolute physical stream path is accepted and the caller shell survives'
  has "$(cat "$phys/ro.tsv")" $'\trow\tkilled\ta\t' 'and the records went to it'
  ( cd "$T" && readonly SHMUTANT_STREAM=rel.tsv && SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd5" toy_prepare toy_run > /dev/null 2>"$T/e5"; echo "rc=$?" > "$T/o5" )
  has "$(cat "$T/o5")" 'rc=2' 'a readonly relative stream path is refused with status 2, not assigned'
  has "$(cat "$T/e5")" 'readonly' 'says why'
}

t_pool_refuses_alias_only_callbacks() {
  # a callback name defined only as an alias cannot be called by variable: refused up front,
  # not run into 127 and reported as mutation results
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # shellcheck disable=SC2262
  ( shopt -s expand_aliases; alias aliased_run='toy_run'
    SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" toy_prepare aliased_run > /dev/null 2>"$T/e"; echo "rc=$?" > "$T/rc" )
  has "$(cat "$T/rc")" 'rc=2' 'an alias-only run callback is a harness error'
  has "$(cat "$T/e")" 'run callback not found' 'says why'
  # shellcheck disable=SC2262
  ( shopt -s expand_aliases; alias aliased_prep='toy_prepare'
    SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd2" aliased_prep toy_run > /dev/null 2>"$T/e2"; echo "rc=$?" > "$T/rc2" )
  has "$(cat "$T/rc2")" 'rc=2' 'an alias-only prepare callback is a harness error'
  has "$(cat "$T/e2")" 'prepare callback not found' 'says why'
}

t_rewrite_is_pinned_against_a_sibling_swap() {
  # between the containment check and the rewrite, a concurrent sibling's callback swaps the
  # target's directory for a link to a caller-owned directory: the rewrite, pinned to the
  # directory it checked and naming the target by base name, does not follow it
  mk_toy "$T/toy"; TOY="$T/toy"; mkdir -p "$T/toy/sub" "$T/victim"; printf 'x=1\n' > "$T/toy/sub/extra.sh"; printf 'precious\n' > "$T/victim/extra.sh"
  shmutant_reset; shmutant_target sub/extra.sh
  shmutant_mut 'a' 'x=1' 'x=2' 'add-works'
  ( eval "$(declare -f _shmutant_target_ok | sed '1s/_shmutant_target_ok/_shmutant_target_ok_real/')"
    # the swap only in a clone (the pool also checks the table against pristine)
    _shmutant_target_ok() { _shmutant_target_ok_real "$@" || return 1; case "$1" in */tree*) rm -rf "$1/sub"; ln -s "$T/victim" "$1/sub" ;; esac; }
    SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" toy_prepare toy_run > "$T/out" 2>"$T/err" )
  eq "$(cat "$T/victim/extra.sh")" precious 'a directory swapped for a link after the check is not rewritten through'
  has "$(cat "$T/out")" $'\trow\tunprepared\ta\t' 'the row is unprepared'
  has "$(cat "$T/err")" 'left the tree' 'says why'
}

t_cli_abort_waits_for_the_child_and_names_its_identity() {
  # a signal that lands between the plan subshell's spawn and its registration is held, then
  # acted on once the child is known; and the escalation names the child with the identity
  # taken at the spawn, never by number alone
  local out
  out="$(SHMUTANT="$SHMUTANT" bash -c '. "$SHMUTANT"; SHMUTANT_CLI_SPAWNING=1; _shmutant_cli_abort TERM; echo "pending=$SHMUTANT_CLI_ABORT_PENDING alive"' 2>/dev/null)"
  eq "$out" 'pending=TERM alive' 'a signal during the spawn window is recorded, not acted on'
  out="$(SHMUTANT="$SHMUTANT" bash -c '. "$SHMUTANT"; sleep 30 & SHMUTANT_CLI_CHILD=$!; SHMUTANT_CLI_CHILD_ID="$(_shmutant_identity "$!")"; _shmutant_kill_tree_twice() { printf "%s\n" "$1"; }; _shmutant_cli_abort TERM' 2>/dev/null)"
  case "$out" in [0-9]*:[0-9]*) ;; *) fail_ "the CLI abort escalated with [$out], not pid:identity" ;; esac
}

t_mutate_takes_a_bare_relative_target_as_a_path() {
  # the worker rewrites a target by its base name in a pinned directory: to awk a bare `-` is
  # standard input and `x=1` an assignment, so a bare name is made a path first
  mkdir -p "$T/bare"; printf 'a=1\n' > "$T/bare/-"; printf 'a=1\n' > "$T/bare/x=1"
  ( cd "$T/bare" && shmutant_mutate - 'a=1' 'a=2' < /dev/null ); rc_is $? 0 'a target named - is rewritten'
  eq "$(cat "$T/bare/-")" a=2 'as a file, not standard input'
  ( cd "$T/bare" && shmutant_mutate x=1 'a=1' 'a=3' < /dev/null ); rc_is $? 0 'a target named like an assignment is rewritten'
  eq "$(cat "$T/bare/x=1")" a=3 'as a file'
}

t_stream_altered_in_place_is_reported() {
  # a callback that truncates, overwrites or appends to the SHMUTANT_STREAM file in place (same
  # inode) is seen: the pool checks the stream past what was there when opened against its own
  # private copy of the records
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  printf 'earlier\n' > "$T/s.tsv"
  ( SHMUTANT_STREAM="$T/s.tsv" SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" toy_prepare toy_run > /dev/null 2>"$T/e"; echo "rc=$?" > "$T/rc" )
  has "$(cat "$T/rc")" 'rc=0' 'an untouched stream with earlier content passes'
  has "$(head -n 1 "$T/s.tsv")" earlier 'and the earlier content is kept'
  # truncated after the baseline record went out: that record is gone from the file
  truncating_run() { : > "$SHMUTANT_STREAM"; bash "$1/test.sh"; }
  ( SHMUTANT_STREAM="$T/s2.tsv" SHMUTANT_BASELINE=1 shmutant_pool lbl "$T/wd2" toy_prepare truncating_run > /dev/null 2>"$T/e2"; echo "rc=$?" > "$T/rc2" )
  has "$(cat "$T/rc2")" 'rc=2' 'a stream truncated in place by a callback is a harness error'
  has "$(cat "$T/e2")" 'truncated, overwritten or appended' 'says why'
  appending_run() { printf 'shmutant\t1\trow\tkilled\tfake\tlib.sh\tx\t0\tplanted\n' >> "$SHMUTANT_STREAM"; bash "$1/test.sh"; }
  ( SHMUTANT_STREAM="$T/s3.tsv" SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd3" toy_prepare appending_run > /dev/null 2>"$T/e3"; echo "rc=$?" > "$T/rc3" )
  has "$(cat "$T/rc3")" 'rc=2' 'a record a callback appended to the stream is a harness error'
}

t_cli_removes_only_the_workdir_it_created_by_identity() {
  # a plan whose prepare moves the automatic workdir away and puts a caller directory at its
  # path: the pool refuses to go on, and neither the normal nor the interrupted cleanup removes
  # what now sits there
  mk_toy "$T/toy"; TOY="$T/toy"
  mkdir -p "$T/toy/victim"; printf 'precious\n' > "$T/toy/victim/keep"
  cat > "$T/toy/plan-swap.sh" <<'EOF'
prepare() { printf '%s' "$SHMUTANT_CLI_WD" > "$SHMUTANT_PLAN_DIR/wdpath"; mv "$SHMUTANT_CLI_WD" "$SHMUTANT_CLI_WD.moved" && mv "$SHMUTANT_PLAN_DIR/victim" "$SHMUTANT_CLI_WD"; shmutant_copy_tree "$SHMUTANT_PLAN_DIR" "$1"; }
run() { bash "$1/test.sh"; }
shmutant_target lib.sh
shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
EOF
  mkdir -p "$T/tmpd"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-swap.sh" --no-baseline > /dev/null 2>"$T/e"; rc_is $? 2 'a workdir prepare replaced is a harness error'
  local wd; wd="$(cat "$T/toy/wdpath" 2>/dev/null)"
  [ -n "$wd" ] || fail_ 'fixture: the plan did not record the workdir path'
  [ -f "$wd/keep" ] || fail_ 'the caller directory put at the automatic workdir path was removed'
  has "$(cat "$T/e")" 'no longer the directory this pool marked' 'the pool says why'
  has "$(cat "$T/e")" 'no longer the workdir this run created' 'the CLI says why it left it'
  rm -rf "$T/tmpd"; mkdir -p "$T/tmpd" "$T/toy/victim"; printf 'precious\n' > "$T/toy/victim/keep"
  # the same swap during a prepare that is then interrupted
  sed 's/shmutant_copy_tree "\$SHMUTANT_PLAN_DIR" "\$1"; }/: > "$SHMUTANT_PLAN_DIR\/swapped"; sleep 5; shmutant_copy_tree "$SHMUTANT_PLAN_DIR" "$1"; }/' "$T/toy/plan-swap.sh" > "$T/toy/plan-swap-slow.sh"
  grep -q 'swapped' "$T/toy/plan-swap-slow.sh" || fail_ 'fixture: the slow plan was not derived'
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-swap-slow.sh" --no-baseline > /dev/null 2>"$T/e2" & local cli=$!
  wait_for "$T/toy/swapped" || fail_ 'fixture: the slow prepare never swapped'
  kill -TERM "$cli"; wait "$cli" 2>/dev/null
  wd="$(cat "$T/toy/wdpath" 2>/dev/null)"
  [ -f "$wd/keep" ] || fail_ 'the interrupted cleanup removed the caller directory at the automatic workdir path'
  has "$(cat "$T/e2")" 'no longer the workdir this run created' 'the interrupted CLI says why it left it'
}

t_pool_leaves_a_replaced_workdir_alone() {
  # prepare moves the workdir away and puts a caller directory at its path: whether prepare
  # then fails (a non-empty pristine there) or succeeds, nothing at that path is removed — the
  # prepared tree is removed only from the directory the pool marked, and a readonly
  # SHMUTANT_KEEP changes nothing about that
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  swap_prepare() { local w="${1%/pristine}"; mv "$w" "$w.moved" && mv "$T/victim" "$w"; shmutant_copy_tree "$TOY" "$1"; }
  mkdir -p "$T/victim/pristine"; printf 'precious\n' > "$T/victim/pristine/keep"
  mkdir -p "$T/wd"; SHMUTANT_BASELINE=0 pool lbl "$T/wd" swap_prepare toy_run
  rc_is "$RC" 2 'a prepare that failed in a replaced workdir is a harness error'
  [ -f "$T/wd/pristine/keep" ] || fail_ 'the caller directory at the workdir path lost its pristine entry after a failed prepare'
  mkdir -p "$T/victim/pristine"; printf 'precious\n' > "$T/victim/keep"
  mkdir -p "$T/wd2"; SHMUTANT_BASELINE=0 pool lbl "$T/wd2" swap_prepare toy_run
  rc_is "$RC" 2 'a workdir prepare replaced stops the pool'
  has "$ERR" 'no longer the directory this pool marked' 'says why'
  [ -f "$T/wd2/keep" ] && [ -d "$T/wd2/pristine" ] || fail_ 'the caller directory at the workdir path was emptied after prepare succeeded'
  mkdir -p "$T/victim/pristine"; printf 'precious\n' > "$T/victim/pristine/keep"
  mkdir -p "$T/wd3"
  # shellcheck disable=SC2034
  ( readonly SHMUTANT_KEEP=0; SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd3" swap_prepare toy_run > /dev/null 2>"$T/e3"; echo "rc=$?" > "$T/o3" )
  has "$(cat "$T/o3")" 'rc=2' 'with a readonly SHMUTANT_KEEP the pool still stops, and the caller shell survives'
  [ -f "$T/wd3/pristine/keep" ] || fail_ 'with a readonly SHMUTANT_KEEP the caller directory at the workdir path lost its pristine entry'
}

t_rewrite_refuses_a_worker_directory_swapped_after_the_clone() {
  # after the clone was checked, a sibling's callback renames this worker's directory away and
  # puts an ordinary directory with a matching target path there: the rewrite, pinned to the
  # worker's directory by identity before it descends, does not touch the replacement
  mk_toy "$T/toy"; TOY="$T/toy"; mkdir -p "$T/toy/sub"; printf 'x=1\n' > "$T/toy/sub/extra.sh"
  shmutant_reset; shmutant_target sub/extra.sh
  shmutant_mut 'a' 'x=1' 'x=2' 'add-works'
  ( eval "$(declare -f _shmutant_target_ok | sed '1s/_shmutant_target_ok/_shmutant_target_ok_real/')"
    _shmutant_target_ok() { _shmutant_target_ok_real "$@" || return 1; case "$1" in */tree*) local d="${1%/tree*}"; printf '%s' "$d" > "$T/dpath"; mv "$d" "$d.moved"; mkdir -p "$d/tree/sub"; printf 'x=1\n' > "$d/tree/sub/extra.sh" ;; esac; }
    SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" toy_prepare toy_run > "$T/out" 2>"$T/err" )
  local d; d="$(cat "$T/dpath" 2>/dev/null)"; [ -n "$d" ] || fail_ 'fixture: the swap never happened'
  eq "$(cat "$d/tree/sub/extra.sh")" x=1 'the replacement directory at the worker path was not rewritten'
  case "$(cat "$T/out")" in *$'\trow\tkilled\ta\t'*) fail_ 'the row was scored killed on a rewrite of a replacement directory' ;; esac
  rm -rf "$d" "$d.moved"
}

t_target_through_a_link_chain_to_an_absolute_link_is_refused() {
  # a relative link to an absolute in-tree link: the chain is followed, and the table refused
  # before any worker runs, not reported unprepared afterwards
  mk_toy "$T/toy"; TOY="$T/toy"
  chain_prepare() { toy_prepare "$1"; mkdir -p "$1/real"; cp "$1/lib.sh" "$1/real/lib.sh"; ln -s "$1/real" "$1/b"; ln -s b "$1/a"; }
  shmutant_reset; shmutant_target a/lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" chain_prepare toy_run
  rc_is "$RC" 2 'a target reached through a relative link to an absolute in-tree link is refused up front'
  has "$ERR" 'absolute one' 'says why'
  case "$OUT" in *$'\trow\t'*) fail_ 'a row ran on a refused table' ;; esac
}

t_public_helpers_are_immune_to_aliases_at_run_time() {
  # bash parses a command substitution when it runs: with expand_aliases on in the caller's
  # shell, a `$(printf …)` inside the library would expand the caller's alias at run time. Each
  # public entry point turns the option off for its duration and puts it back. In a separate
  # bash, in its own process group and bounded: a shell that hits a run-time parse error exits
  # (and must not take this runner's EXIT trap with it), and one whose path resolution spins on
  # aliased output never returns (`timeout` is not portable, so the bound is a poll).
  mkdir -p "$T/src/sub"; printf 'x=1\n' > "$T/src/f"; printf 'x=1\n' > "$T/src/sub/g"
  : > "$T/alias-out"
  set -m
  ( SHMUTANT="$SHMUTANT" T="$T" bash -c '
    . "$SHMUTANT"; shopt -s expand_aliases; alias printf="echo ALIASED"; alias command="echo ALIASED"; alias ls="echo ALIASED"
    shmutant_copy_tree "$T/src" "$T/dst" 2>&1 || { echo "copy rc=$?"; exit 1; }
    shopt -q expand_aliases || { echo "aliases not put back"; exit 1; }
    shmutant_mutate "$T/dst/f" "x=1" "x=2" 2>&1 || { echo "mutate rc=$?"; exit 1; }
    echo ok' > "$T/alias-out" 2>&1; echo "rc=$?" >> "$T/alias-out" ) 2>/dev/null & local child=$! i=0
  set +m
  until grep -q '^rc=' "$T/alias-out" 2>/dev/null || [ "$i" -ge 600 ]; do i=$((i + 1)); sleep 0.1; done
  grep -q '^rc=' "$T/alias-out" 2>/dev/null || { kill -KILL -- -"$child" 2>/dev/null; wait "$child" 2>/dev/null; fail_ 'copy_tree or mutate under run-time aliases never returned'; return; }
  wait "$child" 2>/dev/null
  has "$(cat "$T/alias-out")" 'rc=0' "copy_tree and mutate run under run-time aliases: [$(cat "$T/alias-out")]"
  has "$(cat "$T/alias-out")" ok 'and the aliased shell survived them'
  [ -f "$T/dst/sub/g" ] || fail_ 'copy_tree under run-time aliases did not copy'
  eq "$(cat "$T/dst/f" 2>/dev/null)" x=2 'mutate under run-time aliases rewrote the file'
}

t_verdict_scans_a_large_output() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # a quarter million lines of chatter before the failure line, and more after it
  chatty_run() { awk 'BEGIN { for (i = 0; i < 250000; i++) print "line", i }'; bash "$1/test.sh"; local rc=$?; awk 'BEGIN { for (i = 0; i < 100000; i++) print "after", i }'; return "$rc"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare chatty_run
  eq "$(verdict_of a)" killed 'the witness line is found in a large output'
  [ "$(wc -l < "$T/wd/mut-0/output" | tr -d ' ')" -gt 350000 ] || fail_ 'the output artifact is not the whole capture'
}

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
  # a callback leaving by a bare `exit` keeps the status of its last command
  bare_exit_run() { bash "$1/test.sh"; exit; }
  pool lbl "$T/wd2" toy_prepare bare_exit_run
  rc_is "$RC" 1 'the pool still fails'
  eq "$(verdict_of 'crashes')" aborted 'a bare exit carried the callback'"'"'s own status through the snapshot'
}

t_verdict_aborted_no_red_line() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'exits 1 silently' 'is_even() {' 'is_even() { exit 1;' 'even-works'
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 1 'exit 1 without a red line fails the pool'
  eq "$(verdict_of 'exits 1 silently')" aborted 'verdict is aborted'
  has "$ERR" 'no [FAIL: ] line' 'says no red line was printed'
  # the prefix must start the line: a mention of it elsewhere is not a failure line
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'mentions the prefix' 'is_even() {' 'is_even() { echo "note: FAIL: even-works is mentioned, not failed"; exit 1;' 'even-works'
  pool lbl "$T/wd2" toy_prepare toy_run
  eq "$(verdict_of 'mentions the prefix')" aborted 'a line that carries the prefix mid-line is not a red line'
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
  [ -z "$(ps -A -o args= | grep -F "touch '$T/finished'" | grep -v grep)" ] || fail_ 'a process of the run is still there (frozen or alive) after the timeout was scored'
}

t_verdict_timeout_kills_an_escaped_process_group() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'hangs' '$1 + $2' '$1 - $2' 'add-works'
  escaping_run() { set -m; bash -c "sleep 4; touch '$T/finished'" & wait; }
  SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=1 pool lbl "$T/wd" toy_prepare escaping_run
  eq "$(verdict_of 'hangs')" timeout 'verdict is timeout'
  sleep 4
  [ -e "$T/finished" ] && fail_ 'a descendant in its own process group outlived the timeout'
  ( sleep 3 & sleep 3 & wait ) & local p=$!
  sleep 0.3
  eq "$(_shmutant_descendants "$p" | wc -l | tr -d ' ')" 2 'the descendant walk finds both children'
  kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
}

t_verdict_timeout_kills_a_reparented_term_ignoring_descendant() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'hangs' '$1 + $2' '$1 - $2' 'add-works'
  # own process group AND ignores TERM: the leader dies to TERM, this one is reparented, and only
  # the pid set captured before TERM can still name it for KILL.
  # Two of them: with one, even an unsplit pid list is still one valid pid.
  stubborn_escaping_run() { set -m; bash -c "trap '' TERM; sleep 4; touch '$T/finished'" & bash -c "trap '' TERM; sleep 4; touch '$T/finished2'" & wait; }
  SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=1 pool lbl "$T/wd" toy_prepare stubborn_escaping_run
  eq "$(verdict_of 'hangs')" timeout 'verdict is timeout'
  sleep 4
  [ -e "$T/finished" ] || [ -e "$T/finished2" ] && fail_ 'a reparented TERM-ignoring descendant outlived the KILL escalation'
  rm -f "$T/finished" "$T/finished2"
  ( IFS=''; SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=1 shmutant_pool lbl "$T/wd2" toy_prepare stubborn_escaping_run > /dev/null 2>&1 )
  sleep 4
  [ -e "$T/finished" ] || [ -e "$T/finished2" ] && fail_ 'with the caller IFS empty, the descendant pid list was not split and a descendant survived'
}

t_verdict_timeout_kills_a_descendant_seen_before_it_detached() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'hangs' '$1 + $2' '$1 - $2' 'add-works'
  # The intermediate lives through two watchdog polls then exits, so at the deadline the
  # survivor has ppid 1 and a process group that is not the leader's; only a snapshot taken
  # while it was still attached can name it.
  detaching_run() { set -m; bash -c "bash -c 'sleep 7; touch \"$T/finished\"' & sleep 1.3" & sleep 4; }
  SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=2 pool lbl "$T/wd" toy_prepare detaching_run
  eq "$(verdict_of 'hangs')" timeout 'verdict is timeout'
  sleep 6
  [ -e "$T/finished" ] && fail_ 'a descendant that detached before the deadline outlived the kill'
}

t_settings_take_a_canonical_form() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'crashes' 'is_even() {' 'is_even() { exit 8;' 'even-works'
  SHMUTANT_RED_STATUS=08 pool lbl "$T/wd" toy_prepare toy_run
  eq "$(verdict_of crashes)" aborted 'a red status of 08 is 8'
  has "$ERR" 'exited 8 with no' 'and the explanation compares it as 8, not 08'
  SHMUTANT_JOBS=0002 pool lbl "$T/wd" toy_prepare toy_run
  eq "$(field summary 7)" 2 'the jobs field of the summary is canonical'
}

t_mode_spec_is_immune_to_nocasematch() {
  printf 'x\n' > "$T/f"; chmod 4644 "$T/f"
  ( shopt -s nocasematch; shmutant_mutate "$T/f" x y ); rc_is $? 0 'applies'
  eq "$(ls -l "$T/f" | cut -c1-10)" '-rwSr--r--' 'a set-uid bit without execute stays without execute under a caller'"'"'s nocasematch'
  # the caller's errtrace is not mistaken for errexit and switched to it
  ( shopt -s nocasematch; set -E; shmutant_reset; shmutant_target lib.sh; shmutant_mut 'a' 'a' 'b' 'w'
    mk_toy "$T/toy2"; TOY="$T/toy2"
    shmutant_pool lbl "$T/wd" toy_prepare toy_run > /dev/null 2>&1
    [ -o errexit ] && echo "FAIL: $_unit: a caller with errtrace on came back with errexit on"; exit 0 ) | grep FAIL && _failed=1
  return 0
}

t_library_sources_under_errexit() {
  # a caller with set -e and expand_aliases off (the noninteractive default) must be able to
  # source the library: `shopt -p` returns 1 for an unset option
  bash -c 'set -e; shopt -u expand_aliases; . "$1"; echo sourced' _ "$SHMUTANT" > "$T/out" 2>&1
  has "$(cat "$T/out")" sourced 'the library can be sourced by a caller under set -e'
}

t_library_restores_alias_state_when_refusing_an_old_bash() {
  # the floor refusal path, reached through a copy whose version test always fails
  sed 's/^_shmutant_bash_ok() {$/_shmutant_bash_ok() { return 1; }; _shmutant_bash_ok_never() {/' "$SHMUTANT" > "$T/old.sh"
  bash -c 'shopt -s expand_aliases; . "$1" 2>/dev/null; rc=$?; shopt -q expand_aliases && echo "rc=$rc aliases=on" || echo "rc=$rc aliases=off"' _ "$T/old.sh" > "$T/out" 2>&1
  has "$(cat "$T/out")" 'rc=2 aliases=on' 'an old bash is refused with the caller'"'"'s alias setting put back'
}

t_library_is_immune_to_aliases_at_parse_time() {
  # sourced into a shell whose aliases would otherwise be baked into every function body
  mk_toy "$T/toy"
  # shellcheck disable=SC2262,SC1090
  ( shopt -s expand_aliases; alias cp='cp -i'; alias mkdir='mkdir -v'; alias printf='echo ALIASED'
    . "$SHMUTANT"
    shopt -q expand_aliases || { echo "FAIL: $_unit: the caller's expand_aliases was not put back"; exit 1; }
    shmutant_reset; shmutant_target lib.sh; shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
    prep() { cp -R "$T/toy/." "$1"; }; runit() { bash "$1/test.sh"; }
    SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" prep runit 2>/dev/null | grep -v '^shmutant	' && { echo "FAIL: $_unit: an aliased utility printed into the verdict stream"; exit 1; }
    exit 0 ) < /dev/null || _failed=1
  # shellcheck disable=SC2262,SC1090
  ( shopt -s expand_aliases; alias shopt='echo ALIASED-SHOPT'; alias printf='echo ALIASED'
    . "$SHMUTANT"; builtin shopt -q expand_aliases || { echo "FAIL: $_unit: an aliased shopt broke the restoration"; exit 1; }
    shmutant_reset; shmutant_target lib.sh; shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
    prep() { cp -R "$T/toy/." "$1"; }; runit() { bash "$1/test.sh"; }
    SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd-sh" prep runit 2>/dev/null | grep -q '^shmutant	1	row	killed' || { echo "FAIL: $_unit: with shopt aliased, aliases stayed on while the library was parsed and the pool could not run"; exit 1; }
    exit 0 ) < /dev/null || _failed=1
  # shellcheck disable=SC2262,SC1090
  ( shopt -s expand_aliases; alias cp='cp -i'; . "$SHMUTANT"
    printf 'old\n' > "$T/g"; shmutant_mutate "$T/g" old new ) < /dev/null; rc_is $? 0 'a cp -i alias in the caller does not break the rewrite'
}

t_pool_revalidates_settings_after_prepare() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # shellcheck disable=SC2034
  meddling_prepare() { SHMUTANT_TIMEOUT=bogus; shmutant_copy_tree "$TOY" "$1"; }
  pool lbl "$T/wd" meddling_prepare toy_run
  rc_is "$RC" 2 'a setting prepare invalidated is caught before any worker reads it'
  has "$ERR" 'SHMUTANT_TIMEOUT' 'names the setting'
  unset SHMUTANT_TIMEOUT
  pool lbl "$T/wd" toy_prepare toy_run 0
  rc_is "$RC" 2 'a pool cap of 0 is refused, not replaced by the default'
  pool lbl "$T/wd" toy_prepare toy_run abc
  rc_is "$RC" 2 'a non-numeric pool cap is refused'
  SHMUTANT_RED_PREFIX=$'FAIL:\nx' pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a red prefix containing a newline is refused'
  has "$ERR" 'newline' 'says why'
}

t_pool_bookkeeping_survives_prepare_assignments() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # shellcheck disable=SC2034
  clobbering_prepare() { n=0; label=x; wd=/nowhere; run=nothing; pout=/dev/null; cap=abc; SHMUTANT_JOBS=1; shmutant_copy_tree "$TOY" "$1"; }
  pool lbl "$T/wd" clobbering_prepare toy_run
  rc_is "$RC" 0 'a prepare that assigns n, label, wd, run, pout and cap as its own variables does not derail the pool'
  eq "$(verdict_of a)" killed 'the row still ran'
  eq "$(field summary 4)" lbl 'the label is the pool'"'"'s'
  eq "$(field summary 7)" 1 'SHMUTANT_JOBS assigned by prepare is honoured, so jobs is recomputed after it'
  # shellcheck disable=SC2034
  accumulating_prepare() { rc=1; killed=99; shmutant_copy_tree "$TOY" "$1"; }
  pool lbl "$T/wd2" accumulating_prepare toy_run
  rc_is "$RC" 0 'a prepare that assigns rc=1 does not make a fully killed pool return 1'
  eq "$(field summary 6)" 1 'a prepare that assigns killed=99 does not inflate the summary'
  # shellcheck disable=SC2034
  misaligning_prepare() { base_verdict=(green); shmutant_copy_tree "$TOY" "$1"; }
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'red' '$1 + $2' '$1 - $2' 'nobody'
  pool lbl "$T/wd3" misaligning_prepare toy_run
  eq "$(verdict_of red)" baseline 'a prepare that pre-fills the baseline arrays cannot misalign a red baseline with its row'
}

t_pool_validates_boolean_settings() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  SHMUTANT_KEEP=true pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'SHMUTANT_KEEP=true is refused, not read as 0'
  has "$ERR" 'SHMUTANT_KEEP' 'names it'
  SHMUTANT_BASELINE=false pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'SHMUTANT_BASELINE=false is refused, not read as 1'
}

t_verdict_timeout_with_a_leading_zero() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'hangs' '$1 + $2' '$1 - $2' 'add-works'
  # 08: digits only, but not a valid octal constant, which is what bash arithmetic would read.
  slow_run() { bash -c "sleep 12; touch '$T/finished'"; }
  SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=08 pool lbl "$T/wd" toy_prepare slow_run
  eq "$(verdict_of 'hangs')" timeout 'a timeout of 08 is eight seconds, not an octal error that disarms the watchdog'
  [ "${OUT##*$'\t'hangs$'\t'}" != "$OUT" ] && [ "$(field row 8 | cut -d. -f1)" -ge 8 ] || fail_ "the run was cut short of eight seconds: $(field row 8)s"
  has "$ERR" 'within 8s' 'the bound is reported in its canonical form, not as 08'
  sleep 3
  [ -e "$T/finished" ] && fail_ 'the run outlived the leading-zero timeout'
}

t_run_leftovers_are_killed_after_a_normal_return() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # returns at once, leaving a helper in its own process group and a plain one in the run's
  leaky_run() { set -m; bash -c "sleep 4; touch '$T/escaped'" & bash -c "bash -c 'sleep 4; touch \"$T/grandchild\"' & wait" & set +m; bash -c "sleep 4; touch '$T/grouped'" & bash "$1/test.sh"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare leaky_run
  eq "$(verdict_of a)" killed 'the verdict is the callback'"'"'s own'
  sleep 5
  [ -e "$T/grouped" ] && fail_ 'a helper left in the run'"'"'s process group outlived the verdict'
  [ -e "$T/escaped" ] && fail_ 'a helper in its own process group, seen by the watchdog, outlived the verdict'
  [ -e "$T/grandchild" ] && fail_ 'a child of a retained leftover outlived the verdict: retained victims must be searched from too'
}

t_run_cannot_redirect_the_leftover_record() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  printf 'precious\n' > "$T/victim"
  # shellcheck disable=SC2034
  meddling_run() { mark="$T/victim"; left_w=1; set -m; bash -c "sleep 4; touch '$T/escaped'" & set +m; bash "$1/test.sh"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare meddling_run
  eq "$(verdict_of a)" killed 'the verdict is the callback'"'"'s own'
  eq "$(cat "$T/victim")" precious 'a callback assigning mark cannot point the leftover record at a caller file'
  [ -e "$T/victim.left" ] && fail_ 'the leftover record was written beside the caller file'
  sleep 5
  [ -e "$T/escaped" ] && fail_ 'the escaped helper survived because the leftover record was lost'
}

# shellcheck disable=SC2034
t_freeze_records_only_what_it_stopped() {
  # The listing names a child that has already been replaced by the time of the stop: with the
  # process table stubbed to report a bystander as a descendant, the bystander must be left
  # running and not appear among the frozen.
  sleep 5 & local bystander=$!
  ( sleep 5; : ) & local root=$!
  sleep 0.3
  ( _shmutant_descendants_started() { printf '%s %s\n' "$bystander" "$(( $(_shmutant_identity "$bystander") - 100 ))"; printf '%s \n' "$root"; }
    local -a frozen=() roots=("$root"); local -A have=()
    _shmutant_freeze_from
    case " ${frozen[*]} " in *" $bystander:"*) echo "FAIL: $_unit: a pid whose process had changed since the listing was recorded as frozen" ;; esac
    case " ${frozen[*]} " in *" $root:"*) echo "FAIL: $_unit: a pid listed with no start time was recorded as frozen" ;; esac
    [ "${SHMUTANT_FREEZE_UNSETTLED:-0}" = 1 ] || echo "FAIL: $_unit: an entry with nothing to verify it by did not make the freeze unsettled"
    exit 0 )
  sleep 0.2
  case "$(ps -o stat= -p "$root")" in T*) fail_ 'a pid listed with no start time was left stopped' ;; esac
  sleep 0.2
  case "$(ps -o stat= -p "$bystander")" in T*) fail_ 'the bystander was left stopped' ;; esac
  kill -0 "$bystander" 2>/dev/null; rc_is $? 0 'the bystander is still there'
  # KILL: a bystander a defect left stopped would never see a TERM, and the wait would hang
  kill -KILL "$bystander" "$root" 2>/dev/null; wait "$bystander" "$root" 2>/dev/null
}

# shellcheck disable=SC2034
t_freeze_that_never_settles_is_reported() {
  # A freeze whose every pass finds a process it has not seen reaches its bound and records it,
  # and the run is then scored unsettled rather than trusted. Driven with fabricated pids and
  # stubbed helpers: no real process is spawned, stopped or killed, so nothing the freeze does
  # can escape to the suite runner (this unit runs nested inside a pool during self-mutation).
  ( echo 0 > "$T/fc"
    # Each pass reports a fresh pid the freeze has not seen, and the frozen-set check accepts it,
    # so the loop keeps finding new work until the 32-pass bound. The counter is a file: the
    # stub is called from a process substitution, where a variable would not persist.
    _shmutant_descendants_started() { [ "$1" = 2000000000 ] || return 0; local n; n=$(($(cat "$T/fc") + 1)); echo "$n" > "$T/fc"; printf '%s %s\n' "$((2000000000 + n))" "$n"; }
    _shmutant_frozen_only() { SHMUTANT_FROZEN_NOW=("${1%% *}"); }
    declare -a frozen=() roots=(2000000000); declare -A have=()
    SHMUTANT_FREEZE_UNSETTLED=0
    _shmutant_freeze_from
    [ "$SHMUTANT_FREEZE_UNSETTLED" = 1 ] || { echo "FAIL: $_unit: a freeze that found new work on every pass ended as if settled"; exit 1; }
    exec {u}>|"$T/unsettled"; SHMUTANT_UNSETTLED_FD="$u"
    _shmutant_kill_tree_twice 2000000000
    grep -qx unsettled "$T/unsettled" || { echo "FAIL: $_unit: the unsettled freeze was not reported on the descriptor the runner named"; exit 1; }
    exit 0 ) || _failed=1
  # The pool turns an unsettled run into an `unsettled` verdict. Driven through a stubbed
  # runner, so no real freeze kill runs here either.
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  ( _shmutant_run_bounded() { SHMUTANT_RUN_STATUS=0; SHMUTANT_RUN_RED=0; SHMUTANT_RUN_WITNESSED=0; SHMUTANT_RUN_FIRED=0; SHMUTANT_RUN_PUBLISHED=1; SHMUTANT_RUN_UNSETTLED=1; }
    SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" toy_prepare toy_run > "$T/out" 2> "$T/err" )
  has "$(cat "$T/out")" 'unsettled' 'a run the freeze could not settle is scored unsettled, not the callback status'
}

t_post_run_cleanup_never_signals_a_reaped_root_by_number() {
  # After a normal return the root has been reaped, so its number may already belong to
  # someone else: _shmutant_kill_tree signals a root only through an identity-checked victim,
  # never by bare number. A live process handed in as the root without identity must survive.
  sleep 5 & local bystander=$!
  _shmutant_kill_tree TERM "$bystander"; sleep 0.2
  kill -0 "$bystander" 2>/dev/null; rc_is $? 0 'a root given by number alone is not signalled'
  local id; id="$(_shmutant_identity "$bystander")"
  _shmutant_kill_tree TERM "$bystander" "$bystander:$id"; sleep 0.2
  kill -0 "$bystander" 2>/dev/null; rc_is $? 1 'a root given with a matching identity is'
  wait "$bystander" 2>/dev/null
  ( sleep 0.1 ) & local dead=$!; wait "$dead"
  _shmutant_kill_tree_twice "$dead"; rc_is $? 0 'kill_tree_twice on a reaped root is a quiet no-op'
  sleep 5 & local b2=$!
  local id2; id2="$(_shmutant_identity "$b2")"
  _shmutant_kill_tree_twice "$b2:$(( id2 - 100 ))"; sleep 0.2
  kill -0 "$b2" 2>/dev/null; rc_is $? 0 'a root whose given identity does not match is neither stopped nor killed'
  case "$(ps -o stat= -p "$b2")" in T*) fail_ 'the mismatched root was left stopped' ;; esac
  kill "$b2" 2>/dev/null; wait "$b2" 2>/dev/null
  # a rejected root's current children are not searched from either
  ( sleep 5; : ) & local b3=$!
  sleep 0.3
  local kid; kid="$(_shmutant_descendants "$b3" | head -n 1)"
  [ -n "$kid" ] || fail_ 'fixture: the root has no child to protect'
  _shmutant_kill_tree_twice "$b3:$(( $(_shmutant_identity "$b3") - 100 ))"; sleep 0.2
  kill -0 "$kid" 2>/dev/null; rc_is $? 0 'the children of a root whose identity does not match are left alone'
  kill "$b3" "$kid" 2>/dev/null; wait "$b3" 2>/dev/null
  # a bare pid is stopped and killed even when ps cannot identify it
  sleep 5 & local b4=$!
  ( _shmutant_identity() { return 1; }; _shmutant_snapshot() { :; }; _shmutant_descendants() { :; }; _shmutant_kill_tree_twice "$b4" ); sleep 0.2
  kill -0 "$b4" 2>/dev/null; rc_is $? 1 'a bare live root is killed even when no identity can be read'
  wait "$b4" 2>/dev/null
}

t_stream_descriptor_survives_a_callback_swapping_the_path() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  printf 'precious\n' > "$T/victim"
  swapping_run() { rm -f "$T/stream"; ln -s "$T/victim" "$T/stream"; bash "$1/test.sh"; }
  ( SHMUTANT_STREAM="$T/stream" shmutant_pool lbl "$T/wd" toy_prepare swapping_run > /dev/null 2>"$T/e" ); rc_is $? 2 'a stream path a callback replaced is a harness error: the records went where nobody can read them'
  has "$(cat "$T/e")" 'no longer names the file' 'says so'
  eq "$(cat "$T/victim")" precious 'records never follow a symlink a callback put at the stream path'
  removing_run() { rm -f "$T/stream2"; bash "$1/test.sh"; }
  ( SHMUTANT_STREAM="$T/stream2" shmutant_pool lbl "$T/wd2" toy_prepare removing_run > /dev/null 2>"$T/e" ); rc_is $? 2 'a stream a callback removed is a harness error'
  has "$(cat "$T/e")" 'no longer names the file' 'says so'
  keeping_run() { bash "$1/test.sh"; }
  ( SHMUTANT_STREAM="$T/stream3" shmutant_pool lbl "$T/wd3" toy_prepare keeping_run > /dev/null 2>"$T/e" ); rc_is $? 0 'an untouched stream is fine'
  has "$(cat "$T/stream3")" 'killed' 'and carries the records'
  has "$(cat "$T/e")" 'killed on their own witness' 'opening the stream did not swallow the pool'"'"'s own stderr'
}

t_prepare_cannot_redirect_its_own_capture() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # prepare turns every capture-shaped name in the workdir into a FIFO: reading the root by
  # path afterwards would block forever, before any per-run bound exists
  fifo_prepare() { toy_prepare "$1"; local f; for f in "$1"/../.prepare.*; do [ -e "$f" ] && rm -f "$f" && mkfifo "$f"; done; mkfifo "$1/../.prepare.planted"; }
  ( SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" fifo_prepare toy_run > "$T/out" 2>&1; touch "$T/pool-done" ) &
  local bg=$! i=0
  until [ -e "$T/pool-done" ]; do i=$((i + 1)); [ "$i" -lt 100 ] || break; sleep 0.1; done
  if [ ! -e "$T/pool-done" ]; then kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null; fail_ 'the pool blocked reading a capture prepare had replaced with a FIFO'; return; fi
  wait "$bg" 2>/dev/null
  has "$(cat "$T/out")" 'killed' 'the pool ran to its verdict'
}

t_pool_removes_a_read_only_pristine_root() {
  mk_toy "$T/toy"; TOY="$T/toy"; chmod 555 "$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  pool lbl "$T/wd" toy_prepare toy_run
  chmod 755 "$T/toy"
  rc_is "$RC" 0 'a target inside a read-only directory is still rewritten, and killed'
  [ -e "$T/wd/pristine" ] && fail_ 'a pristine tree whose preserved root is read-only was not removed'
  mkdir -p "$T/rod"; printf 'x=1\n' > "$T/rod/f"; chmod 555 "$T/rod"
  shmutant_mutate "$T/rod/f" 'x=1' 'x=2'; rc_is $? 0 'mutate loosens a read-only directory for the rewrite'
  eq "$(cat "$T/rod/f")" 'x=2' 'rewritten'
  eq "$(ls -ld "$T/rod" | cut -c1-10)" 'dr-xr-xr-x' 'and puts the directory mode back'
  chmod 755 "$T/rod"
  [ -e "$T/wd/mut-0/tree" ] && fail_ 'a clone whose root is read-only was not removed'
  mkdir -p "$T/deep/a/b"; : > "$T/deep/a/b/f"; chmod 000 "$T/deep/a"
  _shmutant_remove "$T/deep"; rc_is $? 0 'a mode-000 directory left inside a tree of ours does not block its removal'
}

t_pool_failure_after_prepare_removes_pristine() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target absent.sh; shmutant_mut 'r' 'a' 'b' 'add-works'
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a missing target after prepare is a harness error'
  [ -e "$T/wd/pristine" ] && fail_ 'the prepared tree was left behind by a validation failure'
  SHMUTANT_KEEP=1 pool lbl "$T/wd2" toy_prepare toy_run
  [ -d "$T/wd2/pristine" ] || fail_ 'with SHMUTANT_KEEP=1 the prepared tree is kept even on a validation failure'
}

t_run_cannot_lose_the_leftover_record_by_locking_its_dir() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # leaves an escaped helper, then makes its worker directory unwritable before returning
  locking_run() { set -m; bash -c "sleep 4; touch '$T/escaped'" & set +m; local rc; bash "$1/test.sh"; rc=$?; chmod 555 "$1/.."; return "$rc"; }
  SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 pool lbl "$T/wd" toy_prepare locking_run
  chmod 755 "$T/wd/mut-0" 2>/dev/null
  eq "$(verdict_of a)" killed 'the verdict is the callback'"'"'s own'
  sleep 5
  [ -e "$T/escaped" ] && fail_ 'the leftover record was lost to a locked directory and the helper survived'
  untrapping_run() { trap - EXIT; set -m; bash -c "sleep 4; touch '$T/escaped2'" & set +m; bash "$1/test.sh"; }
  SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 pool lbl "$T/wd2" toy_prepare untrapping_run
  sleep 5
  [ -e "$T/escaped2" ] && fail_ 'a callback that dropped the EXIT trap escaped the snapshot taken on return'
  exiting_run() { trap - EXIT; set -m; bash -c "sleep 4; touch '$T/escaped3'" & set +m; exit 0; }
  SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 pool lbl "$T/wd3" toy_prepare exiting_run
  sleep 5
  [ -e "$T/escaped3" ] && fail_ 'a callback that dropped the EXIT trap and left by exit escaped the snapshot'
}

leaky_c() { set -m; bash -c "sleep 3; touch '$T/escaped-c'" & set +m; bash "$1/test.sh"; }

t_run_cannot_forge_its_output_or_the_marker() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  printf 'precious\n' > "$T/victim"
  # replaces its captured output with a file that claims the witness, then exits with a status
  # that is neither green nor red
  forging_run() { rm -f "$1/../output"; printf 'FAIL: add-works: forged\n' > "$1/../output"; exit 1; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare forging_run
  eq "$(verdict_of a)" aborted 'the verdict is scored from the output the harness captured (empty: exit 1 with no red line is aborted), not a file the callback put in its place'
  linking_output_run() { rm -f "$1/../output"; ln -s "$T/victim" "$1/../output"; echo "FAIL: add-works: real"; exit 1; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd2" toy_prepare linking_output_run
  eq "$(cat "$T/victim")" precious 'a symlink the callback put at output is never written through'
  ( set -C; SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd3" toy_prepare toy_run > "$T/o" 2>/dev/null ); rc_is $? 0 'the channels open under a caller noclobber'
  has "$(cat "$T/o")" $'\tkilled\t' 'and the row is scored'
  ( set -C; SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 shmutant_pool lbl "$T/wd4" toy_prepare leaky_c > /dev/null 2>&1 )
  sleep 4
  [ -e "$T/escaped-c" ] && fail_ 'under noclobber the leftover record was not opened and an escaped helper survived'
}

t_pool_never_trusts_a_verdict_from_a_replaced_directory() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # a run that is a survivor, but plants a killed verdict in a fresh directory of the same name
  planting_run() { local d; d="$(cd "$1/.." && pwd -P)"; mv "$d" "$d.moved" && mkdir -p "$d" && printf 'killed\n1\n1\n' > "$d/verdict"; exit 0; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare planting_run
  rc_is "$RC" 2 'a planted verdict in a replacement directory is a harness error, never a pass'
  eq "$(verdict_of a)" lost 'the verdict comes from the channel, not the planted file: lost'
  has "$ERR" 'no longer the directory' 'the replaced directory is named'
  rm -rf "$T/wd/mut-0"; mv "$T/wd/mut-0.moved" "$T/wd/mut-0" 2>/dev/null
}

t_run_errexit_failure_still_snapshots_leftovers() {
  mk_toy "$T/toy"
  # In a fresh process: this suite runs each unit on the left of ||, where bash ignores errexit.
  export TOY="$T/toy" T
  bash -c '
    . "$1"
    toy_prepare() { shmutant_copy_tree "$TOY" "$1"; }
    strict_leaky_run() { set -e; set -m; bash -c "sleep 4; touch \"$T/escaped\"" & set +m; false; echo "FAIL: add-works: unreachable"; }
    shmutant_target lib.sh
    shmutant_mut a "\$1 + \$2" "\$1 - \$2" add-works
    SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 shmutant_pool lbl "$T/wd" toy_prepare strict_leaky_run 2>/dev/null' _ "$SHMUTANT" > "$T/o"
  eq "$(awk -F'\t' '$3 == "row" { print $4 }' "$T/o")" aborted 'the callback'"'"'s own errexit ended the run: aborted'
  sleep 5
  [ -e "$T/escaped" ] && fail_ 'a helper left by a callback that errexit-failed outlived the verdict: the snapshot did not run'
}

t_worker_cleanup_refuses_a_swapped_directory() {
  mk_toy "$T/toy"; TOY="$T/toy"
  # A directory identity carries its resolved physical path, not the inode alone: an inode is
  # unique only within a filesystem, so a same-inode directory across a swapped mount would
  # otherwise pass. (A cross-mount swap is impractical to stage in a unit; the path component
  # that closes it is asserted directly.)
  mkdir -p "$T/idd"
  case "$(_shmutant_dir_id "$T/idd")" in */*) ;; *) fail_ 'a directory identity does not carry its physical path' ;; esac
  eq "$(_shmutant_dir_id "$T/idd")" "$(command -p ls -di -- "$T/idd" | awk '{print $1}'):$(cd "$T/idd" && pwd -P)" 'the identity is inode and physical path'
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  mkdir -p "$T/victim/tree" "$T/victim/output"; printf 'precious\n' > "$T/victim/tree/keep"; printf 'mine\n' > "$T/victim/output/keep"
  # renames its worker directory away and leaves a symlink to a caller tree in its place
  swapping_run() { local d; d="$(cd "$1/.." && pwd -P)"; bash "$1/test.sh"; local rc=$?; mv "$d" "$d.moved" && ln -s "$T/victim" "$d"; return "$rc"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare swapping_run
  [ -f "$T/victim/tree/keep" ] || fail_ 'cleanup followed the swapped worker directory into a caller tree'
  has "$ERR" 'no longer the worker directory' 'the swap is reported'
  [ -e "$T/victim/verdict" ] && fail_ 'the verdict was written through the swapped directory'
  [ -f "$T/victim/output/keep" ] || fail_ 'publishing the capture removed a directory named output in the caller tree behind the swap'
  eq "$(verdict_of a)" lost 'no verdict is written beneath a swapped directory'
  rm -f "$T/wd/mut-0"; mv "$T/wd/mut-0.moved" "$T/wd/mut-0" 2>/dev/null
  # a plain directory in place of the worker directory, not a symlink
  replacing_run() { local d; d="$(cd "$1/.." && pwd -P)"; bash "$1/test.sh"; local rc=$?; mv "$d" "$d.moved" && mkdir -p "$d/tree" && printf 'fake\n' > "$d/tree/keep"; return "$rc"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd2" toy_prepare replacing_run
  [ -f "$T/wd2/mut-0/tree/keep" ] || fail_ 'cleanup removed beneath a fresh directory that merely has the worker directory'"'"'s name'
  has "$ERR" 'no longer the worker directory' 'the replacement is detected by inode'
  rm -rf "$T/wd2/mut-0"; mv "$T/wd2/mut-0.moved" "$T/wd2/mut-0" 2>/dev/null
}

# shellcheck disable=SC2034
t_sibling_cannot_plant_in_another_workers_directory() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # Planted in a worker's directory before its worker starts, as a concurrent sibling could:
  # `tree` a symlink to another tree, `output` a symlink to a victim. The clone must not be
  # copied into the link's target, and the capture must not be written through the link.
  mkdir -p "$T/wd"; toy_prepare "$T/wd/pristine"
  mkdir -p "$T/wd/mut-0" "$T/other"; printf 'precious\n' > "$T/victim"
  ln -s "$T/other" "$T/wd/mut-0/tree"; ln -s "$T/victim" "$T/wd/mut-0/output"
  declare -gA SHMUTANT_DIR_IDS=() SHMUTANT_VERDICT_W=() SHMUTANT_VERDICT_R=() SHMUTANT_RES_VERDICT=() SHMUTANT_RES_US=() SHMUTANT_RES_STATUS=()
  SHMUTANT_DIR_IDS[mut-0]="$(_shmutant_dir_id "$T/wd/mut-0")"; SHMUTANT_PRISTINE_ID="$(_shmutant_dir_id "$T/wd/pristine")"
  # the pool's record of the prepared tree, which the worker checks before cloning
  SHMUTANT_PRISTINE_STATE="$(_shmutant_pristine_state "$T/wd/pristine")"
  SHMUTANT_ROWS_SEL=(add-works)
  _shmutant_open_channel "$T/wd" mut-0 || fail_ 'fixture: no channel'
  ( SHMUTANT_TIMEOUT=0 _shmutant_worker mut 0 "$T/wd" toy_run "" )
  SHMUTANT_CLEANUP_FAILED=0; _shmutant_collect "$T/wd/mut-0" mut-0 0 2>/dev/null
  eq "$SHMUTANT_V_VERDICT" unprepared 'a planted link at tree is not cloned into'
  eq "$(find "$T/other" -mindepth 1 | wc -l | tr -d ' ')" 0 'nothing was copied into the link'"'"'s target'
  rm -f "$T/wd/mut-0/tree"
  _shmutant_open_channel "$T/wd" mut-0 || fail_ 'fixture: no channel'
  ( SHMUTANT_TIMEOUT=0 _shmutant_worker mut 0 "$T/wd" toy_run "" )
  _shmutant_collect "$T/wd/mut-0" mut-0 0 2>/dev/null
  eq "$SHMUTANT_V_VERDICT" killed 'the row is scored on its own run'
  eq "$(cat "$T/victim")" precious 'a link planted at output was not written through'
  [ -L "$T/wd/mut-0/output" ] && fail_ 'the capture was not renamed over the planted link'
  has "$(cat "$T/wd/mut-0/output")" 'FAIL: add-works' 'and the capture is the run'"'"'s own output'
}

t_worker_verdict_cannot_be_forged_through_a_link() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  printf 'precious\n' > "$T/victim"
  linking_run() { ln -sf "$T/victim" "$1/../verdict"; bash "$1/test.sh"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare linking_run
  eq "$(verdict_of a)" killed 'the verdict is still read correctly'
  eq "$(cat "$T/victim")" precious 'a symlink the callback planted at verdict is never written through: the verdict travels on a channel'
}

t_pool_interrupted_kills_its_workers() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  unbounded_run() { : > "$T/started"; bash -c "sleep 4; touch '$T/finished'"; }
  ( SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 shmutant_pool lbl "$T/wd" toy_prepare unbounded_run > /dev/null 2>&1 ) & local pp=$!
  wait_for "$T/started" || fail_ 'the run never started'
  kill -TERM "$pp"; wait "$pp" 2>/dev/null
  sleep 4
  [ -e "$T/finished" ] && fail_ 'a worker outlived the pool that was interrupted with TERM'
  stubborn_run() { set -m; bash -c "trap '' TERM; : > '$T/started2'; sleep 5; touch '$T/stubborn'" & wait; }
  ( SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 shmutant_pool lbl "$T/wd2" toy_prepare stubborn_run > /dev/null 2>&1 ) & pp=$!
  wait_for "$T/started2" || fail_ 'the stubborn run never started'
  kill -TERM "$pp"; wait "$pp" 2>/dev/null
  sleep 5
  [ -e "$T/stubborn" ] && fail_ 'a TERM-ignoring escaped descendant outlived the interrupted pool: the TERM victims were not retained for KILL'
  # with nothing readable from the process table, the run's group is still ended by number,
  # through the group and holder the runner reported on its channel
  plain_run() { : > "$T/started3"; bash -c "sleep 4; touch '$T/finished3'"; }
  ( _shmutant_identity() { return 1; }; _shmutant_identity_table() { SHMUTANT_START=(); }; _shmutant_descendants() { :; }; _shmutant_descendants_started() { :; }
    SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 shmutant_pool lbl "$T/wd3" toy_prepare plain_run > /dev/null 2>&1 ) & pp=$!
  wait_for "$T/started3" || fail_ 'the no-ps run never started'
  kill -TERM "$pp"; wait "$pp" 2>/dev/null
  sleep 4
  [ -e "$T/finished3" ] && fail_ 'with no process table, an interrupted run outlived the pool: its group was not ended by number'
}

# shellcheck disable=SC2034
t_abort_during_spawn_is_deferred() {
  ( trap '_shmutant_abort_workers TERM' TERM
    # a caller trap that survives re-delivery, so an early re-raise is a FAIL, not an abort
    SHMUTANT_TRAP_INT=""; SHMUTANT_TRAP_TERM="trap -- 'hit=1' SIGTERM"; hit=0
    sleep 5 & w=$!
    SHMUTANT_ACTIVE=(); SHMUTANT_SPAWNING=1; SHMUTANT_ABORT_PENDING=""
    # the handler runs while a worker is being registered: it must only take note
    _shmutant_abort_workers TERM
    [ "$hit" = 0 ] || { echo "FAIL: $_unit: the signal was re-delivered during spawn"; exit 1; }
    [ "$SHMUTANT_ABORT_PENDING" = TERM ] || { echo "FAIL: $_unit: a signal during spawn was not deferred"; exit 1; }
    kill -0 "$w" 2>/dev/null || { echo "FAIL: $_unit: the handler killed during spawn"; exit 1; }
    SHMUTANT_ACTIVE=("$w"); SHMUTANT_SPAWNING=0
    trap - TERM
    ( _shmutant_abort_workers "$SHMUTANT_ABORT_PENDING" ) 2>/dev/null
    sleep 0.3
    kill -0 "$w" 2>/dev/null && { echo "FAIL: $_unit: the deferred abort did not kill the registered worker"; exit 1; }
    exit 0 ) || _failed=1
}

# shellcheck disable=SC2034
t_run_publishes_its_group_before_the_callback_runs() {
  mkdir -p "$T/d"
  # the callback sees, on its own channel, the group record already written by the runner
  ( exec {vf}>|"$T/chan"; SHMUTANT_VERDICT_FD="$vf"
    cb() { cat "$T/chan" > "$T/seen"; }
    SHMUTANT_TIMEOUT=0 _shmutant_run_bounded "$T/d" cb "$T/d" sel 2>/dev/null )
  has "$(cat "$T/seen")" 'group ' 'the group and holder are on the channel before plan code runs'
}

t_run_output_is_published_over_a_planted_directory() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  dir_planting_run() { mkdir -p "$1/../output"; bash "$1/test.sh"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare dir_planting_run
  eq "$(verdict_of a)" killed 'killed'
  [ -f "$T/wd/mut-0/output" ] || fail_ 'the documented output artifact is not a regular file'
  has "$(cat "$T/wd/mut-0/output")" 'FAIL: add-works' 'and it holds the capture'
}

# shellcheck disable=SC2034
t_run_output_publication_failure_is_a_harness_error() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # the callback locks its worker directory after going red: the capture is still published
  locking_run() { bash "$1/test.sh"; local rc=$?; chmod 555 "$1/.."; return "$rc"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare locking_run
  chmod 755 "$T/wd/mut-0" 2>/dev/null
  eq "$(verdict_of a)" killed 'killed'
  rc_is "$RC" 0 'a directory the callback locked is unlocked and the capture published'
  [ -f "$T/wd/mut-0/output" ] || fail_ 'the output artifact is missing after the callback locked its directory'
  # and when it truly cannot be published, the pool says so and fails
  ( _shmutant_run_bounded() { SHMUTANT_RUN_STATUS=1; SHMUTANT_RUN_RED=1; SHMUTANT_RUN_WITNESSED=1; SHMUTANT_RUN_FIRED=0; SHMUTANT_RUN_UNSETTLED=0; SHMUTANT_RUN_PUBLISHED=0; }
    SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd2" toy_prepare toy_run > "$T/out" 2>"$T/err"; echo "rc=$?" >> "$T/out" )
  has "$(cat "$T/out")" 'rc=2' 'an output that could not be published is a harness error'
  has "$(cat "$T/err")" 'could not be published' 'and is named'
}

t_run_capture_has_no_name_while_run_executes() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$2 + $1' 'add-works'
  # the callback tries to write a failure line into any capture-shaped file it can find, then
  # returns red with no genuine failure line of its own
  forging_run() { local f; for f in "$1"/../.output.* "$1"/../output; do [ -e "$f" ] && printf 'FAIL: add-works: forged\n' >> "$f"; done; bash "$1/test.sh" > /dev/null 2>&1; return 1; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare forging_run
  eq "$(verdict_of a)" aborted 'a red status with no genuine failure line stays aborted: the capture had no name to forge into'
  [ -f "$T/wd/mut-0/output" ] || fail_ 'the artifact was still materialised afterwards'
}

t_run_partial_channel_open_is_a_setup_failure() {
  mkdir -p "$T/d"
  # The descriptor limit is lowered to one below the smallest value at which a run succeeds:
  # some of the channels open, the rest cannot, and the run must not start.
  cb() { touch "$T/ran"; }
  local n ok=""
  for (( n = 8; n <= 64; n++ )); do
    ( ulimit -n "$n" 2>/dev/null || exit 2; SHMUTANT_TIMEOUT=0 _shmutant_run_bounded "$T/d" cb "$T/d" sel 2>/dev/null; [ "$SHMUTANT_RUN_STATUS" = 0 ] ) && { ok="$n"; break; }
  done
  [ -n "$ok" ] || { echo "note: $_unit: no descriptor limit let a run through; skipped"; return; }
  rm -f "$T/ran"
  ( ulimit -n "$(( ok - 1 ))"; SHMUTANT_TIMEOUT=0 _shmutant_run_bounded "$T/d" cb "$T/d" sel 2>/dev/null
    printf '%s' "$SHMUTANT_RUN_STATUS" > "$T/status" )
  eq "$(cat "$T/status")" 127 'a channel that could not be opened is a setup failure'
  [ -e "$T/ran" ] && fail_ 'the callback ran without its channels'
  eq "$(find "$T/d" -name '.*' | wc -l | tr -d ' ')" 0 'no channel file was left behind'
  # and through the pool it is a harness error, not a verdict on the row
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  ( ulimit -n "$(( ok - 1 ))"; SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" toy_prepare toy_run > "$T/out" 2>"$T/err"; echo "rc=$?" >> "$T/out" )
  has "$(cat "$T/out")" 'rc=2' 'a run that could not be set up is a harness error'
  has "$(cat "$T/err")" 'could not be set up' 'and is named'
}

# shellcheck disable=SC2034
t_pool_survives_a_caller_chld_trap() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  shmutant_mut 'b' '$1 + $2' '$2 + $1' 'add-works'
  # a caller whose CHLD trap reaps every child: the pool must neither spin nor lose verdicts,
  # and the trap must be back afterwards
  ( trap 'wait 2>/dev/null' CHLD; SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" toy_prepare toy_run > "$T/out" 2>"$T/err"; echo "rc=$?" >> "$T/out"; trap -p CHLD > "$T/trap" ) &
  local bg=$! i=0
  until grep -q '^rc=' "$T/out" 2>/dev/null || [ "$i" -ge 300 ]; do i=$((i + 1)); sleep 0.1; done
  grep -q '^rc=' "$T/out" || { kill -KILL "$bg" 2>/dev/null; wait "$bg" 2>/dev/null; fail_ 'the pool spun forever under a caller CHLD trap'; return; }
  wait "$bg" 2>/dev/null
  has "$(cat "$T/out")" $'\trow\tkilled\ta\t' 'row a killed under a caller CHLD trap'
  has "$(cat "$T/out")" $'\trow\tsurvived\tb\t' 'row b survived under a caller CHLD trap'
  has "$(cat "$T/out")" 'rc=1' 'the pool status is its own'
  has "$(cat "$T/trap")" 'CHLD' 'the caller'"'"'s CHLD trap was put back'
  # and the residue: workers already reaped by someone else are scored lost, not spun on
  ( declare -gA SHMUTANT_ACTIVE_KEY=([12345]=mut-0) SHMUTANT_ACTIVE_ID=() SHMUTANT_VERDICT_R=() SHMUTANT_RES_VERDICT=() SHMUTANT_RES_US=() SHMUTANT_RES_STATUS=() SHMUTANT_DIR_IDS=()
    pids=(12345); SHMUTANT_ACTIVE=(12345)
    _shmutant_reap_one "$T/wd" 2>/dev/null
    [ "${#pids[@]}" -eq 0 ] || { echo "FAIL: $_unit: a pid nothing could wait for stayed in the list"; exit 1; }
    [ "${SHMUTANT_RES_VERDICT[mut-0]:-}" = lost ] || { echo "FAIL: $_unit: a worker reaped by someone else is not scored lost"; exit 1; }
    exit 0 ) || _failed=1
}

t_pool_abort_waits_only_for_its_helpers() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  unbounded_run() { : > "$T/started"; bash -c "sleep 4; touch '$T/finished'"; }
  # the caller has a long job of its own; the interrupt must not wait for it
  ( sleep 30 & SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 shmutant_pool lbl "$T/wd" toy_prepare unbounded_run > /dev/null 2>&1 ) & local pp=$!
  wait_for "$T/started" || fail_ 'the run never started'
  local t0; t0="$(_shmutant_now)"
  kill -TERM "$pp"; wait "$pp" 2>/dev/null
  [ $(( ($(_shmutant_now) - t0) / 1000000 )) -lt 10 ] || fail_ 'the interrupt handler blocked on the caller'"'"'s own background job'
  sleep 4
  [ -e "$T/finished" ] && fail_ 'the worker survived the interrupt'
}

t_pool_survives_failglob() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  ( shopt -s failglob; shmutant_pool lbl "$T/wd" toy_prepare toy_run > "$T/o" 2>&1 ); rc_is $? 0 'a caller with failglob on still gets a full pass'
  has "$(cat "$T/o")" $'\tkilled\t' 'the row was killed, not lost'
}

t_run_errexit_is_honoured_in_workers() {
  mk_toy "$T/toy"
  # In a fresh process: this suite runs each unit on the left of ||, where bash ignores errexit.
  export TOY="$T/toy" T
  bash -c '
    . "$1"
    toy_prepare() { shmutant_copy_tree "$TOY" "$1"; }
    strict_run() { set -e; false; echo "FAIL: add-works: never reached"; exit 0; }
    shmutant_target lib.sh
    shmutant_mut a "\$1 + \$2" "\$1 - \$2" add-works
    SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" toy_prepare strict_run 2>/dev/null' _ "$SHMUTANT" > "$T/o"
  eq "$(awk -F'\t' '$3 == "row" { print $4 }' "$T/o")" aborted 'a run whose own set -e fires exits at the failure (status 1, no red line): aborted, not killed or survived'
}

t_pool_restores_caller_traps() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  ( trap - TERM INT
    before_term="$(trap -p TERM)"; before_int="$(trap -p INT)"
    shmutant_pool lbl "$T/wd" toy_prepare toy_run > /dev/null 2>&1
    [ "$(trap -p TERM)" = "$before_term" ] || { echo "FAIL: $_unit: the TERM trap changed across the pool: [$before_term] -> [$(trap -p TERM)]"; exit 1; }
    [ "$(trap -p INT)" = "$before_int" ] || { echo "FAIL: $_unit: the INT trap changed across the pool: [$before_int] -> [$(trap -p INT)]"; exit 1; }
    ( sleep 5 ) & c=$!; sleep 0.3; kill -TERM "$c"; wait "$c" 2>/dev/null; rc=$?
    [ "$rc" -ne 0 ] || { echo "FAIL: $_unit: TERM is ignored after the pool"; exit 1; }
    exit 0 ) || _failed=1
  ( trap 'echo mine' TERM
    shmutant_pool lbl "$T/wd2" toy_prepare toy_run > /dev/null 2>&1
    [ "$(trap -p TERM)" = "trap -- 'echo mine' SIGTERM" ] || { echo "FAIL: $_unit: the caller's own TERM trap was not restored intact: $(trap -p TERM)"; exit 1; }
    exit 0 ) || _failed=1
}

t_inside_ignores_nocasematch() {
  _shmutant_inside /a/b /a/b/c; rc_is $? 0 'below the root'
  _shmutant_inside /a/b /a/b; rc_is $? 0 'the root itself'
  _shmutant_inside /a/b /a/bc; rc_is $? 1 'a sibling with the root as a prefix is outside'
  ( shopt -s nocasematch; _shmutant_inside /a/b /A/B/c ); rc_is $? 1 'a path that only resembles the root in case is outside, whatever the caller'"'"'s nocasematch says'
  _shmutant_inside / /tmp/work; rc_is $? 0 'the filesystem root contains every absolute path'
  _shmutant_inside / /; rc_is $? 0 'and itself'
}

t_verdict_timeout_kills_a_descendant_seen_then_reparented() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'hangs' '$1 + $2' '$1 - $2' 'add-works'
  # A is seen by the watchdog while its parent I is alive, then I exits and A is reparented, so
  # at the deadline A is reachable only through what the watchdog retained.
  # I lives through two watchdog polls and dies well before the deadline: one poll is a
  # coin-flip on a loaded host.
  orphaning_run() { set -m; bash -c "bash -c 'sleep 7; touch \"$T/orphan\"' & sleep 1.3" & sleep 4; }
  SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=2 pool lbl "$T/wd" toy_prepare orphaning_run
  eq "$(verdict_of 'hangs')" timeout 'verdict is timeout'
  sleep 6
  [ -e "$T/orphan" ] && fail_ 'a descendant seen by the watchdog and then reparented outlived the timeout'
  [ -z "$(ps -A -o args= | grep -F "touch \"$T/orphan\"" | grep -v grep)" ] || fail_ 'the reparented descendant is still there'
  rm -f "$T/orphan"
  ( IFS=''; SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=2 shmutant_pool lbl "$T/wd2" toy_prepare orphaning_run > /dev/null 2>&1 )
  sleep 6
  [ -e "$T/orphan" ] && fail_ 'with the caller IFS empty, the retained list was not split and the reparented descendant survived'
}

# shellcheck disable=SC2034
t_verdict_timeout_without_an_identity() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'hangs' '$1 + $2' '$1 - $2' 'add-works'
  slow_run() { bash -c "sleep 6; touch '$T/finished'"; }
  # No identity can be read for the wrapper (no usable ps): the root is still the runner's own
  # unreaped child, and the bound must still end it rather than wait forever.
  ( _shmutant_identity() { return 1; }; _shmutant_identity_table() { SHMUTANT_START=(); }; _shmutant_descendants() { :; }
    SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=1 shmutant_pool lbl "$T/wd" toy_prepare slow_run > "$T/out" 2>&1
    touch "$T/pool-done" ) &
  local bg=$!
  local i=0; until [ -e "$T/pool-done" ]; do i=$((i + 1)); [ "$i" -lt 150 ] || break; sleep 0.1; done
  if [ ! -e "$T/pool-done" ]; then kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null; fail_ 'without an identity the timeout never ended the run'; return; fi
  wait "$bg" 2>/dev/null
  has "$(cat "$T/out")" 'timeout' 'the verdict is timeout'
  sleep 6
  [ -e "$T/finished" ] && fail_ 'the run outlived its timeout'
}

# shellcheck disable=SC2034
t_returned_run_without_an_identity_is_still_cleaned_up() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # The callback returns after backgrounding a helper in its own group, and nothing about the
  # process table can be read: the group the wrapper ran in must still be ended by number.
  leaving_run() { bash -c "sleep 4; touch '$T/escaped'" & bash "$1/test.sh"; }
  ( _shmutant_identity() { return 1; }; _shmutant_identity_table() { SHMUTANT_START=(); }; _shmutant_descendants() { :; }; _shmutant_descendants_started() { :; }
    SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 shmutant_pool lbl "$T/wd" toy_prepare leaving_run > "$T/out" 2>&1 )
  has "$(cat "$T/out")" 'killed' 'the verdict is the callback'"'"'s own'
  sleep 5
  [ -e "$T/escaped" ] && fail_ 'a helper left in the wrapper'"'"'s group survived a normal return when no process could be identified'
}

# shellcheck disable=SC2034
t_run_group_is_not_signalled_by_number_without_its_holder() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # The callback ends the holder, so the group's number is no longer known to be the run's:
  # with nothing readable from the process table either, what it left behind is not signalled
  # by number, and the run says so.
  # the holder is the member of the run's own process group that is neither the run nor its child
  holder_killing_run() { local me=$BASHPID h; while read -r h; do kill -KILL "$h" 2>/dev/null; done < <(ps -A -o pid= -o ppid= -o pgid= | awk -v g="$me" '$3 == g && $1 != g && $2 != g { print $1 }'); bash -c "sleep 3; touch '$T/survivor'" & bash "$1/test.sh"; }
  ( _shmutant_identity() { return 1; }; _shmutant_identity_table() { SHMUTANT_START=(); }; _shmutant_descendants() { :; }; _shmutant_descendants_started() { :; }
    SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 shmutant_pool lbl "$T/wd" toy_prepare holder_killing_run > "$T/out" 2> "$T/err" )
  has "$(cat "$T/out")" 'killed' 'the verdict is the callback'"'"'s own'
  has "$(cat "$T/err")" 'could not be verified' 'the unverifiable group is reported'
  sleep 4
  [ -e "$T/survivor" ] || fail_ 'a group whose holder was gone was still signalled by number'
}

t_callback_bare_wait_does_not_block_on_the_holder() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # the job's own status, then a bare wait
  waiting_run() { bash "$1/test.sh" & local j=$! rc; wait "$j"; rc=$?; wait; return "$rc"; }
  local t0; t0="$(_shmutant_now)"
  SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=6 pool lbl "$T/wd" toy_prepare waiting_run
  eq "$(verdict_of a)" killed 'a callback that backgrounds its suite and waits gets its own verdict'
  [ $(( ($(_shmutant_now) - t0) / 1000000 )) -lt 5 ] || fail_ 'a bare wait in the callback blocked on the holder until the timeout'
}

t_verdict_timeout_stops_a_run_that_keeps_forking() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'hangs' '$1 + $2' '$1 - $2' 'add-works'
  # a new escaped child every few milliseconds: one forked between a snapshot and the kill
  # survives unless the tree was frozen first
  forking_run() { set -m; while :; do bash -c "sleep 4; touch '$T/leak.$RANDOM'" & sleep 0.02; done; }
  SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=1 pool lbl "$T/wd" toy_prepare forking_run
  eq "$(verdict_of 'hangs')" timeout 'verdict is timeout'
  sleep 5
  [ -z "$(find "$T" -maxdepth 1 -name 'leak.*' -print -quit)" ] || fail_ 'a child forked while the tree was being killed outlived the timeout'
  [ -z "$(ps -A -o args= | grep -F "touch '$T/leak" | grep -v grep)" ] || fail_ 'children of the run are still there after the timeout'
}

t_verdict_timeout_marker_cannot_be_forged() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  forging_run() { : > "$1/../timeout"; : > "$1/../.fired.forged"; bash "$1/test.sh"; }
  SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 pool lbl "$T/wd" toy_prepare forging_run
  eq "$(verdict_of a)" killed 'a file the callback writes beside its clone is not read as the watchdog marker'
}

t_baseline_non_red_exit_is_aborted() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'nobody'
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 1 'the row is not killed'
  eq "$(field baseline 5)" aborted 'a selector that matches nothing (exit 2) is an aborted baseline, not a red one'
  has "$(field baseline 7)" 'neither green nor red' 'says so'
  eq "$(verdict_of a)" baseline 'the row is scored baseline'
}

t_kill_tree_skips_a_reused_pid() {
  eq "$(_shmutant_etime_secs '00:05')" 5 'mm:ss'
  eq "$(_shmutant_etime_secs '01:02:03')" 3723 'hh:mm:ss'
  eq "$(_shmutant_etime_secs '2-01:02:03')" 176523 'dd-hh:mm:ss'
  eq "$(_shmutant_etime_secs 'junk')" 0 'garbage reads as zero'
  sleep 5 & local p=$!
  sleep 1.2
  local id; id="$(_shmutant_identity "$p")"
  case "$id" in [0-9]*) ;; *) fail_ "identity is not a start time in epoch seconds: [$id]" ;; esac
  [ "$id" -le "$(( $(_shmutant_now) / 1000000 ))" ] || fail_ 'a start time in the future'
  _shmutant_alive_since "$p" "$id"; rc_is $? 0 'a process seen a moment ago with this identity is the same process'
  sleep 1.1
  _shmutant_alive_since "$p" "$id"; rc_is $? 0 'the identity is stable while the process lives'
  _shmutant_alive_since "$p" "$(( id - 100 ))"; rc_is $? 1 'a pid recorded as having started earlier than this process is a reused pid'
  _shmutant_kill_tree TERM 2147483000 "$p:$(( id - 100 ))"; sleep 0.2
  kill -0 "$p" 2>/dev/null; rc_is $? 0 'a retained pid that fails the identity check is not signalled'
  kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
}

t_pool_survives_nounset() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  ( set -u; unset SHMUTANT_TIMEOUT SHMUTANT_RED_STATUS SHMUTANT_JOBS SHMUTANT_STREAM SHMUTANT_KEEP SHMUTANT_BASELINE SHMUTANT_RED_PREFIX
    shmutant_pool lbl "$T/wd" toy_prepare toy_run > /dev/null 2> "$T/err" ); rc_is $? 0 'a caller with set -u and no settings gets the defaults, not an unbound-variable abort'
  hasnt "$(cat "$T/err")" 'unbound' 'no unbound variable diagnostic'
}

t_pool_refuses_hard_linked_target() {
  mk_toy "$T/toy"; TOY="$T/toy"
  linking_prepare() { shmutant_copy_tree "$TOY" "$1" && ln "$1/lib.sh" "$1/alias.sh"; }
  shmutant_reset; shmutant_target lib.sh; shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  pool lbl "$T/wd" linking_prepare toy_run
  rc_is "$RC" 2 'a target with a second hard link is refused before any run'
  has "$ERR" 'hard link' 'says why'
}

t_pool_recreates_worker_dirs() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  mkdir -p "$T/wd/mut-0/tree/stale" "$T/wd/base-0"; : > "$T/wd/.shmutant"
  : > "$T/wd/mut-0/timeout"; : > "$T/wd/base-0/timeout"
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 0 'a stale timeout marker from an earlier pool does not poison the verdict'
  eq "$(verdict_of a)" killed 'killed, not timeout'
  eq "$(field baseline 5)" green 'baseline green, not timeout'
  [ -e "$T/wd/mut-0/tree/stale" ] && fail_ 'stale clone content survived into the new run'
  # a row skipped because its baseline is red still gets a fresh directory
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  mkdir -p "$T/wd2/mut-0/tree"; printf 'old\n' > "$T/wd2/mut-0/output"; : > "$T/wd2/.shmutant"
  red_run() { echo "FAIL: add-works: always"; return 1; }
  pool lbl "$T/wd2" toy_prepare red_run
  eq "$(verdict_of a)" baseline 'the row is baseline-skipped'
  [ -e "$T/wd2/mut-0/output" ] && fail_ 'an earlier pool'"'"'s output survived under a baseline-skipped row'
  [ -e "$T/wd2/mut-0/tree" ] && fail_ 'an earlier pool'"'"'s tree survived under a baseline-skipped row'
}

# shellcheck disable=SC2034
t_collect_fails_closed() {
  declare -gA SHMUTANT_DIR_IDS=() SHMUTANT_VERDICT_W=() SHMUTANT_VERDICT_R=() SHMUTANT_RES_VERDICT=() SHMUTANT_RES_US=() SHMUTANT_RES_STATUS=()
  SHMUTANT_CLEANUP_FAILED=0
  mkdir -p "$T/d"; SHMUTANT_DIR_IDS[d]="$(_shmutant_dir_id "$T/d")"
  # no channel at all
  _shmutant_collect "$T/d" d 0
  eq "$SHMUTANT_V_VERDICT" lost 'no channel reads as lost'
  # a channel with nothing on it
  _shmutant_open_channel "$T" d || fail_ 'fixture: cannot open a channel'
  _shmutant_collect "$T/d" d 0
  eq "$SHMUTANT_V_VERDICT" lost 'an empty channel reads as lost'
  # a good verdict, but the worker did not exit 0
  _shmutant_open_channel "$T" d; printf 'verdict killed 1 1\n' >&"${SHMUTANT_VERDICT_W[d]}"
  _shmutant_collect "$T/d" d 137
  eq "$SHMUTANT_V_VERDICT" lost 'a verdict from a worker that was killed reads as lost'
  # a planted file at the old name changes nothing
  printf 'killed\n1\n1\n' > "$T/d/verdict"
  _shmutant_open_channel "$T" d
  _shmutant_collect "$T/d" d 0
  eq "$SHMUTANT_V_VERDICT" lost 'a verdict file planted in the directory is not read'
  _shmutant_open_channel "$T" d; printf 'verdict  5 0\n' >&"${SHMUTANT_VERDICT_W[d]}"
  _shmutant_collect "$T/d" d 0
  eq "$SHMUTANT_V_VERDICT" lost 'a blank verdict word reads as lost'
  # the last verdict line wins, a damaged duration reads as zero, group lines are ignored
  _shmutant_open_channel "$T" d; printf 'group 1 2 3\nverdict survived 5 0\nverdict killed abc 1\n' >&"${SHMUTANT_VERDICT_W[d]}"
  _shmutant_collect "$T/d" d 0
  eq "$SHMUTANT_V_VERDICT" killed 'verdict word read'
  eq "$SHMUTANT_V_US" 0 'a damaged duration reads as zero'
  eq "$SHMUTANT_V_STATUS" 1 'status read'
  eq "$SHMUTANT_CLEANUP_FAILED" 0 'a clean directory is not a cleanup failure'
  # a replaced directory is a harness error
  SHMUTANT_DIR_IDS[d]=999999999
  _shmutant_open_channel "$T" d
  _shmutant_collect "$T/d" d 0 2>/dev/null
  eq "$SHMUTANT_CLEANUP_FAILED" 1 'a directory that is no longer the one the pool made is a cleanup failure'
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

t_pool_runs_prepare_in_its_own_shell() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  exporting_prepare() { export TOY_MARK=set-by-prepare; shmutant_copy_tree "$TOY" "$1"; }
  marked_run() { [ "${TOY_MARK:-}" = set-by-prepare ] || exit 3; bash "$1/test.sh"; }
  unset TOY_MARK
  pool lbl "$T/wd" exporting_prepare marked_run
  rc_is "$RC" 0 'state prepare establishes in the pool shell reaches run'
  eq "$(verdict_of a)" killed 'killed, not aborted'
  unset TOY_MARK
}

t_pool_aborts_running_workers_when_a_dir_cannot_be_recreated() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  shmutant_mut 'b' '$1 + $2' '$1 * $2' 'add-works'
  hanging_run() { : > "$T/started"; bash -c "sleep 30; touch '$T/finished'"; }
  make_unremovable "$T/wd/mut-1/held" || { echo "note: $_unit: no way to make a directory unremovable here; skipped"; return; }
  : > "$T/wd/.shmutant"
  # The startup failure on mut-1 is held until mut-0 is RUNNING its callback: the abort must
  # then end a live worker and remove a clone that exists, which is what the assertions below
  # observe (a worker still fingerprinting pristine when aborted has neither).
  eval "$(declare -f _shmutant_fresh_dir | sed '1s/_shmutant_fresh_dir/_shmutant_fresh_dir_real/')"
  _shmutant_fresh_dir() { local i=0; case "$1" in */mut-1) until [ -e "$T/${WAIT_FOR:-started}" ] || [ "$i" -ge 100 ]; do i=$((i + 1)); sleep 0.1; done ;; esac; _shmutant_fresh_dir_real "$@"; }
  local t0; t0="$(_shmutant_now)"
  WAIT_FOR=started SHMUTANT_JOBS=2 SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 pool lbl "$T/wd" toy_prepare hanging_run
  unmake_unremovable "$T/wd/mut-1/held"
  [ -e "$T/started" ] || fail_ 'fixture: the running worker never started its callback before the abort'
  rc_is "$RC" 2 'the harness error is reported'
  [ $(( ($(_shmutant_now) - t0) / 1000000 )) -lt 15 ] || fail_ 'the pool waited on the unbounded worker instead of ending it'
  [ -e "$T/wd/mut-0/tree" ] && fail_ 'the ended worker'"'"'s clone was left behind'
  [ "${#SHMUTANT_VERDICT_R[@]}" -eq 0 ] || fail_ 'the ended workers'"'"' channels were left open in the caller shell'
  sleep 1
  [ -e "$T/finished" ] && fail_ 'the running worker survived the abort'
  # with a TERM-ignoring escaped descendant, the abort must not return before it is gone
  stubborn_hanging_run() { : > "$T/started2"; set -m; bash -c "trap '' TERM; sleep 30; touch '$T/finished2'" & wait; }
  make_unremovable "$T/wd2/mut-1/held" || { eval "$(declare -f _shmutant_fresh_dir_real | sed '1s/_shmutant_fresh_dir_real/_shmutant_fresh_dir/')"; unset -f _shmutant_fresh_dir_real; return; }
  : > "$T/wd2/.shmutant"
  WAIT_FOR=started2 SHMUTANT_JOBS=2 SHMUTANT_BASELINE=0 SHMUTANT_TIMEOUT=0 pool lbl "$T/wd2" toy_prepare stubborn_hanging_run
  unmake_unremovable "$T/wd2/mut-1/held"
  eval "$(declare -f _shmutant_fresh_dir_real | sed '1s/_shmutant_fresh_dir_real/_shmutant_fresh_dir/')"; unset -f _shmutant_fresh_dir_real
  rc_is "$RC" 2 'harness error'
  [ -z "$(ps -A -o args= | grep -F "touch '$T/finished2'" | grep -v grep)" ] || fail_ 'the abort returned while a TERM-ignoring descendant was still alive'
}

t_pool_refuses_unremovable_pristine() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  make_unremovable "$T/wd/pristine/held" || { echo "note: $_unit: no way to make a directory unremovable here; skipped"; return; }
  : > "$T/wd/.shmutant"
  pool lbl "$T/wd" toy_prepare toy_run
  unmake_unremovable "$T/wd/pristine/held"
  rc_is "$RC" 2 'a pristine directory that cannot be recreated aborts the pool'
  has "$ERR" 'cannot recreate' 'says why'
}

t_pool_prepare_capture_never_follows_a_link() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  printf 'precious\n' > "$T/victim"; mkdir -p "$T/wd"; ln -s "$T/victim" "$T/wd/prepare.out"
  pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 0 'killed'
  eq "$(cat "$T/victim")" precious 'a symlink at the old capture name is never written through'
}

t_pool_reads_the_table_prepare_declared() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  declaring_prepare() { toy_prepare "$1"; shmutant_mut 'b' '$1 + $2' '$2 + $1' 'add-works'; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 0 'baseline'
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" declaring_prepare toy_run
  rc_is "$RC" 1 'a row prepare declared is run, and here survives'
  eq "$(verdict_of b)" survived 'the row declared by prepare has its verdict'
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  newline_root_prepare() { toy_prepare "$1"; mkdir -p "$1/r
"; printf '%s\n' "$1/r
"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wdnl" newline_root_prepare toy_run
  rc_is "$RC" 2 'a prepare root whose name ends in a newline is refused, not trimmed to the sibling'
  has "$ERR" 'contains a newline' 'says why'
  refusing_prepare() { toy_prepare "$1"; shmutant_mut 'c' '' 'x' 'add-works' 2>/dev/null; true; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" refusing_prepare toy_run
  rc_is "$RC" 2 'a declaration refused inside prepare is the same harness error as one refused before it'
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  unsetting_prepare() { toy_prepare "$1"; unset -f gone_run; }
  gone_run() { bash "$1/test.sh"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" unsetting_prepare gone_run
  rc_is "$RC" 2 'a run callback prepare took away is a harness error, not an aborted row'
  has "$ERR" 'not found after prepare' 'says so'
  # errexit is not leaked into a run callback by a caller that has it on. In a fresh process:
  # this suite runs each unit where bash ignores errexit.
  bash -c '. "$1"; set -e; T="$2"; TOY="$T/toy"
    toy_prepare() { shmutant_copy_tree "$TOY" "$1"; }
    counting_run() { false; bash "$1/test.sh"; }
    shmutant_reset; shmutant_target lib.sh; shmutant_mut "a" "\$1 + \$2" "\$1 - \$2" add-works
    SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd5" toy_prepare counting_run > "$T/out" 2>&1; echo "rc=$?" >> "$T/out"' _ "$SHMUTANT" "$T"
  has "$(cat "$T/out")" 'killed' 'a run callback owns its own errexit: the caller'"'"'s set -e did not end it at its first false'
  has "$(cat "$T/out")" 'rc=0' 'and the caller shell survived a pool status under set -e'
  # a harness error from the row pool (a worker directory that cannot be recreated) under the
  # caller's set -e still passes through the pool's own cleanup: the prepared tree is gone
  mkdir -p "$T/wd7"; : > "$T/wd7/.shmutant"
  if make_unremovable "$T/wd7/mut-0/held"; then
    bash -c '. "$1"; set -e; T="$2"; TOY="$T/toy"
      toy_prepare() { shmutant_copy_tree "$TOY" "$1"; }
      toy_run() { bash "$1/test.sh"; }
      shmutant_reset; shmutant_target lib.sh; shmutant_mut "a" "\$1 + \$2" "\$1 - \$2" add-works
      SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd7" toy_prepare toy_run > "$T/out3" 2>&1; echo "after=$?" >> "$T/out3"' _ "$SHMUTANT" "$T"
    unmake_unremovable "$T/wd7/mut-0/held"
    [ -e "$T/wd7/pristine" ] && fail_ 'a row pool that could not start its workers, under the caller'"'"'s set -e, ended the caller before the prepared tree was removed'
  else
    echo "note: $_unit: no way to make a directory unremovable here; the errexit cleanup case was skipped"
  fi
}

t_pool_prepare_keeps_its_own_errexit() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  cat > "$T/toy/plan.sh" <<'EOF'
prepare() { set -e; false; shmutant_copy_tree "$SHMUTANT_PLAN_DIR" "$1"; }
run() { bash "$1/test.sh"; }
shmutant_target lib.sh
shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
EOF
  mkdir -p "$T/tmpd"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan.sh" > /dev/null 2> "$T/e"; rc_is $? 2 'a prepare whose own set -e fires ends the run as a harness error, not a pass over a partial tree'
  has "$(cat "$T/e")" 'before the pool completed' 'says so'
  eq "$(find "$T/tmpd" -mindepth 1 | wc -l | tr -d ' ')" 0 'and the automatic workdir was still removed'
  lax_prepare() { set -e; shmutant_copy_tree "$TOY" "$1"; }
  case "$-" in *e*) fail_ 'precondition: errexit already on' ;; esac
  shmutant_pool lbl "$T/wd3" lax_prepare toy_run > /dev/null 2>&1; rc_is $? 0 'killed'
  case "$-" in *e*) fail_ 'the errexit prepare turned on leaked into the caller' ;; esac
  # and on a pool that stops right after prepare (a root outside the workdir)
  escaping_lax_prepare() { set -e; shmutant_copy_tree "$TOY" "$1"; printf '%s\n' "$T"; }
  shmutant_pool lbl "$T/wd4" escaping_lax_prepare toy_run > /dev/null 2>&1; rc_is $? 2 'refused'
  case "$-" in *e*) fail_ 'the errexit prepare turned on leaked into the caller through an early return' ;; esac
}

t_pool_clone_keeps_metadata() {
  mk_toy "$T/toy"; TOY="$T/toy"; chmod 555 "$T/toy/lib.sh"
  touch -t 200001010000 "$T/toy/lib.sh" "$T/toy/test.sh"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  SHMUTANT_KEEP=1 SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 0 'a read-only target is still mutated and killed'
  eq "$(ls -l "$T/wd/pristine/lib.sh" | cut -c1-10)" '-r-xr-xr-x' 'copy_tree kept the mode'
  eq "$(ls -l "$T/wd/mut-0/tree/lib.sh" | cut -c1-10)" '-r-xr-xr-x' 'the clone kept the mode through the rewrite'
  # Timestamps are what -p alone adds over the mode bits cp copies anyway.
  [ "$T/wd/pristine/test.sh" -nt "$T/toy/test.sh" ] && fail_ 'copy_tree did not keep the timestamp'
  [ "$T/wd/mut-0/tree/test.sh" -nt "$T/toy/test.sh" ] && fail_ 'the clone did not keep the timestamp'
  mkdir -p "$T/root"; printf 'r\n' > "$T/root/f"; chmod 700 "$T/root"; touch -t 200001010000 "$T/root"
  shmutant_copy_tree "$T/root" "$T/root-copy"; rc_is $? 0 'copies'
  eq "$(ls -ld "$T/root-copy" | cut -c1-10)" 'drwx------' 'the destination root carries the source root mode'
  [ "$T/root-copy" -nt "$T/root" ] && fail_ 'the destination root did not keep the source root timestamp'
  chmod 755 "$T/root" "$T/root-copy"
  local rootowned
  for rootowned in /var/empty /etc/skel /usr/share/base-files /etc/cron.d; do
    [ -d "$rootowned" ] && [ "$(ls -ld "$rootowned" | awk '{ print $3 }')" != "$(id -un)" ] && break
    rootowned=""
  done
  if [ -n "$rootowned" ] && [ "$(id -u)" -ne 0 ]; then
    shmutant_copy_tree "$rootowned" "$T/owned-copy" 2>"$T/e"; rc_is $? 1 'a root whose owner cannot be reproduced is a copy failure, not a silent success'
    has "$(cat "$T/e")" 'could not reproduce' 'says why'
  else
    echo "note: $_unit: no directory owned by another user was available, or running as root; the ownership-failure path was not exercised"
  fi
  chmod 755 "$T/toy/lib.sh"
}

t_pool_reports_a_clone_it_could_not_remove() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # the callback leaves something in its clone that nobody can delete, then fails its witness
  pinning_run() { make_unremovable "$1/pinned" || printf 'unavailable\n' > "$T/skip"; bash "$1/test.sh"; }
  SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare pinning_run
  if [ -e "$T/skip" ]; then echo "note: $_unit: no way to make a directory unremovable here; skipped"; return; fi
  unmake_unremovable "$T/wd/mut-0/tree/pinned"
  rc_is "$RC" 2 'a clone that could not be removed is a harness error, not a pass'
  has "$ERR" 'was not removed' 'names the clone'
  has "$ERR" 'as promised' 'and says the run is unclean'
}

t_pool_refuses_a_worker_dir_under_a_swapped_workdir() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  shmutant_mut 'b' '$1 + $2' '$1 * $2' 'add-works'
  # the first run moves the whole workdir away and leaves a symlink to a caller tree in its
  # place: the second worker's directory, not yet created, must not be made through the link
  mkdir -p "$T/elsewhere"
  swapping_run() { mv "$T/wd" "$T/moved"; ln -s "$T/elsewhere" "$T/wd"; bash "$1/test.sh"; }
  SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare swapping_run
  rc_is "$RC" 2 'a workdir replaced by a symlink is a harness error'
  [ -e "$T/elsewhere/mut-1" ] && fail_ 'a worker directory was created through the symlink'
  rm -f "$T/wd"; mv "$T/moved" "$T/wd" 2>/dev/null
  # the swap two levels up: the workdir's own parent becomes a symlink to a tree holding a
  # directory of the workdir's name, whose mut-1 is the caller's
  mkdir -p "$T/nest/wd" "$T/other/wd/mut-1"; printf 'theirs\n' > "$T/other/wd/mut-1/keep"
  swapping_up_run() { mv "$T/nest" "$T/nest.moved"; ln -s "$T/other" "$T/nest"; bash "$1/test.sh"; }
  SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 pool lbl "$T/nest/wd" toy_prepare swapping_up_run
  rc_is "$RC" 2 'a swap above the workdir'"'"'s parent is a harness error'
  [ -f "$T/other/wd/mut-1/keep" ] || fail_ 'the caller'"'"'s mut-1 behind an ancestor swap was removed'
  rm -f "$T/nest"; mv "$T/nest.moved" "$T/nest" 2>/dev/null
}

t_pool_refuses_unremovable_worker_dir() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  mkdir -p "$T/wd/mut-0"; printf 'killed\n1\n1\n' > "$T/wd/mut-0/verdict"; : > "$T/wd/.shmutant"
  make_unremovable "$T/wd/mut-0/held" || { echo "note: $_unit: no way to make a directory unremovable here; skipped"; return; }
  # with a long caller job of its own, so a bare wait in the failure path would block on it
  sleep 30 & local job=$!
  local t0; t0="$(_shmutant_now)"
  SHMUTANT_BASELINE=0 shmutant_pool lbl "$T/wd" toy_prepare toy_run > "$T/o" 2> "$T/err"; RC=$?
  OUT="$(cat "$T/o")"; ERR="$(cat "$T/err")"
  unmake_unremovable "$T/wd/mut-0/held"
  [ $(( ($(_shmutant_now) - t0) / 1000000 )) -lt 10 ] || fail_ 'the failure path waited on the caller'"'"'s own background job'
  kill "$job" 2>/dev/null; wait "$job" 2>/dev/null
  rc_is "$RC" 2 'a worker directory that cannot be recreated aborts the pool'
  has "$ERR" 'cannot recreate' 'says why'
  hasnt "$OUT" $'\trow\tkilled' 'the stale killed verdict was not reported'
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
  rm -f "$T/trace"
  # A one-second window so both workers reach `start` before either reaches `end` if they run
  # at once; counting the starts before the first end is deterministic where trace order is not.
  trace_run() { echo start >> "$T/trace"; sleep 1; echo end >> "$T/trace"; bash "$1/test.sh"; }
  SHMUTANT_JOBS=1 SHMUTANT_BASELINE=0 pool lbl "$T/wd" toy_prepare trace_run
  rc_is "$RC" 0 'all killed'
  eq "$(field summary 7)" 1 'summary reports jobs=1'
  eq "$(awk '/^end/{print c; exit} /^start/{c++}' "$T/trace")" 1 'with one job only one run has started before the first ends'
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
  : > "$T/stream"; chmod 444 "$T/stream"
  SHMUTANT_STREAM="$T/stream" pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'an unwritable stream is exit 2 before any run: it is opened once, up front'
  has "$ERR" 'cannot open SHMUTANT_STREAM' 'says the stream could not be opened'
  SHMUTANT_EMIT_FAILED=0
  SHMUTANT_STREAM_FD=199 _shmutant_emit shmutant 1 row x 2>/dev/null
  eq "$SHMUTANT_EMIT_FAILED" 1 'a record that cannot be written to the open descriptor is counted as a lost write'
  # in this shell, not a subshell: the failed open and the retry must share the cache
  : > "$T/stream2"; chmod 444 "$T/stream2"
  SHMUTANT_STREAM="$T/stream2" shmutant_pool lbl "$T/wd" toy_prepare toy_run > "$T/o" 2>/dev/null; rc_is $? 2 'unwritable at first'
  chmod 644 "$T/stream2"
  SHMUTANT_STREAM="$T/stream2" shmutant_pool lbl "$T/wd" toy_prepare toy_run > "$T/o" 2>/dev/null; rc_is $? 0 'after the permissions are fixed, a retry with the same path opens it'
  eq "$(grep -c '^shmutant' "$T/stream2")" 3 'and the records land in the file, not on stdout'
  eq "$(cat "$T/o")" '' 'nothing went to stdout'
  chmod 644 "$T/stream"
  SHMUTANT_STREAM="$T/no/such/dir/stream" pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a stream in a missing directory is refused up front'
  SHMUTANT_STREAM="$T/wd/stream" pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a stream inside the workdir is refused: cleanup would delete it'
  has "$ERR" 'inside the workdir' 'says why'
  mkdir -p "$T/wd"; ln -s "$T/wd/inside" "$T/link-stream"
  SHMUTANT_STREAM="$T/link-stream" pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a symlink stream is refused: its referent could be anywhere'
  has "$ERR" 'symlink' 'says why'
  mkfifo "$T/fifo"
  # Bounded: without the guard the first record blocks on the FIFO forever, and a hang is not
  # a failed assertion. The watchdog is the unit's own, not the pool's.
  ( SHMUTANT_STREAM="$T/fifo" shmutant_pool lbl "$T/wd" toy_prepare toy_run > /dev/null 2> "$T/fifo-err" ) &
  local pp=$!
  ( sleep 5; kill "$pp" 2>/dev/null ) & local dog=$!
  wait "$pp"; rc_is $? 2 'a FIFO stream is refused: with no reader the first record would block forever'
  kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
  has "$(cat "$T/fifo-err")" 'not a regular file' 'says why'
}

t_pool_validates_red_status_and_prefix() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  SHMUTANT_RED_STATUS=0 pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'red status 0 is refused: 0 is green'
  SHMUTANT_RED_STATUS=256 pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'red status 256 is refused'
  SHMUTANT_RED_STATUS=foo pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a non-numeric red status is refused'
  SHMUTANT_RED_PREFIX='' pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'an empty red prefix is refused'
  has "$ERR" 'every line' 'says why'
  SHMUTANT_RED_STATUS=99999999999999999999999 pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a red status wider than a shell integer is refused'
  has "$ERR" 'got [99999999999999999999999]' 'the overflowing value is refused as given, not as whatever it wraps to'
  SHMUTANT_TIMEOUT=99999999999999999999999 pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a timeout wider than a shell integer is refused'
  has "$ERR" 'too large' 'says why'
  SHMUTANT_JOBS=0 pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'SHMUTANT_JOBS=0 is refused rather than replaced by the CPU count'
  SHMUTANT_JOBS=abc pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'a non-numeric SHMUTANT_JOBS is refused'
  SHMUTANT_JOBS=99999 pool lbl "$T/wd" toy_prepare toy_run
  rc_is "$RC" 2 'an absurd SHMUTANT_JOBS is refused'
}

t_stream_relative_survives_a_prepare_that_cds() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  wandering_prepare() { shmutant_copy_tree "$TOY" "$1" && cd "$1"; }
  ( cd "$T" && SHMUTANT_STREAM=rel.tsv shmutant_pool lbl "$T/wd" wandering_prepare toy_run > /dev/null 2>&1 ); rc_is $? 0 'killed'
  [ -f "$T/rel.tsv" ] || fail_ 'a relative SHMUTANT_STREAM in a library call was re-based by a prepare that changed directory'
  [ -e "$T/wd/pristine/rel.tsv" ] && fail_ 'the stream was written inside pristine'
}

t_stream_assigned_by_prepare_is_honoured() {
  mk_toy "$T/toy"; TOY="$T/toy"
  shmutant_reset; shmutant_target lib.sh
  shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
  # shellcheck disable=SC2034
  redirecting_prepare() { SHMUTANT_STREAM="$T/late.tsv"; shmutant_copy_tree "$TOY" "$1"; }
  pool lbl "$T/wd" toy_prepare toy_run
  ( shmutant_pool lbl "$T/wd2" redirecting_prepare toy_run > "$T/out" 2>/dev/null ); rc_is $? 0 'killed'
  eq "$(grep -c '^shmutant' "$T/late.tsv")" 3 'a stream path assigned by prepare receives the records'
  eq "$(cat "$T/out")" '' 'and nothing went to stdout'
  ln -sf "$T/victim-late" "$T/late2.tsv"; printf 'precious\n' > "$T/victim-late"
  # shellcheck disable=SC2034
  linking_prepare() { SHMUTANT_STREAM="$T/late2.tsv"; shmutant_copy_tree "$TOY" "$1"; }
  ( shmutant_pool lbl "$T/wd3" linking_prepare toy_run > /dev/null 2>&1 ); rc_is $? 2 'a symlink stream assigned by prepare is refused like one set up front'
  eq "$(cat "$T/victim-late")" precious 'and never written through'
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
  ( set -u; shmutant_copy_tree "$T/src" 2>"$T/e" ); rc_is $? 1 'a missing destination is a copy failure even under set -u'
  # a caller cd function must not make the hard-link scan miss aliases: it points at a known
  # link-free directory, so were the scan to honour it the multiply linked source would pass
  mkdir -p "$T/hlc" "$T/hlc-empty"; printf 'x' > "$T/hlc/a"; ln "$T/hlc/a" "$T/hlc/b"
  ( cd() { builtin cd "$T/hlc-empty"; }; shmutant_copy_tree "$T/hlc" "$T/hlc-copy" 2>/dev/null ); rc_is $? 1 'a caller cd function does not make the hard-link scan pass a multiply linked source'
  # an existing destination with an entry of a source name (here a symlink to a caller file) is
  # refused: the copy neither writes through it nor removes it
  mkdir -p "$T/coll-src" "$T/coll-dst" "$T/coll-victim"; printf 'src\n' > "$T/coll-src/f"; printf 'precious\n' > "$T/coll-victim/f"
  ln -s "$T/coll-victim/f" "$T/coll-dst/f"
  shmutant_copy_tree "$T/coll-src" "$T/coll-dst" 2>"$T/e3"; rc_is $? 1 'a non-empty destination is refused'
  has "$(cat "$T/e3")" 'not empty' 'says why'
  eq "$(cat "$T/coll-victim/f")" precious 'the caller file behind the colliding symlink is untouched'
  [ -L "$T/coll-dst/f" ] || fail_ 'the colliding destination entry was removed'
  mkdir -p "$T/coll-empty"; shmutant_copy_tree "$T/coll-src" "$T/coll-empty"; rc_is $? 0 'an existing empty destination is accepted'
  ( set -u; shmutant_mutate "$T/src/sub/f" y 2>"$T/e2" ); rc_is $? 1 'a mutate call missing an argument is a failure even under set -u'
  mkdir -p "$T/nlm
"; printf 'old\n' > "$T/nlm
/f"; mkdir -p "$T/nlm"
  shmutant_mutate "$T/nlm
/f" old new 2>/dev/null; rc_is $? 1 'a mutate path with a newline is refused'
  eq "$(find "$T/nlm" -mindepth 1 | wc -l | tr -d ' ')" 0 'and nothing was made in the sibling directory'
  has "$(cat "$T/e2")" 'usage' 'reported as a usage error'
  ( set -u; SHMUTANT_SELECT=x shmutant_selected 2>"$T/e3" ); rc_is $? 2 'a selected call with no unit is a usage failure even under set -u'
  has "$(cat "$T/e3")" 'usage' 'reported as a usage error'
  mkdir -p "$T/cwd"
  ( cd "$T/cwd" && shmutant_copy_tree "$T/src" "" 2>/dev/null ); rc_is $? 1 'an empty destination is refused'
  eq "$(find "$T/cwd" -mindepth 1 | wc -l | tr -d ' ')" 0 'and nothing was copied into the current directory'
  has "$(cat "$T/e")" 'usage' 'reported as a usage error, not an unbound-variable abort'
  [ -e "$T/dst2" ] && fail_ 'a missing source was refused only after its destination had been created'
  mkdir -p "$T/gl/.git/objects"; printf 'o' > "$T/gl/.git/objects/x"; ln "$T/gl/.git/objects/x" "$T/gl/.git/objects/y"; printf 'f' > "$T/gl/f"
  shmutant_copy_tree "$T/gl" "$T/gl-copy"; rc_is $? 0 'hard links inside the top-level .git, which the copy skips, do not refuse the copy'
  mkdir -p "$T/a[1]/.git/objects"; printf 'o' > "$T/a[1]/.git/objects/x"; ln "$T/a[1]/.git/objects/x" "$T/a[1]/.git/objects/y"; printf 'f' > "$T/a[1]/f"
  shmutant_copy_tree "$T/a[1]" "$T/a1-copy"; rc_is $? 0 'a source whose name is a glob pattern still has its top-level .git skipped'
  [ -e "$T/a1-copy/.git" ] && fail_ '.git was copied from the bracketed source'
  eq "$(cat "$T/gl-copy/f")" f 'the rest arrived'
  ln -s "$T/hl" "$T/hl-link"; mkdir -p "$T/hl"; printf 'x' > "$T/hl/a"; ln "$T/hl/a" "$T/hl/b"
  shmutant_copy_tree "$T/hl-link" "$T/hl-link-copy" 2>/dev/null; rc_is $? 1 'a symlinked source root is resolved first, so its hard links are still seen'
  mkdir -p "$T/modsrc"; printf 'm' > "$T/modsrc/f"; chmod 750 "$T/modsrc"; ln -s "$T/modsrc" "$T/modsrc-link"
  shmutant_copy_tree "$T/modsrc-link" "$T/modsrc-copy"; rc_is $? 0 'copy through a symlinked source root'
  eq "$(ls -ld "$T/modsrc-copy" | cut -c1-10)" 'drwxr-x---' 'the root mode copied is the directory'"'"'s, not the link'"'"'s'
  mkdir -p "$T/real-dst"; ln -s "$T/real-dst" "$T/dst-link"
  shmutant_copy_tree "$T/src" "$T/dst-link" 2>"$T/e"; rc_is $? 1 'a symlink at the destination is refused'
  has "$(cat "$T/e")" 'is a symlink' 'says why'
  ln -s "$T/src" "$T/into-src"
  shmutant_copy_tree "$T/src" "$T/into-src/.work" 2>"$T/e"; rc_is $? 1 'a destination reached through a symlink into the source is caught as a self-copy'
  has "$(cat "$T/e")" 'inside the source' 'says why'
  [ -e "$T/src/.work" ] && fail_ 'the copy was created through the link'
  [ -e "$T/real-dst/top" ] && fail_ 'the copy went through the destination link'
  shmutant_copy_tree "$T/hl" "$T/hl-copy" 2>"$T/e"; rc_is $? 1 'a source with a hard-linked file is refused: a copy cannot keep the links joined'
  mkdir -p "$T/pwd-real" "$T/pwd-fake"
  ( cd "$T/pwd-real" && PWD="$T/pwd-fake" shmutant_copy_tree "$T/src" copy ); rc_is $? 0 'a relative destination copies'
  [ -e "$T/pwd-real/copy/sub/f" ] || fail_ 'a relative destination was not resolved from the real current directory'
  [ -e "$T/pwd-fake/copy" ] && fail_ 'a relative destination was resolved from the PWD variable instead'
  mkdir -p "$T/dots/src"; printf 'd' > "$T/dots/src/f"
  shmutant_copy_tree "$T/dots/src" "$T/dots/src/junk/../../copy"; rc_is $? 0 'a destination with dot components that resolves outside the source is accepted'
  [ -e "$T/dots/src/junk" ] && fail_ 'a transient component was created inside the source'
  [ -e "$T/dots/copy/junk" ] && fail_ 'the transient component was copied'
  eq "$(cat "$T/dots/copy/f")" d 'the copy landed where the path resolves'
  has "$(cat "$T/e")" 'hard link' 'says why'
  shmutant_copy_tree "$T/src" "$T/src/.work/pristine" 2>"$T/e"; rc_is $? 1 'a destination inside the source is refused'
  has "$(cat "$T/e")" 'inside the source' 'says why'
  [ -e "$T/src/.work" ] && fail_ 'the refusal left the directory it had created inside the source'
}

t_copy_tree_ignores_caller_glob_settings() {
  mkdir -p "$T/src/sub"; printf 'a' > "$T/src/sub/f"; printf 'b' > "$T/src/.hidden"; printf 'c' > "$T/src/top"
  ( set -f; shopt -s failglob dotglob; GLOBIGNORE='*/sub'; shmutant_copy_tree "$T/src" "$T/dst" ); rc_is $? 0 'copies under set -f, failglob, dotglob and GLOBIGNORE'
  eq "$(cat "$T/dst/sub/f" "$T/dst/.hidden" "$T/dst/top" 2>&1)" 'abc' 'every entry arrived exactly once'
  [ -e "$T/dst/.hidden/.hidden" ] && fail_ 'a hidden entry was copied twice (dotglob leaked)'
  mkdir -p "$T/bare/only"; printf 'd' > "$T/bare/only/f"
  ( shopt -s failglob; shmutant_copy_tree "$T/bare" "$T/dst2" ); rc_is $? 0 'a source with no hidden entries copies under failglob'
}

t_bash_floor() {
  _shmutant_bash_ok 5 3; rc_is $? 0 '5.3 is at the floor'
  _shmutant_bash_ok 5 9; rc_is $? 0 '5.9 is above the floor'
  _shmutant_bash_ok 6 0; rc_is $? 0 '6.0 is above the floor'
  _shmutant_bash_ok 5 2; rc_is $? 1 '5.2 is below the floor'
  _shmutant_bash_ok 4 4; rc_is $? 1 '4.4 is below the floor'
  _shmutant_bash_ok 3 2; rc_is $? 1 '3.2 is below the floor'
  has "$(_shmutant_install_hint)" 'bash' 'the install hint names bash'
  # the final dispatch guard invokes the builtin: a caller's function named [ or test that
  # always succeeds does not make sourcing run the CLI and exit the caller's shell
  # shellcheck disable=SC1090
  eq "$( eval '[() { return 0; }; test() { return 0; }'; . "$SHMUTANT" > /dev/null 2>&1; echo alive )" alive 'sourcing under functions named [ and test that always succeed leaves the caller alive'
  # the floor test invokes the builtin, never a caller's function named [
  eq "$( eval '[() { return 0; }'; _shmutant_bash_ok 5 2; echo "rc=$?" )" rc=1 'a function named [ that always succeeds does not make 5.2 pass the floor'
  # the PATH candidate is an executable file, never an (exported) function named bash
  ( bash() { :; }; export -f bash; out="$(_shmutant_path_bash)"
    case "$out" in /*) [ -x "$out" ] && exit 0 ;; esac
    echo "FAIL: $_unit: with a function named bash the PATH lookup returned [$out], not an executable path"; exit 1 ) || _failed=1
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
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan.sh" --workdir --keep > /dev/null 2>"$T/e"; rc_is $? 2 'a flag where a value was expected is refused'
  cp "$T/toy/plan.sh" "$T/toy/plan.sh
"; printf 'exit 7\n' > "$T/toy/plan.sh
"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan.sh
" > /dev/null 2>"$T/e"; rc_is $? 2 'a plan path ending in a newline is refused, not resolved to its sibling'
  has "$(cat "$T/e")" 'newline' 'says why'
  rm -f "$T/toy/plan.sh
"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan.sh" --workdir --keep > /dev/null 2>"$T/e"
  has "$(cat "$T/e")" 'needs a value' 'says so'
  [ -e "./--keep" ] && fail_ 'a directory named --keep was created'
  printf 'touch "$SHMUTANT_PLAN_DIR/loaded"\n' >> "$T/toy/plan.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan.sh" --jobs abc > /dev/null 2>&1; rc_is $? 2 'a bad --jobs is refused'
  [ -e "$T/toy/loaded" ] && fail_ 'the plan ran before its settings were checked'
  sed -i.bak '/loaded/d' "$T/toy/plan.sh"; rm -f "$T/toy/plan.sh.bak"
  ( _shmutant_checksum "$T/does-not-exist" 2>/dev/null ); rc_is $? 2 'a digest that could not be computed is a failure, not an empty line'
  # --keep on the command line, and a prepare that settles SHMUTANT_KEEP=0: the settled value
  # is what the workers honoured and what decides the workdir
  sed 's/^prepare() {/prepare() { SHMUTANT_KEEP=0;/' "$T/toy/plan.sh" > "$T/toy/plan-unkeep.sh"
  rm -rf "$T/tmpd"; mkdir -p "$T/tmpd"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-unkeep.sh" --keep > /dev/null 2>&1
  eq "$(find "$T/tmpd" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" 0 'a prepare that settled SHMUTANT_KEEP=0 under --keep leaves no workdir behind'
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
  kept="$(SHMUTANT_KEEP=1 bash "$SHMUTANT" run "$T/toy/plan.sh" 2>&1 >/dev/null | sed -n 's/^shmutant: workdir kept: //p')"
  [ -n "$kept" ] && [ -f "$kept/mut-0/tree/lib.sh" ] || fail_ 'SHMUTANT_KEEP=1 without --keep did not keep the created workdir'
  [ -n "$kept" ] && rm -rf -- "$kept"
  mkdir -p "$T/decoy"; printf 'exit 3\n' > "$T/decoy/plan.sh"
  ( cd "$T/toy" && PATH="$T/decoy:$PATH" bash "$SHMUTANT" run plan.sh > /dev/null 2>&1 ); rc_is $? 1 'a bare plan name is sourced from its own directory, not from PATH (1: the survivor row, not the decoy'"'"'s 3)'
  { printf 'set -e\nfalse\n'; cat "$T/toy/plan.sh"; } > "$T/toy/plan-ef.sh"
  bash "$SHMUTANT" run "$T/toy/plan-ef.sh" > /dev/null 2>"$T/err-ef"; rc_is $? 2 'a plan whose own set -e fires while loading is a load failure'
  has "$(cat "$T/err-ef")" 'before the pool completed' 'says so'
  { cat "$T/toy/plan.sh"; printf 'made=1\nkeep=0\n'; } > "$T/toy/plan-clobber.sh"
  mkdir -p "$T/theirs"; printf 'keep\n' > "$T/theirs/precious"
  bash "$SHMUTANT" run "$T/toy/plan-clobber.sh" --workdir "$T/theirs" > /dev/null 2>&1; rc_is $? 1 'the clobbering plan still loads and runs'
  eq "$(cat "$T/theirs/precious" 2>/dev/null)" keep 'a plan assigning made=1 cannot make the CLI delete a supplied workdir'
  { cat "$T/toy/plan.sh"; printf 'SHMUTANT_CLI_MADE=1\n'; } > "$T/toy/plan-ro.sh"
  bash "$SHMUTANT" run "$T/toy/plan-ro.sh" --workdir "$T/theirs" > /dev/null 2>&1; rc_is $? 1 'a plan assigning the CLI state names changes nothing outside its subshell'
  eq "$(cat "$T/theirs/precious" 2>/dev/null)" keep 'and the supplied workdir is still there'
  { printf 'cd "$SHMUTANT_PLAN_DIR"\n'; cat "$T/toy/plan.sh"; } > "$T/toy/plan-cd.sh"
  mkdir -p "$T/from"
  ( cd "$T/from" && bash "$SHMUTANT" run "$T/toy/plan-cd.sh" --workdir rel --keep > /dev/null 2>&1 )
  [ -f "$T/from/rel/mut-0/output" ] || fail_ 'a relative --workdir was resolved after the plan changed directory'
  [ -e "$T/toy/rel" ] && fail_ 'artifacts landed relative to the plan directory instead'
  printf 'shmutant_target lib.sh\nshmutant_mut a b c d\n' > "$T/inherit.sh"
  prepare() { mkdir -p "$1"; printf 'b\n' > "$1/lib.sh"; }; run() { :; }; export -f prepare run
  bash "$SHMUTANT" run "$T/inherit.sh" > /dev/null 2>&1; rc_is $? 2 'exported prepare/run functions from the environment do not stand in for the plan'"'"'s'
  unset -f prepare run
  { printf 'set -e\n'; cat "$T/toy/plan.sh"; } > "$T/toy/plan-e.sh"
  bash "$SHMUTANT" run "$T/toy/plan-e.sh" > /dev/null 2>&1; rc_is $? 1 'a plan with set -e still reports the survivor as 1, not an errexit abort'
  kept="$(bash "$SHMUTANT" run "$T/toy/plan-e.sh" --keep 2>&1 >/dev/null | sed -n 's/^shmutant: workdir kept: //p')"
  [ -n "$kept" ] || fail_ 'a plan with set -e made the CLI exit at the pool call before its cleanup and report'
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
  mkdir -p "$T/tmpd"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/broken.sh" > /dev/null 2>&1; rc_is $? 2 'a broken plan is a load failure'
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/norun.sh" > /dev/null 2>&1; rc_is $? 2 'a plan without callbacks is a load failure'
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-ef.sh" > /dev/null 2>&1; rc_is $? 2 'a plan whose errexit fires is a load failure'
  eq "$(find "$T/tmpd" -mindepth 1 | wc -l | tr -d ' ')" 0 'no automatic workdir survives a load failure'
  grep -v "'broken'" "$T/toy/plan.sh" > "$T/toy/plan-base.sh"
  { cat "$T/toy/plan-base.sh"; printf 'trap "echo bye" EXIT\nexit 0\n'; } > "$T/toy/plan-trap.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-trap.sh" > /dev/null 2>"$T/err-trap"; rc_is $? 2 'a plan that installs its own EXIT trap and exits is still a load failure'
  has "$(cat "$T/err-trap")" 'before the pool completed' 'the exit is reported as an incomplete run'
  { cat "$T/toy/plan-base.sh"; printf 'builtin trap "echo bye" EXIT\nexit 0\n'; } > "$T/toy/plan-btrap.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-btrap.sh" > /dev/null 2>&1; rc_is $? 2 'builtin trap cannot replace the guard for the exit that follows'
  { cat "$T/toy/plan-base.sh"; printf 'command trap "echo bye" EXIT; exit 0\n'; } > "$T/toy/plan-ctrap.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-ctrap.sh" > /dev/null 2>&1; rc_is $? 2 'command trap on the same line cannot either'
  { cat "$T/toy/plan-base.sh"; printf 'helper() { builtin trap "echo bye" EXIT; }\nhelper\nexit 0\n'; } > "$T/toy/plan-ftrap.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-ftrap.sh" > /dev/null 2>&1; rc_is $? 2 'nor a trap set inside a helper function'
  { cat "$T/toy/plan-base.sh"; printf 'exit 0\n'; } > "$T/toy/plan-exit.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-exit.sh" > /dev/null 2>&1; rc_is $? 2 'a plan that exits 0 is a load failure, not a pass'
  { printf 'SHMUTANT_KEEP=1\n'; cat "$T/toy/plan-base.sh"; } > "$T/toy/plan-keep.sh"
  kept="$(TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-keep.sh" 2>&1 >/dev/null | sed -n 's/^shmutant: workdir kept: //p')"
  [ -n "$kept" ] && [ -f "$kept/mut-0/tree/lib.sh" ] || fail_ 'SHMUTANT_KEEP=1 set inside the plan did not keep the workdir the CLI created'
  [ -n "$kept" ] && rm -rf -- "$kept"
  cat > "$T/toy/plan-hang.sh" <<'EOF'
prepare() { shmutant_copy_tree "$SHMUTANT_PLAN_DIR" "$1"; }
run() { : > "$SHMUTANT_PLAN_DIR/started"; bash -c "sleep 4; touch '$SHMUTANT_PLAN_DIR/finished'"; }
shmutant_target lib.sh
shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
EOF
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-hang.sh" --timeout 0 --no-baseline > /dev/null 2>&1 & local cli=$!
  wait_for "$T/toy/started" || fail_ 'the run never started'; rm -f "$T/toy/started"
  kill -TERM "$cli"; wait "$cli" 2>/dev/null
  sleep 4
  [ -e "$T/toy/finished" ] && fail_ 'a worker outlived the CLI that was sent TERM'
  eq "$(find "$T/tmpd" -mindepth 1 | wc -l | tr -d ' ')" 0 'the interrupted CLI removed the workdir it created'
  sed 's/^prepare() {/prepare() { : > "$SHMUTANT_PLAN_DIR\/preparing"; sleep 3;/' "$T/toy/plan-hang.sh" > "$T/toy/plan-slow-prepare.sh"
  SHMUTANT_KEEP=1 TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-slow-prepare.sh" --timeout 0 --no-baseline > /dev/null 2>&1 & cli=$!
  wait_for "$T/toy/preparing" || fail_ 'prepare never started'; rm -f "$T/toy/preparing"
  kill -TERM "$cli"; wait "$cli" 2>/dev/null
  [ "$(find "$T/tmpd" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -ge 1 ] || fail_ 'SHMUTANT_KEEP=1 in the environment was not honoured by an interrupt during prepare'
  rm -rf "$T/tmpd"/*
  sed 's/^prepare() {/prepare() { SHMUTANT_KEEP=1;/' "$T/toy/plan-hang.sh" > "$T/toy/plan-hang-keep.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-hang-keep.sh" --timeout 0 --no-baseline > /dev/null 2>&1 & cli=$!
  wait_for "$T/toy/started" || fail_ 'the keep run never started'; rm -f "$T/toy/started"
  kill -TERM "$cli"; wait "$cli" 2>/dev/null
  sleep 4
  rm -f "$T/toy/finished"
  [ "$(find "$T/tmpd" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -ge 1 ] || fail_ 'SHMUTANT_KEEP=1 set by prepare was not honoured when the CLI was interrupted'
  rm -rf "$T/tmpd"/*
  # --keep on the command line, settled to 0 by prepare, then interrupted: the workdir the CLI
  # created is removed, as an uninterrupted run with that settled value would
  sed 's/^prepare() {/prepare() { SHMUTANT_KEEP=0;/' "$T/toy/plan-hang.sh" > "$T/toy/plan-hang-unkeep.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-hang-unkeep.sh" --keep --timeout 0 --no-baseline > /dev/null 2>&1 & cli=$!
  wait_for "$T/toy/started" || fail_ 'the unkeep run never started'; rm -f "$T/toy/started"
  kill -TERM "$cli"; wait "$cli" 2>/dev/null
  sleep 4; rm -f "$T/toy/finished"
  eq "$(find "$T/tmpd" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" 0 'a workdir created under --keep that prepare settled to 0 is removed on an interrupt'
  # the workdir's parent swapped for a link to a caller tree holding a directory of the same
  # name: neither the final cleanup nor an interrupt may remove through it
  # (the swap is two levels up: the workdir's own parent stays a real directory, reached
  # through the link, so only the pinned physical parent can tell)
  mkdir -p "$T/tmp2/nest/deeper" "$T/toy/theirs"
  cat > "$T/toy/plan-swap-parent.sh" <<'EOF'
prepare() { shmutant_copy_tree "$SHMUTANT_PLAN_DIR" "$1"; }
run() { local w; w="$(cd "$1/../.." && pwd -P)"; local up; up="$(dirname "$(dirname "$w")")"; mkdir -p "$SHMUTANT_PLAN_DIR/theirs/deeper/$(basename "$w")/keep"; mv "$up" "$up.moved"; ln -s "$SHMUTANT_PLAN_DIR/theirs" "$up"; bash "$1/test.sh"; }
shmutant_target lib.sh
shmutant_mut 'a' '$1 + $2' '$1 - $2' 'add-works'
EOF
  TMPDIR="$T/tmp2/nest/deeper" bash "$SHMUTANT" run "$T/toy/plan-swap-parent.sh" --no-baseline > /dev/null 2>"$T/e"
  [ "$(find "$T/toy/theirs" -name keep | wc -l | tr -d ' ')" -ge 1 ] || fail_ 'the caller tree behind a swapped workdir ancestor was removed by the CLI cleanup'
  has "$(cat "$T/e")" 'no longer the workdir this run created' 'the swap is reported'
  rm -f "$T/tmp2/nest"; mv "$T/tmp2/nest.moved" "$T/tmp2/nest" 2>/dev/null; rm -rf "$T/tmp2" "$T/toy/theirs"
  # SHMUTANT_KEEP=1 in the environment, interrupted while the plan is still loading (before
  # anything could be reported): the decision was the operator's, and the workdir stays
  { printf ': > "$SHMUTANT_PLAN_DIR/loading"; sleep 3\n'; cat "$T/toy/plan-hang.sh"; } > "$T/toy/plan-slow-load.sh"
  SHMUTANT_KEEP=1 TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-slow-load.sh" --timeout 0 --no-baseline > /dev/null 2>&1 & cli=$!
  wait_for "$T/toy/loading" || fail_ 'the plan never started loading'; rm -f "$T/toy/loading"
  kill -TERM "$cli"; wait "$cli" 2>/dev/null
  [ "$(find "$T/tmpd" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -ge 1 ] || fail_ 'SHMUTANT_KEEP=1 in the environment was not honoured by an interrupt during plan load'
  rm -rf "$T/tmpd"/*
  # SHMUTANT_KEEP=1 assigned by the plan at load time, interrupted while prepare is still running
  { printf 'SHMUTANT_KEEP=1\n'; cat "$T/toy/plan-slow-prepare.sh"; } > "$T/toy/plan-load-keep.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-load-keep.sh" --timeout 0 --no-baseline > /dev/null 2>&1 & cli=$!
  wait_for "$T/toy/preparing" || fail_ 'prepare never started'; rm -f "$T/toy/preparing"
  kill -TERM "$cli"; wait "$cli" 2>/dev/null
  [ "$(find "$T/tmpd" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -ge 1 ] || fail_ 'SHMUTANT_KEEP=1 assigned by the plan at load was not honoured by an interrupt during prepare'
  rm -rf "$T/tmpd"/*
  # an interrupt in a caller-supplied workdir leaves no marker files behind
  mkdir -p "$T/mine"
  bash "$SHMUTANT" run "$T/toy/plan-hang.sh" --workdir "$T/mine" --timeout 0 --no-baseline > /dev/null 2>&1 & cli=$!
  wait_for "$T/toy/started" || fail_ 'the run never started'; rm -f "$T/toy/started"
  kill -TERM "$cli"; wait "$cli" 2>/dev/null
  sleep 4; rm -f "$T/toy/finished"
  eq "$(find "$T/mine" -maxdepth 1 -name '.done.*' -o -maxdepth 1 -name '.keep.*' | wc -l | tr -d ' ')" 0 'no completion or keep marker survives an interrupt in the caller'"'"'s workdir'
  SHMUTANT_KEEP=1 TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-hang.sh" --timeout 0 --no-baseline > /dev/null 2>&1 & cli=$!
  wait_for "$T/toy/started" || fail_ 'the env-keep run never started'; rm -f "$T/toy/started"
  kill -TERM "$cli"; wait "$cli" 2>/dev/null
  sleep 4
  rm -f "$T/toy/finished"
  [ "$(find "$T/tmpd" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -ge 1 ] || fail_ 'with SHMUTANT_KEEP=1 the interrupted CLI still removed its workdir'
  rm -rf "$T/tmpd"/*
  { cat "$T/toy/plan-base.sh"; printf 'echo plan-says-hello\n'; } > "$T/toy/plan-chatty.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-chatty.sh" > "$T/chatty.out" 2>"$T/chatty.err"
  hasnt "$(cat "$T/chatty.out")" 'plan-says-hello' 'what a plan prints while loading stays out of the verdict stream'
  has "$(cat "$T/chatty.err")" 'plan-says-hello' 'and reaches stderr instead'
  eq "$(grep -vc '^shmutant	1	' "$T/chatty.out")" 0 'every stdout line is a record'
  { cat "$T/toy/plan-base.sh"; printf 'exec bash -c "sleep 4; touch %s/execd"\n' "$T/toy"; } > "$T/toy/plan-exec-hang.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-exec-hang.sh" --timeout 0 > /dev/null 2>&1 & cli=$!
  sleep 1
  local t0; t0="$(_shmutant_now)"
  kill -TERM "$cli"; wait "$cli" 2>/dev/null
  [ $(( ($(_shmutant_now) - t0) / 1000000 )) -lt 10 ] || fail_ 'interrupting a CLI whose plan execd a command blocked instead of killing it'
  sleep 4
  [ -e "$T/toy/execd" ] && fail_ 'the command the plan execd into outlived the interrupted CLI'
  # A plan forging the marker while loading, by every name the workdir could give it.
  { cat "$T/toy/plan-base.sh"; printf 'for f in "${SHMUTANT_CLI_DONE_PATH:-}" "$SHMUTANT_CLI_WD"/.done.*; do [ -n "$f" ] && [ -e "$f" ] && printf "0 0\\n" > "$f"; done; exit 0\n'; } > "$T/toy/plan-forge.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-forge.sh" > /dev/null 2>&1; rc_is $? 2 'a plan that writes a completion marker while loading and exits 0 is still a load failure'
  { cat "$T/toy/plan-base.sh"; printf 'exec true\n'; } > "$T/toy/plan-exec.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-exec.sh" > /dev/null 2>&1; rc_is $? 2 'a plan that execs cannot become a passing run'
  { printf 'set -e\nroot="$(pwd)"\n( true )\n'; cat "$T/toy/plan-base.sh"; } > "$T/toy/plan-subs.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-subs.sh" > /dev/null 2>&1; rc_is $? 1 'a plan with set -e, a command substitution and a subshell loads and runs normally'
  { cat "$T/toy/plan-base.sh"; printf 'trap "echo usr" USR1\n'; } > "$T/toy/plan-usr.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-usr.sh" > /dev/null 2>&1; rc_is $? 1 'a plan may still trap other signals'
  eq "$(find "$T/tmpd" -mindepth 1 | wc -l | tr -d ' ')" 0 'no automatic workdir survives those load failures'
  ( cd "$T" && TMPDIR="$T/tmpd" SHMUTANT_STREAM=missing/out.tsv bash "$SHMUTANT" run "$T/toy/plan-base.sh" > /dev/null 2>"$T/e" ); rc_is $? 2 'a relative SHMUTANT_STREAM in a missing directory is refused'
  has "$(cat "$T/e")" 'does not exist' 'says why'
  [ -e "$T/out.tsv" ] && fail_ 'the stream was re-based onto the wrong directory'
  # prepare leaves a read-only tree in the workdir and ends the subshell before the pool could
  # clean up: the automatic workdir is still removed.
  { cat "$T/toy/plan-base.sh"; printf 'prepare() { mkdir -p "$1/ro"; : > "$1/ro/f"; chmod 555 "$1/ro"; exit 0; }\n'; } > "$T/toy/plan-roexit.sh"
  TMPDIR="$T/tmpd" bash "$SHMUTANT" run "$T/toy/plan-roexit.sh" > /dev/null 2>&1; rc_is $? 2 'a prepare that exits is a harness error'
  eq "$(find "$T/tmpd" -mindepth 1 | wc -l | tr -d ' ')" 0 'the automatic workdir holding a read-only tree was removed after the early exit'
  ( cd "$T" && TMPDIR=tmpd SHMUTANT_STREAM=out.tsv bash "$SHMUTANT" run "$T/toy/plan-cd.sh" > /dev/null 2>&1 )
  [ -f "$T/out.tsv" ] || fail_ 'a relative SHMUTANT_STREAM was resolved after the plan changed directory'
  [ -e "$T/toy/out.tsv" ] && fail_ 'the stream landed relative to the plan directory'
  eq "$(find "$T/tmpd" -mindepth 1 | wc -l | tr -d ' ')" 0 'a relative TMPDIR workdir is resolved before the plan cds, and removed'
  [ -e "$T/toy/tmpd" ] && fail_ 'a second workdir was created relative to the plan directory'
  bash "$SHMUTANT" > /dev/null 2>&1; rc_is $? 2 'no command is usage'
  bash "$SHMUTANT" bogus > /dev/null 2>&1; rc_is $? 2 'an unknown command is usage'
  has "$(bash "$SHMUTANT" help)" 'usage:' 'help prints usage'
  eq "$(bash "$SHMUTANT" version)" "shmutant $SHMUTANT_VERSION" 'version prints the marker'
  eq "$(bash "$SHMUTANT" checksum)" "$(_shmutant_checksum "$SHMUTANT")" 'checksum hashes the file it runs from'
  case "$(bash "$SHMUTANT" checksum)" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) fail_ 'checksum is not a hex digest' ;;
  esac
  local platform
  if command -v sha256sum > /dev/null 2>&1; then platform="$(sha256sum "$SHMUTANT" | awk '{print $1}')"
  else platform="$(shasum -a 256 "$SHMUTANT" | awk '{print $1}')"; fi
  eq "$(_shmutant_checksum "$SHMUTANT")" "$platform" 'checksum agrees with the platform tool'
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

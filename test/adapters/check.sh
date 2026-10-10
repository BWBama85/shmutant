#!/usr/bin/env bash
# test/adapters/check.sh <bats|shellspec> — run the adapter block docs/integrating.md gives for
# <framework>, byte for byte, on its fixture under test/adapters/<framework>, through
# `shmutant.sh run`, and require what the doc says of it: the verdict stream the fixture's
# expected.tsv lists, the same stream with SHMUTANT_BASELINE=0 save that the row whose selector
# matches nothing is `aborted`, exact selection by the block's own `run`, and the framework
# version the doc names.
#
# Needs the framework on PATH, at the version CI pins. Prints the verdict stream on stdout.
# Exit 0 = every check held; 1 = a check failed, after printing the stream, the CLI's stderr and
# every run's output to stderr; 2 = the check could not run (usage, no framework, no block).
set -u
unset CDPATH

# An inherited SHMUTANT_SELECT, SHMUTANT_STREAM, SHMUTANT_BASELINE=0 or red setting would change
# what the run proves. FORCE_COLOR is set because CI environments often set it, and the blocks
# must keep their red lines plain there; NO_COLOR would mask it.
unset -v "${!SHMUTANT_@}" NO_COLOR
export FORCE_COLOR=1

fw="${1:-}"
case "$fw" in
  bats)      heading='### Bats';      plan=test/mutants.sh; vprefix=''
             nomatch='a witness no test carries' ;;
  shellspec) heading='### ShellSpec'; plan=spec/mutants.sh; vprefix='ShellSpec '
             nomatch='a selector no example carries' ;;
  *)         echo "usage: test/adapters/check.sh bats|shellspec" >&2; exit 2 ;;
esac
command -v "$fw" > /dev/null || { echo "check: $fw is not on PATH" >&2; exit 2; }

root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)" || exit 2
doc="$root/docs/integrating.md"
made="$(mktemp -d "${TMPDIR:-/tmp}/adapters.XXXXXX")" || exit 2
trap 'rm -rf -- "$made"' EXIT
tmp="$(cd -P -- "$made" && pwd -P)" || exit 2

fails=0
bad() { printf 'FAIL: %s: %s\n' "$fw" "$*" >&2; fails=$((fails + 1)); }

# The doc's text under <heading>, up to the next heading outside a fence; then its first sh block.
awk -v h="$heading" '
  $0 == h { on = 1; next }
  !on { next }
  /^```/ { fence = !fence }
  !fence && /^#/ { exit }
  { print }' "$doc" > "$tmp/section" || exit 2
awk 'on && $0 == "```" { done = 1; exit }
     on { print; n++ }
     $0 == "```sh" { on = 1 }
     END { exit !(done && n) }' "$tmp/section" > "$tmp/adapter.sh" \
  || { echo "check: no \`\`\`sh block under '$heading' in docs/integrating.md" >&2; exit 2; }

version="$("$fw" --version | head -n 1)"
[ -n "$version" ] || { echo "check: $fw --version printed nothing" >&2; exit 2; }
version="$vprefix$version"
tr '\n' ' ' < "$tmp/section" | grep -qwF -- "$version" \
  || bad "the doc's $heading section does not name the version run here: $version"

cp -R -- "$root/test/adapters/$fw" "$tmp/fixture" || exit 2
# The block goes beside the plan in the copy, through the physical path of the plan's
# directory and never through a link already at its name: a symlink at either, carried over
# from the working tree, would take the write outside the copy.
dest="$(cd -P -- "$tmp/fixture/${plan%/*}" && pwd -P)" || exit 2
case "$dest" in
  "$tmp/fixture/"*) ;;
  *) echo "check: $fw: ${plan%/*} in the fixture copy resolves outside it, to $dest" >&2; exit 2 ;;
esac
rm -f -- "$dest/adapter.sh" || exit 2
cp -- "$tmp/adapter.sh" "$dest/adapter.sh" || exit 2

# pool <name> — run the plan from inside the copy of the fixture, one that holds the unmutated
# library, so an adapter that ran the tests there instead of in the clone would see no mutant at
# all. A setting assigned before the call reaches that run only. Its workdir, stream and stderr
# are $tmp/wd-<name>, $tmp/stream-<name> and $tmp/stderr-<name>; its status is the return.
pool() {
  (cd -- "$tmp/fixture" && exec bash "$root/shmutant.sh" run "$tmp/fixture/$plan" --workdir "$tmp/wd-$1" --keep) \
    > "$tmp/stream-$1" 2> "$tmp/stderr-$1"
}
# reduce <stream> — every record, reduced to what expected.tsv states of it and sorted; anything
# else is a line of its own.
reduce() {
  awk -F'\t' -v OFS='\t' '
    $1 != "shmutant" || $2 != 1 { print "foreign", $0; next }
    $3 == "baseline"            { print "baseline", $4, $5; next }
    $3 == "row"                 { print "row", $5, $4; next }
    $3 == "summary"             { print "summary", $5, $6; next }
                                { print "foreign", $0 }' "$1" | LC_ALL=C sort
}

# --- the pool as the doc gives it.
pool on; rc=$?
cat -- "$tmp/stream-on"
[ "$rc" -eq 1 ] || bad "shmutant exited $rc; expected 1 (rows not killed, no harness error)"
reduce "$tmp/stream-on" > "$tmp/got"
LC_ALL=C sort -- "$tmp/fixture/expected.tsv" > "$tmp/want"
diff -- "$tmp/want" "$tmp/got" >&2 || bad "the verdict stream is not test/adapters/$fw/expected.tsv (above: < expected, > got)"

# --- with SHMUTANT_BASELINE=0, as the doc says of a selector that matches nothing: the row
# expected.tsv scores `baseline` for it is `aborted`, no baseline record is written, and every
# other record stands.
SHMUTANT_BASELINE=0 pool off; rc=$?
[ "$rc" -eq 1 ] || bad "with SHMUTANT_BASELINE=0, shmutant exited $rc; expected 1"
reduce "$tmp/stream-off" > "$tmp/got-off"
awk -F'\t' -v OFS='\t' -v nomatch="$nomatch" '
  $1 == "baseline" { next }
  $1 == "row" && $2 == nomatch && $3 == "baseline" { $3 = "aborted"; n++ }
  { print }
  END { exit n != 1 }' "$tmp/want" > "$tmp/want-off.unsorted" \
  || bad "test/adapters/$fw/expected.tsv does not score the row '$nomatch' baseline exactly once"
LC_ALL=C sort -- "$tmp/want-off.unsorted" > "$tmp/want-off"
diff -- "$tmp/want-off" "$tmp/got-off" >&2 \
  || bad "with SHMUTANT_BASELINE=0, the verdict stream is not the one derived from expected.tsv (above: < expected, > got)"

# --- selection, by the block's own run called directly: the TAP plan and result lines it prints.
# call_run <root> <select> — the block sourced alone, its table calls stubbed, then `run`,
# without this script's nounset, which the pool does not impose either.
call_run() {
  (
    set +u
    shmutant_copy_tree() { :; }; shmutant_target() { :; }; shmutant_mut() { :; }
    # shellcheck disable=SC1091
    . "$tmp/adapter.sh"
    export SHMUTANT_SELECT="$2"
    run "$1" "$2"
  )
}
# selects <select> <status> <tap-line>… — run exits <status> and prints exactly these TAP lines.
selects() {
  local sel="$1" want_rc="$2" out got want n
  shift 2
  out="$(cd -- "$tmp" && call_run "$tmp/fixture" "$sel" 2>> "$tmp/selects.err")"; n=$?
  got="$(printf '%s\n' "$out" | grep -E '^(1\.\.[0-9]+|ok |not ok )')"
  want="$(printf '%s\n' "$@")"
  [ "$n" -eq "$want_rc" ] || bad "selecting '$sel': run exited $n, expected $want_rc"
  [ "$got" = "$want" ] || bad "selecting '$sel': TAP lines '${got//$'\n'/ | }', expected '${want//$'\n'/ | }'"
}

case "$fw" in
  bats)
    selects 'parse rejects empty input' 0 '1..1' 'ok 1 parse rejects empty input'
    selects 'parse.empty (status) [1]' 0 '1..1' 'ok 1 parse.empty (status) [1]'
    selects 'parse keeps \ ^ $ | * + ? { }' 0 '1..1' 'ok 1 parse keeps \ ^ $ | * + ? { }'
    selects 'parse a{2}' 0 '1..1' 'ok 1 parse a{2}'
    selects 'parse prints its input' 0 '1..2' 'ok 1 parse prints its input' 'ok 2 parse prints its input'
    selects 'parse has no such test' 1 '1..0' ;;
  shellspec)
    selects 'rejects empty input' 0 '1..1' 'ok 1 - parse rejects empty input'
    selects 'refuses [empty] input *?' 0 '1..1' 'ok 1 - parse refuses [empty] input *?'
    selects 'prints its input' 0 '1..2' 'ok 1 - parse prints its input' 'ok 2 - twin parse prints its input'
    selects 'keeps a|b' 0 '1..2' 'ok 1 - parse keeps a|b' 'ok 2 - parse keeps a-b'
    selects 'parse' 0 '1..11' 'ok 1 - parse rejects empty input' 'ok 2 - parse rejects empty input with status 1' \
      'ok 3 - parse prints its input' 'ok 4 - parse refuses [empty] input *?' 'ok 5 - parse refuses e input *?' \
      'ok 6 - parse refuses [empty] input X?' 'ok 7 - parse refuses [empty] input *X' 'ok 8 - parse keeps a|b' \
      'ok 9 - parse b' 'ok 10 - parse keeps a-b' 'ok 11 - twin parse prints its input'
    # A fatal error (the library Include names is missing) exits 102 with no failing example.
    cp -R -- "$tmp/fixture" "$tmp/broken" || exit 2
    rm -f -- "$tmp/broken/lib/parse.sh"
    out="$(cd -- "$tmp" && call_run "$tmp/broken" 'rejects empty input' 2>> "$tmp/selects.err")"; n=$?
    [ "$n" -eq 102 ] || bad "a missing Include exited $n, expected 102"
    case "$out" in *'not ok '*) bad "a missing Include printed a failing example" ;; esac ;;
esac

if [ "$fails" -gt 0 ]; then
  {
    printf '== shmutant stderr\n'; cat -- "$tmp/stderr-on"
    printf '== shmutant stream with SHMUTANT_BASELINE=0\n'; cat -- "$tmp/stream-off" 2>/dev/null
    printf '== shmutant stderr with SHMUTANT_BASELINE=0\n'; cat -- "$tmp/stderr-off" 2>/dev/null
    printf '== run stderr from the selection checks\n'; cat -- "$tmp/selects.err" 2>/dev/null
    for f in "$tmp"/wd-*/*/output; do
      [ -f "$f" ] || continue
      printf '== %s\n' "${f#"$tmp"/}"; cat -- "$f"
    done
  } >&2
  printf 'check: %s: %d check(s) failed\n' "$fw" "$fails" >&2
  exit 1
fi
printf 'check: %s: every check held (%s)\n' "$fw" "$version" >&2

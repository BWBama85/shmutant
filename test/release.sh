#!/usr/bin/env bash
# test/release.sh — scripts/release.sh, run in throwaway clones of a local bare origin with gh,
# curl and sleep stubbed on PATH, so no case reaches GitHub or the network.
#
# Each case gets its own fixture: the origin, and a clone of it on main holding this checkout's
# scripts/release.sh beside a small shmutant.sh (SHMUTANT_VERSION=1.2.3), its CHECKSUMS, and a
# docs/integrating.md naming the fixture's install URL; CI green by default. One case runs the
# repository's own shmutant.sh and docs/integrating.md through the same checks.
#
# Needs git and jq (the gh stub answers --jq with it). Exit 0 = every case held; 1 = a case
# failed, each failure a `FAIL: <case>: …` line; 2 = the test could not run.
while IFS=' ' builtin read -r _ _ _fn; do [[ -n $_fn ]] && builtin unset -f "$_fn"; done <<EOF
$(builtin declare -F)
EOF
set -u
unset CDPATH

for t in git jq; do
  command -v "$t" > /dev/null || { echo "test/release.sh: $t is not on PATH" >&2; exit 2; }
done
root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
# ino <path> — the inode of <path> itself; status 1, printing nothing, when ls cannot read it.
ino() {
  local out id
  out="$(ls -di -- "$1" 2> /dev/null)" || return 1
  read -r id _ <<< "$out"
  case "$id" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$id"
}
# Made under the physical TMPDIR, so its name is final when mktemp returns. It is removed only
# while it keeps the inode read just after; until that inode is read, only an empty directory there.
base="$(cd -P -- "${TMPDIR:-/tmp}" && pwd -P)" || exit 2
tmp="$(mktemp -d "$base/release-test.XXXXXX")" || exit 2
tmp_id=""
trap 'if [ -z "$tmp_id" ]; then rmdir -- "$tmp" 2> /dev/null || echo "test/release.sh: left $tmp in place" >&2
  elif id="$(ino "$tmp")" && [ "$id" = "$tmp_id" ]; then rm -rf -- "$tmp"
  else echo "test/release.sh: left $tmp in place" >&2; fi' EXIT
tmp_id="$(ino "$tmp")" || exit 2

SLUG=shmutant-test/fixture
VER=1.2.3
TAG="v$VER"
URL="https://raw.githubusercontent.com/$SLUG/$TAG/shmutant.sh"

# No git setting from the caller reaches a fixture: not a repository or index it names, nor a user
# or system config (a tag.gpgSign there would sign the fixture's tags). https and ssh are refused
# outright, so a fixture whose insteadOf went missing fails rather than reach GitHub.
unset -v "${!GIT_@}"
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" GIT_CONFIG_NOSYSTEM=1 \
  GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid \
  GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid \
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=protocol.https.allow GIT_CONFIG_VALUE_0=never \
  GIT_CONFIG_KEY_1=protocol.ssh.allow GIT_CONFIG_VALUE_1=never
mkdir -p "$HOME" "$tmp/bin" || exit 2

# --- stubs: every call is appended to $STUB/events, one line each ------------------------------

cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh, as scripts/release.sh calls it, answered from the fixture in $STUB. Exit 3 = a call the
# driver should not make, or one it made with prompts left on.
unset -f git
{ printf 'gh'; printf ' %q' "$@"; printf '\n'; } >> "$STUB/events"
# $STUB/gh.signal (TERM or INT): the call sends that signal to the caller's process group.
[ ! -e "$STUB/gh.signal" ] || kill "-$(cat "$STUB/gh.signal")" 0
[ "${GH_PROMPT_DISABLED:-}" = 1 ] && [ "${GIT_TERMINAL_PROMPT:-}" = 0 ] && [ "${GIT_ASKPASS:-}" = false ] \
  || { echo "gh stub: called with prompts or askpass enabled" >&2; exit 3; }
jqx=""; paginate=0; a=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) jqx="$2"; shift 2 ;;
    --paginate) paginate=1; shift ;;
    *) a+=("$1"); shift ;;
  esac
done
reply() { if [ -n "$jqx" ]; then jq -r "$jqx"; else cat; fi; }
# pages — a list read must ask for every page.
pages() { [ "$paginate" -eq 1 ] || { echo "gh stub: a list read without --paginate" >&2; exit 3; }; }
fail() { echo "gh: $1" >&2; exit 1; }
# opts <args>… — sets repo, dir, output, verify, patterns and files from a release subcommand's arguments.
opts() {
  repo=""; dir=""; output=""; verify=0; files=(); patterns=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -R) repo="$2"; shift 2 ;;
      --dir) dir="$2"; shift 2 ;;
      -O) output="$2"; shift 2 ;;
      --pattern) patterns+=("$2"); shift 2 ;;
      --title|--notes) shift 2 ;;
      --verify-tag) verify=1; shift ;;
      *) files+=("$1"); shift ;;
    esac
  done
  [ "$repo" = "github.com/$SLUG" ] || { echo "gh stub: -R $repo, not github.com/$SLUG" >&2; exit 3; }
}
# An api call names no host, so the driver must have pinned GH_HOST; a release command names its
# own with -R (checked in opts), so a printed one works from the operator's shell too.
[ "${a[0]:-}" != api ] || [ "${GH_HOST:-}" = github.com ] || { echo "gh stub: api call not pinned to github.com" >&2; exit 3; }
case "${a[0]:-} ${a[1]:-}" in
  "api repos/$SLUG/git/ref/heads/main")
    [ ! -e "$STUB/api-main.fail" ] || fail "HTTP 502"
    sha="$(cat "$STUB/api-main" 2> /dev/null || git -C "$STUB/origin.git" rev-parse refs/heads/main)" || exit 1
    printf '{"object":{"sha":"%s"}}\n' "$sha" | reply ;;
  "api repos/$SLUG")
    printf '{"permissions":{"push":%s}}\n' "$(cat "$STUB/push" 2> /dev/null || echo true)" | reply ;;
  "api repos/$SLUG/commits/"*"/check-suites?per_page=1")
    printf '{"total_count":%s}\n' "$(cat "$STUB/suites" 2> /dev/null || echo 1)" | reply ;;
  "api repos/$SLUG/commits/"*"/check-runs?filter=latest&per_page=1")
    reply < "$STUB/checks.json" ;;
  "api repos/$SLUG/actions/workflows/ci.yml/runs?head_sha="*"&per_page=1")
    reply < "$STUB/runs.json" ;;
  "api repos/$SLUG/commits/"*"/check-runs?filter=latest&per_page=100")
    pages; [ ! -e "$STUB/checks.fail" ] || fail "HTTP 502"
    reply < "$STUB/checks.json" ;;
  "api repos/$SLUG/actions/workflows/ci.yml/runs?head_sha="*"&per_page=100")
    pages; reply < "$STUB/runs.json" ;;
  "api repos/$SLUG/commits/"*"/status")
    reply < "$STUB/status.json" ;;
  "api repos/$SLUG/git/matching-refs/tags/"*)
    # GitHub's view of the tag: origin's, unless $STUB/github-tag overrides it with a commit,
    # `none`, or `after:<commit>` (none until origin has the tag, then that commit).
    pages; t="${a[1]##*/}"; typ=commit; sha=""
    # $STUB/github-tag.fail-after: the read fails once origin has the tag.
    if [ -e "$STUB/github-tag.fail-after" ] && git -C "$STUB/origin.git" rev-parse -q --verify "refs/tags/$t" > /dev/null; then
      fail "HTTP 502"
    fi
    if [ -e "$STUB/github-tag" ]; then
      v="$(cat "$STUB/github-tag")"
      case "$v" in
        none) sha="" ;;
        after:*) ! git -C "$STUB/origin.git" rev-parse -q --verify "refs/tags/$t" > /dev/null || sha="${v#after:}" ;;
        *) sha="$v" ;;
      esac
    else
      line="$(git -C "$STUB/origin.git" for-each-ref --format='%(objecttype) %(objectname)' "refs/tags/$t")"
      [ -z "$line" ] || { typ="${line%% *}"; sha="${line#* }"; }
    fi
    if [ -n "$sha" ]; then printf '[{"ref":"refs/tags/%s","object":{"type":"%s","sha":"%s"}}]\n' "$t" "$typ" "$sha" | reply
    else echo '[]' | reply; fi ;;
  "api repos/$SLUG/git/tags/"*)
    printf '{"object":{"sha":"%s"}}\n' "$(git -C "$STUB/origin.git" rev-parse "${a[1]##*/}^{}")" | reply ;;
  "api repos/$SLUG/releases?per_page=100")
    pages
    # $STUB/advance-main holds a commit origin's main moves to once the releases are listed: the
    # last read of the checks, so a cut sees main move between its checks and its tag.
    [ ! -e "$STUB/advance-main" ] || git -C "$STUB/origin.git" update-ref refs/heads/main "$(cat "$STUB/advance-main")" || exit 1
    # $STUB/advance-api-main: at the same point GitHub's main, as the API reports it, moves there
    # while origin's stays (origin's URL leading to a mirror).
    [ ! -e "$STUB/advance-api-main" ] || cp -- "$STUB/advance-api-main" "$STUB/api-main" || exit 1
    # $STUB/api-main.fail-later: from the same point, reads of GitHub's main fail.
    [ ! -e "$STUB/api-main.fail-later" ] || : > "$STUB/api-main.fail" || exit 1
    draft=false; [ ! -e "$STUB/release.draft" ] || draft=true
    as="$(ls -1 -- "$STUB/release" 2> /dev/null | jq -Rn '[inputs | {name: .}]')" || exit 1
    ls -- "$STUB/published" | jq -Rn --argjson d "$draft" --argjson as "$as" \
      '[inputs | {tag_name: ., draft: $d, assets: $as}]' | reply ;;
  "release create")
    [ ! -e "$STUB/create.fail" ] || fail "HTTP 500"
    t="${a[2]}"; opts "${a[@]:3}"
    [ "$verify" -eq 1 ] || { echo "gh stub: release create without --verify-tag" >&2; exit 3; }
    git -C "$STUB/origin.git" rev-parse -q --verify "refs/tags/$t" > /dev/null || fail "tag $t doesn't exist in the repo"
    mkdir -p "$STUB/release" && cp -- "${files[@]}" "$STUB/release/" || exit 1
    [ ! -e "$STUB/asset.tamper" ] || echo '# tampered' >> "$STUB/release/$(cat "$STUB/asset.tamper")"
    [ ! -e "$STUB/asset.omit" ] || rm -f -- "$STUB/release/$(cat "$STUB/asset.omit")"
    [ ! -e "$STUB/asset.extra" ] || echo 'release notes' > "$STUB/release/notes.txt"
    # The driver runs this from <its directory>/assets.
    made="$(dirname -- "$PWD")"; name="$(basename -- "$made")"
    # $STUB/retarget: the TMPDIR symlink now leads elsewhere, where a victim sits at the run's name.
    if [ -e "$STUB/retarget" ]; then
      ln -sfn "$STUB/b" "$STUB/link" && mkdir -p "$STUB/b/$name/assets" \
        && echo victim > "$STUB/b/$name/victim" && echo theirs > "$STUB/b/$name/assets/shmutant.sh" || exit 1
    fi
    # $STUB/link-tmp: the run's directory is replaced by a link to another directory that holds a
    # byte-identical copy of the asset.
    if [ -e "$STUB/link-tmp" ]; then
      mkdir -p "$STUB/elsewhere/assets" && cp -- shmutant.sh "$STUB/elsewhere/assets/" \
        && mv -- "$made" "$made.moved" && ln -s "$STUB/elsewhere" "$made" || exit 1
    fi
    # $STUB/replace-asset: within the run's own directory, shmutant.sh becomes a new file, identical.
    if [ -e "$STUB/replace-asset" ]; then
      cp -- shmutant.sh .replacement && mv -- .replacement shmutant.sh || exit 1
    fi
    # $STUB/replace-identical: the run's directory is moved away, and another made at its path holds
    # byte-identical copies of both assets.
    if [ -e "$STUB/replace-identical" ]; then
      mv -- "$made" "$made.moved" && mkdir -p -- "$made/assets" \
        && cp -- shmutant.sh CHECKSUMS "$made/assets/" || exit 1
    fi
    # $STUB/replace-tmp: the run's directory is moved away, and another made at its path holds a
    # file of its own under the asset name.
    if [ -e "$STUB/replace-tmp" ]; then
      mv -- "$made" "$made.moved" && mkdir -p -- "$made/assets" && echo theirs > "$made/assets/shmutant.sh" || exit 1
    fi
    if [ -e "$STUB/asset.merge" ]; then
      mv -- "$STUB/release/shmutant.sh" "$STUB/release/shmutant.sh CHECKSUMS" && rm -f -- "$STUB/release/CHECKSUMS" || exit 1
    fi
    : > "$STUB/published/$t" ;;
  "release download")
    t="${a[2]}"; opts "${a[@]:3}"
    [ -e "$STUB/published/$t" ] || fail "Not Found (HTTP 404)"
    [ ! -e "$STUB/download.fail" ] || fail "HTTP 502"
    # -O - writes the one asset the patterns select to stdout; none or several is an error.
    sel=()
    for f in "$STUB/release/"*; do
      [ -f "$f" ] || continue
      [ "${#patterns[@]}" -eq 0 ] || { keep=0; for pt in "${patterns[@]}"; do case "${f##*/}" in $pt) keep=1 ;; esac; done; [ "$keep" -eq 1 ] || continue; }
      sel+=("$f")
    done
    [ "$output" = - ] || { echo "gh stub: release download without -O -" >&2; exit 3; }
    [ "${#sel[@]}" -eq 1 ] || fail "${#sel[@]} assets match; -O - takes exactly one"
    cat -- "${sel[0]}" ;;
  *) echo "gh stub: unexpected call: ${a[*]}" >&2; exit 3 ;;
esac
EOF

cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
# curl … [-o <file>] <url>, answered from the fixture's origin onto <file> or stdout: <url> must be
# a raw URL of the fixture's repository. $STUB/curl.404s holds how many downloads fail before one
# succeeds; $STUB/curl.mode `tamper` alters the bytes, `nowrite` and `unreachable` fail as curl
# does (23, 7), `term` and `int` send TERM or INT to the caller's process group.
out=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --proto|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
unset -f git
printf 'curl %s\n' "$url" >> "$STUB/events"
notfound() { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
mode="$(cat "$STUB/curl.mode" 2> /dev/null)"
case "$mode" in
  term|int) kill "-$(printf '%s' "$mode" | tr a-z A-Z)" 0; notfound ;;
  nowrite) echo "curl: (23) Failure writing output to destination" >&2; exit 23 ;;
  unreachable) echo "curl: (7) Failed to connect" >&2; exit 7 ;;
esac
# $STUB/curl.codes: one exit code per call, consumed in order.
if [ -s "$STUB/curl.codes" ]; then
  code="$(head -n 1 "$STUB/curl.codes")"; sed -i.bak 1d "$STUB/curl.codes" && rm -f -- "$STUB/curl.codes.bak"
  echo "curl: ($code) scripted failure" >&2; exit "$code"
fi
n="$(cat "$STUB/curl.404s" 2> /dev/null)"
if [ "${n:-0}" -gt 0 ]; then echo $((n - 1)) > "$STUB/curl.404s"; notfound; fi
case "$url" in "https://raw.githubusercontent.com/$SLUG/"*/shmutant.sh) ;; *) notfound ;; esac
t="${url#"https://raw.githubusercontent.com/$SLUG/"}"; t="${t%/shmutant.sh}"
body="$(git -C "$STUB/origin.git" cat-file blob "$t:shmutant.sh" 2> /dev/null && printf x)" || notfound
body="${body%x}"
[ "$mode" != tamper ] || body="$body# tampered
"
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
EOF

cat > "$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >> "$STUB/events"
# $STUB/sleep.fail: the pause cannot run.
[ ! -e "$STUB/sleep.fail" ] || exit 1
EOF

cat > "$tmp/bin/rm" <<'EOF'
#!/usr/bin/env bash
# rm, failing on the driver's temporary directory while $STUB/rm.fail exists.
if [ -e "${STUB:-/nonexistent}/rm.fail" ]; then
  for a in "$@"; do case "$a" in */release.*) echo "rm: $a: Operation not permitted" >&2; exit 1 ;; esac; done
fi
exec /bin/rm "$@"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/curl" "$tmp/bin/sleep" "$tmp/bin/rm" || exit 2

# --- fixtures ----------------------------------------------------------------------------------

# sha256 — the SHA-256 of stdin.
sha256() {
  local out
  if command -v sha256sum > /dev/null; then out="$(sha256sum)"; else out="$(shasum -a 256)"; fi || exit 2
  printf '%s\n' "${out%% *}"
}

# checks <name:status:conclusion>… — the check runs the gh stub lists on any commit (`null` for no
# conclusion). runs <id:status:conclusion>… — the same for its ci.yml workflow runs.
checks() {
  printf '%s\n' "$@" | jq -Rn '[inputs | select(. != "") | split(":")
    | {name: .[0], status: .[1], conclusion: (if .[2] == "null" then null else .[2] end)}]
    | {total_count: length, check_runs: .}' > "$S/checks.json" || exit 2
}
runs() {
  printf '%s\n' "$@" | jq -Rn '[inputs | select(. != "") | split(":")
    | {id: (.[0] | tonumber), status: .[1], conclusion: (if .[2] == "null" then null else .[2] end)}]
    | {total_count: length, workflow_runs: .}' > "$S/runs.json" || exit 2
}
# recount <file> <n> — make GitHub's own count in <file> say <n>, whatever it lists.
recount() { jq --argjson n "$2" '.total_count = $n' "$S/$1" > "$S/$1.new" && mv -- "$S/$1.new" "$S/$1" || exit 2; }

# commit <dir> <message> — commit everything in <dir>. land <dir> <message> — and push it to main.
commit() { git -C "$1" add -A && git -C "$1" commit -q --allow-empty -m "$2" || exit 2; }
land() { commit "$1" "$2"; git -C "$1" push -q origin main || exit 2; }

# checksum <dir> — rewrite <dir>/CHECKSUMS for its shmutant.sh.
checksum() { local d; d="$(sha256 < "$1/shmutant.sh")" || exit 2; printf '%s  shmutant.sh\n' "$d" > "$1/CHECKSUMS" || exit 2; }

# fixture <case> — a fresh origin and clone for <case>; sets S (the stubs' state) and c (the clone).
fixture() {
  S="$tmp/$1/stub"; c="$tmp/$1/clone"
  mkdir -p "$S/published" "$c/scripts" "$c/docs" || exit 2
  git init -q --bare -b main "$S/origin.git" && git init -q -b main "$c" || exit 2
  cp -- "$root/scripts/release.sh" "$c/scripts/" || exit 2
  printf '#!/usr/bin/env bash\nSHMUTANT_VERSION=%s\n' "$VER" > "$c/shmutant.sh" || exit 2
  checksum "$c"
  printf 'curl -fsSL -o scripts/shmutant.sh %s\n' "$URL" > "$c/docs/integrating.md" || exit 2
  git -C "$c" remote add origin "https://github.com/$SLUG.git" || exit 2
  git -C "$c" config "url.$S/origin.git.insteadOf" "https://github.com/$SLUG.git" || exit 2
  land "$c" fixture
  checks alpha:completed:success beta:completed:success
  runs 7:completed:success
  echo '{"total_count":0,"state":"pending"}' > "$S/status.json" || exit 2
}

# other_clone — a second clone of the origin, at $o, for commits the fixture's clone lacks.
other_clone() { o="$S/../other"; git clone -q "$S/origin.git" "$o" || exit 2; }

# rel <arg>… — scripts/release.sh in the clone, from its root; sets rc, out and err.
rel() {
  (cd -- "$c" && PATH="$tmp/bin:$PATH" STUB="$S" SLUG="$SLUG" bash scripts/release.sh "$@") \
    > "$S/out" 2> "$S/err"
  rc=$?
  out="$(cat "$S/out")"; err="$(cat "$S/err")"
}
# relg <arg>… — rel with the driver in a process group of its own (set -m), so a stub's signal to
# its group reaches the driver and its children only. The background job is the driver itself.
relg() {
  bash -c 'set -m; cd -- "$1" || exit 2; PATH="$2:$PATH" STUB="$3" SLUG="$4" bash scripts/release.sh "${@:5}" & wait $!' \
    _ "$c" "$tmp/bin" "$S" "$SLUG" "$@" > "$S/out" 2> "$S/err"
  rc=$?
  out="$(cat "$S/out")"; err="$(cat "$S/err")"
}
# relq <arg>… — rel with the driver's stdout closed, so every report line it writes fails.
relq() {
  (cd -- "$c" && PATH="$tmp/bin:$PATH" STUB="$S" SLUG="$SLUG" bash scripts/release.sh "$@" >&-) 2> "$S/err"
  rc=$?
  out=""; err="$(cat "$S/err")"
}
# relb <text> <arg>… — rel with the driver's stdout a pipe whose reader keeps the lines up to the
# first holding <text>, then exits. SIGPIPE is ignored, as a caller may leave it, so each later
# line's write fails rather than kill the driver.
relb() {
  local stop="$1"; shift
  (cd -- "$c" && trap '' PIPE && PATH="$tmp/bin:$PATH" STUB="$S" SLUG="$SLUG" bash scripts/release.sh "$@") \
    2> "$S/err" | awk -v s="$stop" '{ print } index($0, s) { exit }' > "$S/out"
  rc="${PIPESTATUS[0]}"
  out="$(cat "$S/out")"; err="$(cat "$S/err")"
}
# rele <var=value>… -- <arg>… — rel with these variables in the driver's environment, through env:
# a shell's own SHELLOPTS and BASHOPTS are readonly, so a prefix assignment cannot set them.
rele() {
  local vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done
  shift
  (cd -- "$c" && PATH="$tmp/bin:$PATH" STUB="$S" SLUG="$SLUG" env "${vars[@]}" bash scripts/release.sh "$@") \
    > "$S/out" 2> "$S/err"
  rc=$?
  out="$(cat "$S/out")"; err="$(cat "$S/err")"
}
# relp <path> <arg>… — rel with exactly <path> as PATH.
relp() {
  local path="$1"; shift
  (cd -- "$c" && PATH="$path" STUB="$S" SLUG="$SLUG" bash scripts/release.sh "$@") > "$S/out" 2> "$S/err"
  rc=$?
  out="$(cat "$S/out")"; err="$(cat "$S/err")"
}
# toolbox <dir> <tool>… — <dir> holding a link to each <tool>, a stub where test/release.sh has one.
toolbox() {
  local d="$1" t p; shift
  mkdir -p "$d" || exit 2
  for t in bash git jq dirname tr awk grep sort wc mkdir rmdir rm sleep mktemp cat cp ls sed head "$@"; do
    if [ -x "$tmp/bin/$t" ]; then p="$tmp/bin/$t"; else p="$(command -v "$t")" || continue; fi
    ln -sf "$p" "$d/$t" || exit 2
  done
}
events() { cat "$S/events" 2> /dev/null; }
refusals() { printf '%s\n' "$err" | grep -c '^release: refused: '; }
origin_tags() { git -C "$S/origin.git" tag -l; }

# --- assertions --------------------------------------------------------------------------------

_case=""; fails=0
fail_() { printf 'FAIL: %s: %s\n' "$_case" "$*"; fails=$((fails + 1)); }
eq()    { [ "$1" = "$2" ] || fail_ "$3: got [$1] want [$2]"; }
has()   { case "$1" in *"$2"*) ;; *) fail_ "$3: missing [$2] in [$1]" ;; esac; }
hasnt() { case "$1" in *"$2"*) fail_ "$3: unexpectedly contains [$2]" ;; *) ;; esac; }
rc_is() { [ "$1" -eq "$2" ] || fail_ "$3: rc $1, want $2 (stderr: $err)"; }

# refused_once <message> <what> — the run refused exactly once, with <message>, and published nothing.
refused_once() {
  rc_is "$rc" 1 "$2"
  has "$err" "$1" "$2"
  eq "$(refusals)" 1 "$2: the one refusal"
  has "$err" "1 precondition(s) refused; nothing was tagged, pushed or published" "$2: the verdict"
  hasnt "$(events)" "gh release" "$2: no release call"
}

# published_nothing <what> — no tag here or on origin, and no release call.
published_nothing() {
  eq "$(git -C "$c" tag -l)" "" "$1: no tag in the clone"
  eq "$(origin_tags)" "" "$1: no tag on origin"
  hasnt "$(events)" "gh release" "$1: no release call"
}

# --- cases -------------------------------------------------------------------------------------

c_dry_run_on_a_clean_green_main_passes_and_changes_nothing() {
  local before w
  before="$(git -C "$c" for-each-ref; git -C "$S/origin.git" for-each-ref)"
  mkdir -p "$S/tmp"
  TMPDIR="$S/tmp" rel --dry-run "$VER"
  rc_is "$rc" 0 "the dry run"
  for w in "on main" "the work tree is clean" "HEAD is origin's main" "GitHub's API agrees" \
           "CI is green on origin's main" "shmutant.sh sets SHMUTANT_VERSION=$VER" "CHECKSUMS matches shmutant.sh" \
           "docs/integrating.md's install URL is $URL" "no tag $TAG in this checkout" \
           "no tag $TAG on origin" "no tag $TAG on GitHub" "no GitHub release for $TAG"; do
    has "$out" "release: ok: $w" "each precondition is reported"
  done
  has "$out" "2 check run(s) and 1 ci.yml run(s), each a success" "CI's evidence is counted"
  has "$out" "dry run: every precondition holds for $TAG" "the verdict"
  eq "$err" "" "nothing on stderr"
  eq "$(git -C "$c" for-each-ref; git -C "$S/origin.git" for-each-ref)" "$before" "no ref made or moved"
  eq "$(git -C "$c" status --porcelain --untracked-files=all)" "" "the work tree untouched"
  eq "$(ls -A "$S/tmp")" "" "no temporary file"
  hasnt "$(events)" "gh release" "no release call"
  hasnt "$(events)" "curl" "no download"
  rel --dry-run "$TAG"
  rc_is "$rc" 0 "a version given as vX.Y.Z"
}

c_the_repository_docs_and_version_pass_their_checks() {
  local real
  real="$(sed -n 's/^SHMUTANT_VERSION=//p' "$root/shmutant.sh")"
  cp -- "$root/shmutant.sh" "$root/CHECKSUMS" "$c/" || exit 2
  sed "s#raw\.githubusercontent\.com/BWBama85/shmutant/#raw.githubusercontent.com/$SLUG/#" \
    "$root/docs/integrating.md" > "$c/docs/integrating.md" || exit 2
  land "$c" real-files
  rel --dry-run "$real"
  has "$out" "release: ok: shmutant.sh sets SHMUTANT_VERSION=$real" "the real version line"
  has "$out" "release: ok: CHECKSUMS matches shmutant.sh" "the real CHECKSUMS"
  has "$out" "release: ok: docs/integrating.md's install URL is https://raw.githubusercontent.com/$SLUG/v$real/shmutant.sh" \
    "the real doc's URL, at the real version's tag"
}

c_a_cut_that_refuses_publishes_nothing() {
  checks alpha:completed:failure beta:completed:success
  rel "$VER"
  refused_once "CI is not green on origin's main" "a cut on red CI"
  published_nothing "a cut on red CI"
}

c_refuses_a_version_mismatch() {
  rel --dry-run 9.9.9
  rc_is "$rc" 1 "another version"
  has "$err" "version mismatch: shmutant.sh sets SHMUTANT_VERSION=$VER, not 9.9.9" "the version refusal"
  has "$err" "docs/integrating.md's URL installs $TAG, not v9.9.9" "and the doc's"
  eq "$(refusals)" 2 "two refusals"
}

c_refuses_a_version_set_twice() {
  echo "SHMUTANT_VERSION=$VER" >> "$c/shmutant.sh"; checksum "$c"; land "$c" twice
  rel --dry-run "$VER"
  refused_once "shmutant.sh at HEAD does not set SHMUTANT_VERSION on exactly one line" "two assignments"
}

c_refuses_checksums_drift() {
  echo '# drift' >> "$c/shmutant.sh"; land "$c" drift
  rel --dry-run "$VER"
  refused_once "CHECKSUMS does not match shmutant.sh" "shmutant.sh changed, CHECKSUMS not"
}

c_refuses_a_malformed_checksums() {
  local d
  d="$(sed 's/ .*//' "$c/CHECKSUMS")"
  printf '%s  shmutant.sh\n%s  other\n' "$d" "$d" > "$c/CHECKSUMS"; land "$c" two-lines
  rel --dry-run "$VER"
  refused_once "CHECKSUMS is not the one line '<sha256>  shmutant.sh'" "a second line"
}

c_refuses_a_dirty_tree() {
  : > "$c/untracked"
  rel --dry-run "$VER"
  refused_once "the work tree is not clean (1 path(s)" "an untracked file"
  rm -f -- "$c/untracked"; echo >> "$c/docs/integrating.md"
  rel --dry-run "$VER"
  refused_once "the work tree is not clean (1 path(s)" "a modified file"
}

c_refuses_off_main() {
  git -C "$c" switch -q -c topic
  rel --dry-run "$VER"
  refused_once "not on main (on topic)" "on a branch"
  git -C "$c" switch -q --detach
  rel --dry-run "$VER"
  refused_once "not on main (on a detached HEAD)" "detached"
}

c_refuses_behind_origin_main() {
  other_clone; land "$o" ahead
  rel --dry-run "$VER"
  refused_once "behind origin/main, or diverged from it" "origin's main not fetched"
  git -C "$c" fetch -q origin
  rel --dry-run "$VER"
  refused_once "behind origin/main: origin's main is" "origin's main fetched, not merged"
}

c_refuses_ahead_of_and_diverged_from_origin_main() {
  commit "$c" local
  rel --dry-run "$VER"
  refused_once "ahead of origin/main" "an unpushed commit"
  other_clone; land "$o" theirs; git -C "$c" fetch -q origin
  rel --dry-run "$VER"
  refused_once "diverged from origin/main" "both sides committed"
}

c_refuses_when_the_api_disagrees_with_origin() {
  echo 0123456789012345678901234567890123456789 > "$S/api-main"
  rel --dry-run "$VER"
  refused_once "GitHub's API says $SLUG's main is 0123456789012345678901234567890123456789" "another main"
  rm -f -- "$S/api-main"; : > "$S/api-main.fail"
  rel --dry-run "$VER"
  rc_is "$rc" 2 "an unreadable API"
  has "$err" "cannot read $SLUG's main through the GitHub API" "says so"
}

c_refuses_ci_that_is_not_green() {
  checks alpha:completed:failure beta:completed:success
  rel --dry-run "$VER"
  refused_once "CI is not green on origin's main" "a failure"
  has "$err" "alpha concluded failure" "the failing check is named"
  checks alpha:completed:success beta:in_progress:null
  rel --dry-run "$VER"
  refused_once "beta is in_progress" "a pending check"
  checks alpha:completed:skipped beta:completed:success
  rel --dry-run "$VER"
  refused_once "alpha concluded skipped" "a skipped check"
  checks alpha:completed:success gamma:completed:neutral
  rel --dry-run "$VER"
  refused_once "gamma concluded neutral" "a neutral check"
  checks
  rel --dry-run "$VER"
  refused_once "GitHub lists no check runs on it" "no check runs at all"
}

c_refuses_a_ci_workflow_run_that_is_not_green() {
  runs 7:in_progress:null
  rel --dry-run "$VER"
  refused_once "ci.yml run 7 is in_progress" "a run still going (a job not yet reported)"
  runs 7:completed:failure
  rel --dry-run "$VER"
  refused_once "ci.yml run 7 concluded failure" "a failed run"
  runs 7:completed:success 8:completed:cancelled
  rel --dry-run "$VER"
  refused_once "ci.yml run 8 concluded cancelled" "one of two runs"
  runs
  rel --dry-run "$VER"
  refused_once "the ci.yml workflow has not run on it" "no run"
}

c_refuses_commit_statuses_that_are_not_success() {
  echo '{"total_count":1,"state":"failure"}' > "$S/status.json"
  rel --dry-run "$VER"
  refused_once "its 1 commit status(es) are failure" "a failing status"
  echo '{"total_count":2,"state":"pending"}' > "$S/status.json"
  rel --dry-run "$VER"
  refused_once "its 2 commit status(es) are pending" "a pending status"
  echo '{"total_count":1,"state":"success"}' > "$S/status.json"
  rel --dry-run "$VER"
  rc_is "$rc" 0 "a successful status"
}

c_stops_when_ci_cannot_be_read() {
  : > "$S/checks.fail"
  rel --dry-run "$VER"
  rc_is "$rc" 2 "an unreadable Checks API"
  has "$err" "cannot read the check runs on" "says so"
}

c_refuses_an_existing_tag() {
  git -C "$c" tag "$TAG"
  rel --dry-run "$VER"
  refused_once "tag $TAG already exists in this checkout" "a local tag"
  git -C "$c" push -q origin "refs/tags/$TAG"; git -C "$c" tag -d "$TAG" > /dev/null
  rel --dry-run "$VER"
  rc_is "$rc" 1 "a tag on origin, which GitHub then has too"
  has "$err" "tag $TAG already exists on origin" "the origin refusal"
  has "$err" "tag $TAG already exists on GitHub's $SLUG" "and GitHub's"
  eq "$(refusals)" 2 "two refusals"
}

c_refuses_an_existing_release() {
  : > "$S/published/v0.0.1"; : > "$S/published/$TAG"
  rel --dry-run "$VER"
  refused_once "GitHub already has a release for $TAG" "a release with no tag"
}

c_refuses_a_doc_url_it_cannot_use() {
  echo "curl https://raw.githubusercontent.com/someone/else/$TAG/shmutant.sh" > "$c/docs/integrating.md"
  land "$c" other-repo
  rel --dry-run "$VER"
  refused_once "docs/integrating.md's URL is for someone/else, but origin is $SLUG" "another repository"
  echo "https://raw.githubusercontent.com/$SLUG/v1.2.2/shmutant.sh" > "$c/docs/integrating.md"
  land "$c" older-tag
  rel --dry-run "$VER"
  refused_once "docs/integrating.md's URL installs v1.2.2, not $TAG" "the previous release's URL"
  echo "https://raw.githubusercontent.com/$SLUG/main/shmutant.sh" > "$c/docs/integrating.md"
  land "$c" branch-url
  rel --dry-run "$VER"
  refused_once "docs/integrating.md's URL installs main, not $TAG" "a URL at a branch"
  echo 'no url here' > "$c/docs/integrating.md"; land "$c" no-url
  rel --dry-run "$VER"
  refused_once "docs/integrating.md names no raw.githubusercontent.com URL of shmutant.sh" "no URL"
  printf '%s\n%s\n' "https://raw.githubusercontent.com/$SLUG/v1.0.0/shmutant.sh" "$URL" > "$c/docs/integrating.md"
  land "$c" two-urls
  rel --dry-run "$VER"
  refused_once "docs/integrating.md names more than one URL of shmutant.sh" "two URLs"
}

c_reports_every_refusal_in_one_run() {
  : > "$c/untracked"
  checks alpha:completed:failure beta:completed:success
  git -C "$c" tag "$TAG"
  rel --dry-run "$VER"
  rc_is "$rc" 1 "three refusals"
  eq "$(refusals)" 3 "each one reported"
  has "$err" "3 precondition(s) refused" "the verdict counts them"
}

c_rejects_bad_arguments() {
  local v
  for v in 1.2 01.2.3 1.2.3-rc.1 vv1.2.3 '1.2.3 ' '' -; do
    rel --dry-run "$v"
    rc_is "$rc" 2 "version [$v]"
  done
  rel --dry-run 1.2
  has "$err" "not a version: '1.2'" "says why"
  rel --dry-run
  rc_is "$rc" 2 "no version"
  rel --dry-run 1.2.3 1.2.4
  rc_is "$rc" 2 "two versions"
  rel --dry-run --verify 1.2.3
  rc_is "$rc" 2 "two modes"
  rel --bogus 1.2.3
  rc_is "$rc" 2 "an unknown option"
  hasnt "$(events)" "gh" "no GitHub call before the arguments hold"
}

c_reads_every_github_origin_form_and_prints_none() {
  local form
  for form in "git@github.com:$SLUG.git" "ssh://git@github.com/$SLUG" "https://x-access-token:s3cret@github.com/$SLUG.git"; do
    git -C "$c" remote set-url origin "$form"
    git -C "$c" config "url.$S/origin.git.insteadOf" "$form"
    rel --dry-run "$VER"
    rc_is "$rc" 0 "origin $form"
  done
  hasnt "$out$err" "s3cret" "a URL's credential is not printed"
  git -C "$c" remote set-url origin "https://someone:s3cret@example.com/x.git"
  rel --dry-run "$VER"
  rc_is "$rc" 2 "an origin elsewhere"
  has "$err" "origin's URL is not a github.com HTTPS or SSH repository URL" "says why"
  hasnt "$err" "s3cret" "its credential is not printed"
  for form in "https://github.com/../x.git" "https://evil.example/@github.com/$SLUG.git" \
              "https://evil.example?@github.com/$SLUG.git" "https://evil.example#@github.com/$SLUG.git" \
              "https://evil.example\\@github.com/$SLUG.git" "https://github.com/$SLUG.git?x"; do
    git -C "$c" remote set-url origin "$form"
    git -C "$c" config "url.$S/origin.git.insteadOf" "$form"
    rel --dry-run "$VER"
    rc_is "$rc" 2 "origin $form"
    has "$err" "origin's URL is not a github.com HTTPS or SSH repository URL" "origin $form is refused for its URL"
  done
}

c_a_push_url_must_name_the_same_repository() {
  git -C "$c" config remote.origin.pushurl "git@github.com:$SLUG.git"
  git -C "$c" config "url.$S/origin.git.pushInsteadOf" "git@github.com:$SLUG.git"
  rel --dry-run "$VER"
  rc_is "$rc" 0 "a push URL for the same repository, over ssh"
  git -C "$c" config remote.origin.pushurl "git@github.com:someone/else.git"
  rel --dry-run "$VER"
  rc_is "$rc" 2 "a push URL for another repository"
  has "$err" "a push URL of origin is not a github.com HTTPS or SSH URL of $SLUG" "says so"
  git -C "$c" config remote.origin.pushurl "git@github.com:$SLUG.git"
  git -C "$c" config --add remote.origin.pushurl "git@github.com:someone/else.git"
  rel --dry-run "$VER"
  rc_is "$rc" 2 "a second push URL, for another repository"
  git -C "$c" config --unset-all remote.origin.pushurl
  git -C "$c" config --add remote.origin.url "https://github.com/$SLUG.git"
  rel --dry-run "$VER"
  rc_is "$rc" 2 "two fetch URLs"
  has "$err" "origin has more than one URL" "says so"
}

c_refuses_a_token_that_cannot_push() {
  echo false > "$S/push"
  rel --dry-run "$VER"
  refused_once "gh's account has no push access to $SLUG" "a read-only token"
}

c_ignores_the_callers_git_repository_and_tool_functions() {
  git() { echo "a shadowing git" >&2; return 1; }
  export -f git
  GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/nonexistent rel --dry-run "$VER"
  unset -f git
  rc_is "$rc" 0 "GIT_DIR and a git function exported by the caller"
}

c_reads_a_quoted_version_and_any_case_of_the_repository() {
  printf '#!/usr/bin/env bash\nSHMUTANT_VERSION="%s"\n' "$VER" > "$c/shmutant.sh"; checksum "$c"
  echo "curl https://raw.githubusercontent.com/Shmutant-Test/Fixture/$TAG/shmutant.sh" > "$c/docs/integrating.md"
  land "$c" quoted
  rel --dry-run "$VER"
  rc_is "$rc" 0 "SHMUTANT_VERSION=\"$VER\" and a doc URL in another case"
}

c_cut_tags_publishes_verifies_and_hands_off() {
  local main ev lc lu ld
  main="$(git -C "$S/origin.git" rev-parse main)"
  rel "$VER"
  rc_is "$rc" 0 "the cut"
  eq "$(git -C "$S/origin.git" cat-file -t "refs/tags/$TAG")" tag "origin has an annotated tag"
  eq "$(git -C "$S/origin.git" rev-parse "$TAG^{commit}")" "$main" "it names the commit CI checked"
  eq "$(git -C "$S/origin.git" cat-file tag "$TAG" | sed -n '$p')" "shmutant $VER" "its message"
  eq "$(git hash-object "$S/release/shmutant.sh")" "$(git -C "$c" rev-parse "$TAG:shmutant.sh")" "the shmutant.sh asset is the tag's"
  eq "$(git hash-object "$S/release/CHECKSUMS")" "$(git -C "$c" rev-parse "$TAG:CHECKSUMS")" "the CHECKSUMS asset is the tag's"
  ev="$(events)"
  has "$ev" "gh release create $TAG -R github.com/$SLUG --verify-tag" "the release is created from the pushed tag only"
  has "$ev" "curl $URL" "the documented URL is downloaded"
  lc="$(printf '%s\n' "$ev" | grep -n '^gh release create' | head -n 1 | cut -d: -f1)"
  lu="$(printf '%s\n' "$ev" | grep -n '^curl ' | head -n 1 | cut -d: -f1)"
  ld="$(printf '%s\n' "$ev" | grep -n '^gh release download' | head -n 1 | cut -d: -f1)"
  { [ -n "$lc" ] && [ -n "$lu" ] && [ -n "$ld" ] && [ "$lc" -lt "$lu" ] && [ "$lu" -lt "$ld" ]; } \
    || fail_ "create, then the URL, then the assets: event lines [$lc] [$lu] [$ld]"
  has "$out" "verified: $URL has the SHA-256 CHECKSUMS at $TAG gives" "the URL verified"
  has "$out" "verified: the release $TAG carries shmutant.sh and CHECKSUMS as tagged" "the assets verified"
  eq "$(printf '%s\n' "$out" | sed -n '$p')" "release: next: baseline release roll --version $TAG" "the last line hands off"
  rel --verify "$VER"
  rc_is "$rc" 0 "--verify on the published release"
  rel "$VER"
  rc_is "$rc" 1 "a second cut of the same version"
  eq "$(refusals)" 4 "refused: the tag here, on origin, on GitHub, and the release"
}

c_verify_fails_loudly_on_a_mismatched_download() {
  echo tamper > "$S/curl.mode"
  rel "$VER"
  rc_is "$rc" 1 "the raw URL serves other bytes"
  has "$err" "VERIFY FAILED: $URL has SHA-256" "the mismatch is named"
  has "$err" "is published but does not verify" "the verdict"
  hasnt "$out" "baseline release roll" "no hand-off"
}

c_verify_fails_on_a_mismatched_or_missing_asset() {
  local a
  echo shmutant.sh > "$S/asset.tamper"
  rel "$VER"
  rc_is "$rc" 1 "the release's shmutant.sh differs"
  has "$err" "VERIFY FAILED: the release's shmutant.sh has SHA-256" "the mismatch is named"
  hasnt "$out" "baseline release roll" "no hand-off"
  fixture "${_case}_checksums"
  echo CHECKSUMS > "$S/asset.tamper"
  rel "$VER"
  rc_is "$rc" 1 "the release's CHECKSUMS differs"
  has "$err" "VERIFY FAILED: the release's CHECKSUMS is not CHECKSUMS at $TAG" "the mismatch is named"
  for a in shmutant.sh CHECKSUMS; do
    fixture "${_case}_omit_$a"
    echo "$a" > "$S/asset.omit"
    rel "$VER"
    rc_is "$rc" 1 "the release lacks $a"
    has "$err" "VERIFY FAILED: the release $TAG has no asset $a" "the missing asset is named"
  done
}

c_verify_retries_a_bounded_number_of_times() {
  echo 99 > "$S/curl.404s"
  rel "$VER"
  rc_is "$rc" 1 "the URL never answers"
  has "$err" "VERIFY FAILED: $URL answered an HTTP error on each of 12 attempts" "says so"
  eq "$(events | grep -c '^curl ')" 12 "twelve downloads"
  eq "$(events | grep -c '^sleep 30$')" 11 "eleven pauses"
  rm -f -- "$S/curl.404s"
  rel --verify "$VER"
  rc_is "$rc" 0 "--verify, once the URL answers"
}

c_verify_waits_for_a_late_url() {
  echo 3 > "$S/curl.404s"
  rel "$VER"
  rc_is "$rc" 0 "the URL answers on the fourth try"
  eq "$(events | grep -c '^curl ')" 4 "four downloads"
  eq "$(events | grep -c '^sleep ')" 3 "three pauses"
}

c_an_interrupted_cut_says_how_to_finish() {
  echo term > "$S/curl.mode"
  relg "$VER"
  rc_is "$rc" 143 "TERM during verification"
  has "$err" "interrupted once the tag $TAG may exist" "says so"
  has "$err" "scripts/release.sh --verify $VER" "and how to finish"
}

c_an_interrupt_exits_130_and_says_how_to_finish() {
  echo int > "$S/curl.mode"
  relg "$VER"
  rc_is "$rc" 130 "INT during verification"
  has "$err" "interrupted once the tag $TAG may exist" "says so"
}

c_verify_refuses_a_draft_release() {
  rel "$VER"
  rc_is "$rc" 0 "the cut"
  : > "$S/release.draft"
  rel --verify "$VER"
  rc_is "$rc" 1 "--verify on a release that is a draft"
  has "$err" "VERIFY FAILED: the release $TAG is a draft" "says so"
}

c_failed_release_create_prints_the_way_to_finish() {
  : > "$S/create.fail"
  rel "$VER"
  rc_is "$rc" 1 "gh release create fails"
  has "$err" "gh release create failed" "says so"
  has "$err" "to finish the release of $TAG by hand" "says what is left"
  has "$err" "gh release create $TAG -R github.com/$SLUG --verify-tag" "prints the create command"
  has "$err" "scripts/release.sh --verify $VER" "and the check after it"
  eq "$(git -C "$S/origin.git" rev-parse "$TAG^{commit}")" "$(git -C "$S/origin.git" rev-parse main)" "the tag is on origin"
  rel --verify "$VER"
  rc_is "$rc" 1 "--verify before the release exists"
  has "$err" "VERIFY FAILED: GitHub has no release for $TAG" "says so"
}

c_the_printed_hand_finish_publishes_the_tagged_assets() {
  local cmd a orig repl
  # A replacement for each asset's blob in the checkout: the printed steps must not write them.
  for a in shmutant.sh CHECKSUMS; do
    orig="$(git -C "$c" rev-parse "HEAD:$a")"
    repl="$( { cat "$c/$a"; echo '# replaced'; } | git -C "$c" hash-object -w --stdin)" || exit 2
    git -C "$c" replace "$orig" "$repl" || exit 2
  done
  : > "$S/create.fail"
  rel "$VER"
  rc_is "$rc" 1 "gh release create fails"
  rm -f -- "$S/create.fail"
  echo '# an edit made in the work tree afterwards' >> "$c/shmutant.sh"
  mkdir -p "$S/finish" || exit 2
  # The printed steps, run as printed: write the assets, then the "with no release" command.
  while IFS= read -r cmd; do
    (cd -- "$S/finish" && unset GH_HOST && PATH="$tmp/bin:$PATH" STUB="$S" SLUG="$SLUG" \
       GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false eval "$cmd") 2>> "$S/finish.err" \
      || fail_ "a printed step failed: $cmd ($(cat "$S/finish.err"))"
  done <<EOF
$(printf '%s\n' "$err" | sed -n -e 's/^release:   \(git -C .*\)$/\1/p' -e 's/^release:   with no release:   //p')
EOF
  eq "$(git hash-object "$S/release/shmutant.sh")" "$(git -C "$c" rev-parse "$TAG:shmutant.sh")" "the asset is the tag's, not the edited file"
  rel --verify "$VER"
  rc_is "$rc" 0 "--verify after finishing by hand"
}

c_failed_tag_creation_publishes_nothing() {
  git -C "$c" config tag.gpgSign true; git -C "$c" config gpg.program false
  rel "$VER"
  rc_is "$rc" 1 "git tag fails (a signing program that fails)"
  has "$err" "could not create the tag $TAG; nothing was pushed" "says so"
  published_nothing "a failed tag"
}

c_failed_push_publishes_nothing() {
  printf '#!/bin/sh\nexit 1\n' > "$S/origin.git/hooks/pre-receive"; chmod +x "$S/origin.git/hooks/pre-receive"
  rel "$VER"
  rc_is "$rc" 1 "origin refuses the push"
  has "$err" "could not push $TAG; origin does not have it and nothing was published" "says so"
  has "$err" "git tag -d $TAG" "says how to retry"
  eq "$(origin_tags)" "" "no tag on origin"
  hasnt "$(events)" "gh release" "no release call"
}

c_a_push_that_reports_failure_but_landed_stops_to_finish_by_hand() {
  printf '#!/bin/sh\nenv -u GIT_QUARANTINE_PATH git update-ref refs/tags/%s "$(git rev-parse main)"\nexit 1\n' "$TAG" \
    > "$S/origin.git/hooks/pre-receive"
  chmod +x "$S/origin.git/hooks/pre-receive"
  rel "$VER"
  rc_is "$rc" 1 "origin has the tag at the commit, though the push failed"
  has "$err" "the push of $TAG reported a failure, but origin has the tag" "says so"
  has "$err" "to finish the release of $TAG by hand" "and how to finish"
  hasnt "$(events)" "gh release create" "publishes nothing itself"
}

c_a_tag_another_hand_pushed_first_is_not_finished() {
  land "$c" second
  printf '#!/bin/sh\nenv -u GIT_QUARANTINE_PATH git update-ref refs/tags/%s main~1\nexit 1\n' "$TAG" \
    > "$S/origin.git/hooks/pre-receive"
  chmod +x "$S/origin.git/hooks/pre-receive"
  rel "$VER"
  rc_is "$rc" 1 "origin gains another $TAG while the push is refused"
  has "$err" "origin has a $TAG this run did not push (it names $(git -C "$S/origin.git" rev-parse main~1))" "says so"
  hasnt "$err" "by hand" "no advice to finish someone else's tag"
  hasnt "$(events)" "gh release" "no release call"
}

c_a_tag_origin_moved_is_not_published() {
  land "$c" second
  printf '#!/bin/sh\ngit update-ref refs/tags/%s main~1\n' "$TAG" > "$S/origin.git/hooks/post-receive"
  chmod +x "$S/origin.git/hooks/post-receive"
  rel "$VER"
  rc_is "$rc" 1 "origin's tag names another commit after the push"
  has "$err" "origin's $TAG names $(git -C "$S/origin.git" rev-parse main~1), not $(git -C "$S/origin.git" rev-parse main)" "says so"
  hasnt "$(events)" "gh release create" "no release from it"
}

c_verify_needs_the_tag_where_origin_has_it() {
  rel --verify "$VER"
  rc_is "$rc" 2 "no local tag"
  has "$err" "this checkout has no tag $TAG" "says so"
  git -C "$c" tag -a "$TAG" -m x
  rel --verify "$VER"
  rc_is "$rc" 1 "a tag origin lacks"
  has "$err" "origin's $TAG names nothing" "says so"
}

c_stops_without_a_tool_it_needs() {
  toolbox "$S/box" gh sleep
  relp "$S/box" --dry-run "$VER"
  rc_is "$rc" 2 "no curl on PATH"
  has "$err" "curl is not on PATH" "says so"
}

c_hashes_with_whichever_digest_tool_there_is() {
  local t
  for t in sha256sum shasum openssl; do
    command -v "$t" > /dev/null || { echo "note: $_case: no $t on this host; its branch is not exercised" >&2; continue; }
    toolbox "$S/box-$t" gh curl sleep "$t"
    relp "$S/box-$t" --dry-run "$VER"
    rc_is "$rc" 0 "only $t"
    has "$out" "release: ok: CHECKSUMS matches shmutant.sh" "only $t: the digest matches"
  done
  toolbox "$S/box-none" gh curl sleep
  relp "$S/box-none" --dry-run "$VER"
  rc_is "$rc" 2 "no digest tool"
  has "$err" "no sha256sum, shasum or openssl on PATH" "says so"
  toolbox "$S/box-bad" gh curl sleep
  printf '#!/bin/sh\necho "not a digest  -"\n' > "$S/box-bad/sha256sum"; chmod +x "$S/box-bad/sha256sum"
  relp "$S/box-bad" --dry-run "$VER"
  rc_is "$rc" 2 "a digest tool that prints no digest"
  has "$err" "the digest tool printed no SHA-256" "says so"
}

c_refuses_a_checksums_line_hiding_a_nul() {
  local d
  d="$(sha256 < "$c/shmutant.sh")" || exit 2
  printf '%s  shmutant.sh\n\0' "$d" > "$c/CHECKSUMS"; land "$c" nul
  rel --dry-run "$VER"
  refused_once "CHECKSUMS is not the one line '<sha256>  shmutant.sh' (it is 79 bytes, not 78)" "a NUL after the line"
}

c_a_failed_asset_read_after_the_tag_exits_2() {
  failbox "$S/fr" git 128 "*cat-file blob $(git -C "$c" rev-parse HEAD:shmutant.sh)"
  relf "$S/fr" "$VER"
  rc_is "$rc" 2 "shmutant.sh unreadable when the assets are written"
  has "$err" "cannot read shmutant.sh at" "says so"
  has "$err" "to finish the release of $TAG by hand" "and how to finish"
  hasnt "$(events)" "gh release create" "nothing published"
}

c_takes_a_promisor_setting_by_its_value() {
  git -C "$c" config remote.origin.promisor false || exit 2
  git_box "$S/oldgit" 2.39.5
  (cd -- "$c" && PATH="$S/oldgit:$tmp/bin:$PATH" STUB="$S" SLUG="$SLUG" bash scripts/release.sh --dry-run "$VER") > "$S/out" 2> "$S/err"
  rc=$?; err="$(cat "$S/err")"
  rc_is "$rc" 0 "remote.origin.promisor=false is no partial clone, even under git 2.39"
}

c_refuses_a_checksums_line_that_is_not_exactly_one() {
  local d
  d="$(sha256 < "$c/shmutant.sh")" || exit 2
  printf '%s  shmutant.sh\n\n' "$d" > "$c/CHECKSUMS"; land "$c" trailing-blank
  rel --dry-run "$VER"
  refused_once "CHECKSUMS is not the one line '<sha256>  shmutant.sh'" "a trailing blank line"
  printf '%s  shmutant.sh' "$d" > "$c/CHECKSUMS"; land "$c" no-newline
  rel --dry-run "$VER"
  refused_once "CHECKSUMS is not the one line '<sha256>  shmutant.sh'" "no final newline"
}

c_prints_no_control_character_from_a_check_name() {
  checks "$(printf 'evil\033[2Jname'):completed:failure"
  rel --dry-run "$VER"
  refused_once "evil?[2Jname concluded failure" "a check name with an escape sequence"
  case "$err" in *$'\033'*) fail_ "the escape reached stderr" ;; esac
}

c_stops_when_origin_has_no_main() {
  git -C "$S/origin.git" update-ref -d refs/heads/main
  rel --dry-run "$VER"
  rc_is "$rc" 2 "origin without main"
  has "$err" "origin has no main branch" "says so"
}

c_stops_below_the_top_of_its_work_tree() {
  mkdir -p "$c/sub/scripts" && cp -- "$c/scripts/release.sh" "$c/sub/scripts/" || exit 2
  (cd -- "$c" && PATH="$tmp/bin:$PATH" STUB="$S" SLUG="$SLUG" bash sub/scripts/release.sh --dry-run "$VER") > "$S/out" 2> "$S/err"
  rc=$?; err="$(cat "$S/err")"
  rc_is "$rc" 2 "a copy in a subdirectory"
  has "$err" "is not at the top of its work tree" "says so"
}

c_a_push_that_went_elsewhere_is_named() {
  git init -q --bare -b main "$S/elsewhere.git" || exit 2
  git -C "$c" config "url.$S/elsewhere.git.pushInsteadOf" "https://github.com/$SLUG.git"
  rel "$VER"
  rc_is "$rc" 1 "the push lands where origin's URL does not read"
  has "$err" "git push reported success, but origin's URL has no $TAG" "says so"
  hasnt "$(events)" "gh release" "no release call"
}

c_ignores_the_callers_shell_options_functions_and_host() {
  awk() { echo "a shadowing awk" >&2; return 1; }
  export -f awk
  rele SHELLOPTS=errexit:noclobber:nounset BASHOPTS=nocasematch GH_HOST=ghe.example.invalid -- --dry-run "$VER"
  unset -f awk
  rc_is "$rc" 0 "errexit, noclobber, nocasematch, an awk function and GH_HOST from the caller"
  checks alpha:completed:failure
  rele SHELLOPTS=errexit BASHOPTS=nocasematch -- --dry-run "$VER"
  refused_once "alpha concluded failure" "a refusal under errexit and nocasematch"
}

c_refuses_uppercase_checksums_even_under_the_callers_nocasematch() {
  local d
  d="$(sha256 < "$c/shmutant.sh")" || exit 2
  printf '%s  shmutant.sh\n' "$(printf '%s' "$d" | tr a-f A-F)" > "$c/CHECKSUMS"; land "$c" uppercase
  rele BASHOPTS=nocasematch -- --dry-run "$VER"
  refused_once "CHECKSUMS is not the one line '<sha256>  shmutant.sh'" "uppercase hex"
}

c_reads_only_an_exact_install_url() {
  printf 'sig: https://raw.githubusercontent.com/%s/%s/shmutant.sh.sig\n' "$SLUG" "$TAG" > "$c/docs/integrating.md"
  land "$c" sig-only
  rel --dry-run "$VER"
  refused_once "docs/integrating.md names no raw.githubusercontent.com URL of shmutant.sh" "a signature URL only"
  printf 'q: https://raw.githubusercontent.com/%s/%s/shmutant.sh?asset=signature\n' "$SLUG" "$TAG" > "$c/docs/integrating.md"
  land "$c" query-only
  rel --dry-run "$VER"
  refused_once "docs/integrating.md names no raw.githubusercontent.com URL of shmutant.sh" "a URL with a query only"
  printf '%s\nsig: %s.sig\nAt the end of a sentence: %s.\n' "$URL" "$URL" "$URL" > "$c/docs/integrating.md"
  land "$c" with-sig
  rel --dry-run "$VER"
  rc_is "$rc" 0 "the install URL beside its signature, and at a sentence's end"
}

c_sets_aside_the_callers_tracing_and_aliases() {
  git -C "$c" remote set-url origin "https://x-access-token:s3cret@github.com/$SLUG.git"
  git -C "$c" config "url.$S/origin.git.insteadOf" "https://x-access-token:s3cret@github.com/$SLUG.git"
  rele SHELLOPTS=xtrace:verbose -- --dry-run "$VER"
  rc_is "$rc" 0 "xtrace and verbose from the caller"
  hasnt "$err" "s3cret" "the origin URL's token is not traced"
  hasnt "$err" "GH_PROMPT_DISABLED" "nor the script's source"
  rele SHELLOPTS=keyword:allexport -- --dry-run "$VER"
  rc_is "$rc" 0 "keyword and allexport from the caller"
  hasnt "$out" "HOME=" "the environment is not dumped"
  printf 'shopt -s expand_aliases\nalias grep="grep -v"\nalias awk=false\n' > "$S/bash_env"
  rele BASH_ENV="$S/bash_env" -- --dry-run "$VER"
  rc_is "$rc" 0 "aliases from the caller's BASH_ENV"
  # noexec cannot be undone from inside, which is why the skill runs the driver with SHELLOPTS
  # removed and reads success from its last line: here it exits 0 and prints nothing.
  rele SHELLOPTS=noexec -- --dry-run "$VER"
  hasnt "$out" "every precondition holds" "noexec: no verdict line, whatever the status"
}

# sha_box <dir> — <dir> holding a sha256sum that fails on the call $STUB/sha.failat names and is a
# real digest tool otherwise; calls are counted in $STUB/sha.count.
sha_box() {
  local real args=""
  real="$(command -v sha256sum || command -v shasum)" || exit 2
  case "$real" in *shasum) args="-a 256" ;; esac
  toolbox "$1" gh curl sleep
  printf '#!/usr/bin/env bash\nn=$(( $(cat "$STUB/sha.count" 2> /dev/null || echo 0) + 1 )); echo "$n" > "$STUB/sha.count"\n[ "$n" != "$(cat "$STUB/sha.failat" 2> /dev/null)" ] || { echo "sha256sum: read error" >&2; exit 1; }\nexec %q %s\n' \
    "$real" "$args" > "$1/sha256sum" && chmod +x "$1/sha256sum" || exit 2
}

c_verify_exits_2_when_it_cannot_hash_what_it_read() {
  rel "$VER"
  rc_is "$rc" 0 "the cut"
  sha_box "$S/box-sha"
  # In --verify: 1 CHECKSUMS at the tag, 2 the raw download, 3 the shmutant.sh asset, 4 CHECKSUMS.
  echo 2 > "$S/sha.failat"; rm -f -- "$S/sha.count"
  relp "$S/box-sha" --verify "$VER"
  rc_is "$rc" 2 "the download cannot be hashed"
  has "$err" "cannot compute the SHA-256 of the download" "says so"
  echo 4 > "$S/sha.failat"; rm -f -- "$S/sha.count"
  relp "$S/box-sha" --verify "$VER"
  rc_is "$rc" 2 "a release asset cannot be hashed"
  has "$err" "cannot compute the SHA-256 of the release's CHECKSUMS" "says so"
}

c_publishes_the_assets_of_the_commit_it_checked() {
  # origin's post-receive hook commits a change to the clone, so HEAD moves once the tag is pushed.
  printf '#!/bin/sh\necho "# moved" >> %s/shmutant.sh && env -u GIT_DIR -u GIT_QUARANTINE_PATH git -C %s commit -qam moved\n' \
    "$(printf '%q' "$c")" "$(printf '%q' "$c")" > "$S/origin.git/hooks/post-receive"
  chmod +x "$S/origin.git/hooks/post-receive"
  rel "$VER"
  rc_is "$rc" 0 "the cut, though the checkout moved under it"
  [ "$(git -C "$c" rev-parse HEAD)" != "$(git -C "$S/origin.git" rev-parse "$TAG^{commit}")" ] \
    || fail_ "the hook did not move the checkout, so this case proves nothing"
  eq "$(git hash-object "$S/release/shmutant.sh")" "$(git -C "$S/origin.git" rev-parse "$TAG:shmutant.sh")" "the asset is the checked commit's"
}

c_verify_exits_2_without_a_digest_tool() {
  rel "$VER"
  rc_is "$rc" 0 "the cut"
  toolbox "$S/box-none" gh curl sleep
  relp "$S/box-none" --verify "$VER"
  rc_is "$rc" 2 "--verify with no digest tool"
  has "$err" "no sha256sum, shasum or openssl on PATH" "says so"
}

c_refuses_to_tag_when_main_moves_after_the_checks() {
  other_clone; commit "$o" newer
  git -C "$o" push -q origin HEAD:refs/heads/next || exit 2
  git -C "$o" rev-parse HEAD > "$S/advance-main"
  rel "$VER"
  rc_is "$rc" 1 "origin's main moves between the checks and the tag"
  has "$err" "origin's main moved from" "says so"
  has "$err" "nothing was tagged" "and that nothing was"
  published_nothing "main moved"
}

c_refuses_to_tag_when_githubs_main_moves_after_the_checks() {
  echo 0123456789012345678901234567890123456789 > "$S/advance-api-main"
  rel "$VER"
  rc_is "$rc" 1 "GitHub's main moves between the checks and the tag, origin's does not"
  has "$err" "GitHub's main moved from" "says so"
  has "$err" "nothing was tagged" "and that nothing was"
  published_nothing "GitHub's main moved"
  rm -f -- "$S/advance-api-main" "$S/api-main"; : > "$S/api-main.fail-later"
  rel "$VER"
  rc_is "$rc" 2 "GitHub's main cannot be read again before the tag"
  has "$err" "cannot read $SLUG's main through the GitHub API; nothing was tagged" "says so"
  published_nothing "GitHub's main unreadable"
}

c_reads_an_inode_whatever_ifs_the_caller_set() {
  # The driver's own shell only: BASH_ENV reaches every bash, the stubs included.
  printf '[ "${0##*/}" != release.sh ] || IFS=:\n' > "$S/ifs.sh"
  rele BASH_ENV="$S/ifs.sh" -- "$VER"
  rc_is "$rc" 0 "the cut, with IFS=: set before the driver runs"
}

c_a_pause_that_cannot_run_exits_2() {
  : > "$S/sleep.fail"
  echo 1 > "$S/curl.404s"
  rel "$VER"
  rc_is "$rc" 2 "a retry of the download cannot pause"
  has "$err" "cannot pause before the next download" "says so"
}

c_a_pause_between_tag_reads_that_cannot_run_exits_2() {
  : > "$S/sleep.fail"
  echo none > "$S/github-tag"
  rel "$VER"
  rc_is "$rc" 2 "a re-read of GitHub's tags cannot pause"
  has "$err" "cannot pause before reading $SLUG's tags again" "says so"
  has "$err" "to finish the release of $TAG by hand" "and how to finish"
  hasnt "$(events)" "gh release create" "nothing was published"
}

c_refuses_a_version_that_is_not_a_plain_assignment() {
  printf '#!/usr/bin/env bash\nSHMUTANT_VERSION="%s'"'"'\n' "$VER" > "$c/shmutant.sh"; checksum "$c"; land "$c" mismatched-quotes
  rel --dry-run "$VER"
  refused_once "shmutant.sh at HEAD does not assign SHMUTANT_VERSION a plain version" "mismatched quotes"
}

c_ignores_git_replacement_objects() {
  local orig repl
  orig="$(git -C "$c" rev-parse HEAD:shmutant.sh)"
  repl="$( { cat "$c/shmutant.sh"; echo '# replaced'; } | git -C "$c" hash-object -w --stdin)" || exit 2
  git -C "$c" replace "$orig" "$repl" || exit 2
  rel --dry-run "$VER"
  rc_is "$rc" 0 "a replacement for shmutant.sh's blob"
  has "$out" "release: ok: CHECKSUMS matches shmutant.sh" "the committed bytes were read"
}

c_pushes_only_its_own_tag() {
  git -C "$c" config push.followTags true
  git -C "$c" tag -a unrelated -m unrelated
  rel "$VER"
  rc_is "$rc" 0 "the cut, with push.followTags and another annotated tag"
  eq "$(origin_tags)" "$TAG" "only the release tag reached origin"
}

# partial_clone — a blobless clone of the origin, without a checkout, at $pc; sets packs to its
# pack directory's listing.
partial_clone() {
  git -C "$S/origin.git" config uploadpack.allowFilter true || exit 2
  pc="$S/../partial"
  git clone -q --filter=blob:none --no-checkout "file://$S/origin.git" "$pc" || exit 2
  mkdir -p "$pc/scripts" && cp -- "$root/scripts/release.sh" "$pc/scripts/" || exit 2
  git -C "$pc" remote set-url origin "https://github.com/$SLUG.git" || exit 2
  git -C "$pc" config "url.$S/origin.git.insteadOf" "https://github.com/$SLUG.git" || exit 2
  packs="$(ls "$pc/.git/objects/pack")"
}

# git_box <dir> <version> — <dir> holding a git that reports <version> and is the real one otherwise.
git_box() {
  mkdir -p "$1" || exit 2
  printf '#!/usr/bin/env bash\n[ "${1:-}" != version ] || { echo "git version %s"; exit 0; }\nexec %q "$@"\n' \
    "$2" "$(command -v git)" > "$1/git" && chmod +x "$1/git" || exit 2
}

c_dry_run_fetches_nothing_into_a_partial_clone() {
  local gv
  gv="$(git version | sed 's/^git version //')"
  case "$(printf '%s\n2.45\n' "$gv" | sort -t. -k1,1n -k2,2n | head -n 1)" in
    2.45) : ;;
    *) echo "note: $_case: git $gv predates GIT_NO_LAZY_FETCH; the old-git refusal case covers it" >&2; return ;;
  esac
  partial_clone
  (cd -- "$pc" && PATH="$tmp/bin:$PATH" STUB="$S" SLUG="$SLUG" bash scripts/release.sh --dry-run "$VER") > "$S/out" 2> "$S/err"
  rc=$?; err="$(cat "$S/err")"
  rc_is "$rc" 2 "a clone missing the blobs it would check"
  has "$err" "cannot read shmutant.sh at" "says so"
  eq "$(ls "$pc/.git/objects/pack")" "$packs" "nothing was fetched"
}

c_counts_any_promisor_remote_as_a_partial_clone() {
  git -C "$c" remote add mirror "file://$S/origin.git" && git -C "$c" config remote.mirror.promisor true || exit 2
  git_box "$S/oldgit" 2.39.5
  (cd -- "$c" && PATH="$S/oldgit:$tmp/bin:$PATH" STUB="$S" SLUG="$SLUG" bash scripts/release.sh --dry-run "$VER") > "$S/out" 2> "$S/err"
  rc=$?; err="$(cat "$S/err")"
  rc_is "$rc" 2 "a promisor remote other than origin, git 2.39"
  has "$err" "cannot be kept from fetching objects it lacks" "says why"
}

c_refuses_a_partial_clone_under_a_git_that_would_fetch() {
  partial_clone
  git_box "$S/oldgit" 2.39.5
  (cd -- "$pc" && PATH="$S/oldgit:$tmp/bin:$PATH" STUB="$S" SLUG="$SLUG" bash scripts/release.sh --dry-run "$VER") > "$S/out" 2> "$S/err"
  rc=$?; err="$(cat "$S/err")"
  rc_is "$rc" 2 "a partial clone, git 2.39"
  has "$err" "cannot be kept from fetching objects it lacks" "says why"
  eq "$(ls "$pc/.git/objects/pack")" "$packs" "nothing was fetched"
  hasnt "$(events)" "gh" "and nothing was asked of GitHub"
}

# corrupt_blob <rev:path> — overwrite the clone's loose object for <rev:path> with garbage, which no
# reader, root included, can inflate.
corrupt_blob() {
  local obj f
  obj="$(git -C "$c" rev-parse "$1")" || exit 2
  f="$c/.git/objects/${obj:0:2}/${obj:2}"
  chmod u+w "$f" && printf 'not a git object' > "$f" || exit 2
}

c_exits_2_on_an_unreadable_blob() {
  rel "$VER"
  rc_is "$rc" 0 "the cut"
  corrupt_blob HEAD:CHECKSUMS
  rel --verify "$VER"
  rc_is "$rc" 2 "--verify, CHECKSUMS unreadable"
  has "$err" "cannot read CHECKSUMS at" "says so"
  fixture "${_case}_dry"
  corrupt_blob HEAD:CHECKSUMS
  rel --dry-run "$VER"
  rc_is "$rc" 2 "a dry run, CHECKSUMS unreadable"
  has "$err" "cannot read CHECKSUMS at" "says so"
}

c_reports_a_temporary_directory_it_cannot_remove() {
  mkdir -p "$S/tmp"; : > "$S/rm.fail"
  TMPDIR="$S/tmp" rel "$VER"
  rc_is "$rc" 0 "the cut still succeeds"
  has "$err" "could not remove $S/tmp/release." "and says what it could not remove"
  rm -f -- "$S/rm.fail"
}

c_refuses_a_tag_github_already_has() {
  git -C "$S/origin.git" rev-parse main > "$S/github-tag"
  rel --dry-run "$VER"
  refused_once "tag $TAG already exists on GitHub's $SLUG" "a tag GitHub has and origin lacks"
}

c_publishes_nothing_when_github_lacks_the_pushed_tag() {
  echo none > "$S/github-tag"
  rel "$VER"
  rc_is "$rc" 1 "origin's URL is a mirror GitHub does not see"
  has "$err" "origin has $TAG, but GitHub's API does not show it on $SLUG after 3 reads" "says so"
  eq "$(events | grep -c '^sleep 2$')" 2 "re-read twice, pausing between"
  hasnt "$(events)" "gh release create" "no release"
}

c_publishes_nothing_when_githubs_tag_names_another_commit() {
  land "$c" second
  echo "after:$(git -C "$S/origin.git" rev-parse main~1)" > "$S/github-tag"
  rel "$VER"
  rc_is "$rc" 1 "GitHub's tag names another commit after the push"
  has "$err" "GitHub's $TAG names $(git -C "$S/origin.git" rev-parse main~1), not $(git -C "$S/origin.git" rev-parse main)" "says so"
  hasnt "$(events)" "gh release create" "no release"
}

c_verify_refuses_a_github_tag_that_moved() {
  rel "$VER"
  rc_is "$rc" 0 "the cut"
  echo 0123456789012345678901234567890123456789 > "$S/github-tag"
  rel --verify "$VER"
  rc_is "$rc" 1 "--verify, GitHub's tag moved while origin's did not"
  has "$err" "VERIFY FAILED: GitHub's $TAG names 0123456789012345678901234567890123456789" "says so"
}

c_verify_matches_each_asset_name_whole() {
  : > "$S/asset.merge"
  rel "$VER"
  rc_is "$rc" 1 "one asset named 'shmutant.sh CHECKSUMS' in place of both"
  has "$err" "VERIFY FAILED: the release $TAG has no asset shmutant.sh" "the missing asset is named"
}

c_verify_downloads_only_the_two_assets_it_checks() {
  mkdir -p "$S/tmp"; : > "$S/asset.extra"
  TMPDIR="$S/tmp" rel "$VER"
  rc_is "$rc" 0 "a release that also carries notes.txt"
  hasnt "$err" "left $S/tmp" "nothing unexpected was written"
  eq "$(ls -A "$S/tmp")" "" "and the temporary directory is gone"
}

c_verify_tells_http_errors_from_other_download_failures() {
  rel "$VER"
  rc_is "$rc" 0 "the cut"
  { echo 7; yes 22 | head -n 11; } > "$S/curl.codes"
  rel --verify "$VER"
  rc_is "$rc" 2 "a connection failure, then HTTP errors"
  has "$err" "not every failure was an HTTP error" "says so"
  { yes 22 | head -n 11; echo 7; } > "$S/curl.codes"
  rel --verify "$VER"
  rc_is "$rc" 2 "HTTP errors, then a connection failure"
  yes 22 | head -n 12 > "$S/curl.codes"
  rel --verify "$VER"
  rc_is "$rc" 1 "an HTTP error every time"
  has "$err" "answered an HTTP error on each of 12 attempts" "says so"
}

c_stops_without_a_text_tool_it_needs() {
  toolbox "$S/box" gh curl sleep
  rm -f -- "$S/box/sort"
  relp "$S/box" --dry-run "$VER"
  rc_is "$rc" 2 "no sort on PATH"
  has "$err" "sort is not on PATH" "says so"
}

c_clears_gits_own_tracing() {
  git -C "$c" remote set-url origin "https://x-access-token:s3cret@github.com/$SLUG.git"
  git -C "$c" config "url.$S/origin.git.insteadOf" "https://x-access-token:s3cret@github.com/$SLUG.git"
  rele GIT_TRACE=1 GIT_TRACE_SETUP=1 GIT_TRACE2=1 GIT_TRACE2_EVENT=1 GIT_CURL_VERBOSE=1 -- --dry-run "$VER"
  rc_is "$rc" 0 "git tracing exported by the caller"
  hasnt "$err" "s3cret" "the origin URL's token is not traced"
  hasnt "$err" "trace:" "git traced nothing"
}

c_verify_exits_2_when_a_read_fails() {
  rel "$VER"
  rc_is "$rc" 0 "the cut"
  : > "$S/download.fail"
  rel --verify "$VER"
  rc_is "$rc" 2 "the release's assets cannot be downloaded"
  has "$err" "could not download the asset shmutant.sh of the release $TAG" "says so"
  rm -f -- "$S/download.fail"; echo nowrite > "$S/curl.mode"
  rel --verify "$VER"
  rc_is "$rc" 2 "the raw download cannot be written"
  has "$err" "the download of $URL could not be passed to the digest (curl exit 23)" "says so"
  echo unreachable > "$S/curl.mode"
  rel --verify "$VER"
  rc_is "$rc" 2 "the raw URL cannot be reached"
  has "$err" "could not download $URL in 12 attempts (the last curl exit was 7" "says so"
}

c_cleanup_follows_no_symlink_swapped_after_allocation() {
  local left
  mkdir -p "$S/a" "$S/b" && ln -s "$S/a" "$S/link" || exit 2
  : > "$S/retarget"
  TMPDIR="$S/link" rel "$VER"
  rc_is "$rc" 0 "the cut, with TMPDIR's symlink retargeted under it"
  eq "$(ls -A "$S/a")" "" "the directory it made is gone"
  left="$(ls -A "$S/b")"
  [ -n "$left" ] && [ -f "$S/b/$left/victim" ] && [ "$(cat "$S/b/$left/assets/shmutant.sh")" = theirs ] \
    || fail_ "something planted at the new target was removed"
}

c_cleanup_leaves_a_directory_that_replaced_its_own() {
  local d
  mkdir -p "$S/tmp"; : > "$S/replace-tmp"
  TMPDIR="$S/tmp" rel "$VER"
  rc_is "$rc" 0 "the cut, its directory replaced while the release was created"
  has "$err" "it is no longer the directory this run made" "cleanup says why it left the directory"
  for d in "$S"/tmp/release.*; do
    case "$d" in *.moved) ;; *) [ "$(cat "$d/assets/shmutant.sh" 2> /dev/null)" = theirs ] \
      || fail_ "the replacing directory's own assets/shmutant.sh was removed" ;; esac
  done
}

c_never_adopts_a_directory_that_appears_at_its_chosen_name() {
  mkdir -p "$S/box-race" "$S/tmp" || exit 2
  # On the first call for the run's directory, another directory appears at that name, holding a
  # file, just before the real mkdir runs.
  printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in */release.[0-9]*) case "${a##*/release.}" in */*) ;; *) [ -e "%s/raced" ] || { /bin/mkdir -- "$a" && echo theirs > "$a/theirs" && : > "%s/raced"; } ;; esac ;; esac; done\nexec /bin/mkdir "$@"\n' \
    "$S" "$S" > "$S/box-race/mkdir"
  chmod +x "$S/box-race/mkdir" || exit 2
  (cd -- "$c" && PATH="$S/box-race:$tmp/bin:$PATH" TMPDIR="$S/tmp" STUB="$S" SLUG="$SLUG" bash scripts/release.sh "$VER") > "$S/out" 2> "$S/err"
  rc=$?; err="$(cat "$S/err")"
  rc_is "$rc" 0 "the cut, after a race at its first chosen name"
  hasnt "$err" "left $S/tmp" "the raced directory was never taken for its own"
  eq "$(cat "$S"/tmp/release.*/theirs 2> /dev/null)" theirs "and still holds its file"
}

c_cleanup_never_reaches_through_a_link_that_replaced_its_directory() {
  mkdir -p "$S/tmp"; : > "$S/link-tmp"
  TMPDIR="$S/tmp" rel "$VER"
  rc_is "$rc" 0 "the cut, its directory replaced by a link while the release was created"
  has "$err" "it is no longer the directory this run made" "cleanup says why it left it"
  [ -f "$S/elsewhere/assets/shmutant.sh" ] || fail_ "an identical copy behind the link was removed"
}

c_cleanup_takes_identical_content_for_nothing() {
  local d
  mkdir -p "$S/tmp"; : > "$S/replace-identical"
  TMPDIR="$S/tmp" rel "$VER"
  rc_is "$rc" 0 "the cut, its directory replaced by one holding identical copies"
  has "$err" "it is no longer the directory this run made" "cleanup says why it left it"
  for d in "$S"/tmp/release.*; do
    case "$d" in *.moved) ;; *) [ -f "$d/assets/shmutant.sh" ] && [ -f "$d/assets/CHECKSUMS" ] \
      || fail_ "an identical copy in the replacing directory was removed" ;; esac
  done
}

c_cleanup_removes_only_the_files_it_wrote() {
  mkdir -p "$S/tmp"; : > "$S/replace-asset"
  TMPDIR="$S/tmp" rel "$VER"
  rc_is "$rc" 0 "the cut, one asset swapped for an identical new file"
  has "$err" "it is not empty" "cleanup says why it left the directory"
  local f found=0
  for f in "$S"/tmp/release.*/assets/shmutant.sh; do [ ! -f "$f" ] || found=1; done
  [ "$found" -eq 1 ] || fail_ "the swapped-in file was removed"
}

c_a_read_that_fails_after_the_push_exits_2() {
  : > "$S/github-tag.fail-after"
  rel "$VER"
  rc_is "$rc" 2 "GitHub's tags unreadable after the push"
  has "$err" "cannot be read through the GitHub API" "says so"
  has "$err" "to finish the release of $TAG by hand" "and how to finish"
  fixture "${_case}_origin"
  # A git that cannot list origin's tags once origin has this one.
  mkdir -p "$S/box-ls" || exit 2
  printf '#!/usr/bin/env bash\ncase "$*" in *"ls-remote origin refs/tags/%s"*) ! %q -C %q rev-parse -q --verify refs/tags/%s > /dev/null || { echo "fatal: injected" >&2; exit 128; } ;; esac\nexec %q "$@"\n' \
    "$TAG" "$(command -v git)" "$S/origin.git" "$TAG" "$(command -v git)" > "$S/box-ls/git" && chmod +x "$S/box-ls/git" || exit 2
  relf "$S/box-ls" "$VER"
  rc_is "$rc" 2 "origin's tags unreadable after the push"
  has "$err" "cannot read origin's tags after the push of $TAG" "says so"
  has "$err" "to finish the release of $TAG by hand" "and how to finish"
}

c_refuses_more_check_suites_than_github_lists_runs_for() {
  echo 1001 > "$S/suites"
  rel --dry-run "$VER"
  refused_once "it has 1001 check suites, and GitHub lists check runs for the latest 1,000 only" "1001 check suites"
}

c_never_adopts_a_directory_a_signal_arrives_with() {
  mkdir -p "$S/box-steal" "$S/tmp" || exit 2
  # Another process makes the run's chosen directory first, with a file of its own, and signals the
  # run while its mkdir fails.
  printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in */release.[0-9]*) case "${a##*/release.}" in */*) ;; *) [ -e "%s/stolen" ] || { /bin/mkdir -p -- "$a/assets" && echo theirs > "$a/assets/shmutant.sh" && : > "%s/stolen"; } ;; esac ;; esac; done\n/bin/mkdir "$@"; rc=$?\nkill -TERM 0\nexit "$rc"\n' \
    "$S" "$S" > "$S/box-steal/mkdir"
  chmod +x "$S/box-steal/mkdir" || exit 2
  bash -c 'set -m; cd -- "$1" || exit 2; PATH="$2:$PATH" TMPDIR="$3" STUB="$4" SLUG="$5" bash scripts/release.sh "$6" & wait $!' \
    _ "$c" "$S/box-steal:$tmp/bin" "$S/tmp" "$S" "$SLUG" "$VER" > "$S/out" 2> "$S/err"
  rc=$?; err="$(cat "$S/err")"
  rc_is "$rc" 143 "TERM while mkdir fails on a directory another made"
  eq "$(cat "$S"/tmp/release.*/assets/shmutant.sh 2> /dev/null)" theirs "the other directory and its file are untouched"
}

c_exits_2_when_a_text_tool_fails() {
  toolbox "$S/box" gh curl sleep sha256sum shasum openssl
  rm -f -- "$S/box/sort"
  printf '#!/bin/sh\ncat\nexit 1\n' > "$S/box/sort" && chmod +x "$S/box/sort" || exit 2
  relp "$S/box" --dry-run "$VER"
  rc_is "$rc" 2 "a sort that fails"
  has "$err" "cannot sort the URLs in docs/integrating.md" "says so"
}

c_refuses_ci_lists_shorter_than_githubs_count() {
  recount checks.json 1001
  rel --dry-run "$VER"
  refused_once "GitHub counts 1001 check runs on it but listed 2" "a check-run list GitHub capped"
  checks alpha:completed:success beta:completed:success
  recount runs.json 1001
  rel --dry-run "$VER"
  refused_once "GitHub counts 1001 ci.yml runs on it but listed 1" "a workflow-run list GitHub capped"
}

# failbox <dir> <tool> <status> <glob> — <dir> holding a <tool> that exits <status> when its
# arguments, joined by spaces, match <glob>, and is the real <tool> otherwise.
failbox() {
  mkdir -p "$1" || exit 2
  printf '#!/usr/bin/env bash\npat=%q\ncase "$*" in $pat) echo "%s: injected failure" >&2; exit %s ;; esac\nexec %q "$@"\n' \
    "$4" "$2" "$3" "$(command -v "$2")" > "$1/$2" && chmod +x "$1/$2" || exit 2
}
# relf <box> <arg>… — rel with <box> first on PATH.
relf() {
  local box="$1"; shift
  (cd -- "$c" && PATH="$box:$tmp/bin:$PATH" STUB="$S" SLUG="$SLUG" bash scripts/release.sh "$@") > "$S/out" 2> "$S/err"
  rc=$?
  out="$(cat "$S/out")"; err="$(cat "$S/err")"
}

# trbox <dir> <input> fail|empty — <dir> holding a tr that, given exactly <input> on stdin, exits 1
# (fail) or prints nothing and exits 0 (empty), and is the real tr otherwise.
trbox() {
  mkdir -p "$1" || exit 2
  printf '#!/usr/bin/env bash\nf="$(mktemp %q)" || exit 2\ncat > "$f"\nif [ "$(cat "$f")" = %q ]; then rm -f -- "$f"; [ %q = empty ] && exit 0; echo "tr: injected failure" >&2; exit 1; fi\n%q "$@" < "$f"; s=$?; rm -f -- "$f"; exit "$s"\n' \
    "$1/in.XXXXXX" "$2" "$3" "$(command -v tr)" > "$1/tr" && chmod +x "$1/tr" || exit 2
}

c_a_failed_lower_case_exits_2_and_never_matches() {
  trbox "$S/t1" "$SLUG" fail
  relf "$S/t1" --dry-run "$VER"; rc_is "$rc" 2 "origin's name"; has "$err" "cannot lower-case origin's repository name" "says so"
  trbox "$S/t2" "$SLUG" empty
  relf "$S/t2" --dry-run "$VER"; rc_is "$rc" 2 "origin's name, lower-cased to nothing"; has "$err" "cannot lower-case origin's repository name" "says so"
  # Names in another case than origin's, so that only their own lower-casing fails.
  git -C "$c" config remote.origin.pushurl "git@github.com:SHMUTANT-TEST/FIXTURE.git"
  rel --dry-run "$VER"; rc_is "$rc" 0 "a push URL naming origin's repository in capitals"
  trbox "$S/t3" SHMUTANT-TEST/FIXTURE fail
  relf "$S/t3" --dry-run "$VER"; rc_is "$rc" 2 "a push URL's name"; has "$err" "cannot lower-case a push URL's repository name" "says so"
  git -C "$c" config --unset remote.origin.pushurl
  echo "https://raw.githubusercontent.com/Shmutant-Test/fixture/$TAG/shmutant.sh" > "$c/docs/integrating.md"
  land "$c" doc-in-capitals
  rel --dry-run "$VER"; rc_is "$rc" 0 "an install URL naming origin's repository in capitals"
  trbox "$S/t4" Shmutant-Test/fixture fail
  relf "$S/t4" --dry-run "$VER"; rc_is "$rc" 2 "the install URL's name"
  has "$err" "cannot lower-case the repository name in docs/integrating.md's URL" "says so"
}

c_an_unreadable_inode_stops_the_cut_before_the_tag() {
  mkdir -p "$S/tmp"
  failbox "$S/i1" ls 1 '-di -- *'
  TMPDIR="$S/tmp" relf "$S/i1" "$VER"
  rc_is "$rc" 2 "the run's directory has no readable inode"
  has "$err" "cannot read the inode of the temporary directory" "says so"
  published_nothing "an unreadable inode"
  for d in "$S"/tmp/release.*; do [ ! -e "$d" ] || fail_ "left $d behind"; done
  # An ls that prints an inode but fails, and one that succeeds but prints no inode.
  mkdir -p "$S/i3" "$S/i4" || exit 2
  printf '#!/bin/sh\necho "1 $3"\nexit 1\n' > "$S/i3/ls"; printf '#!/bin/sh\necho "x $3"\n' > "$S/i4/ls"
  chmod +x "$S/i3/ls" "$S/i4/ls" || exit 2
  TMPDIR="$S/tmp" relf "$S/i3" "$VER"; rc_is "$rc" 2 "ls fails after printing an inode"
  TMPDIR="$S/tmp" relf "$S/i4" "$VER"; rc_is "$rc" 2 "ls prints no inode"
  published_nothing "an inode ls did not read"
}

# asset_inode_unreadable <path under the run's directory> — a cut whose ls cannot read that path's
# inode, once the tag is pushed: a failed read, so exit 2, with the way to finish and no release.
asset_inode_unreadable() {
  mkdir -p "$S/tmp"
  failbox "$S/ia" ls 1 "-di -- */$1"
  TMPDIR="$S/tmp" relf "$S/ia" "$VER"
  rc_is "$rc" 2 "$1 has no readable inode"
  has "$err" "cannot read the inode of $S/tmp/release." "says so"
  has "$err" "to finish the release of $TAG by hand" "and how to finish"
  hasnt "$(events)" "gh release create" "no release was created"
}
c_an_unreadable_assets_directory_inode_exits_2() { asset_inode_unreadable assets; }
c_an_unreadable_shmutant_sh_asset_inode_exits_2() { asset_inode_unreadable assets/shmutant.sh; }
c_an_unreadable_checksums_asset_inode_exits_2() { asset_inode_unreadable assets/CHECKSUMS; }

c_ignores_the_callers_shallow_file() {
  printf 'not a commit id\n' > "$S/bad"
  rele GIT_SHALLOW_FILE="$S/bad" -- --dry-run "$VER"
  rc_is "$rc" 0 "a caller's malformed shallow file"
}

c_exits_2_when_a_read_fails_rather_than_finds_nothing() {
  local sha head
  failbox "$S/f1" git 128 '*symbolic-ref --quiet --short HEAD*'
  relf "$S/f1" --dry-run "$VER"; rc_is "$rc" 2 "HEAD unreadable"; has "$err" "cannot read HEAD" "says so"
  failbox "$S/f2" git 128 '*config --get-all remote.origin.pushurl*'
  relf "$S/f2" --dry-run "$VER"; rc_is "$rc" 2 "push URLs unreadable"; has "$err" "cannot read origin's push URLs" "says so"
  failbox "$S/f3" git 128 '*--get-regexp*'
  relf "$S/f3" --dry-run "$VER"; rc_is "$rc" 2 "config unreadable"; has "$err" "cannot read git's config" "says so"
  failbox "$S/f4" git 128 '*rev-parse --quiet --verify refs/tags/*'
  relf "$S/f4" --dry-run "$VER"; rc_is "$rc" 2 "local tags unreadable"; has "$err" "cannot read this checkout's tags" "says so"
  failbox "$S/f5" grep 2 '*^SHMUTANT_VERSION=*'
  relf "$S/f5" --dry-run "$VER"; rc_is "$rc" 2 "the version search fails"; has "$err" "cannot search shmutant.sh (grep exit 2)" "says so"
  failbox "$S/f6" grep 2 "*-Fxq -- $TAG*"
  relf "$S/f6" --dry-run "$VER"; rc_is "$rc" 2 "the release search fails"; has "$err" "cannot search $SLUG's GitHub releases (grep exit 2)" "says so"
  other_clone; land "$o" newer; sha="$(git -C "$o" rev-parse HEAD)"
  failbox "$S/f7" git 128 "*rev-parse --verify --quiet $sha^{commit}*"
  relf "$S/f7" --dry-run "$VER"; rc_is "$rc" 2 "origin's main unreadable here"; has "$err" "cannot read commit $sha" "says so"
  git -C "$c" fetch -q origin || exit 2
  head="$(git -C "$c" rev-parse HEAD)"
  failbox "$S/f8" git 128 "*merge-base --is-ancestor $head $sha*"
  relf "$S/f8" --dry-run "$VER"; rc_is "$rc" 2 "is HEAD behind: the comparison fails"; has "$err" "cannot compare HEAD with $sha" "says so"
  failbox "$S/f9" git 128 "*merge-base --is-ancestor $sha $head*"
  relf "$S/f9" --dry-run "$VER"; rc_is "$rc" 2 "is HEAD ahead: the comparison fails"; has "$err" "cannot compare HEAD with $sha" "says so"
}

c_an_interrupt_while_allocating_leaves_nothing() {
  mkdir -p "$S/box-mkdir" "$S/tmp" || exit 2
  # A mkdir that makes the run's directory and then sends TERM to its process group.
  printf '#!/usr/bin/env bash\n/bin/mkdir "$@" || exit 1\nfor a in "$@"; do case "$a" in */release.[0-9]*) case "${a##*/release.}" in */*) ;; *) kill -TERM 0 ;; esac ;; esac; done\n' \
    > "$S/box-mkdir/mkdir"
  chmod +x "$S/box-mkdir/mkdir" || exit 2
  # In a process group of its own (set -m), so the stub's TERM to its group reaches the driver only.
  # The background job is the driver itself, not a list: a subshell around it would take the TERM
  # too and let the wait return before the driver had cleaned up.
  bash -c 'set -m; cd -- "$1" || exit 2; PATH="$2:$PATH" TMPDIR="$3" STUB="$4" SLUG="$5" bash scripts/release.sh "$6" & wait $!' \
    _ "$c" "$S/box-mkdir:$tmp/bin" "$S/tmp" "$S" "$SLUG" "$VER" > "$S/out" 2> "$S/err"
  rc=$?; err="$(cat "$S/err")"
  rc_is "$rc" 143 "TERM while the temporary directory is made"
  eq "$(ls -A "$S/tmp")" "" "and it is removed"
}

c_a_dry_run_whose_report_is_lost_does_not_pass() {
  relq --dry-run "$VER"
  rc_is "$rc" 2 "a dry run with its stdout closed"
  has "$err" "line(s) of this run's report could not be written to stdout: every precondition holds for $TAG" "says so"
  # Under bash 3.2 a line it could not write would come back inside the next read, and refuse.
  eq "$(refusals)" 0 "and refuses nothing"
  relq --help
  rc_is "$rc" 2 "--help with its stdout closed"
}

c_a_cut_whose_report_is_lost_stops_before_the_tag() {
  relq "$VER"
  rc_is "$rc" 2 "a cut with its stdout closed"
  has "$err" "but the cut stops here: nothing was tagged, pushed or published" "says so"
  published_nothing "a cut with its stdout closed"
}

c_a_report_lost_after_the_tag_says_the_release_is_out() {
  relb "pushed $TAG" "$VER"
  rc_is "$rc" 2 "stdout lost once the tag is pushed"
  has "$err" "could not be written to stdout: the release $TAG is published and verifies; next: baseline release roll --version $TAG" "says what was done"
  has "$(events)" "gh release create" "the release was published"
  hasnt "$err" "VERIFY FAILED" "and is not called a verify failure"
}

c_a_verify_whose_report_is_lost_does_not_pass() {
  rel "$VER"
  rc_is "$rc" 0 "the cut"
  relq --verify "$VER"
  rc_is "$rc" 2 "--verify with its stdout closed"
  has "$err" "could not be written to stdout: the release $TAG verifies" "says so"
  hasnt "$err" "VERIFY FAILED" "and is not called a verify failure"
}

c_refuses_a_doc_holding_a_nul() {
  printf 'curl -fsSL -o scripts/shmutant.sh %s\0.sh\n' "${URL%.sh}" > "$c/docs/integrating.md"
  land "$c" nul-in-url
  rel --dry-run "$VER"
  refused_once "docs/integrating.md at $(git -C "$c" rev-parse HEAD) holds a NUL byte, so its text cannot be checked" "a NUL inside the URL"
  printf '%s\n\0\n' "$URL" > "$c/docs/integrating.md"
  land "$c" nul-after-url
  rel --dry-run "$VER"
  refused_once "docs/integrating.md at $(git -C "$c" rev-parse HEAD) holds a NUL byte" "a NUL on a line of its own"
  # Counted in bytes: multibyte text, and either newline shape at the end, is no NUL.
  printf 'Install it \342\200\224 %s' "$URL" > "$c/docs/integrating.md"
  land "$c" no-final-newline
  rel --dry-run "$VER"
  rc_is "$rc" 0 "a UTF-8 doc with no final newline"
  printf 'Install it \342\200\224\n\n%s\n\n\n' "$URL" > "$c/docs/integrating.md"
  land "$c" blank-lines-at-end
  rel --dry-run "$VER"
  rc_is "$rc" 0 "a UTF-8 doc ending in blank lines"
}

c_refuses_a_version_line_holding_a_nul() {
  printf '#!/usr/bin/env bash\nSHMUTANT_VERSION=1.2\0.3\n' > "$c/shmutant.sh"; checksum "$c"
  land "$c" nul-in-version
  rel --dry-run "$VER"
  refused_once "shmutant.sh at $(git -C "$c" rev-parse HEAD) holds a NUL byte, so its text cannot be checked" "a NUL in the version"
}

c_verify_fails_on_a_tagged_doc_holding_a_nul() {
  rel "$VER"
  rc_is "$rc" 0 "the cut"
  # The tag moved, here and on origin, to a commit whose doc holds a NUL in the install URL.
  printf 'curl -fsSL -o scripts/shmutant.sh %s\0.sh\n' "${URL%.sh}" > "$c/docs/integrating.md"
  commit "$c" nul-in-url
  git -C "$c" tag -f -a "$TAG" -m moved HEAD > /dev/null && git -C "$c" push -q -f origin "refs/tags/$TAG" || exit 2
  rel --verify "$VER"
  rc_is "$rc" 1 "--verify at a tag whose doc holds a NUL"
  has "$err" "VERIFY FAILED: at $TAG, docs/integrating.md at $(git -C "$c" rev-parse HEAD) holds a NUL byte" "says so"
}

c_an_interrupted_verify_says_it_changed_nothing() {
  local sig
  for sig in term:143 int:130; do
    fixture "${_case}_${sig%%:*}"
    rel "$VER"
    rc_is "$rc" 0 "the cut"
    echo "${sig%%:*}" > "$S/curl.mode"
    relg --verify "$VER"
    rc_is "$rc" "${sig#*:}" "${sig%%:*} during a standalone --verify"
    has "$err" "interrupted; --verify changes nothing, so re-run it to check the release $TAG" "says so"
  done
}

c_an_interrupt_before_the_tag_says_nothing_was_published() {
  local mode
  for mode in --dry-run --cut; do
    fixture "${_case}${mode#-}"
    echo TERM > "$S/gh.signal"
    if [ "$mode" = --cut ]; then relg "$VER"; else relg "$mode" "$VER"; fi
    rc_is "$rc" 143 "TERM during the checks of a ${mode#--}"
    has "$err" "interrupted; nothing was tagged, pushed or published" "says so"
    published_nothing "an interrupted ${mode#--}"
  done
}

# --- run ---------------------------------------------------------------------------------------

n=0
for f in $(declare -F | awk '$3 ~ /^c_/ { print $3 }'); do
  _case="${f#c_}"; n=$((n + 1))
  fixture "$_case"
  "$f"
done
[ "$n" -gt 0 ] || { echo "test/release.sh: no case ran" >&2; exit 2; }
if [ "$fails" -gt 0 ]; then
  printf 'test/release.sh: %d case(s) ran, %d check(s) failed\n' "$n" "$fails" >&2
  exit 1
fi
printf 'test/release.sh: %d case(s) ran, every check held\n' "$n" >&2

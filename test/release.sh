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
set -u
unset CDPATH

for t in git jq; do
  command -v "$t" > /dev/null || { echo "test/release.sh: $t is not on PATH" >&2; exit 2; }
done
root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
made="$(mktemp -d "${TMPDIR:-/tmp}/release-test.XXXXXX")" || exit 2
trap 'rm -rf -- "$made"' EXIT
tmp="$(cd -P -- "$made" && pwd -P)" || exit 2

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
[ "${GH_PROMPT_DISABLED:-}" = 1 ] && [ "${GIT_TERMINAL_PROMPT:-}" = 0 ] \
  || { echo "gh stub: called with prompts enabled" >&2; exit 3; }
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
# opts <args>… — sets repo, dir, verify and files from a release subcommand's arguments.
opts() {
  repo=""; dir=""; verify=0; files=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -R) repo="$2"; shift 2 ;;
      --dir) dir="$2"; shift 2 ;;
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
  "api repos/$SLUG/commits/"*"/check-runs?filter=latest&per_page=100")
    pages; [ ! -e "$STUB/checks.fail" ] || fail "HTTP 502"
    reply < "$STUB/checks.json" ;;
  "api repos/$SLUG/actions/workflows/ci.yml/runs?head_sha="*"&per_page=100")
    pages; reply < "$STUB/runs.json" ;;
  "api repos/$SLUG/commits/"*"/status")
    reply < "$STUB/status.json" ;;
  "api repos/$SLUG/releases?per_page=100")
    pages
    # $STUB/advance-main holds a commit origin's main moves to once the releases are listed: the
    # last read of the checks, so a cut sees main move between its checks and its tag.
    [ ! -e "$STUB/advance-main" ] || git -C "$STUB/origin.git" update-ref refs/heads/main "$(cat "$STUB/advance-main")" || exit 1
    draft=false; [ ! -e "$STUB/release.draft" ] || draft=true
    ls -- "$STUB/published" | jq -Rn --argjson d "$draft" '[inputs | {tag_name: ., draft: $d}]' | reply ;;
  "release create")
    [ ! -e "$STUB/create.fail" ] || fail "HTTP 500"
    t="${a[2]}"; opts "${a[@]:3}"
    [ "$verify" -eq 1 ] || { echo "gh stub: release create without --verify-tag" >&2; exit 3; }
    git -C "$STUB/origin.git" rev-parse -q --verify "refs/tags/$t" > /dev/null || fail "tag $t doesn't exist in the repo"
    mkdir -p "$STUB/release" && cp -- "${files[@]}" "$STUB/release/" || exit 1
    [ ! -e "$STUB/asset.tamper" ] || echo '# tampered' >> "$STUB/release/$(cat "$STUB/asset.tamper")"
    [ ! -e "$STUB/asset.omit" ] || rm -f -- "$STUB/release/$(cat "$STUB/asset.omit")"
    : > "$STUB/published/$t" ;;
  "release download")
    t="${a[2]}"; opts "${a[@]:3}"
    [ -e "$STUB/published/$t" ] || fail "Not Found (HTTP 404)"
    cp -- "$STUB/release/"* "$dir/" || exit 1
    [ ! -e "$STUB/asset.unreadable" ] || chmod 000 "$dir/$(cat "$STUB/asset.unreadable")" ;;
  *) echo "gh stub: unexpected call: ${a[*]}" >&2; exit 3 ;;
esac
EOF

cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
# curl … -o <file> <url>, answered from the fixture's origin: <url> must be a raw URL of the
# fixture's repository. $STUB/curl.404s holds how many downloads fail before one succeeds;
# $STUB/curl.mode `tamper` alters the bytes, `unreadable` leaves them unreadable, `term` and `int`
# send TERM or INT to the caller.
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
case "$mode" in term|int) kill "-$(printf '%s' "$mode" | tr a-z A-Z)" "$PPID"; notfound ;; esac
n="$(cat "$STUB/curl.404s" 2> /dev/null)"
if [ "${n:-0}" -gt 0 ]; then echo $((n - 1)) > "$STUB/curl.404s"; notfound; fi
case "$url" in "https://raw.githubusercontent.com/$SLUG/"*/shmutant.sh) ;; *) notfound ;; esac
t="${url#"https://raw.githubusercontent.com/$SLUG/"}"; t="${t%/shmutant.sh}"
git -C "$STUB/origin.git" cat-file blob "$t:shmutant.sh" > "$out" 2> /dev/null || notfound
[ "$mode" != tamper ] || echo '# tampered' >> "$out"
[ "$mode" != unreadable ] || chmod 000 "$out"
EOF

cat > "$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >> "$STUB/events"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/curl" "$tmp/bin/sleep" || exit 2

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
  printf '%s\n' "$@" | jq -Rn '{check_runs: [inputs | select(. != "") | split(":")
    | {name: .[0], status: .[1], conclusion: (if .[2] == "null" then null else .[2] end)}]}' > "$S/checks.json" || exit 2
}
runs() {
  printf '%s\n' "$@" | jq -Rn '{workflow_runs: [inputs | select(. != "") | split(":")
    | {id: (.[0] | tonumber), status: .[1], conclusion: (if .[2] == "null" then null else .[2] end)}]}' > "$S/runs.json" || exit 2
}

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
  for t in bash git jq dirname tr awk grep sort wc mkdir rm mktemp cat cp ls sed head "$@"; do
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
           "no tag $TAG on origin" "no GitHub release for $TAG"; do
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
  refused_once "tag $TAG already exists on origin" "a tag on origin"
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
  refused_once "gh's token cannot push to $SLUG" "a read-only token"
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
  eq "$(refusals)" 3 "refused: the tag here, on origin, and the release"
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
  has "$err" "VERIFY FAILED: $URL did not download in 12 attempts" "says so"
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
  rel "$VER"
  rc_is "$rc" 143 "TERM during verification"
  has "$err" "interrupted once the tag $TAG may exist" "says so"
  has "$err" "scripts/release.sh --verify $VER" "and how to finish"
}

c_an_interrupt_exits_130_and_says_how_to_finish() {
  echo int > "$S/curl.mode"
  rel "$VER"
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
  local cmd
  : > "$S/create.fail"
  rel "$VER"
  rc_is "$rc" 1 "gh release create fails"
  rm -f -- "$S/create.fail"
  echo '# an edit made in the work tree afterwards' >> "$c/shmutant.sh"
  mkdir -p "$S/finish" || exit 2
  # The printed steps, run as printed: write the assets, then the "with no release" command.
  while IFS= read -r cmd; do
    (cd -- "$S/finish" && unset GH_HOST && PATH="$tmp/bin:$PATH" STUB="$S" SLUG="$SLUG" \
       GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 eval "$cmd") 2>> "$S/finish.err" \
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

c_verify_exits_2_when_it_cannot_hash_what_it_read() {
  echo unreadable > "$S/curl.mode"
  rel "$VER"
  rc_is "$rc" 2 "the download cannot be read"
  has "$err" "cannot compute the SHA-256 of the download" "says so"
  rm -f -- "$S/curl.mode"; echo CHECKSUMS > "$S/asset.unreadable"
  rel --verify "$VER"
  rc_is "$rc" 2 "a downloaded asset cannot be read"
  has "$err" "cannot compute the SHA-256 of the release's CHECKSUMS" "says so"
}

c_publishes_the_assets_of_the_commit_it_checked() {
  # origin's post-receive hook commits a change to the clone, so HEAD moves once the tag is pushed.
  printf '#!/bin/sh\necho "# moved" >> %s/shmutant.sh && env -u GIT_DIR -u GIT_QUARANTINE_PATH git -C %s commit -qam moved\n' "$c" "$c" \
    > "$S/origin.git/hooks/post-receive"
  chmod +x "$S/origin.git/hooks/post-receive"
  rel "$VER"
  rc_is "$rc" 0 "the cut, though the checkout moved under it"
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

# --- run ---------------------------------------------------------------------------------------

n=0
for f in $(declare -F | awk '$3 ~ /^c_/ { print $3 }'); do
  _case="${f#c_}"; n=$((n + 1))
  fixture "$_case"
  "$f"
done
if [ "$fails" -gt 0 ]; then
  printf 'test/release.sh: %d case(s) ran, %d check(s) failed\n' "$n" "$fails" >&2
  exit 1
fi
printf 'test/release.sh: %d case(s) ran, every check held\n' "$n" >&2

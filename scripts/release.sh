#!/usr/bin/env bash
# scripts/release.sh [--dry-run | --verify] <version> — cut shmutant release <version>.
#
# <version> is X.Y.Z, with or without a leading v; the tag is vX.Y.Z. Prereleases are not cut.
#
# A cut checks every precondition below and changes nothing unless all of them hold. It then
# creates the annotated tag vX.Y.Z on the commit it checked, pushes it, publishes the GitHub
# release with shmutant.sh and CHECKSUMS from that tag attached, runs --verify, and prints the
# milestone command the operator runs next.
#
# Preconditions, each refused on stderr with its own `release: refused: …` line:
#   - HEAD is on main, the work tree is clean (untracked files included), and HEAD is the commit
#     origin's main names, asked of origin with ls-remote and of GitHub's API;
#   - CI is green on that commit: every check run GitHub lists on it is completed with conclusion
#     success, the ci.yml workflow ran on it and each of its runs there concluded success, each
#     list is as long as GitHub's own count of it, and its commit statuses, if any, are success;
#   - shmutant.sh at HEAD sets SHMUTANT_VERSION=<version>, on one line;
#   - CHECKSUMS at HEAD is the one line `<sha256>  shmutant.sh`, and the digest is shmutant.sh's;
#   - docs/integrating.md at HEAD names one raw.githubusercontent.com URL of shmutant.sh: this
#     repository's, at the tag v<version>;
#   - no tag v<version> exists in this checkout, on origin or on GitHub, and no GitHub release has it.
# Just before tagging, origin's main is read again and must still be the commit checked. After the
# push, origin's tag and GitHub's tag must both name it before anything is published.
#
# --dry-run  checks every precondition and changes nothing: no fetch, no tag, no push, no release,
#            and no file of its own. In a partial clone it needs git 2.45 or newer, which honours
#            GIT_NO_LAZY_FETCH, and refuses an older git (exit 2) rather than let it fetch.
# --verify   checks a published release only: origin's and GitHub's tags must name the commit this
#            checkout's tag names, the URL docs/integrating.md documents there and the release's
#            shmutant.sh must have the digest CHECKSUMS there gives, and the release's CHECKSUMS
#            must be that file. A cut verifies against the commit it checked. Its last line on
#            success is `release: verified: the release <tag> carries …`.
#
# The repository is the one origin's single URL names, a github.com HTTPS or SSH URL; every push
# URL origin has must name the same one. Every gh call names it, on github.com, and gh's account
# must be able to push to it. Needs git, gh, curl, the POSIX text tools, and sha256sum, shasum or
# openssl. Git over HTTPS and gh never prompt: credentials come from a credential helper or gh's
# login, no askpass program is run, and a missing credential fails instead of waiting. The caller's
# exported functions and aliases, its GIT_* repository, git's tracing variables, git replacement
# objects and GH_HOST, and the shell options that change what a command does (xtrace, verbose, keyword, allexport, errexit,
# noclobber, pipefail, posix, nocasematch) are set aside before anything is read. A function
# named after a builtin the setup itself calls (builtin, read, unset, declare) cannot be, nor can
# the options that stop commands from running at all (noexec, onecmd): run the driver with
# SHELLOPTS, BASHOPTS and BASH_ENV removed, as the /release skill does, and take success from its
# last line, not from its exit status alone.
#
# Exit 0 = done, or (--dry-run) every precondition held; 1 = a precondition refused, or a publish
# or verify step failed, saying so on stderr; 130/143 = interrupted, saying what may already be
# published; 2 = could not run (usage, a missing tool, a failed read).
builtin set -u +a +e +k +v +x +C +o pipefail +o posix
builtin shopt -u nocasematch expand_aliases
while IFS=' ' builtin read -r _ _ _fn; do [[ -n $_fn ]] && builtin unset -f "$_fn"; done <<EOF
$(builtin declare -F)
EOF
unset CDPATH
export LC_ALL=C GH_HOST=github.com GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1 \
  GIT_NO_LAZY_FETCH=1
unset -v GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_COMMON_DIR GIT_NAMESPACE GIT_SHALLOW_FILE "${!GIT_TRACE@}" GIT_CURL_VERBOSE
export GIT_TRACE2=0 GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0 GIT_ASKPASS=false

# Downloads of the raw URL before --verify gives up, and the pause between them: a new tag can
# answer 404 there for a while, and a cached 404 lives up to 300 seconds. Reads of GitHub's tag
# just after the push, and their pause, for an API that has not yet shown it.
attempts=12
pause=30
ref_reads=3
ref_pause=2

say()   { printf 'release: %s\n' "$*"; }
err()   { printf 'release: %s\n' "$*" >&2; }
die()   { err "$*"; exit 2; }
usage() { printf 'usage: scripts/release.sh [--dry-run | --verify] <version>\n'; }

mode="cut"; version=""; nver=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|--verify)
      [ "$mode" = cut ] || { err "--dry-run and --verify exclude each other"; usage >&2; exit 2; }
      mode="${1#--}" ;;
    -h|--help) usage; exit 0 ;;
    -*) err "unknown option: $1"; usage >&2; exit 2 ;;
    *)  nver=$((nver + 1)); version="$1" ;;
  esac
  shift
done
[ "$nver" -eq 1 ] || { usage >&2; exit 2; }
re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
ver="${version#v}"
[[ "$ver" =~ $re ]] || die "not a version: '$version' (want X.Y.Z or vX.Y.Z)"
tag="v$ver"

for t in git gh curl grep sort awk tr wc dirname mkdir rmdir rm sleep ls; do
  command -v "$t" > /dev/null 2>&1 || die "$t is not on PATH"
done

root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || die "cannot resolve the repository root"
g() { git -C "$root" "$@"; }
top="$(g rev-parse --show-toplevel 2> /dev/null)" && top="$(cd -P -- "$top" && pwd -P)" \
  || die "$root is not a git work tree"
[ "$top" = "$root" ] || die "scripts/release.sh is not at the top of its work tree ($top)"

# lower <s> — <s> in lower case; status 1 when tr fails or prints nothing for a non-empty <s>.
lower() { local l; l="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" && [ -n "$l" ] && printf '%s\n' "$l"; }

# slug_of <url> — the owner/repo a github.com HTTPS or SSH URL names; status 1 for any other URL.
# HTTPS userinfo is held to characters that cannot end the host: git reads `/`, `?` or `#` as its
# end and would connect to whatever precedes them.
slug_of() {
  local u="${1%/}" s="" re='^https://[A-Za-z0-9._~%!$&+,;=:-]+@github\.com/(.+)$'
  u="${u%.git}"
  case "$u" in
    https://github.com/*)   s="${u#https://github.com/}" ;;
    git@github.com:*)       s="${u#git@github.com:}" ;;
    ssh://git@github.com/*) s="${u#ssh://git@github.com/}" ;;
    *) [[ "$u" =~ $re ]] && s="${BASH_REMATCH[1]}" ;;
  esac
  case "/$s/" in */./*|*/../*) return 1 ;; esac
  re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
  [[ "$s" =~ $re ]] || return 1
  printf '%s\n' "$s"
}

# The URLs themselves are never printed: an HTTPS remote can carry a token. Git fetches from the
# first of several URLs and pushes to all of them, so origin may have one.
ourl="$(g config --get-all remote.origin.url)" || die "this checkout has no remote named origin"
case "$ourl" in *$'\n'*) die "origin has more than one URL; give it one" ;; esac
slug="$(slug_of "$ourl")" || die "origin's URL is not a github.com HTTPS or SSH repository URL"
lslug="$(lower "$slug")" || die "cannot lower-case origin's repository name (tr failed)"
pushurls="$(g config --get-all remote.origin.pushurl)"; rc=$?
[ "$rc" -le 1 ] || die "cannot read origin's push URLs (git config exit $rc)"
while IFS= read -r pu; do
  [ -n "$pu" ] || continue
  pslug="$(slug_of "$pu")" || die "a push URL of origin is not a github.com HTTPS or SSH URL of $slug"
  lpslug="$(lower "$pslug")" || die "cannot lower-case a push URL's repository name (tr failed)"
  [ "$lpslug" = "$lslug" ] || die "a push URL of origin is not a github.com HTTPS or SSH URL of $slug"
done <<EOF
$pushurls
EOF

hexre='^[0-9a-f]{40}([0-9a-f]{24})?$'

# Any remote whose promisor setting is true, not only origin, can be fetched from lazily. A config
# read that fails, rather than finding nothing (1), is exit 2.
promisors="$(g config --bool --get-regexp '^remote\..*\.promisor$')"; prc=$?
[ "$prc" -le 1 ] || die "cannot read git's config (exit $prc)"
pclone="$(g config --get extensions.partialclone)"; rc=$?
[ "$rc" -le 1 ] || die "cannot read git's config (exit $rc)"
case " $promisors" in *" true"*) promisor=1 ;; *) promisor=0 ;; esac
if [ "$promisor" -eq 1 ] || [ -n "$pclone" ]; then
  gv="$(git version)" || die "cannot read git's version"
  re='^git version ([0-9]+)\.([0-9]+)'
  [[ "$gv" =~ $re ]] || die "cannot read git's version: $gv"
  [ "${BASH_REMATCH[1]}" -gt 2 ] || { [ "${BASH_REMATCH[1]}" -eq 2 ] && [ "${BASH_REMATCH[2]}" -ge 45 ]; } \
    || die "this is a partial clone, and $gv (older than 2.45) cannot be kept from fetching objects it lacks: use git 2.45 or newer, or a full clone"
fi

# sha256 — the SHA-256 of stdin, from whichever tool the platform has; fails rather than print
# anything but a digest.
sha256() {
  local out
  if command -v sha256sum > /dev/null 2>&1; then out="$(sha256sum)" || return 1
  elif command -v shasum > /dev/null 2>&1; then out="$(shasum -a 256)" || return 1
  elif command -v openssl > /dev/null 2>&1; then out="$(openssl dgst -sha256)" || return 1; out="${out##* }"
  else err "no sha256sum, shasum or openssl on PATH"; return 1
  fi
  out="${out%% *}"
  [[ "$out" =~ ^[0-9a-f]{64}$ ]] || { err "the digest tool printed no SHA-256"; return 1; }
  printf '%s\n' "$out"
}
blob_sha256() { (set -o pipefail; g cat-file blob "$1" | sha256); }
# streamed <command>… — runs <command> into sha256; sets s_src and s_sum to the two statuses and
# s_digest to the digest (meaningful only when both are 0).
streamed() {
  local out
  out="$( { "$@" | sha256; printf '\nstatus %s %s\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}"; } )"
  s_digest="${out%%$'\n'*}"
  out="${out##*status }"
  s_src="${out%% *}"; s_sum="${out#* }"
  case "$s_src$s_sum" in ''|*[!0-9]*) s_src=2; s_sum=2 ;; esac
}

# blob <rev> <path> — prints <path> as committed at <rev>; status 1 when <rev> has no such file, 2
# when it cannot be read. Called inside $(…), so it sets nothing: blob_why names the reason.
blob() {
  local t
  t="$(g ls-tree --name-only "$1" -- "$2")" || return 2
  [ "$t" = "$2" ] || return 1
  g cat-file blob "$1:$2" || return 2
}
# blob_why <status> <rev> <path> — sets why for a blob status of 1 or 2.
blob_why() { if [ "$1" -eq 1 ]; then why="$2 has no $3"; else why="cannot read $3 at $2"; fi; }

# checksums_digest <rev> — sets digest to what CHECKSUMS at <rev> gives shmutant.sh; status 1, with
# why set, unless CHECKSUMS is exactly the one line `<sha256>  shmutant.sh`, newline-terminated;
# 2 when it cannot be read.
checksums_digest() {
  local ck rc size re=$'^([0-9a-f]{64})  shmutant\\.sh\n$'
  digest=""
  ck="$(blob "$1" CHECKSUMS && printf x)"; rc=$?
  [ "$rc" -eq 0 ] || { blob_why "$rc" "$1" CHECKSUMS; return "$rc"; }
  ck="${ck%x}"
  # Its size too, from git: command substitution drops NUL bytes, so the text alone cannot show them.
  size="$(g cat-file -s "$1:CHECKSUMS")" || { why="cannot read CHECKSUMS at $1"; return 2; }
  [ "$size" = 78 ] || { why="CHECKSUMS is not the one line '<sha256>  shmutant.sh' (it is $size bytes, not 78)"; return 1; }
  [[ "$ck" =~ $re ]] || { why="CHECKSUMS is not the one line '<sha256>  shmutant.sh'"; return 1; }
  digest="${BASH_REMATCH[1]}"
}

# doc_url <rev> — sets raw_url to the install URL docs/integrating.md at <rev> documents; status 1,
# with why set, unless the doc names exactly one, of this repository at the tag $tag; 2 when the
# doc cannot be read.
doc_url() {
  local doc urls docslug ldocslug doctag rc re='^https://raw\.githubusercontent\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/([^/]+)/shmutant\.sh$'
  raw_url=""
  doc="$(blob "$1" docs/integrating.md)"; rc=$?
  [ "$rc" -eq 0 ] || { blob_why "$rc" "$1" docs/integrating.md; return "$rc"; }
  # Whole URLs, each to the end of its token, so that a longer one (shmutant.sh.sig, shmutant.sh?x=y,
  # shmutant.sh!) is never read as its shmutant.sh prefix.
  # Each stage on its own, so a failing tool is exit 2 and never a short list. grep's 1 is "none".
  # A URL is taken exactly as written: one with anything after shmutant.sh, sentence punctuation
  # included, is not the install URL.
  urls="$(printf '%s\n' "$doc" | grep -oE 'https://raw\.githubusercontent\.com/[^][[:space:]<>"'"'"'`()]*')"; rc=$?
  [ "$rc" -le 1 ] || { why="cannot search docs/integrating.md (grep exit $rc)"; return 2; }
  if [ -n "$urls" ]; then
    urls="$(printf '%s\n' "$urls" | grep -E '/shmutant\.sh$')"; rc=$?
    [ "$rc" -le 1 ] || { why="cannot search docs/integrating.md (grep exit $rc)"; return 2; }
  fi
  if [ -n "$urls" ]; then
    urls="$(printf '%s\n' "$urls" | sort -u)" || { why="cannot sort the URLs in docs/integrating.md (sort failed)"; return 2; }
  fi
  case "$urls" in
    '')      why="docs/integrating.md names no raw.githubusercontent.com URL of shmutant.sh"; return 1 ;;
    *$'\n'*) why="docs/integrating.md names more than one URL of shmutant.sh: $(printf '%s' "$urls" | tr '\n' ' ')"; return 1 ;;
  esac
  [[ "$urls" =~ $re ]] || { why="docs/integrating.md's URL is not https://raw.githubusercontent.com/<owner>/<repo>/<tag>/shmutant.sh: $urls"; return 1; }
  docslug="${BASH_REMATCH[1]}"; doctag="${BASH_REMATCH[2]}"
  ldocslug="$(lower "$docslug")" || { why="cannot lower-case the repository name in docs/integrating.md's URL (tr failed)"; return 2; }
  [ "$ldocslug" = "$lslug" ] \
    || { why="docs/integrating.md's URL is for $docslug, but origin is $slug"; return 1; }
  [ "$doctag" = "$tag" ] \
    || { why="docs/integrating.md's URL installs $doctag, not $tag: point it at $tag before the cut"; return 1; }
  raw_url="$urls"
}

# origin_tag — the commit origin's tag $tag names, empty when origin has no such tag; status 1 when
# origin cannot be read. The peeled line is listed only when asked for by its own pattern.
origin_tag() {
  local out
  out="$(g ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}")" || return 1
  printf '%s\n' "$out" | awk -v t="refs/tags/$tag" '
    $2 == t "^{}" { peeled = $1 } $2 == t { plain = $1 }
    END { print (peeled != "" ? peeled : plain) }'
}

# github_tag — the commit GitHub's tag $tag names, empty when GitHub has no such tag; status 1 when
# the API cannot be read. GitHub is asked directly because origin's URL may be rewritten elsewhere.
github_tag() {
  local out typ sha
  out="$(gh api --paginate "repos/$slug/git/matching-refs/tags/$tag" \
           --jq ".[] | select(.ref == \"refs/tags/$tag\") | [.object.type, .object.sha] | @tsv")" || return 1
  [ -n "$out" ] || return 0
  typ="${out%%$'\t'*}"; sha="${out#*$'\t'}"
  if [ "$typ" = tag ]; then sha="$(gh api "repos/$slug/git/tags/$sha" --jq '.object.sha')" || return 1; fi
  printf '%s\n' "$sha"
}

refused=0
ok()     { say "ok: $*"; }
refuse() { err "refused: $*"; refused=$((refused + 1)); }

# judge <prefix> <lines> — adds to notgreen each line (`<name>\t<status>\t<conclusion>`) that is not
# a completed success, naming it <prefix><name>; sets judged to the number of lines.
judge() {
  local name status conclusion
  judged=0
  while IFS=$'\t' read -r name status conclusion; do
    [ -n "$name" ] || continue
    judged=$((judged + 1))
    if [ "$status" != completed ]; then notgreen="$notgreen, $1$name is $status"
    elif [ "$conclusion" != success ]; then notgreen="$notgreen, $1$name concluded $conclusion"
    fi
  done <<EOF
$2
EOF
}

# preflight — every precondition, each reported; sets head, remote, digest and raw_url.
preflight() {
  local branch st ls api perm short runs ntotal nsuites wfruns wtotal statuses n w nst state src vl v fsum peel gt rels rc re behind ahead

  branch="$(g symbolic-ref --quiet --short HEAD)"; rc=$?
  [ "$rc" -le 1 ] || die "cannot read HEAD (git symbolic-ref exit $rc)"
  if [ "$branch" = main ]; then ok "on main"
  else refuse "not on main (on ${branch:-a detached HEAD}): git switch main"
  fi

  st="$(g --no-optional-locks status --porcelain --untracked-files=normal)" || die "git status failed"
  if [ -z "$st" ]; then ok "the work tree is clean"
  else refuse "the work tree is not clean ($(printf '%s\n' "$st" | wc -l | tr -d ' ') path(s) in git status): commit, stash or remove them"
  fi

  head="$(g rev-parse --verify --quiet 'HEAD^{commit}')" || die "HEAD names no commit"
  ls="$(g ls-remote origin refs/heads/main)" || die "cannot read origin (git ls-remote failed)"
  remote="$(printf '%s\n' "$ls" | awk '$2 == "refs/heads/main" { print $1 }')" || die "cannot read origin's main (awk failed)"
  [[ "$remote" =~ $hexre ]] || die "origin has no main branch"
  short="${remote:0:12}"
  # Each read separates "no" (1) from a read that failed (anything else), which is exit 2.
  if [ "$head" = "$remote" ]; then ok "HEAD is origin's main ($short)"
  else
    g rev-parse --verify --quiet "$remote^{commit}" > /dev/null; rc=$?
    [ "$rc" -le 1 ] || die "cannot read commit $remote (git rev-parse exit $rc)"
    if [ "$rc" -eq 1 ]; then
      refuse "behind origin/main, or diverged from it: origin's main is $remote, a commit this checkout has not fetched: git pull --ff-only"
    else
      g merge-base --is-ancestor "$head" "$remote"; behind=$?
      [ "$behind" -le 1 ] || die "cannot compare HEAD with $remote (git merge-base exit $behind)"
      g merge-base --is-ancestor "$remote" "$head"; ahead=$?
      [ "$ahead" -le 1 ] || die "cannot compare HEAD with $remote (git merge-base exit $ahead)"
      if [ "$behind" -eq 0 ]; then
        refuse "behind origin/main: origin's main is $remote, ahead of HEAD: git pull --ff-only"
      elif [ "$ahead" -eq 0 ]; then
        refuse "ahead of origin/main ($remote): HEAD has commits origin's main lacks; land them through a pull request"
      else
        refuse "diverged from origin/main ($remote): HEAD and origin's main each have commits the other lacks"
      fi
    fi
  fi

  api="$(gh api "repos/$slug/git/ref/heads/main" --jq '.object.sha')" || die "cannot read $slug's main through the GitHub API"
  if [ "$api" = "$remote" ]; then ok "GitHub's API agrees that $slug's main is $short"
  else refuse "GitHub's API says $slug's main is ${api:-nothing}, but origin says $remote: origin is not $slug, or main just moved"
  fi
  perm="$(gh api "repos/$slug" --jq '.permissions.push')" || die "cannot read $slug through the GitHub API"
  if [ "$perm" = true ]; then ok "gh's account has push access to $slug"
  else refuse "gh's account has no push access to $slug, so it could not publish the release after the tag: gh auth login as one that has"
  fi

  runs="$(gh api --paginate "repos/$slug/commits/$remote/check-runs?filter=latest&per_page=100" \
            --jq '.check_runs[] | [(.name | gsub("[[:cntrl:]]"; "?")), .status, (.conclusion // "none")] | @tsv')" \
    || die "cannot read the check runs on $remote from GitHub"
  ntotal="$(gh api "repos/$slug/commits/$remote/check-runs?filter=latest&per_page=1" --jq '.total_count')" \
    || die "cannot read the check runs on $remote from GitHub"
  nsuites="$(gh api "repos/$slug/commits/$remote/check-suites?per_page=1" --jq '.total_count')" \
    || die "cannot read the check suites on $remote from GitHub"
  wfruns="$(gh api --paginate "repos/$slug/actions/workflows/ci.yml/runs?head_sha=$remote&per_page=100" \
              --jq '.workflow_runs[] | [.id, .status, (.conclusion // "none")] | @tsv')" \
    || die "cannot read the ci.yml workflow runs on $remote from GitHub"
  wtotal="$(gh api "repos/$slug/actions/workflows/ci.yml/runs?head_sha=$remote&per_page=1" --jq '.total_count')" \
    || die "cannot read the ci.yml workflow runs on $remote from GitHub"
  statuses="$(gh api "repos/$slug/commits/$remote/status" --jq '[.total_count, .state] | @tsv')" \
    || die "cannot read the commit statuses on $remote from GitHub"
  notgreen=""
  judge "" "$runs"; n="$judged"
  [ "$n" -gt 0 ] || notgreen="$notgreen, GitHub lists no check runs on it"
  [ "$n" = "$ntotal" ] || notgreen="$notgreen, GitHub counts $ntotal check runs on it but listed $n, so not all could be checked"
  [ "${nsuites:-0}" -le 1000 ] 2> /dev/null \
    || notgreen="$notgreen, it has ${nsuites:-an unknown number of} check suites, and GitHub lists check runs for the latest 1,000 only"
  judge "ci.yml run " "$wfruns"; w="$judged"
  [ "$w" -gt 0 ] || notgreen="$notgreen, the ci.yml workflow has not run on it"
  [ "$w" = "$wtotal" ] || notgreen="$notgreen, GitHub counts $wtotal ci.yml runs on it but listed $w, so not all could be checked"
  IFS=$'\t' read -r nst state <<EOF
$statuses
EOF
  [ "${nst:-0}" = 0 ] || [ "$state" = success ] || notgreen="$notgreen, its $nst commit status(es) are $state"
  if [ -z "$notgreen" ]; then ok "CI is green on origin's main ($short): $n check run(s) and $w ci.yml run(s), each a success"
  else refuse "CI is not green on origin's main ($short): ${notgreen#, }"
  fi

  src="$(blob "$head" shmutant.sh)"; rc=$?
  [ "$rc" -eq 0 ] || { blob_why "$rc" "$head" shmutant.sh; die "$why"; }
  vl="$(printf '%s\n' "$src" | grep -e '^SHMUTANT_VERSION=')"; rc=$?
  [ "$rc" -le 1 ] || die "cannot search shmutant.sh (grep exit $rc)"
  case "$vl" in
    "SHMUTANT_VERSION=\""*"\"") v="${vl#SHMUTANT_VERSION=\"}"; v="${v%\"}" ;;
    "SHMUTANT_VERSION='"*"'")   v="${vl#SHMUTANT_VERSION=\'}"; v="${v%\'}" ;;
    *)                          v="${vl#SHMUTANT_VERSION=}" ;;
  esac
  re='^[0-9A-Za-z.+-]+$'
  case "$vl" in
    ''|*$'\n'*) refuse "shmutant.sh at HEAD does not set SHMUTANT_VERSION on exactly one line" ;;
    *) if ! [[ "$v" =~ $re ]]; then refuse "shmutant.sh at HEAD does not assign SHMUTANT_VERSION a plain version: $vl"
       elif [ "$v" = "$ver" ]; then ok "shmutant.sh sets SHMUTANT_VERSION=$ver"
       else refuse "version mismatch: shmutant.sh sets SHMUTANT_VERSION=$v, not $ver"
       fi ;;
  esac

  checksums_digest "$head"; rc=$?
  if [ "$rc" -eq 2 ]; then die "$why"
  elif [ "$rc" -ne 0 ]; then refuse "$why"
  else
    fsum="$(blob_sha256 "$head:shmutant.sh")" || die "cannot compute the SHA-256 of shmutant.sh"
    if [ "$fsum" = "$digest" ]; then ok "CHECKSUMS matches shmutant.sh ($digest)"
    else refuse "CHECKSUMS does not match shmutant.sh: it says $digest, the file's SHA-256 is $fsum"
    fi
  fi

  doc_url "$head"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "docs/integrating.md's install URL is $raw_url"
  elif [ "$rc" -eq 2 ]; then die "$why"
  else refuse "$why"
  fi

  g rev-parse --quiet --verify "refs/tags/$tag" > /dev/null; rc=$?
  [ "$rc" -le 1 ] || die "cannot read this checkout's tags (git rev-parse exit $rc)"
  if [ "$rc" -eq 0 ]; then refuse "tag $tag already exists in this checkout"
  else ok "no tag $tag in this checkout"
  fi
  peel="$(origin_tag)" || die "cannot read origin's tags (git ls-remote failed)"
  if [ -n "$peel" ]; then refuse "tag $tag already exists on origin (if a cut of it stopped partway, finish its release by hand and check it with --verify)"
  else ok "no tag $tag on origin"
  fi
  gt="$(github_tag)" || die "cannot read $slug's tags through the GitHub API"
  if [ -n "$gt" ]; then refuse "tag $tag already exists on GitHub's $slug (it names $gt)"
  else ok "no tag $tag on GitHub"
  fi
  rels="$(gh api --paginate "repos/$slug/releases?per_page=100" --jq '.[].tag_name')" \
    || die "cannot list $slug's GitHub releases"
  printf '%s\n' "$rels" | grep -Fxq -- "$tag"; rc=$?
  [ "$rc" -le 1 ] || die "cannot search $slug's GitHub releases (grep exit $rc)"
  if [ "$rc" -eq 0 ]; then refuse "GitHub already has a release for $tag"
  else ok "no GitHub release for $tag"
  fi
}

# verify <commit> — the published release, against CHECKSUMS at <commit>, which origin's tag must
# name; every mismatch is reported. A failed read or a missing tool exits 2.
verify() {
  local c="$1" got ck i=0 bad=0 a peel gt rc crc httponly=1 rel draft has_sh has_ck
  peel="$(origin_tag)" || die "cannot read origin's tags (git ls-remote failed)"
  [ "$peel" = "$c" ] || { err "VERIFY FAILED: origin's $tag names ${peel:-nothing}, not $c"; return 1; }
  gt="$(github_tag)" || die "cannot read $slug's tags through the GitHub API"
  [ "$gt" = "$c" ] || { err "VERIFY FAILED: GitHub's $tag names ${gt:-nothing}, not $c"; return 1; }
  checksums_digest "$c"; rc=$?
  [ "$rc" -ne 2 ] || die "$why"
  [ "$rc" -eq 0 ] || { err "VERIFY FAILED: at $tag, $why"; return 1; }
  doc_url "$c"; rc=$?
  [ "$rc" -ne 2 ] || die "$why"
  [ "$rc" -eq 0 ] || { err "VERIFY FAILED: at $tag, $why"; return 1; }
  ck="$(blob_sha256 "$c:CHECKSUMS")" || die "cannot compute the SHA-256 of CHECKSUMS at $tag"

  # Downloads go straight into the digest, never to a file, and each side's status is read on its
  # own. An HTTP error on every attempt is the URL not serving the file: a verify failure. Any
  # other failure on any attempt is a read that did not happen: exit 2.
  while :; do
    streamed curl -q -fsSL --proto '=https' --connect-timeout 20 --max-time 300 "$raw_url"
    crc="$s_src"
    # The digest's own failure first: it closes the pipe, and curl then dies of SIGPIPE, which
    # would otherwise read as a download that failed and was worth retrying.
    [ "$s_sum" -eq 0 ] || die "cannot compute the SHA-256 of the download"
    [ "$crc" -ne 0 ] || break
    [ "$crc" -ne 23 ] || die "the download of $raw_url could not be passed to the digest (curl exit 23)"
    [ "$crc" -eq 22 ] || httponly=0
    i=$((i + 1))
    if [ "$i" -ge "$attempts" ]; then
      [ "$httponly" -eq 0 ] || { err "VERIFY FAILED: $raw_url answered an HTTP error on each of $i attempts"; return 1; }
      die "could not download $raw_url in $i attempts (the last curl exit was $crc, and not every failure was an HTTP error)"
    fi
    say "downloading $raw_url failed (curl exit $crc, attempt $i of $attempts); retrying in ${pause}s"
    sleep "$pause"
  done
  got="$s_digest"
  if [ "$got" = "$digest" ]; then say "verified: $raw_url has the SHA-256 CHECKSUMS at $tag gives ($digest)"
  else err "VERIFY FAILED: $raw_url has SHA-256 $got, but CHECKSUMS at $tag says $digest"; bad=1
  fi

  # The list, not the by-tag read: it names drafts too, and its failure is a failed read, never
  # an answer. The tag is validated as v<digits and dots> above, so it is safe in the filter.
  # Each required asset is matched by its whole name inside the filter, never in a joined list.
  rel="$(gh api --paginate "repos/$slug/releases?per_page=100" \
          --jq ".[] | select(.tag_name == \"$tag\") | [(.draft | tostring), (any(.assets[]; .name == \"shmutant.sh\") | tostring), (any(.assets[]; .name == \"CHECKSUMS\") | tostring)] | @tsv")" \
    || die "cannot list $slug's GitHub releases"
  case "$rel" in
    '')      err "VERIFY FAILED: GitHub has no release for $tag"; return 1 ;;
    *$'\n'*) err "VERIFY FAILED: GitHub lists more than one release for $tag"; return 1 ;;
  esac
  IFS=$'\t' read -r draft has_sh has_ck <<EOF
$rel
EOF
  [ "$draft" = false ] || { err "VERIFY FAILED: the release $tag is a draft"; return 1; }
  [ "$has_sh" = true ] || { err "VERIFY FAILED: the release $tag has no asset shmutant.sh"; return 1; }
  [ "$has_ck" = true ] || { err "VERIFY FAILED: the release $tag has no asset CHECKSUMS"; return 1; }
  for a in shmutant.sh CHECKSUMS; do
    streamed gh release download "$tag" -R "github.com/$slug" --pattern "$a" -O -
    [ "$s_sum" -eq 0 ] || die "cannot compute the SHA-256 of the release's $a"
    [ "$s_src" -eq 0 ] || die "could not download the asset $a of the release $tag"
    got="$s_digest"
    case "$a" in
      shmutant.sh) [ "$got" = "$digest" ] \
                     || { err "VERIFY FAILED: the release's shmutant.sh has SHA-256 $got, but CHECKSUMS at $tag says $digest"; bad=1; } ;;
      CHECKSUMS)   [ "$got" = "$ck" ] \
                     || { err "VERIFY FAILED: the release's CHECKSUMS is not CHECKSUMS at $tag"; bad=1; } ;;
    esac
  done
  [ "$bad" -eq 0 ] || return 1
  say "verified: the release $tag carries shmutant.sh and CHECKSUMS as tagged"
}

# Set once the tag may exist: from then on, an interrupt says what is left to do.
tagged=0
interrupted() {
  [ "$tagged" -eq 0 ] || {
    err "interrupted once the tag $tag may exist. Ask origin (git ls-remote origin refs/tags/$tag): if it lacks the tag, delete it here (git tag -d $tag) and re-run; if its tag names $remote, finish by hand as below; if it names another commit, inspect it before anything else."
    finish_by_hand
  }
  exit "$1"
}
# The run's temporary directory holds only the two release assets, written from the checked commit.
# Each directory and file's inode is recorded as it is made. Cleanup removes an asset only while it
# is still that inode and still holds exactly that commit's blob (its git object id), never through a
# symbolic link, and then rmdirs the directories. What it removes is what it checked an instant
# before; nothing closes that instant, as nothing in a shell can remove by inode. What it leaves, it reports. A cleanup failure does not change the status of a run
# whose outcome is already decided; it is reported beside it.
made=""; made_id=""; assets_id=""; sh_id=""; ck_id=""
# inode_of <path> — the inode of <path> itself (not of a link's target); status 1, printing
# nothing, for a link or when ls cannot read it.
inode_of() {
  local out id
  [ ! -L "$1" ] || return 1
  out="$(ls -di -- "$1" 2> /dev/null)" || return 1
  read -r id _ <<EOF
$out
EOF
  case "$id" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$id"
}
cleanup() {
  local f want id
  [ -n "$made" ] || return 0
  if [ -z "$made_id" ]; then
    rmdir -- "$made" 2> /dev/null || err "left $made in place: its inode was never read, so only an empty directory there is removed"
    return 0
  fi
  if [ "$(inode_of "$made")" != "$made_id" ]; then
    err "left $made in place: it is no longer the directory this run made"; return 0
  fi
  if [ -n "${remote:-}" ] && [ -n "$assets_id" ] && [ "$(inode_of "$made/assets")" = "$assets_id" ]; then
    for f in shmutant.sh CHECKSUMS; do
      case "$f" in shmutant.sh) id="$sh_id" ;; *) id="$ck_id" ;; esac
      [ -n "$id" ] && [ -f "$made/assets/$f" ] && [ "$(inode_of "$made/assets/$f")" = "$id" ] || continue
      want="$(g rev-parse --verify --quiet "$remote:$f" 2> /dev/null)" || continue
      [ "$(g hash-object --no-filters -- "$made/assets/$f" 2> /dev/null)" = "$want" ] || continue
      rm -f -- "$made/assets/$f" || err "could not remove $made/assets/$f"
    done
    rmdir -- "$made/assets" 2> /dev/null
  fi
  rmdir -- "$made" 2> /dev/null || err "left $made in place: it is not empty, and cleanup removes only the assets it can prove it wrote"
}
# newtmp — makes the run's temporary directory: a random name, then an atomic mkdir that fails on
# anything already there. Signals are held until the directory is the run's own and its name set,
# then handled, so cleanup can always reach it.
newtmp() {
  local pending="" base n=0 try
  trap 'pending=130' INT
  trap 'pending=143' TERM
  base="$(cd -P -- "${TMPDIR:-/tmp}" && pwd -P)" || base=""
  while [ -n "$base" ] && [ -z "$pending" ] && [ "$n" -lt 20 ]; do
    n=$((n + 1))
    try="$base/release.$$.$RANDOM$RANDOM"
    [ ! -e "$try" ] && [ ! -L "$try" ] || continue
    # mkdir runs with INT and TERM ignored, so its status is the whole truth: only a directory this
    # mkdir made is ever taken, and one it made is always known.
    if (trap '' INT TERM; exec mkdir -m 700 -- "$try") 2> /dev/null; then made="$try"; made_id="$(inode_of "$try")"; break; fi
  done
  trap cleanup EXIT
  trap 'interrupted 130' INT
  trap 'interrupted 143' TERM
  [ -z "$pending" ] || interrupted "$pending"
  [ -n "$made" ] && [ -d "$made" ] || die "cannot create a temporary directory under ${TMPDIR:-/tmp}"
  [ -n "$made_id" ] || die "cannot read the inode of the temporary directory $made"
}

if [ "$mode" = verify ]; then
  local_sha="$(g rev-parse --quiet --verify "refs/tags/$tag^{commit}")" \
    || die "this checkout has no tag $tag: git fetch origin tag $tag"
  verify "$local_sha" || exit 1
  exit 0
fi

preflight
if [ "$refused" -gt 0 ]; then
  err "$refused precondition(s) refused; nothing was tagged, pushed or published"
  exit 1
fi
if [ "$mode" = dry-run ]; then
  say "dry run: every precondition holds for $tag at $remote; nothing was tagged, pushed or published"
  exit 0
fi

notes="shmutant $ver

    curl -fsSL -o scripts/shmutant.sh $raw_url
    bash scripts/shmutant.sh checksum   # $digest

CHECKSUMS, attached, carries the SHA-256 of shmutant.sh at this tag."
create=(gh release create "$tag" -R "github.com/$slug" --verify-tag --title "shmutant $ver" --notes "$notes" shmutant.sh CHECKSUMS)
finish_by_hand() {
  err "to finish the release of $tag by hand, once origin has the tag naming $remote: in an empty"
  err "directory, write the two assets from that commit, then run the step that applies there:"
  err "  $(printf '%q ' git -C "$root" --no-replace-objects cat-file blob "$remote:shmutant.sh")> shmutant.sh"
  err "  $(printf '%q ' git -C "$root" --no-replace-objects cat-file blob "$remote:CHECKSUMS")> CHECKSUMS"
  err "  see what exists:   $(printf '%q ' gh release view "$tag" -R "github.com/$slug")"
  err "  with no release:   $(printf '%q ' "${create[@]}")"
  err "  with a draft:      $(printf '%q ' gh release upload "$tag" -R "github.com/$slug" shmutant.sh CHECKSUMS --clobber)"
  err "                     $(printf '%q ' gh release edit "$tag" -R "github.com/$slug" --draft=false)"
  err "  then check it:     $(printf '%q ' env -u SHELLOPTS -u BASHOPTS -u BASH_ENV bash "$root/scripts/release.sh" --verify "$ver")"
}

newtmp
ls="$(g ls-remote origin refs/heads/main)" || die "cannot read origin (git ls-remote failed)"
now="$(printf '%s\n' "$ls" | awk '$2 == "refs/heads/main" { print $1 }')" || die "cannot read origin's main (awk failed)"
[ "$now" = "$remote" ] \
  || { err "origin's main moved from $remote to ${now:-nothing} since the checks; nothing was tagged. Re-run to check the new head."; exit 1; }
tagged=1
g tag -a "$tag" "$remote" -m "shmutant $ver" || { err "could not create the tag $tag; nothing was pushed"; exit 1; }
g push --no-follow-tags origin "refs/tags/$tag"; prc=$?
if ! peel="$(origin_tag)"; then
  err "cannot read origin's tags after the push of $tag (git push exited $prc)."
  finish_by_hand
  exit 2
fi
if [ -z "$peel" ] && [ "$prc" -eq 0 ]; then
  err "git push reported success, but origin's URL has no $tag: the push went somewhere else (a push URL rewritten by pushInsteadOf?). Nothing was published; find the tag before deleting it here (git tag -d $tag)."
  exit 1
elif [ -z "$peel" ]; then
  err "could not push $tag; origin does not have it and nothing was published. Delete the local tag (git tag -d $tag) and re-run."
  exit 1
elif [ "$peel" != "$remote" ]; then
  if [ "$prc" -eq 0 ]; then err "origin's $tag names $peel, not $remote: inspect it before anything else"
  else err "origin has a $tag this run did not push (it names $peel); nothing was published. Find out who made it before deleting the local tag (git tag -d $tag)."
  fi
  exit 1
elif [ "$prc" -ne 0 ]; then
  err "the push of $tag reported a failure, but origin has the tag, naming $remote."
  finish_by_hand
  exit 1
fi
i=0
while :; do
  gt="$(github_tag)" || { err "pushed $tag, but $slug's tags cannot be read through the GitHub API."; finish_by_hand; exit 2; }
  i=$((i + 1))
  [ -z "$gt" ] && [ "$i" -lt "$ref_reads" ] || break
  sleep "$ref_pause"
done
if [ -z "$gt" ]; then
  err "origin has $tag, but GitHub's API does not show it on $slug after $i reads: origin's URL may lead somewhere else (a url.insteadOf mirror), or GitHub has not caught up. Nothing was published."
  err "Ask GitHub (gh api repos/$slug/git/matching-refs/tags/$tag). If it has the tag naming $remote, finish by hand as below; if it has none, find where the push went."
  finish_by_hand
  exit 1
elif [ "$gt" != "$remote" ]; then
  err "GitHub's $tag names $gt, not $remote: inspect it before anything else. Nothing was published."
  exit 1
fi
say "pushed $tag, naming $remote, on origin and on GitHub"

mkdir -- "$made/assets" && assets_id="$(inode_of "$made/assets")" \
  && : > "$made/assets/shmutant.sh" && sh_id="$(inode_of "$made/assets/shmutant.sh")" \
  && : > "$made/assets/CHECKSUMS" && ck_id="$(inode_of "$made/assets/CHECKSUMS")" \
  || { err "could not write the release assets from $tag"; finish_by_hand; exit 1; }
for a in shmutant.sh CHECKSUMS; do
  want="$(g rev-parse --verify --quiet "$remote:$a")" \
    || { err "cannot read $a at $remote"; finish_by_hand; exit 2; }
  g cat-file blob "$want" > "$made/assets/$a"; rc=$?
  # git reports a read it could not make with 128; anything else is the write.
  [ "$rc" -ne 128 ] || { err "cannot read $a at $remote"; finish_by_hand; exit 2; }
  [ "$rc" -eq 0 ] || { err "could not write the release asset $a"; finish_by_hand; exit 1; }
  [ "$(g hash-object --no-filters -- "$made/assets/$a")" = "$want" ] \
    || { err "the release asset $a does not hold $a at $remote"; finish_by_hand; exit 2; }
done
(cd -- "$made/assets" && "${create[@]}") \
  || { err "gh release create failed"; finish_by_hand; exit 1; }
say "published the release $tag"

if ! verify "$remote"; then
  err "the release $tag is published but does not verify: investigate before announcing it or rolling the milestone"
  exit 1
fi
say "released shmutant $ver: https://github.com/$slug/releases/tag/$tag"
say "next: baseline release roll --version $tag"

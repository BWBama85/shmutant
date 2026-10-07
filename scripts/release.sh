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
#     success, the ci.yml workflow ran on it and each of its runs there concluded success, and
#     its commit statuses, if it has any, are success;
#   - shmutant.sh at HEAD sets SHMUTANT_VERSION=<version>, on one line;
#   - CHECKSUMS at HEAD is the one line `<sha256>  shmutant.sh`, and the digest is shmutant.sh's;
#   - docs/integrating.md at HEAD names one raw.githubusercontent.com URL of shmutant.sh: this
#     repository's, at the tag v<version>;
#   - no tag v<version> exists in this checkout or on origin, and no GitHub release has it.
#
# --dry-run  checks every precondition and changes nothing: no fetch, no tag, no push, no release,
#            and no file of its own.
# --verify   checks a published release only: the URL docs/integrating.md documents at the tag
#            and the release's shmutant.sh must have the digest CHECKSUMS at the tag gives, and
#            the release's CHECKSUMS must be that file. Needs the tag in this checkout, where
#            origin has it.
#
# The repository is the one origin's single URL names, a github.com HTTPS or SSH URL; every push
# URL origin has must name the same one. Every gh call names it, on github.com, and gh's account
# must be able to push to it. Needs git, gh, curl, and sha256sum, shasum or openssl. Git over HTTPS
# and gh never prompt: a missing credential fails instead of waiting. What the caller's
# environment exports does not change what runs: its functions, shell options, GIT_* repository
# and GH_HOST are set aside.
#
# Exit 0 = done, or (--dry-run) every precondition held; 1 = a precondition refused, or a publish
# or verify step failed, saying so on stderr; 130/143 = interrupted, saying what may already be
# published; 2 = could not run (usage, a missing tool, a failed read).
while IFS=' ' builtin read -r _ _ _fn; do [[ -n $_fn ]] && builtin unset -f "$_fn"; done <<EOF
$(builtin declare -F)
EOF
set -u +e +C +o pipefail +o posix
shopt -u nocasematch
unset CDPATH
export LC_ALL=C GH_HOST=github.com GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0
unset -v GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_COMMON_DIR GIT_NAMESPACE

# Downloads of the raw URL before --verify gives up, and the pause between them: a new tag can
# answer 404 there for a while, and a cached 404 lives up to 300 seconds.
attempts=12
pause=30

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

for t in git gh curl; do command -v "$t" > /dev/null 2>&1 || die "$t is not on PATH"; done

root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || die "cannot resolve the repository root"
g() { git -C "$root" "$@"; }
top="$(g rev-parse --show-toplevel 2> /dev/null)" && top="$(cd -P -- "$top" && pwd -P)" \
  || die "$root is not a git work tree"
[ "$top" = "$root" ] || die "scripts/release.sh is not at the top of its work tree ($top)"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

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
pushurls="$(g config --get-all remote.origin.pushurl)"
while IFS= read -r pu; do
  [ -n "$pu" ] || continue
  pslug="$(slug_of "$pu")" && [ "$(lower "$pslug")" = "$(lower "$slug")" ] \
    || die "a push URL of origin is not a github.com HTTPS or SSH URL of $slug"
done <<EOF
$pushurls
EOF

hexre='^[0-9a-f]{40}([0-9a-f]{24})?$'

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

# checksums_digest <rev> — sets digest to what CHECKSUMS at <rev> gives shmutant.sh; status 1, with
# why set, unless CHECKSUMS is exactly the one line `<sha256>  shmutant.sh`, newline-terminated.
checksums_digest() {
  local ck re=$'^([0-9a-f]{64})  shmutant\\.sh\n$'
  digest=""
  ck="$(g cat-file blob "$1:CHECKSUMS" 2> /dev/null && printf x)" || { why="$1 has no CHECKSUMS"; return 1; }
  ck="${ck%x}"
  [[ "$ck" =~ $re ]] || { why="CHECKSUMS is not the one line '<sha256>  shmutant.sh'"; return 1; }
  digest="${BASH_REMATCH[1]}"
}

# doc_url <rev> — sets raw_url to the install URL docs/integrating.md at <rev> documents; status 1,
# with why set, unless the doc names exactly one, of this repository at the tag $tag.
doc_url() {
  local doc urls docslug doctag re='^https://raw\.githubusercontent\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/([^/]+)/shmutant\.sh$'
  raw_url=""
  doc="$(g cat-file blob "$1:docs/integrating.md" 2> /dev/null)" || { why="$1 has no docs/integrating.md"; return 1; }
  urls="$(printf '%s\n' "$doc" | grep -oE 'https://raw\.githubusercontent\.com/[A-Za-z0-9_./-]*/shmutant\.sh' | sort -u)"
  case "$urls" in
    '')      why="docs/integrating.md names no raw.githubusercontent.com URL of shmutant.sh"; return 1 ;;
    *$'\n'*) why="docs/integrating.md names more than one URL of shmutant.sh: $(printf '%s' "$urls" | tr '\n' ' ')"; return 1 ;;
  esac
  [[ "$urls" =~ $re ]] || { why="docs/integrating.md's URL is not https://raw.githubusercontent.com/<owner>/<repo>/<tag>/shmutant.sh: $urls"; return 1; }
  docslug="${BASH_REMATCH[1]}"; doctag="${BASH_REMATCH[2]}"
  [ "$(lower "$docslug")" = "$(lower "$slug")" ] \
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
  local branch st ls api perm short runs wfruns statuses n w nst state vl v fsum peel rels

  branch="$(g symbolic-ref --quiet --short HEAD)" || branch=""
  if [ "$branch" = main ]; then ok "on main"
  else refuse "not on main (on ${branch:-a detached HEAD}): git switch main"
  fi

  st="$(g --no-optional-locks status --porcelain --untracked-files=normal)" || die "git status failed"
  if [ -z "$st" ]; then ok "the work tree is clean"
  else refuse "the work tree is not clean ($(printf '%s\n' "$st" | wc -l | tr -d ' ') path(s) in git status): commit, stash or remove them"
  fi

  head="$(g rev-parse --verify --quiet 'HEAD^{commit}')" || die "HEAD names no commit"
  ls="$(g ls-remote origin refs/heads/main)" || die "cannot read origin (git ls-remote failed)"
  remote="$(printf '%s\n' "$ls" | awk '$2 == "refs/heads/main" { print $1 }')"
  [[ "$remote" =~ $hexre ]] || die "origin has no main branch"
  short="${remote:0:12}"
  if [ "$head" = "$remote" ]; then ok "HEAD is origin's main ($short)"
  elif ! g cat-file -e "$remote^{commit}" 2> /dev/null; then
    refuse "behind origin/main, or diverged from it: origin's main is $remote, a commit this checkout has not fetched: git pull --ff-only"
  elif g merge-base --is-ancestor "$head" "$remote"; then
    refuse "behind origin/main: origin's main is $remote, ahead of HEAD: git pull --ff-only"
  elif g merge-base --is-ancestor "$remote" "$head"; then
    refuse "ahead of origin/main ($remote): HEAD has commits origin's main lacks; land them through a pull request"
  else
    refuse "diverged from origin/main ($remote): HEAD and origin's main each have commits the other lacks"
  fi

  api="$(gh api "repos/$slug/git/ref/heads/main" --jq '.object.sha')" || die "cannot read $slug's main through the GitHub API"
  if [ "$api" = "$remote" ]; then ok "GitHub's API agrees that $slug's main is $short"
  else refuse "GitHub's API says $slug's main is ${api:-nothing}, but origin says $remote: origin is not $slug, or main just moved"
  fi
  perm="$(gh api "repos/$slug" --jq '.permissions.push')" || die "cannot read $slug through the GitHub API"
  if [ "$perm" = true ]; then ok "gh's token can push to $slug"
  else refuse "gh's token cannot push to $slug, so it could not publish the release after the tag: gh auth login with one that can"
  fi

  runs="$(gh api --paginate "repos/$slug/commits/$remote/check-runs?filter=latest&per_page=100" \
            --jq '.check_runs[] | [(.name | gsub("[[:cntrl:]]"; "?")), .status, (.conclusion // "none")] | @tsv')" \
    || die "cannot read the check runs on $remote from GitHub"
  wfruns="$(gh api --paginate "repos/$slug/actions/workflows/ci.yml/runs?head_sha=$remote&per_page=100" \
              --jq '.workflow_runs[] | [.id, .status, (.conclusion // "none")] | @tsv')" \
    || die "cannot read the ci.yml workflow runs on $remote from GitHub"
  statuses="$(gh api "repos/$slug/commits/$remote/status" --jq '[.total_count, .state] | @tsv')" \
    || die "cannot read the commit statuses on $remote from GitHub"
  notgreen=""
  judge "" "$runs"; n="$judged"
  [ "$n" -gt 0 ] || notgreen="$notgreen, GitHub lists no check runs on it"
  judge "ci.yml run " "$wfruns"; w="$judged"
  [ "$w" -gt 0 ] || notgreen="$notgreen, the ci.yml workflow has not run on it"
  IFS=$'\t' read -r nst state <<EOF
$statuses
EOF
  [ "${nst:-0}" = 0 ] || [ "$state" = success ] || notgreen="$notgreen, its $nst commit status(es) are $state"
  if [ -z "$notgreen" ]; then ok "CI is green on origin's main ($short): $n check run(s) and $w ci.yml run(s), each a success"
  else refuse "CI is not green on origin's main ($short): ${notgreen#, }"
  fi

  g cat-file -e "$head:shmutant.sh" 2> /dev/null || die "HEAD has no shmutant.sh"
  vl="$(g cat-file blob "$head:shmutant.sh" | grep -e '^SHMUTANT_VERSION=')"
  v="${vl#SHMUTANT_VERSION=}"; v="${v#[\"\']}"; v="${v%[\"\']}"
  case "$vl" in
    ''|*$'\n'*) refuse "shmutant.sh at HEAD does not set SHMUTANT_VERSION on exactly one line" ;;
    *) if [ "$v" = "$ver" ]; then ok "shmutant.sh sets SHMUTANT_VERSION=$ver"
       else refuse "version mismatch: shmutant.sh sets SHMUTANT_VERSION=$v, not $ver"
       fi ;;
  esac

  if ! checksums_digest "$head"; then refuse "$why"
  else
    fsum="$(blob_sha256 "$head:shmutant.sh")" || die "cannot compute the SHA-256 of shmutant.sh"
    if [ "$fsum" = "$digest" ]; then ok "CHECKSUMS matches shmutant.sh ($digest)"
    else refuse "CHECKSUMS does not match shmutant.sh: it says $digest, the file's SHA-256 is $fsum"
    fi
  fi

  if doc_url "$head"; then ok "docs/integrating.md's install URL is $raw_url"
  else refuse "$why"
  fi

  if g rev-parse --quiet --verify "refs/tags/$tag" > /dev/null; then refuse "tag $tag already exists in this checkout"
  else ok "no tag $tag in this checkout"
  fi
  peel="$(origin_tag)" || die "cannot read origin's tags (git ls-remote failed)"
  if [ -n "$peel" ]; then refuse "tag $tag already exists on origin (if a cut of it stopped partway, finish its release by hand and check it with --verify)"
  else ok "no tag $tag on origin"
  fi
  rels="$(gh api --paginate "repos/$slug/releases?per_page=100" --jq '.[].tag_name')" \
    || die "cannot list $slug's GitHub releases"
  if printf '%s\n' "$rels" | grep -Fxq -- "$tag"; then refuse "GitHub already has a release for $tag"
  else ok "no GitHub release for $tag"
  fi
}

# verify — the published release, against CHECKSUMS at the tag; every mismatch is reported.
verify() {
  local got ck i=0 bad=0 pub a
  checksums_digest "refs/tags/$tag" || { err "VERIFY FAILED: at $tag, $why"; return 1; }
  doc_url "refs/tags/$tag" || { err "VERIFY FAILED: at $tag, $why"; return 1; }
  ck="$(blob_sha256 "refs/tags/$tag:CHECKSUMS")" || return 1
  mkdir -- "$made/raw" "$made/dl" || { err "cannot create the download directories"; return 1; }

  until curl -q -fsSL --proto '=https' --connect-timeout 20 --max-time 300 -o "$made/raw/shmutant.sh" "$raw_url"; do
    i=$((i + 1))
    [ "$i" -lt "$attempts" ] || { err "VERIFY FAILED: $raw_url did not download in $i attempts"; return 1; }
    say "downloading $raw_url failed (attempt $i of $attempts); retrying in ${pause}s"
    sleep "$pause"
  done
  got="$(sha256 < "$made/raw/shmutant.sh")" || return 1
  if [ "$got" = "$digest" ]; then say "verified: $raw_url has the SHA-256 CHECKSUMS at $tag gives ($digest)"
  else err "VERIFY FAILED: $raw_url has SHA-256 $got, but CHECKSUMS at $tag says $digest"; bad=1
  fi

  pub="$(gh api "repos/$slug/releases/tags/$tag" --jq '.draft')" \
    || { err "VERIFY FAILED: GitHub gave no published release for $tag (none exists, or the API failed)"; return 1; }
  [ "$pub" = false ] || { err "VERIFY FAILED: the release $tag is a draft"; return 1; }
  gh release download "$tag" -R "$slug" --dir "$made/dl" \
    || { err "VERIFY FAILED: could not download the assets of the release $tag"; return 1; }
  for a in shmutant.sh CHECKSUMS; do
    if [ ! -f "$made/dl/$a" ]; then err "VERIFY FAILED: the release $tag has no asset $a"; bad=1; continue; fi
    got="$(sha256 < "$made/dl/$a")" || return 1
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
    err "interrupted once the tag $tag may exist. If origin lacks it (git ls-remote origin refs/tags/$tag), delete it here (git tag -d $tag) and re-run; if origin has it, finish by hand."
    finish_by_hand
  }
  exit "$1"
}
newtmp() {
  made="$(mktemp -d "${TMPDIR:-/tmp}/release.XXXXXX")" || die "cannot create a temporary directory"
  trap 'rm -rf -- "$made"' EXIT
  trap 'interrupted 130' INT
  trap 'interrupted 143' TERM
}

if [ "$mode" = verify ]; then
  local_sha="$(g rev-parse --quiet --verify "refs/tags/$tag^{commit}")" \
    || die "this checkout has no tag $tag: git fetch origin tag $tag"
  peel="$(origin_tag)" || die "cannot read origin's tags (git ls-remote failed)"
  [ "$peel" = "$local_sha" ] \
    || { err "refused: origin's $tag names ${peel:-nothing}, this checkout's names $local_sha"; exit 1; }
  newtmp
  verify || exit 1
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
create=(gh release create "$tag" -R "$slug" --verify-tag --title "shmutant $ver" --notes "$notes" shmutant.sh CHECKSUMS)
finish_by_hand() {
  err "to finish the release of $tag by hand, once origin has the tag:"
  err "  see what exists:   gh release view $tag -R $slug"
  err "  with no release:   from a checkout of $tag (git switch --detach $tag), run"
  err "                     $(printf '%q ' "${create[@]}")"
  err "  with a draft:      gh release upload $tag -R $slug shmutant.sh CHECKSUMS --clobber"
  err "                     gh release edit $tag -R $slug --draft=false"
  err "  then check it:     bash scripts/release.sh --verify $ver"
}

newtmp
tagged=1
g tag -a "$tag" "$remote" -m "shmutant $ver" || { err "could not create the tag $tag; nothing was pushed"; exit 1; }
g push origin "refs/tags/$tag"; prc=$?
if ! peel="$(origin_tag)"; then
  err "cannot read origin's tags after the push of $tag (git push exited $prc)."
  finish_by_hand
  exit 1
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
say "pushed $tag, naming $remote"

mkdir -- "$made/assets" \
  && g cat-file blob "refs/tags/$tag:shmutant.sh" > "$made/assets/shmutant.sh" \
  && g cat-file blob "refs/tags/$tag:CHECKSUMS" > "$made/assets/CHECKSUMS" \
  || { err "could not write the release assets from $tag"; finish_by_hand; exit 1; }
(cd -- "$made/assets" && "${create[@]}") \
  || { err "gh release create failed"; finish_by_hand; exit 1; }
say "published the release $tag"

if ! verify; then
  err "the release $tag is published but does not verify: investigate before announcing it or rolling the milestone"
  exit 1
fi
say "released shmutant $ver: https://github.com/$slug/releases/tag/$tag"
say "next: baseline release roll --version $tag"

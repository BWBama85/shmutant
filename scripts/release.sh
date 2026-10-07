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
#   - every check run GitHub lists on that commit is completed with conclusion success, and every
#     job in its .github/workflows/ci.yml has one;
#   - shmutant.sh at HEAD sets SHMUTANT_VERSION=<version>, on one line;
#   - CHECKSUMS at HEAD is the one line `<sha256>  shmutant.sh`, and the digest is shmutant.sh's;
#   - docs/integrating.md at HEAD names one raw.githubusercontent.com URL of shmutant.sh, for this
#     repository at a v<version> tag; its tag segment becomes v<version> to verify the cut;
#   - no tag v<version> exists in this checkout or on origin, and no GitHub release has it.
#
# --dry-run  checks every precondition and changes nothing: no fetch, no tag, no push, no release,
#            no file.
# --verify   checks a published release only: the documented URL at the tag and the release's
#            shmutant.sh must have the digest CHECKSUMS at the tag gives, and the release's CHECKSUMS
#            must be that file. Needs the tag in this checkout, where origin has it.
#
# The repository is the one origin's URL names, a github.com HTTPS or SSH URL; every gh call names
# it. Needs git, gh (authenticated), curl, and sha256sum, shasum or openssl.
#
# Exit 0 = done, or (--dry-run) every precondition held; 1 = a precondition refused, or a publish
# or verify step failed, saying so on stderr; 2 = could not run (usage, a missing tool, a failed
# read).
set -u
unset CDPATH
export LC_ALL=C GH_PROMPT_DISABLED=1

# Downloads of the raw URL before --verify gives up, and the pause between them: a new tag can
# answer 404 there for a while.
attempts=10
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

# The URL itself is never printed: an HTTPS remote can carry a token.
url="$(g config --get remote.origin.url)" || die "this checkout has no remote named origin"
u="${url%/}"; u="${u%.git}"; slug=""
case "$u" in
  https://github.com/*)   slug="${u#https://github.com/}" ;;
  git@github.com:*)       slug="${u#git@github.com:}" ;;
  ssh://git@github.com/*) slug="${u#ssh://git@github.com/}" ;;
esac
case "/$slug/" in */./*|*/../*) slug="" ;; esac
re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
[[ "$slug" =~ $re ]] || die "origin's URL is not a github.com HTTPS or SSH repository URL"

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
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# checksums_digest <rev> — sets digest to what CHECKSUMS at <rev> gives shmutant.sh; status 1, with
# why set, when CHECKSUMS is not exactly the line `<sha256>  shmutant.sh`.
checksums_digest() {
  local ck re='^([0-9a-f]{64})  shmutant\.sh$'
  digest=""
  ck="$(g cat-file blob "$1:CHECKSUMS" 2> /dev/null)" || { why="$1 has no CHECKSUMS"; return 1; }
  [[ "$ck" =~ $re ]] || { why="CHECKSUMS is not the one line '<sha256>  shmutant.sh'"; return 1; }
  digest="${BASH_REMATCH[1]}"
}

# doc_url <rev> — sets raw_url to the install URL docs/integrating.md at <rev> documents, its tag
# segment replaced by $tag; status 1, with why set, unless the doc names exactly one such URL, of
# this repository.
doc_url() {
  local doc urls docslug re='^https://raw\.githubusercontent\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/v[0-9][A-Za-z0-9_.-]*/shmutant\.sh$'
  raw_url=""
  doc="$(g cat-file blob "$1:docs/integrating.md" 2> /dev/null)" || { why="$1 has no docs/integrating.md"; return 1; }
  urls="$(printf '%s\n' "$doc" | grep -oE 'https://raw\.githubusercontent\.com/[A-Za-z0-9_./-]*/shmutant\.sh' | sort -u)"
  [ -n "$urls" ] || { why="docs/integrating.md names no raw.githubusercontent.com URL of shmutant.sh"; return 1; }
  case "$urls" in
    *$'\n'*) why="docs/integrating.md names more than one URL of shmutant.sh: $(printf '%s' "$urls" | tr '\n' ' ')"; return 1 ;;
  esac
  [[ "$urls" =~ $re ]] || { why="docs/integrating.md's URL is not https://raw.githubusercontent.com/<owner>/<repo>/v<version>/shmutant.sh: $urls"; return 1; }
  docslug="${BASH_REMATCH[1]}"
  [ "$(lower "$docslug")" = "$(lower "$slug")" ] \
    || { why="docs/integrating.md's URL is for $docslug, but origin is $slug"; return 1; }
  raw_url="https://raw.githubusercontent.com/$docslug/$tag/shmutant.sh"
}

# ci_jobs <rev> — the job ids .github/workflows/ci.yml at <rev> declares, one per line. A job that
# sets its own name or a matrix is printed as !<id>: its check runs carry other names.
ci_jobs() {
  local y
  y="$(g cat-file blob "$1:.github/workflows/ci.yml" 2> /dev/null)" || return 1
  printf '%s\n' "$y" | awk '
    /^jobs:[[:space:]]*$/                 { on = 1; next }
    on && /^[^[:space:]#]/                { on = 0 }
    !on                                   { next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/     { job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job); print job; next }
    /^    (name|strategy):/               { print "!" job }'
}

# origin_tag — origin's ref lines for refs/tags/$tag and its peeled form; status 1 when origin
# cannot be read. The peeled line is listed only when asked for by its own pattern.
origin_tag() {
  local out
  out="$(g ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}")" || return 1
  printf '%s\n' "$out" | awk -v t="refs/tags/$tag" '$2 == t || $2 == t "^{}"'
}
# origin_peel <lines> — the commit origin's $tag names, from origin_tag's lines.
origin_peel() {
  printf '%s\n' "$1" | awk -v t="refs/tags/$tag" '
    $2 == t "^{}" { peeled = $1 } $2 == t { plain = $1 }
    END { print (peeled != "" ? peeled : plain) }'
}

refused=0
ok()     { say "ok: $*"; }
refuse() { err "refused: $*"; refused=$((refused + 1)); }

# preflight — every precondition, each reported; sets head, remote, digest and raw_url.
preflight() {
  local branch st ls api cirev jobs runs n notgreen missing name status conclusion job vl v rels lines short

  branch="$(g symbolic-ref --quiet --short HEAD)" || branch=""
  if [ "$branch" = main ]; then ok "on main"
  else refuse "not on main (on ${branch:-a detached HEAD}): git switch main"
  fi

  st="$(g status --porcelain --untracked-files=normal)" || die "git status failed"
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

  cirev="$head"; g cat-file -e "$remote^{commit}" 2> /dev/null && cirev="$remote"
  jobs="$(ci_jobs "$cirev")" || die "$cirev has no .github/workflows/ci.yml"
  case "$jobs" in
    *'!'*) die "a job in .github/workflows/ci.yml sets a name or a matrix, so its check runs are not named by its id: $(printf '%s\n' "$jobs" | grep '^!' | tr -d '!' | tr '\n' ' ')" ;;
  esac
  [ -n "$jobs" ] || die ".github/workflows/ci.yml at $cirev declares no jobs"
  runs="$(gh api --paginate "repos/$slug/commits/$remote/check-runs?filter=latest&per_page=100" \
            --jq '.check_runs[] | [.name, .status, (.conclusion // "none")] | @tsv')" \
    || die "cannot read the check runs on $remote from GitHub"
  n=0; notgreen=""; missing=""
  while IFS=$'\t' read -r name status conclusion; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    if [ "$status" != completed ]; then notgreen="$notgreen, $name is $status"
    elif [ "$conclusion" != success ]; then notgreen="$notgreen, $name concluded $conclusion"
    fi
  done <<EOF
$runs
EOF
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    printf '%s\n' "$runs" | cut -f1 | grep -Fxq -- "$job" || missing="$missing $job"
  done <<EOF
$jobs
EOF
  if [ "$n" -eq 0 ]; then refuse "CI is not green on origin's main ($short): GitHub lists no check runs on it"
  else
    [ -z "$notgreen" ] || refuse "CI is not green on origin's main ($short): ${notgreen#, }"
    [ -z "$missing" ] || refuse "CI is not green on origin's main ($short): no check run for the ci.yml job(s)$missing"
    [ -n "$notgreen$missing" ] || ok "CI is green on origin's main ($short): $n check run(s), every one a success"
  fi

  g cat-file -e "$head:shmutant.sh" 2> /dev/null || die "HEAD has no shmutant.sh"
  vl="$(g cat-file blob "$head:shmutant.sh" | grep -e '^SHMUTANT_VERSION=')"
  v="${vl#SHMUTANT_VERSION=}"; v="${v#[\"\']}"; v="${v%[\"\']}"
  if [ -z "$vl" ] || [ "$vl" != "${vl%%$'\n'*}" ]; then refuse "shmutant.sh at HEAD does not set SHMUTANT_VERSION on exactly one line"
  elif [ "$v" = "$ver" ]; then ok "shmutant.sh sets SHMUTANT_VERSION=$ver"
  else refuse "version mismatch: shmutant.sh sets SHMUTANT_VERSION=$v, not $ver"
  fi

  if ! checksums_digest "$head"; then refuse "$why"
  else
    v="$(blob_sha256 "$head:shmutant.sh")" || die "cannot compute the SHA-256 of shmutant.sh"
    if [ "$v" = "$digest" ]; then ok "CHECKSUMS matches shmutant.sh ($digest)"
    else refuse "CHECKSUMS does not match shmutant.sh: it says $digest, the file's SHA-256 is $v"
    fi
  fi

  if doc_url "$head"; then ok "docs/integrating.md's install URL, for $tag: $raw_url"
  else refuse "$why"
  fi

  if g rev-parse --quiet --verify "refs/tags/$tag" > /dev/null; then refuse "tag $tag already exists in this checkout"
  else ok "no tag $tag in this checkout"
  fi
  lines="$(origin_tag)" || die "cannot read origin's tags (git ls-remote failed)"
  if [ -n "$lines" ]; then refuse "tag $tag already exists on origin (if a cut of it stopped partway, finish its release by hand and check it with --verify)"
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
  local want got ck i=0 bad=0 pub a
  checksums_digest "$tag" || { err "VERIFY FAILED: $why at $tag"; return 1; }
  want="$digest"
  doc_url "$tag" || { err "VERIFY FAILED: at $tag, $why"; return 1; }
  mkdir -- "$made/raw" "$made/dl" || { err "cannot create the download directories"; return 1; }

  until curl -fsSL --proto '=https' -o "$made/raw/shmutant.sh" "$raw_url"; do
    i=$((i + 1))
    [ "$i" -lt "$attempts" ] || { err "VERIFY FAILED: $raw_url did not download in $i attempts"; return 1; }
    say "downloading $raw_url failed (attempt $i of $attempts); retrying in ${pause}s"
    sleep "$pause"
  done
  got="$(sha256 < "$made/raw/shmutant.sh")" || return 1
  if [ "$got" = "$want" ]; then say "verified: $raw_url has the SHA-256 CHECKSUMS at $tag gives ($want)"
  else err "VERIFY FAILED: $raw_url has SHA-256 $got, but CHECKSUMS at $tag says $want"; bad=1
  fi

  pub="$(gh api "repos/$slug/releases/tags/$tag" --jq '.draft')" || pub=""
  [ "$pub" = false ] || { err "VERIFY FAILED: GitHub has no published release for $tag"; return 1; }
  gh release download "$tag" -R "$slug" --dir "$made/dl" \
    || { err "VERIFY FAILED: could not download the assets of the release $tag"; return 1; }
  for a in shmutant.sh CHECKSUMS; do
    [ -f "$made/dl/$a" ] || { err "VERIFY FAILED: the release $tag has no asset $a"; bad=1; }
  done
  if [ -f "$made/dl/shmutant.sh" ]; then
    got="$(sha256 < "$made/dl/shmutant.sh")" || return 1
    [ "$got" = "$want" ] || { err "VERIFY FAILED: the release's shmutant.sh has SHA-256 $got, but CHECKSUMS at $tag says $want"; bad=1; }
  fi
  if [ -f "$made/dl/CHECKSUMS" ]; then
    got="$(sha256 < "$made/dl/CHECKSUMS")" || return 1
    ck="$(blob_sha256 "$tag:CHECKSUMS")" || return 1
    [ "$got" = "$ck" ] || { err "VERIFY FAILED: the release's CHECKSUMS is not CHECKSUMS at $tag"; bad=1; }
  fi
  [ "$bad" -eq 0 ] || return 1
  say "verified: the release $tag carries shmutant.sh and CHECKSUMS as tagged"
}

newtmp() {
  made="$(mktemp -d "${TMPDIR:-/tmp}/release.XXXXXX")" || die "cannot create a temporary directory"
  trap 'rm -rf -- "$made"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

if [ "$mode" = verify ]; then
  local_sha="$(g rev-parse --quiet --verify "refs/tags/$tag^{commit}")" \
    || die "this checkout has no tag $tag: git fetch origin tag $tag"
  lines="$(origin_tag)" || die "cannot read origin's tags (git ls-remote failed)"
  peel="$(origin_peel "$lines")"
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

sha="$remote"
notes="shmutant $ver

    curl -fsSL -o scripts/shmutant.sh $raw_url
    bash scripts/shmutant.sh checksum   # $digest

CHECKSUMS, attached, carries the SHA-256 of shmutant.sh at this tag."
create=(gh release create "$tag" -R "$slug" --verify-tag --title "shmutant $ver" --notes "$notes" shmutant.sh CHECKSUMS)
finish_by_hand() {
  err "the tag $tag is on origin, but its GitHub release is missing or incomplete. To finish:"
  err "  see what exists:   gh release view $tag -R $slug"
  err "  with no release:   from a checkout of $tag (git switch --detach $tag), run"
  err "                     $(printf '%q ' "${create[@]}")"
  err "  with a draft:      gh release upload $tag -R $slug shmutant.sh CHECKSUMS --clobber"
  err "                     gh release edit $tag -R $slug --draft=false"
  err "  then check it:     bash scripts/release.sh --verify $ver"
}

newtmp
g tag -a "$tag" "$sha" -m "shmutant $ver" || { err "could not create the tag $tag; nothing was pushed"; exit 1; }
if ! g push origin "refs/tags/$tag"; then
  if ! lines="$(origin_tag)"; then
    err "the push of $tag failed, and origin cannot be read to say whether it has the tag: git ls-remote origin refs/tags/$tag"
  elif [ -z "$lines" ]; then
    err "could not push $tag; origin does not have it and nothing was published. Delete the local tag (git tag -d $tag) and re-run."
  elif [ "$(origin_peel "$lines")" = "$sha" ]; then
    err "the push of $tag reported a failure, but origin has the tag, naming $sha."
    finish_by_hand
  else
    err "origin has a $tag this run did not push (it names $(origin_peel "$lines")); nothing was published. Find out who made it before deleting the local tag (git tag -d $tag)."
  fi
  exit 1
fi
lines="$(origin_tag)" || { err "pushed $tag, but origin cannot be read back"; finish_by_hand; exit 1; }
peel="$(origin_peel "$lines")"
[ "$peel" = "$sha" ] || { err "origin's $tag names ${peel:-nothing}, not $sha: inspect it before anything else"; exit 1; }
say "pushed $tag, naming $sha"

mkdir -- "$made/assets" \
  && g cat-file blob "$tag:shmutant.sh" > "$made/assets/shmutant.sh" \
  && g cat-file blob "$tag:CHECKSUMS" > "$made/assets/CHECKSUMS" \
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

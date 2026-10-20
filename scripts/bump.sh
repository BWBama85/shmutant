#!/usr/bin/env bash
# scripts/bump.sh <X.Y.Z | patch | minor | major> — set the version the next release cut carries.
#
# Run from the root of the checkout. It rewrites, in the work tree, everything scripts/release.sh
# checks a cut's version against:
#   - shmutant.sh's SHMUTANT_VERSION= line;
#   - docs/integrating.md's install URL, at the new tag, and the `# shmutant X.Y.Z` comment on its
#     `shmutant.sh version` line, when it has one;
#   - README.md's `release.sh --dry-run X.Y.Z` example, when it has one;
#   - CHECKSUMS, for the new shmutant.sh.
# It commits nothing: the bump lands as an ordinary pull request, and the cut follows it. The /release
# skill runs it when shmutant.sh still carries a version that is already tagged.
#
# patch, minor and major name the version after the current one. The new version must be newer
# than the current one. Every file is checked before any is written, so a refusal leaves them all
# as they were. On success the last line on stdout is `bump: <old> -> <new>`.
#
# Exit 0 = bumped; 1 = refused (a version not newer, or a file not in the shape the driver checks),
# nothing written; 2 = could not run (usage, a missing file or tool, a failed write).
set -u
export LC_ALL=C
unset CDPATH

err()    { printf 'bump: %s\n' "$*" >&2; }
die()    { err "$*"; exit 2; }
refuse() { err "refused: $*"; exit 1; }
usage()  { printf 'usage: scripts/bump.sh <X.Y.Z | patch | minor | major>\n'; }

case "${1-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
for f in shmutant.sh CHECKSUMS docs/integrating.md; do
  [ -f "$f" ] || die "no $f here: run from the root of the checkout"
done

# sha256 <file> — the SHA-256 of <file>, from whichever tool the platform has.
sha256() {
  local out
  if command -v sha256sum > /dev/null 2>&1; then out="$(sha256sum < "$1")" || return 1
  elif command -v shasum > /dev/null 2>&1; then out="$(shasum -a 256 < "$1")" || return 1
  elif command -v openssl > /dev/null 2>&1; then out="$(openssl dgst -sha256 < "$1")" || return 1; out="${out##* }"
  else err "no sha256sum, shasum or openssl on PATH"; return 1
  fi
  out="${out%% *}"
  [[ "$out" =~ ^[0-9a-f]{64}$ ]] || { err "the digest tool printed no SHA-256"; return 1; }
  printf '%s\n' "$out"
}

re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

# The current version, read as scripts/release.sh reads it: one line, optionally quoted.
vl="$(grep -e '^SHMUTANT_VERSION=' shmutant.sh)"; rc=$?
[ "$rc" -le 1 ] || die "cannot search shmutant.sh (grep exit $rc)"
case "$vl" in
  ''|*$'\n'*) refuse "shmutant.sh does not set SHMUTANT_VERSION on exactly one line" ;;
esac
case "$vl" in
  "SHMUTANT_VERSION=\""*"\"") cur="${vl#SHMUTANT_VERSION=\"}"; cur="${cur%\"}" ;;
  "SHMUTANT_VERSION='"*"'")   cur="${vl#SHMUTANT_VERSION=\'}"; cur="${cur%\'}" ;;
  *)                          cur="${vl#SHMUTANT_VERSION=}" ;;
esac
[[ "$cur" =~ $re ]] || refuse "shmutant.sh does not assign SHMUTANT_VERSION a plain version: $vl"
cmaj="${BASH_REMATCH[1]}"; cmin="${BASH_REMATCH[2]}"; cpat="${BASH_REMATCH[3]}"

case "$1" in
  patch) new="$cmaj.$cmin.$((cpat + 1))" ;;
  minor) new="$cmaj.$((cmin + 1)).0" ;;
  major) new="$((cmaj + 1)).0.0" ;;
  *)     new="${1#v}"
         [[ "$new" =~ $re ]] || { err "not a version: '$1' (want X.Y.Z, vX.Y.Z, patch, minor or major)"; usage >&2; exit 2; } ;;
esac
[[ "$new" =~ $re ]] || die "cannot read the new version $new"
nmaj="${BASH_REMATCH[1]}"; nmin="${BASH_REMATCH[2]}"; npat="${BASH_REMATCH[3]}"
if [ "$nmaj" -lt "$cmaj" ] \
   || { [ "$nmaj" -eq "$cmaj" ] && [ "$nmin" -lt "$cmin" ]; } \
   || { [ "$nmaj" -eq "$cmaj" ] && [ "$nmin" -eq "$cmin" ] && [ "$npat" -le "$cpat" ]; }; then
  refuse "$new is not newer than shmutant.sh's $cur"
fi

base="$(cd -P -- "${TMPDIR:-/tmp}" && pwd -P)" || die "cannot enter TMPDIR"
tmp="$(mktemp -d "$base/bump.XXXXXX")" || die "cannot make a temporary directory"
trap 'rm -rf -- "$tmp"' EXIT

# Each new file is made and checked under $tmp first; only then is any written in place.
vre='[0-9]+\.[0-9]+\.[0-9]+'
sed -E "s/^SHMUTANT_VERSION=.*/SHMUTANT_VERSION=$new/" shmutant.sh > "$tmp/shmutant.sh" \
  || die "cannot rewrite shmutant.sh"
sed -E -e "s#(https://raw\.githubusercontent\.com/[^/[:space:]]+/[^/[:space:]]+/)v$vre(/shmutant\.sh)#\1v$new\2#g" \
       -e "s/(shmutant\.sh version[[:space:]]+# shmutant )$vre/\1$new/" docs/integrating.md > "$tmp/integrating.md" \
  || die "cannot rewrite docs/integrating.md"
if [ -f README.md ]; then
  sed -E "s#(scripts/release\.sh --dry-run )v?$vre#\1$new#g" README.md > "$tmp/README.md" \
    || die "cannot rewrite README.md"
fi

[ "$(grep -c -e "^SHMUTANT_VERSION=$new\$" "$tmp/shmutant.sh")" = 1 ] \
  || die "the rewritten shmutant.sh does not set SHMUTANT_VERSION=$new"
urls="$(grep -o -E "https://raw\.githubusercontent\.com/[^[:space:]\"'<>)]*/shmutant\.sh" "$tmp/integrating.md" | sort -u)"
case "$urls" in
  '')      refuse "docs/integrating.md names no raw.githubusercontent.com URL of shmutant.sh" ;;
  *$'\n'*) refuse "docs/integrating.md names more than one URL of shmutant.sh: $(printf '%s' "$urls" | tr '\n' ' ')" ;;
  */v"$new"/shmutant.sh) ;;
  *)       refuse "docs/integrating.md's URL is not at a vX.Y.Z tag, so it cannot be moved to v$new: $urls" ;;
esac
d="$(sha256 "$tmp/shmutant.sh")" || exit 2
printf '%s  shmutant.sh\n' "$d" > "$tmp/CHECKSUMS" || die "cannot write the new CHECKSUMS"

# cat into the file rather than mv over it, so each keeps its mode.
cat "$tmp/shmutant.sh" > shmutant.sh || die "cannot write shmutant.sh"
cat "$tmp/CHECKSUMS" > CHECKSUMS || die "cannot write CHECKSUMS"
cat "$tmp/integrating.md" > docs/integrating.md || die "cannot write docs/integrating.md"
if [ -f README.md ]; then cat "$tmp/README.md" > README.md || die "cannot write README.md"; fi
printf 'bump: %s -> %s\n' "$cur" "$new"

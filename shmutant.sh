#!/usr/bin/env bash
# shmutant — mutation testing for bash and POSIX shell.
#
# Inject one literal defect per row into a throwaway copy of a tree, run only the tests that
# claim to cover it, and require that test to go RED on its own witness. Vendorable as this one
# file: source it for the library API, or execute it for the CLI (`shmutant help`).
#
# Library API:
#   shmutant_target <file>                               file (relative to the tree root) that
#                                                        subsequent rows mutate
#   shmutant_mut <name> <old> <new> <witness> [select]   append one row (literals, never regexes)
#   shmutant_reset                                       empty the table
#   shmutant_pool <label> <workdir> <prepare> <run> [cap] run every row; 0 = every row killed,
#                                                        1 = a row was not, 2 = harness error
#   shmutant_mutate <file> <old> <new>                   0 applied, 1 rewrite failed, 2 no match
#   shmutant_selected <unit>                             true when <unit> is selected (or nothing is)
#   shmutant_copy_tree <src> <dst>                       copy a tree, excluding .git
#
# Adapter contract (two callbacks, called with their arguments, in the pool's shell):
#   prepare <dir>          populate <dir> with the tree under test. Optionally print the tree
#                          root (default: <dir>); it must lie inside <dir>. Called ONCE per pool.
#   run <root> <select>    run the tests covering <select> inside <root>. SHMUTANT_SELECT is
#                          exported with the same value. Exit 0 = green; exit
#                          SHMUTANT_RED_STATUS (default 1) = red; anything else = aborted. A red
#                          line starts with SHMUTANT_RED_PREFIX (default "FAIL: ") and carries
#                          the row's witness.
#
# Environment (all optional):
#   SHMUTANT_JOBS        worker count; replaces the CPU probe, the pool's cap still applies
#   SHMUTANT_TIMEOUT     seconds a single run may take (default 300; 0 = unbounded)
#   SHMUTANT_BASELINE    1 (default) runs each distinct selector once, uninjected, and requires
#                        green; 0 skips that pass
#   SHMUTANT_KEEP        1 keeps every clone after its run (default: clones are removed)
#   SHMUTANT_STREAM      file the verdict stream is appended to (default: stdout)
#   SHMUTANT_RED_PREFIX  see run; SHMUTANT_RED_STATUS  see run
#
# Verdict stream (stdout, tab-separated, one record per line; \t \n \\ escaped in fields):
#   shmutant  1  baseline  <select>  <verdict>  <seconds>  <detail>
#   shmutant  1  row       <verdict> <name>  <target>  <select>  <seconds>  <detail>
#   shmutant  1  summary   <label>   <rows>  <killed>  <jobs>  <seconds>
# Row verdicts: killed (the only pass), survived, accidental, aborted, unapplied, unprepared,
# baseline, timeout, lost.
#
# Requires bash >= 5.3 and coreutils plus awk. Nothing else; `ps` (POSIX) is used when present
# to reach timed-out descendants that left the run's process group.

SHMUTANT_VERSION=0.1.0

# _shmutant_bash_ok <major> <minor> — is that interpreter version at or above the floor?
# Defined in bash-3.2 syntax: it runs before the rest of this file is parsed.
_shmutant_bash_ok() {
  [ "$1" -gt 5 ] || { [ "$1" -eq 5 ] && [ "$2" -ge 3 ]; }
}

# _shmutant_install_hint — the platform's install command for a modern bash.
_shmutant_install_hint() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo 'brew install bash   (then put /opt/homebrew/bin or /usr/local/bin before /bin in PATH)' ;;
    *)      echo 'install bash >= 5.3 from your package manager, Homebrew (brew install bash), or https://ftp.gnu.org/gnu/bash/' ;;
  esac
}

if ! _shmutant_bash_ok "${BASH_VERSINFO[0]:-0}" "${BASH_VERSINFO[1]:-0}"; then
  if [ "${BASH_SOURCE[0]}" = "$0" ] && [ -z "${SHMUTANT_REEXEC:-}" ]; then
    for _shmutant_candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash "$(command -v bash 2>/dev/null)"; do
      if [ -n "$_shmutant_candidate" ] && [ -x "$_shmutant_candidate" ] \
        && "$_shmutant_candidate" -c '[ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }' 2>/dev/null; then
        SHMUTANT_REEXEC=1 exec "$_shmutant_candidate" "$0" "$@"
      fi
    done
  fi
  printf 'shmutant: bash %s is below the 5.3 floor and no newer bash was found; %s\n' \
    "${BASH_VERSION:-unknown}" "$(_shmutant_install_hint)" >&2
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then exit 2; else return 2; fi
fi

SHMUTANT_ROWS_NAME=(); SHMUTANT_ROWS_FILE=(); SHMUTANT_ROWS_OLD=(); SHMUTANT_ROWS_NEW=()
SHMUTANT_ROWS_WIT=(); SHMUTANT_ROWS_SEL=()
SHMUTANT_TARGET=""
SHMUTANT_SELECTED_N=0
SHMUTANT_DECL_ERRORS=0

# _shmutant_err <msg…> — a harness diagnostic on stderr.
_shmutant_err() { printf 'shmutant: %s\n' "$*" >&2; }

# _shmutant_refuse <msg…> — a refused declaration: report it, count it, return 2. The count is
# what lets a plan fail as a whole: sourcing returns only the LAST command's status.
_shmutant_refuse() { _shmutant_err "$@"; SHMUTANT_DECL_ERRORS=$((SHMUTANT_DECL_ERRORS + 1)); return 2; }

# _shmutant_esc <string> — print <string> with backslash, tab and newline escaped for the stream.
_shmutant_esc() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# _shmutant_emit <field>… — append one tab-separated record to the verdict stream. A write that
# fails sets SHMUTANT_EMIT_FAILED, which the pool turns into exit 2: a lost record is a lost
# verdict, and CI reading the stream must never take silence for a pass.
_shmutant_emit() {
  local out="" f
  for f in "$@"; do out+="$(_shmutant_esc "$f")"$'\t'; done
  out="${out%$'\t'}"
  # Through the descriptor the pool opened after validating the path, never by reopening the
  # path: a callback could have replaced it with a symlink since.
  if [ -n "${SHMUTANT_STREAM_FD:-}" ]; then
    { printf '%s\n' "$out" >&"$SHMUTANT_STREAM_FD"; } 2>/dev/null || SHMUTANT_EMIT_FAILED=1
  else
    printf '%s\n' "$out" 2>/dev/null || SHMUTANT_EMIT_FAILED=1
  fi
}

# _shmutant_pos_int <value> — print <value> when it is a positive integer, else return 1.
_shmutant_pos_int() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -gt 0 ] || return 1
  printf '%s' "$1"
}

# _shmutant_cpus — online CPU count, 2 when nothing can report it.
_shmutant_cpus() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" || n="$(nproc 2>/dev/null)" || n=""
  _shmutant_pos_int "$n" || printf '2'
}

# _shmutant_jobs [cap] — min(SHMUTANT_JOBS or cpu count, cap or 8).
_shmutant_jobs() {
  local cap n
  cap="$(_shmutant_pos_int "${1:-8}")" || cap=8
  n="$(_shmutant_pos_int "${SHMUTANT_JOBS:-}")" || n="$(_shmutant_cpus)"
  [ "$n" -le "$cap" ] || n="$cap"
  printf '%s' "$n"
}

# _shmutant_now — seconds since the epoch, to the microsecond, as an integer of microseconds.
_shmutant_now() {
  local t="$EPOCHREALTIME"
  printf '%s' "${t//[!0-9]/}"
}

# _shmutant_secs <microseconds> — render a microsecond count as seconds with three decimals.
_shmutant_secs() {
  local us="$1" ms
  ms=$(( (us + 500) / 1000 ))
  printf '%d.%03d' $(( ms / 1000 )) $(( ms % 1000 ))
}

# _shmutant_abs <dir> — the physical absolute path of an existing directory, or return 1.
# CDPATH is dropped: with it set, `cd` prints the directory it matched and the result would be
# two lines.
_shmutant_abs() {
  ( unset CDPATH; cd -P -- "$1" 2>/dev/null && pwd -P )
}

# _shmutant_inside <root> <path> — true when <path> is <root> or below it, compared byte for
# byte: the caller's nocasematch must not make a path that merely resembles the root pass.
_shmutant_inside() {
  ( shopt -u nocasematch
    if [ "$1" = / ]; then case "$2" in /*) exit 0 ;; esac; exit 1; fi
    case "$2" in "$1"|"$1/"*) exit 0 ;; esac; exit 1 )
}

# _shmutant_target_ok <root> <file> — true when <root>/<file> is a regular file, not a symlink,
# whose directory resolves physically to <root> or below it. A symlinked parent component is
# how a relative target reaches a caller-owned file outside the tree.
_shmutant_target_ok() {
  local root="$1" f="$1/$2" dir
  [ ! -L "$f" ] && [ -f "$f" ] || return 1
  root="$(_shmutant_abs "$root")" || return 1
  dir="$(_shmutant_abs "$(dirname -- "$f")")" || return 1
  _shmutant_inside "$root" "$dir"
}

# shmutant_selected <unit> — true when no selection is active or SHMUTANT_SELECT equals <unit>.
# Counts every selected unit in SHMUTANT_SELECTED_N so a suite can refuse to pass on zero.
shmutant_selected() {
  if [ -z "${SHMUTANT_SELECT:-}" ] || [ "$SHMUTANT_SELECT" = "$1" ]; then
    SHMUTANT_SELECTED_N=$((SHMUTANT_SELECTED_N + 1))
    return 0
  fi
  return 1
}

# shmutant_copy_tree <src> <dst> — copy <src> to <dst> (created), skipping a top-level .git
# and keeping symlinks as symlinks, modes, ownership and timestamps. Returns 1 when anything
# fails to copy, or when <dst> lies inside <src>.
shmutant_copy_tree() {
  local src="$1" dst="$2" entry name rc=0 asrc adst
  [ -d "$src" ] || { _shmutant_err "copy_tree: not a directory: $src"; return 1; }
  # Resolved first, so the scan below and the copy walk the same tree; find would not follow a
  # symlinked root that the glob does.
  src="$(_shmutant_abs "$src")" || { _shmutant_err "copy_tree: cannot resolve $1"; return 1; }
  if [ -L "$dst" ]; then _shmutant_err "copy_tree: destination $dst is a symlink — it would be written through, not created"; return 1; fi
  # The destination is rebuilt on the physical path of its nearest existing ancestor, so the
  # containment check below and every write see the directory a symlinked component would
  # otherwise have hidden; a link into the source tree is then caught, not followed.
  local probe rest=""
  probe="$dst"
  case "$probe" in /*) ;; *) probe="$PWD/$probe" ;; esac
  while [ ! -d "$probe" ] || [ -L "$probe" ]; do
    [ -L "$probe" ] && [ -d "$probe" ] && break
    rest="$(basename -- "$probe")${rest:+/$rest}"; probe="$(dirname -- "$probe")"
    [ "$probe" != / ] || break
  done
  probe="$(_shmutant_abs "$probe")" || { _shmutant_err "copy_tree: cannot resolve the destination $dst"; return 1; }
  dst="$probe${rest:+/$rest}"
  # A copy gives each hard link its own inode, and the pool's later check could not tell: a
  # source carrying one is refused here, naming it.
  local linked
  linked="$(find "$src" -path "$src/.git" -prune -o -type f -links +1 -print 2>/dev/null | head -n 1)"
  if [ -n "$linked" ]; then
    _shmutant_err "copy_tree: $linked has more than one hard link — a copy cannot keep them joined; prepare that tree yourself, or name the file it aliases"; return 1
  fi
  # The first component mkdir would create is remembered, so a refusal leaves nothing behind.
  local made="" probe2="$dst"
  while [ ! -e "$probe2" ]; do made="$probe2"; probe2="$(dirname -- "$probe2")"; [ "$probe2" != "$made" ] || break; done
  mkdir -p -- "$dst" || return 1
  asrc="$(_shmutant_abs "$src")" && adst="$(_shmutant_abs "$dst")" || return 1
  if _shmutant_inside "$asrc" "$adst"; then
    [ -n "$made" ] && rm -rf -- "$made"
    _shmutant_err "copy_tree: destination $dst lies inside the source $src — it would copy itself; use a workdir outside the tree"; return 1
  fi
  # The enumeration runs with the caller's expansion settings neutralised: `set -f` would hand
  # the loop three literal patterns, failglob would abort on an unmatched one, GLOBIGNORE would
  # drop entries, dotglob would list hidden entries twice.
  (
    set +f; shopt -u failglob dotglob; shopt -s nullglob; unset GLOBIGNORE
    for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name="${entry##*/}"
      [ "$name" = .git ] && continue
      cp -RPp -- "$entry" "$dst/" || rc=1
    done
    exit "$rc"
  ) || rc=1
  # The root directory's own metadata, which the per-entry copy never touches, applied LAST:
  # adding entries resets a directory's mtime, and a read-only root would refuse them.
  local rootls
  rootls="$(ls -ld -- "$src" 2>/dev/null)"
  chown -- "$(printf '%s\n' "$rootls" | awk '{ print $3 ":" $4 }')" "$dst" 2>/dev/null || rc=1
  chmod -- "$(_shmutant_mode_spec "${rootls%% *}")" "$dst" 2>/dev/null || rc=1
  touch -r "$src" -- "$dst" 2>/dev/null || rc=1
  [ "$rc" -eq 0 ] || _shmutant_err "copy_tree: could not reproduce the root directory's owner, mode or timestamp on $dst"
  return "$rc"
}

# _shmutant_mode_triple <rwx-triple> <u|g|o> — one clause of a chmod symbolic spec.
_shmutant_mode_triple() {
  local t="$1" who="$2" out=""
  case "${t:0:1}" in r) out+=r ;; esac
  case "${t:1:1}" in w) out+=w ;; esac
  case "${t:2:1}" in
    x) out+=x ;;
    s) out+=xs ;; S) out+=s ;;
    t) out+=xt ;; T) out+=t ;;
  esac
  printf '%s=%s' "$who" "$out"
}

# _shmutant_mode_spec <ls-l-mode-string> — a chmod symbolic spec equal to the mode in an
# `ls -l` mode field (`-rwsr-xr-x` -> `u=rwxs,g=rx,o=rx`), setuid, setgid and sticky included.
_shmutant_mode_spec() {
  local m="$1"
  printf '%s,%s,%s' "$(_shmutant_mode_triple "${m:1:3}" u)" "$(_shmutant_mode_triple "${m:4:3}" g)" "$(_shmutant_mode_triple "${m:7:3}" o)"
}

# _shmutant_mutate_restore <dir> <ls-mode-or-empty> — put back a directory mode shmutant_mutate
# loosened for the rewrite; a no-op when it loosened nothing.
_shmutant_mutate_restore() {
  [ -n "$2" ] && chmod -- "$(_shmutant_mode_spec "$2")" "$1" 2>/dev/null
  return 0
}

# shmutant_mutate <file> <old> <new> — replace the FIRST occurrence of literal <old> with <new>,
# in place. 0 applied; 1 the rewrite failed (file unreadable, dir unwritable); 2 <old> matched
# nothing, file unchanged (awk reports the miss itself, so no `cmp` is needed). A symlink is
# refused (1): renaming over it would swap the link for a
# file and leave the referent, which the tests may read, untouched. A literal spanning two lines
# never matches: awk sees one record.
# ENVIRON, not -v: -v processes backslash escapes, so `\$` and `\n` would arrive altered.
# The rewrite lands in a fresh mktemp sibling (never a predictable name, which could be a symlink
# out of the tree) that carries the target's mode, and is renamed over the target, never
# `sed -i` (BSD and GNU differ), so a failed rewrite cannot half-write. A target whose last line
# has no newline keeps that shape: the only change is the literal.
shmutant_mutate() {
  local f="$1" tmp nl=1 rc mode dir dirmode=""
  [ -n "$2" ] && [ "$2" != "$3" ] || return 2
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  dir="$(dirname -- "$f")"
  # A read-only directory (a preserved 0555 root) cannot host the temp file or the rename; it is
  # made writable for the rewrite and put back afterwards.
  if [ ! -w "$dir" ]; then
    dirmode="$(ls -ld -- "$dir" 2>/dev/null)"; dirmode="${dirmode%% *}"
    chmod -- u+w "$dir" 2>/dev/null || return 1
  fi
  tmp="$(mktemp "$dir/.shmutant.XXXXXX" 2>/dev/null)" || { _shmutant_mutate_restore "$dir" "$dirmode"; return 1; }
  [ -n "$(tail -c 1 -- "$f" 2>/dev/null)" ] && nl=0
  # The mode comes from the `ls -l` field, the one mode read POSIX specifies the same way
  # everywhere, and is reapplied whole after the write: a read-only target (0444, 0555) must be
  # writable while awk runs, and the kernel clears setuid/setgid on write.
  mode="$(ls -ld -- "$f" 2>/dev/null)"; mode="${mode%% *}"
  # cp -p first: run as root it carries the owner and group onto the temp file, which mktemp
  # created as root; the mode is reapplied whole after the write regardless.
  { cp -p -- "$f" "$tmp" && chmod -- u+w "$tmp" && SHMUTANT_MUT_OLD="$2" SHMUTANT_MUT_NEW="$3" SHMUTANT_MUT_NL="$nl" awk '
    BEGIN { old = ENVIRON["SHMUTANT_MUT_OLD"]; new = ENVIRON["SHMUTANT_MUT_NEW"] }
    !hit { i = index($0, old); if (i) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); hit = 1 } }
    NR > 1 { printf "\n" }
    { printf "%s", $0 }
    END { if (NR > 0 && ENVIRON["SHMUTANT_MUT_NL"] == 1) printf "\n"; exit (hit ? 0 : 3) }
  ' "$f" >| "$tmp"; } 2>/dev/null; rc=$?
  case "$rc" in
    0) ;;
    3) rm -f "$tmp"; _shmutant_mutate_restore "$dir" "$dirmode"; return 2 ;;
    *) rm -f "$tmp"; _shmutant_mutate_restore "$dir" "$dirmode"; return 1 ;;
  esac
  chmod -- "$(_shmutant_mode_spec "$mode")" "$tmp" 2>/dev/null || { rm -f "$tmp"; _shmutant_mutate_restore "$dir" "$dirmode"; return 1; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; _shmutant_mutate_restore "$dir" "$dirmode"; return 1; }
  _shmutant_mutate_restore "$dir" "$dirmode"
  return 0
}

# shmutant_target <file> — the tree-relative file that rows appended after this call mutate.
shmutant_target() {
  [ "$#" -eq 1 ] || { _shmutant_refuse "target: exactly one file, got $# arguments — an unquoted path?"; return 2; }
  [ -n "$1" ] || { _shmutant_refuse "target: a file is required"; return 2; }
  case "$1" in /*) _shmutant_refuse "target: must be relative to the tree root: $1"; return 2 ;; esac
  case "/$1/" in */../*) _shmutant_refuse "target: a .. component could leave the tree: $1"; return 2 ;; esac
  SHMUTANT_TARGET="$1"
}

# shmutant_mut <name> <old> <new> <witness> [select] — append one row for the current target.
# <old> and <new> are literals. <witness> is the text a red line must carry. <select> is what
# `run` receives to narrow the suite; it defaults to <witness>.
shmutant_mut() {
  if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then _shmutant_refuse "mut: usage: shmutant_mut <name> <old> <new> <witness> [select] (got $# arguments — an unquoted witness?)"; return 2; fi
  [ -n "$SHMUTANT_TARGET" ] || { _shmutant_refuse "mut '$1': no target — call shmutant_target first"; return 2; }
  [ -n "$1" ] || { _shmutant_refuse "mut: a row needs a name"; return 2; }
  [ -n "$2" ] || { _shmutant_refuse "mut '$1': the old literal is empty — it would match nothing"; return 2; }
  [ "$2" != "$3" ] || { _shmutant_refuse "mut '$1': old and new are identical — the row would inject nothing"; return 2; }
  [ -n "$4" ] || { _shmutant_refuse "mut '$1': a row needs a witness"; return 2; }
  case "$4${5:-}" in *$'\n'*) _shmutant_refuse "mut '$1': a witness or selector cannot contain a newline — a red line is one line"; return 2 ;; esac
  case "$2" in *$'\n'*) _shmutant_refuse "mut '$1': the old literal cannot contain a newline — a literal is matched within one line"; return 2 ;; esac
  SHMUTANT_ROWS_NAME+=("$1"); SHMUTANT_ROWS_FILE+=("$SHMUTANT_TARGET"); SHMUTANT_ROWS_OLD+=("$2")
  SHMUTANT_ROWS_NEW+=("$3"); SHMUTANT_ROWS_WIT+=("$4"); SHMUTANT_ROWS_SEL+=("${5:-$4}")
}

# shmutant_reset — empty the table, forget the current target and the refusals counted so far.
shmutant_reset() {
  SHMUTANT_ROWS_NAME=(); SHMUTANT_ROWS_FILE=(); SHMUTANT_ROWS_OLD=(); SHMUTANT_ROWS_NEW=()
  SHMUTANT_ROWS_WIT=(); SHMUTANT_ROWS_SEL=()
  SHMUTANT_TARGET=""
  SHMUTANT_DECL_ERRORS=0
}

# _shmutant_witnessed <output> <prefix> <witness> — true when some line of <output> (the text,
# not a path: it is read once through the descriptor that captured it) starts with <prefix> and
# carries <witness>. Per line, so a witness cannot match across a passing assertion's echo.
# `case`, never `grep -q`: pipefail promotes grep's early exit to a failure.
_shmutant_witnessed() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$2"*) case "$line" in *"$3"*) return 0 ;; esac ;;
    esac
  done <<< "$1"
  return 1
}

# _shmutant_has_red_line <output> <prefix> — true when any line of the text starts with <prefix>.
_shmutant_has_red_line() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2"*) return 0 ;; esac
  done <<< "$1"
  return 1
}

# _shmutant_descendants <pid> — print every descendant pid of <pid>, via POSIX `ps -A -o pid= -o ppid=`.
# Prints nothing when ps is unavailable; the process-group kill still applies then.
_shmutant_descendants() {
  local table
  table="$(ps -A -o pid= -o ppid= 2>/dev/null)" || return 0
  printf '%s\n' "$table" | awk -v root="$1" '
    { child[NR] = $1; parent[NR] = $2 }
    END {
      want[root] = 1
      do {
        added = 0
        for (i = 1; i <= NR; i++) if ((parent[i] in want) && !(child[i] in want)) { want[child[i]] = 1; added = 1 }
      } while (added)
      for (p in want) if (p != root) print p
    }'
}

# _shmutant_etime_secs <etime> — seconds from a POSIX `ps -o etime` value ([[dd-]hh:]mm:ss).
_shmutant_etime_secs() {
  local v="$1" d=0 h=0 m=0 sec=0 hms
  case "$v" in *-*) d="${v%%-*}"; v="${v#*-}" ;; esac
  hms="$v"
  case "$hms" in
    *:*:*) h="${hms%%:*}"; hms="${hms#*:}"; m="${hms%%:*}"; sec="${hms#*:}" ;;
    *:*)   m="${hms%%:*}"; sec="${hms#*:}" ;;
    *)     sec="$hms" ;;
  esac
  case "$d$h$m$sec" in *[!0-9]*|'') printf '0'; return ;; esac
  printf '%s' $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$sec ))
}

# _shmutant_identity <pid> — the process start time in epoch seconds (now minus POSIX
# `ps -o etime`), or nothing for a dead pid. It is the one identity that survives what a
# daemonising descendant does to itself (setsid changes its group, exec its command line) and
# still tells a reused pid apart: the newer process started later.
_shmutant_identity() {
  local etime now
  etime="$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')" || return 1
  [ -n "$etime" ] || return 1
  now="$(_shmutant_now)"
  printf '%s' $(( now / 1000000 - $(_shmutant_etime_secs "$etime") ))
}

# _shmutant_identity_table — fill SHMUTANT_START[pid] with the start time of every live process
# from ONE `ps -A`. A kill that asked per pid spent longer identifying a tree than the tree's
# earliest members needed to finish.
_shmutant_identity_table() {
  local line now
  SHMUTANT_START=()
  now="$(_shmutant_now)"; now=$(( now / 1000000 ))
  # awk does the etime arithmetic for every row at once; a bash loop over the whole process
  # table took longer than the tree being frozen had left to live.
  while IFS= read -r line; do
    [ -n "$line" ] && SHMUTANT_START["${line%% *}"]="${line#* }"
  done < <(ps -A -o pid= -o etime= 2>/dev/null | awk -v now="$now" '
    NF == 2 && $1 ~ /^[0-9]+$/ {
      e = $2; d = 0
      if (e ~ /-/) { split(e, a, "-"); d = a[1]; e = a[2] }
      n = split(e, t, ":")
      if (n == 3) s = t[1] * 3600 + t[2] * 60 + t[3]
      else if (n == 2) s = t[1] * 60 + t[2]
      else s = t[1]
      print $1, now - (d * 86400 + s)
    }')
}

# _shmutant_alive_since <pid> <start-seen> — true when <pid> still started when <start-seen>
# says, within the one-second resolution of etime. A reused pid started later.
_shmutant_alive_since() {
  local now d
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  now="$(_shmutant_identity "$1")" || return 1
  d=$(( now - $2 ))
  [ "$d" -ge -1 ] && [ "$d" -le 1 ]
}

# _shmutant_kill_tree <signal> <pid> <pids…> — send <signal> to <pid>'s process group, to every
# descendant found now, and to each of <pids…>: the descendants found before an earlier signal,
# which a leader's death may have reparented out of reach of a fresh walk.
# <pids…> are `pid:identity` pairs recorded when each was seen (see _shmutant_identity); one that
# no longer matches is a reused pid and is left alone. `pid:` with no identity is a frozen pid. Every target is decided first and signalled in
# ONE kill: a parent signalled after its child has already run on past the child's death.
# _shmutant_snapshot <pid> — print `pid:identity` for every live descendant of <pid> now.
_shmutant_snapshot() {
  local p
  local -A SHMUTANT_START=()
  _shmutant_identity_table
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -n "${SHMUTANT_START[$p]:-}" ] || continue
    printf '%s:%s\n' "$p" "${SHMUTANT_START[$p]}"
  done < <(_shmutant_descendants "$1")
}

# _shmutant_freeze_from — stop every descendant of the pids in `roots`, repeatedly, until a pass
# finds nothing new; appends what it stopped to `frozen`/`have`. Shares its caller's arrays.
_shmutant_freeze_from() {
  local r p new rounds=0
  local -a found=()
  while :; do
    new=0
    for r in "${roots[@]}"; do
      mapfile -t found < <(_shmutant_descendants "$r")
      [ "${#found[@]}" -gt 0 ] || continue
      kill -STOP "${found[@]}" 2>/dev/null
      for p in "${found[@]}"; do
        [ -n "$p" ] || continue
        [ -n "${have[$p]:-}" ] && continue
        have["$p"]=1; frozen+=("$p:"); roots+=("$p"); new=1
      done
    done
    rounds=$((rounds + 1))
    [ "$new" = 1 ] && [ "$rounds" -lt 16 ] || break
  done
}

# _shmutant_kill_tree_twice <pid> <pids…> — end <pid>'s tree: freeze it, then KILL it. Freezing
# first is what closes the window: a snapshot taken while the tree is still forking misses
# whatever forks next, so the root is stopped, its descendants found and stopped in turn until a
# pass finds nothing new (a stopped process cannot fork), and only then is anything signalled.
# Stopping comes before anything else and in bulk: a pass that spent a `ps` per process let the
# earliest children finish before their turn. A stopped pid cannot exit, so it cannot be reused
# either, and frozen pids need no identity. There is no TERM and no grace: continuing a frozen
# tree to let it handle TERM also lets a handler that ignores it run on, and after a deadline
# nothing may run at all. <pids…> are identity-checked victims recorded earlier (the watchdog's,
# the wrapper's), frozen and searched from as well: one that still lived could otherwise fork a
# child out of reach.
_shmutant_kill_tree_twice() {
  local spec="$1" pid rootid p d
  local -a frozen=() roots=()
  local -A have=()
  shift
  pid="${spec%%:*}"; roots=("$pid")
  # The root is stopped and later signalled by number only when it is known to be the process
  # it was: a bare pid means live at the caller's hands (identity computed now); `pid:identity`
  # carries what was captured while it lived; `pid:` means reaped, whose number may already be
  # someone else's.
  if [ "$spec" = "$pid" ]; then rootid="$(_shmutant_identity "$pid")" || rootid=""; else rootid="${spec#*:}"; fi
  if [ -n "$rootid" ] && _shmutant_alive_since "$pid" "$rootid"; then
    kill -STOP "$pid" 2>/dev/null && { frozen+=("$pid:"); have["$pid"]=1; }
  fi
  # The root's tree first, before any identity work: every pass is one ps and one bulk stop.
  _shmutant_freeze_from
  # Then the retained victims that are still themselves (one table, one bulk stop), and the
  # trees below them.
  local -A SHMUTANT_START=()
  local -a stillours=()
  _shmutant_identity_table
  for p in "$@"; do
    [ -n "$p" ] || continue
    [ -n "${have[${p%%:*}]:-}" ] && continue
    case "${p%%:*}${p#*:}" in *[!0-9]*|'') continue ;; esac
    [ -n "${SHMUTANT_START[${p%%:*}]:-}" ] || continue
    d=$(( SHMUTANT_START[${p%%:*}] - ${p#*:} ))
    [ "$d" -ge -1 ] && [ "$d" -le 1 ] || continue
    have["${p%%:*}"]=1; stillours+=("${p%%:*}")
  done
  if [ "${#stillours[@]}" -gt 0 ]; then
    kill -STOP "${stillours[@]}" 2>/dev/null
    roots=("${stillours[@]}")
    for p in "${stillours[@]}"; do frozen+=("$p:"); done
    _shmutant_freeze_from
  fi
  _shmutant_kill_tree KILL "$pid" "${frozen[@]}"
  return 0
}

_shmutant_kill_tree() {
  local sig="$1" pid="$2" p
  local -a targets=() now=()
  shift 2
  # A victim with an empty identity is frozen, and a frozen pid cannot have been reused.
  for p in "$@"; do
    [ -n "$p" ] || continue
    if [ -z "${p#*:}" ]; then targets+=("${p%%:*}")
    else _shmutant_alive_since "${p%%:*}" "${p#*:}" && targets+=("${p%%:*}")
    fi
  done
  mapfile -t now < <(_shmutant_descendants "$pid")
  for p in "${now[@]}"; do [ -n "$p" ] && targets+=("$p"); done
  # The group, and every identity-checked target: the root is among them when it was alive at
  # the snapshot (a worker or the CLI's plan child shares its parent's group, so `-pid` alone
  # would miss it), and absent once it has been reaped.
  kill "-$sig" -- -"$pid" "${targets[@]}" 2>/dev/null
}

# _shmutant_run_bounded <dir> <run> <root> <select> — run the adapter with stdout+stderr in
# <dir>/output, killed as a process group after SHMUTANT_TIMEOUT seconds. Sets
# SHMUTANT_RUN_STATUS to the exit status; writes <dir>/timeout when the bound was hit.
# Job control is switched on inside one subshell only, so the run gets its own process group
# and the whole tree it spawned dies with it. That subshell's stderr is discarded: with job
# control on, bash reports the reaped job there when the pool itself runs under `$(...)`.
_shmutant_run_bounded() {
  local dir="$1" run="$2" root="$3" sel="$4" timeout mark fifo
  local left_w left_r seen_w seen_r fired out_r
  timeout="$(_shmutant_pos_int "${SHMUTANT_TIMEOUT:-300}")" || timeout=0
  SHMUTANT_RUN_FIRED=0; SHMUTANT_RUN_OUTPUT=""
  # Every channel to and from the run is a descriptor opened HERE, before the callback exists,
  # and never reopened by path afterwards: the run's output (read back through the descriptor
  # that captured it), the wrapper's leftover record, the watchdog's sightings, and the timeout
  # signal, which is a FIFO so that `read -t 0` can test it without consuming it. A callback
  # that removes, locks or symlinks any of these names afterwards changes nothing.
  mark="$(mktemp "$dir/.run.XXXXXX")" || { SHMUTANT_RUN_STATUS=127; return; }
  fifo="$mark.fired"
  { : >| "$mark.left" && : >| "$mark.seen" && : >| "$dir/output" && rm -f -- "$fifo" && mkfifo -- "$fifo"; } 2>/dev/null \
    || { rm -f -- "$mark" "$mark.left" "$mark.seen"; SHMUTANT_RUN_STATUS=127; return; }
  exec {left_w}>|"$mark.left" {left_r}<"$mark.left" {seen_w}>|"$mark.seen" {seen_r}<"$mark.seen" {fired}<>"$fifo" {out_r}<"$dir/output"
  rm -f -- "$mark" "$mark.left" "$mark.seen" "$fifo"
  (
    set -m
    ( _shmutant_wrap_left="$left_w"; export SHMUTANT_SELECT="$sel"; "$run" "$root" "$sel"; rrc=$?
      _shmutant_snapshot "$BASHPID" >&"$_shmutant_wrap_left"; exit "$rrc" ) < /dev/null >> "$dir/output" 2>&1 &
    pid=$!
    # The root's identity while it is certainly alive: the post-run kill must not stop or signal
    # a reaped root by number.
    rootid="$(_shmutant_identity "$pid")" || rootid=""
    dog=""
    if [ "$timeout" -gt 0 ]; then
      (
        # Descendants are snapshotted every half second while the run is alive, so one that
        # detaches from the leader before the deadline (a new session, a reparented child) is
        # still named at the kill. A double fork whose intermediate lives less than a poll is
        # not reachable this way; that needs a containment mechanism this file does not use.
        # Cancelled (the run returned): what was seen is left for the runner, which still has
        # to clean up whatever the callback left behind.
        trap 'kill "$s" 2>/dev/null; for p in "${!seen[@]}"; do printf "%s:%s\n" "$p" "${seen[$p]}"; done >&"$seen_w"; exit 0' TERM
        declare -A seen=()
        # 10#: a validated value like 08 is still octal to bash arithmetic.
        t_end=$(( $(_shmutant_now) + 10#$timeout * 1000000 ))
        while [ "$(_shmutant_now)" -lt "$t_end" ]; do
          sleep 0.5 & s=$!
          wait "$s"
          # Each descendant is remembered with the identity it had when first seen, so a pid
          # reused by a newer process can be told apart at the kill.
          while IFS= read -r p; do
            [ -n "$p" ] || continue
            [ -n "${seen[${p%%:*}]:-}" ] && continue
            seen["${p%%:*}"]="${p#*:}"
          done < <(_shmutant_snapshot "$pid")
        done
        printf 'fired\n' >&"$fired"
        # An array of pid:identity pairs, never an unquoted expansion.
        victims=()
        for p in "${!seen[@]}"; do victims+=("$p:${seen[$p]}"); done
        _shmutant_kill_tree_twice "$pid:$rootid" "${victims[@]}"
      ) < /dev/null > /dev/null 2>&1 &
      dog=$!
    fi
    if [ -n "$dog" ]; then
      # Whichever ends first. A watchdog that ends before the leader has fired and failed to
      # finish (or died): the leader may be frozen, and waiting on it would never return, so
      # the kill is completed here and the run scored as a timeout.
      wait -n -p done_first "$pid" "$dog"; rc=$?
      if [ "${done_first:-}" != "$pid" ]; then
        read -t 0 -u "$fired" || printf 'fired\n' >&"$fired"
        _shmutant_kill_tree_twice "$pid:$rootid"
        wait "$pid"; rc=$?
      else
        # Once the watchdog has fired, let it reach KILL; otherwise cancel it.
        read -t 0 -u "$fired" || kill -TERM "$dog" 2>/dev/null
        wait "$dog" 2>/dev/null
      fi
    else
      wait "$pid"; rc=$?
    fi
    if ! read -t 0 -u "$fired"; then
      # The callback returned, which says nothing about what it backgrounded: its process group
      # and every descendant the watchdog saw are ended before the verdict is accepted.
      leftovers=()
      mapfile -t leftovers <&"$left_r"
      mapfile -t -O "${#leftovers[@]}" leftovers <&"$seen_r"
      _shmutant_kill_tree_twice "$pid:$rootid" "${leftovers[@]}"
    fi
    exit "$rc"
  ) 2> /dev/null
  SHMUTANT_RUN_STATUS=$?
  read -t 0 -u "$fired" && SHMUTANT_RUN_FIRED=1
  SHMUTANT_RUN_OUTPUT="$(cat <&"$out_r")"
  exec {left_w}>&- {left_r}<&- {seen_w}>&- {seen_r}<&- {fired}<&- {out_r}<&-
}

# _shmutant_worker_finish <dir> <verdict> <microseconds> <status> — drop the clone unless
# SHMUTANT_KEEP=1, then write the verdict. Every worker exit goes through here, so an early
# verdict cannot leave a tree behind.
_shmutant_worker_finish() {
  # Only in a directory that is still the one this run created, by inode: a callback may have
  # renamed it away and put a symlink or a fresh directory in its place, and nothing is written
  # or removed beneath a replacement.
  if [ -L "$1" ] || [ "$(ls -di -- "$1" 2>/dev/null | awk '{ print $1 }')" != "${SHMUTANT_DIR_ID:-}" ]; then
    _shmutant_err "refusing to clean $1: it is no longer the worker directory this run created"
    return 0
  fi
  # The worker directory is this run's; a callback that made it unwritable does not get to
  # suppress the verdict.
  [ -w "$1" ] || chmod -- u+rwx "$1" 2>/dev/null
  if [ "${SHMUTANT_KEEP:-0}" != 1 ]; then
    _shmutant_remove "$1/tree" || _shmutant_err "could not remove $1/tree"
  fi
  # Written beside and renamed over `verdict`: a callback can reach this directory and plant a
  # symlink under that name, and a rename replaces the link rather than writing through it.
  local tmp
  tmp="$(mktemp "$1/.verdict.XXXXXX")" || return 0
  printf '%s\n%s\n%s\n' "$2" "$3" "$4" >| "$tmp" && mv -f -- "$tmp" "$1/verdict"
}

# _shmutant_worker <kind> <index> <workdir> <run> <root-suffix> — one job, start to verdict.
# <kind> is `base` (uninjected, for baseline selector <index>) or `mut` (row <index>). Clones the
# pristine tree into <workdir>/<kind>-<index>/tree, injects when <kind> is mut, runs, and writes
# `<verdict>\n<microseconds>\n<status>` to <workdir>/<kind>-<index>/verdict. Always returns 0:
# the pool reaps by pid, and a non-zero worker would be mistaken for a lost verdict.
_shmutant_worker() {
  local kind="$1" i="$2" wd="$3" run="$4" suffix="$5"
  local dir="$3/$1-$2" root sel verdict status t0 t1 target rc red
  set +e
  shopt -u nocasematch
  t0="$(_shmutant_now)"
  # The directory's identity, for a cleanup that must not be fooled by a replacement.
  SHMUTANT_DIR_ID="$(ls -di -- "$dir" 2>/dev/null | awk '{ print $1 }')"
  root="$dir/tree$suffix"
  if [ "$kind" = mut ]; then sel="${SHMUTANT_ROWS_SEL[$i]}"; else sel="${SHMUTANT_BASE_SEL[$i]}"; fi
  # -p: a clone keeps mode, ownership and timestamps, so a test sensitive to them sees the
  # prepared tree's values, not the pool's umask.
  if ! cp -RPp -- "$wd/pristine" "$dir/tree" 2>/dev/null; then
    _shmutant_worker_finish "$dir" unprepared 0 clone; return 0
  fi
  if [ "$kind" = mut ]; then
    target="$root/${SHMUTANT_ROWS_FILE[$i]}"
    _shmutant_target_ok "$root" "${SHMUTANT_ROWS_FILE[$i]}" || { _shmutant_worker_finish "$dir" unprepared 0 missing; return 0; }
    shmutant_mutate "$target" "${SHMUTANT_ROWS_OLD[$i]}" "${SHMUTANT_ROWS_NEW[$i]}"; rc=$?
    case "$rc" in
      0) ;;
      2) _shmutant_worker_finish "$dir" unapplied 0 0; return 0 ;;
      *) _shmutant_worker_finish "$dir" unprepared 0 rewrite; return 0 ;;
    esac
  fi
  _shmutant_run_bounded "$dir" "$run" "$root" "$sel"
  status="$SHMUTANT_RUN_STATUS"
  t1="$(_shmutant_now)"
  if [ "$SHMUTANT_RUN_FIRED" = 1 ]; then
    verdict=timeout
  elif [ "$kind" = base ]; then
    red="${SHMUTANT_RED_STATUS:-1}"
    if [ "$status" -eq 0 ]; then verdict=green
    elif [ "$status" -eq "$red" ]; then verdict=red
    else verdict=aborted; fi
  elif [ "$status" -eq "${SHMUTANT_RED_STATUS:-1}" ]; then
    if _shmutant_witnessed "$SHMUTANT_RUN_OUTPUT" "${SHMUTANT_RED_PREFIX:-FAIL: }" "${SHMUTANT_ROWS_WIT[$i]}"; then
      verdict=killed
    elif _shmutant_has_red_line "$SHMUTANT_RUN_OUTPUT" "${SHMUTANT_RED_PREFIX:-FAIL: }"; then
      verdict=accidental
    else
      verdict=aborted
    fi
  elif [ "$status" -eq 0 ]; then
    verdict=survived
  else
    verdict=aborted
  fi
  _shmutant_worker_finish "$dir" "$verdict" $(( t1 - t0 )) "$status"
  return 0
}

# _shmutant_read_verdict <dir> — load <dir>/verdict into SHMUTANT_V_VERDICT, SHMUTANT_V_US,
# SHMUTANT_V_STATUS; a missing or damaged file reads as `lost`.
_shmutant_read_verdict() {
  SHMUTANT_V_VERDICT=lost; SHMUTANT_V_US=0; SHMUTANT_V_STATUS=""
  [ -f "$1/verdict" ] || return 0
  { IFS= read -r SHMUTANT_V_VERDICT && IFS= read -r SHMUTANT_V_US && IFS= read -r SHMUTANT_V_STATUS; } < "$1/verdict" \
    || { SHMUTANT_V_VERDICT=lost; SHMUTANT_V_US=0; SHMUTANT_V_STATUS=""; }
  [ -n "$SHMUTANT_V_VERDICT" ] || SHMUTANT_V_VERDICT=lost
  _shmutant_pos_int "$SHMUTANT_V_US" > /dev/null || SHMUTANT_V_US=0
}

# _shmutant_detail <verdict> <status> <witness> <select> — the human sentence for a row verdict.
_shmutant_detail() {
  case "$1" in
    killed)     printf 'went red on its witness' ;;
    survived)   printf 'stayed GREEN (exit 0) — nothing selected by [%s] can detect this defect' "$4" ;;
    accidental) printf 'went red, but NOT on its witness [%s] — caught by accident, not by the assertion that claims to cover it' "$3" ;;
    aborted)    if [ "$2" = "${SHMUTANT_RED_STATUS:-1}" ]; then
                  printf 'exited %s with no [%s] line at all — it aborted, it did not fail an assertion' "$2" "${SHMUTANT_RED_PREFIX:-FAIL: }"
                else
                  printf 'exited %s, not %s — the suite ABORTED rather than failing its assertion' "$2" "${SHMUTANT_RED_STATUS:-1}"
                fi ;;
    unapplied)  printf 'the injection did not apply — the old literal matched nothing, so this row tests NOTHING' ;;
    unprepared) case "$2" in
                  clone)   printf 'could not clone the pristine tree' ;;
                  missing) printf 'the target is not a regular file inside the tree' ;;
                  *)       printf 'the rewrite failed' ;;
                esac ;;
    baseline)   printf 'the tests selected by [%s] did not come back green BEFORE any defect was injected — a red result here would prove nothing (see the baseline record)' "$4" ;;
    timeout)    printf 'did not finish within %ss — a defect that hangs the suite is endured, not detected' "${SHMUTANT_TIMEOUT:-300}" ;;
    lost)       printf 'produced NO verdict — its worker died without reporting' ;;
    *)          printf 'unknown verdict [%s]' "$1" ;;
  esac
}

# _shmutant_fresh_dir <dir> — remove <dir> and create it empty; false when either step fails or
# anything is still inside it.
# _shmutant_remove <path> — remove a tree this harness created. Directories are made writable
# first (a preserved read-only root would otherwise refuse), and a path whose parent no longer
# resolves to where it was created is left alone: a callback can rename a worker directory
# and put a symlink in its place, and rm -rf follows a symlink in an intermediate component.
# Returns 1 when something is still there afterwards.
_shmutant_remove() {
  local path="$1" parent
  [ -e "$path" ] || [ -L "$path" ] || return 0
  parent="$(dirname -- "$path")"
  if [ -L "$parent" ]; then
    _shmutant_err "refusing to remove $path: its parent is now a symlink, not the directory it was created in"; return 1
  fi
  if [ -d "$path" ] && [ ! -L "$path" ]; then
    # One pass per level: find cannot enter a directory until the pass before made it readable.
    local i
    for (( i = 0; i < 64; i++ )); do
      [ -n "$(find "$path" -type d ! -perm -u+rwx -print 2>/dev/null | head -n 1)" ] || break
      find "$path" -type d ! -perm -u+rwx -exec chmod u+rwx {} + 2>/dev/null
    done
  fi
  rm -rf -- "$path" 2>/dev/null
  [ ! -e "$path" ] && [ ! -L "$path" ]
}

_shmutant_fresh_dir() {
  _shmutant_remove "$1" || return 1
  mkdir -p -- "$1" 2>/dev/null
}

# _shmutant_run_jobs <kind> <count> <workdir> <run> <suffix> <jobs> — run <count> workers of
# <kind> through a bounded pool; a mut index whose SHMUTANT_SKIP entry is 1 is not started.
# Reaps by pid, so a caller's own background jobs are never consumed by the pool.
# _shmutant_abort_workers <signal> — on INT or TERM while workers run: kill every active
# worker's process tree, put the caller's own traps back, and deliver the signal again so the
# caller's handler (or the default) decides what happens to the caller.
_shmutant_abort_workers() {
  local sig="$1" p
  local -a helpers=()
  for p in "${SHMUTANT_ACTIVE[@]}"; do _shmutant_kill_tree_twice "$p" & helpers+=("$!"); done
  # Only the helpers: a bare wait would also block on the caller's own background jobs.
  [ "${#helpers[@]}" -eq 0 ] || wait "${helpers[@]}" 2>/dev/null
  _shmutant_restore_traps
  kill "-$sig" "$BASHPID"
}

# _shmutant_restore_traps — put back the INT and TERM traps saved by _shmutant_run_jobs. An
# empty saved handler means the caller had none, which is `trap -`, never `trap ""`: the empty
# string would make the shell IGNORE the signal from then on.
_shmutant_restore_traps() {
  # The saved value is the complete `trap -- '…' SIGTERM` declaration `trap -p` printed, put
  # back verbatim; re-spelling it by hand is how a handler once came back as `echo mineSIGTERM`.
  if [ -n "${SHMUTANT_TRAP_INT:-}" ]; then eval "$SHMUTANT_TRAP_INT"; else trap - INT; fi
  if [ -n "${SHMUTANT_TRAP_TERM:-}" ]; then eval "$SHMUTANT_TRAP_TERM"; else trap - TERM; fi
}

# _shmutant_saved_trap <signal> — the caller's current trap declaration for <signal> as
# `trap -p` prints it, or empty.
_shmutant_saved_trap() {
  trap -p "$1"
}

_shmutant_run_jobs() {
  local kind="$1" n="$2" wd="$3" run="$4" suffix="$5" jobs="$6" i done_pid p rc=0
  local -a pids=() rest=()
  SHMUTANT_ACTIVE=()
  SHMUTANT_TRAP_INT="$(_shmutant_saved_trap INT)"; SHMUTANT_TRAP_TERM="$(_shmutant_saved_trap TERM)"
  trap '_shmutant_abort_workers INT' INT
  trap '_shmutant_abort_workers TERM' TERM
  _shmutant_run_jobs_loop "$@"; rc=$?
  _shmutant_restore_traps
  SHMUTANT_ACTIVE=()
  return "$rc"
}

_shmutant_run_jobs_loop() {
  local kind="$1" n="$2" wd="$3" run="$4" suffix="$5" jobs="$6" i done_pid p
  local -a pids=() rest=()
  for (( i = 0; i < n; i++ )); do
    if [ "$kind" = mut ] && [ "${SHMUTANT_SKIP[$i]:-0}" != 0 ]; then continue; fi
    # Recreated, never reused: a stale timeout marker or tree from an earlier pool in the same
    # workdir would be read as this run's.
    if ! _shmutant_fresh_dir "$wd/$kind-$i"; then
      _shmutant_err "cannot recreate $wd/$kind-$i — a stale verdict there could be read as this run's; refusing to continue"
      # The workers already running are ended, not waited for: one of them may be unbounded.
      local -a helpers=()
      for p in "${pids[@]}"; do _shmutant_kill_tree_twice "$p" & helpers+=("$!"); done
      # Never a bare wait: with nothing started it would block on the caller's own jobs.
      [ "${#pids[@]}" -eq 0 ] || wait "${helpers[@]}" "${pids[@]}" 2>/dev/null
      return 2
    fi
    _shmutant_worker "$kind" "$i" "$wd" "$run" "$suffix" &
    pids+=("$!")
    SHMUTANT_ACTIVE=("${pids[@]}")
    if [ "${#pids[@]}" -ge "$jobs" ]; then
      wait -n -p done_pid "${pids[@]}" || true
      rest=()
      for p in "${pids[@]}"; do [ "$p" = "${done_pid:-}" ] || rest+=("$p"); done
      pids=("${rest[@]}")
      SHMUTANT_ACTIVE=("${pids[@]}")
    fi
  done
  [ "${#pids[@]}" -eq 0 ] || wait "${pids[@]}" || true
  return 0
}

# _shmutant_validate_settings <label> <workdir> — every SHMUTANT_* setting the pool and its
# workers read, checked before the first use and again after prepare (which runs in this shell
# and can assign any of them). Replaces SHMUTANT_STREAM by its absolute form. Returns 2 on the
# first violation.
_shmutant_validate_settings() {
  local label="$1" wd="$2"
  # Digits only AND a bounded width: an all-digit value past bash's integer range fails every
  # numeric test with a diagnostic and would fall through as if it had passed.
  # Every setting is read through a default first: a caller's `set -u` must not turn an unset
  # option into an abort.
  local v_timeout="${SHMUTANT_TIMEOUT:-300}" v_red="${SHMUTANT_RED_STATUS:-1}" v_jobs="${SHMUTANT_JOBS:-}"
  case "$v_timeout" in
    *[!0-9]*|'') _shmutant_err "$label: SHMUTANT_TIMEOUT must be a non-negative integer, got [$v_timeout]"; return 2 ;;
  esac
  [ "${#v_timeout}" -le 9 ] || { _shmutant_err "$label: SHMUTANT_TIMEOUT is too large, got [$v_timeout]"; return 2; }
  case "$v_red" in
    *[!0-9]*|'') _shmutant_err "$label: SHMUTANT_RED_STATUS must be an exit status from 1 to 255, got [$v_red]"; return 2 ;;
  esac
  [ "${#v_red}" -le 3 ] || { _shmutant_err "$label: SHMUTANT_RED_STATUS must be an exit status from 1 to 255, got [$v_red]"; return 2; }
  if [ "$v_red" -lt 1 ] || [ "$v_red" -gt 255 ]; then
    _shmutant_err "$label: SHMUTANT_RED_STATUS must be an exit status from 1 to 255, got [$v_red] — 0 is green by definition"; return 2
  fi
  if [ -n "$v_jobs" ]; then
    case "$v_jobs" in *[!0-9]*) _shmutant_err "$label: SHMUTANT_JOBS must be a positive integer, got [$v_jobs]"; return 2 ;; esac
    if [ "${#v_jobs}" -gt 4 ] || [ "$v_jobs" -lt 1 ]; then
      _shmutant_err "$label: SHMUTANT_JOBS must be a positive integer of at most four digits, got [$v_jobs]"; return 2
    fi
  fi
  case "${SHMUTANT_BASELINE:-1}" in 0|1) ;; *) _shmutant_err "$label: SHMUTANT_BASELINE must be 0 or 1, got [${SHMUTANT_BASELINE:-}]"; return 2 ;; esac
  case "${SHMUTANT_KEEP:-0}" in 0|1) ;; *) _shmutant_err "$label: SHMUTANT_KEEP must be 0 or 1, got [${SHMUTANT_KEEP:-}]"; return 2 ;; esac
  if [ -n "${SHMUTANT_RED_PREFIX+x}" ] && [ -z "$SHMUTANT_RED_PREFIX" ]; then
    _shmutant_err "$label: SHMUTANT_RED_PREFIX is empty — every line would count as a red line"; return 2
  fi
  case "${SHMUTANT_RED_PREFIX:-}" in *$'\n'*) _shmutant_err "$label: SHMUTANT_RED_PREFIX contains a newline — no single line could ever start with it"; return 2 ;; esac
  if [ -n "${SHMUTANT_STREAM:-}" ]; then
    local sdir
    if [ -L "$SHMUTANT_STREAM" ]; then
      _shmutant_err "$label: SHMUTANT_STREAM is a symlink ($SHMUTANT_STREAM) — name the file itself, so where the records land can be checked"; return 2
    fi
    if [ -e "$SHMUTANT_STREAM" ] && [ ! -f "$SHMUTANT_STREAM" ]; then
      _shmutant_err "$label: SHMUTANT_STREAM exists and is not a regular file ($SHMUTANT_STREAM) — a FIFO with no reader would block the pool forever"; return 2
    fi
    if ! sdir="$(_shmutant_abs "$(dirname -- "$SHMUTANT_STREAM")")"; then
      _shmutant_err "$label: SHMUTANT_STREAM points into a directory that does not exist: $SHMUTANT_STREAM"; return 2
    fi
    if _shmutant_inside "$wd" "$sdir"; then
      _shmutant_err "$label: SHMUTANT_STREAM lies inside the workdir ($SHMUTANT_STREAM) — the pool recreates and removes what is in there"; return 2
    fi
    # Replaced by its validated absolute form: prepare runs in this shell and may cd.
    SHMUTANT_STREAM="$sdir/$(basename -- "$SHMUTANT_STREAM")"
  fi

  return 0
}

# _shmutant_open_stream <label> — hold the validated SHMUTANT_STREAM open as a descriptor. Called
# again after prepare: a path prepare assigned replaces the one opened before it, and one it
# unset closes it. Returns 2 when the file cannot be opened.
_shmutant_open_stream() {
  local label="$1"
  if [ -n "${SHMUTANT_STREAM_OPENED+x}" ] && [ "$SHMUTANT_STREAM_OPENED" = "${SHMUTANT_STREAM:-}" ]; then return 0; fi
  if [ -n "${SHMUTANT_STREAM_FD:-}" ]; then exec {SHMUTANT_STREAM_FD}>&-; unset SHMUTANT_STREAM_FD; fi
  SHMUTANT_STREAM_OPENED="${SHMUTANT_STREAM:-}"
  [ -n "${SHMUTANT_STREAM:-}" ] || return 0
  # shellcheck disable=SC2093
  if ! exec {SHMUTANT_STREAM_FD}>>"$SHMUTANT_STREAM" 2>/dev/null; then
    _shmutant_err "$label: cannot open SHMUTANT_STREAM for appending: $SHMUTANT_STREAM"; unset SHMUTANT_STREAM_FD; return 2
  fi
}

# _shmutant_pool_fail <label> <workdir> — the exit for a pool that stops after prepare: the
# pristine tree goes unless SHMUTANT_KEEP=1, and the stream descriptor is closed.
_shmutant_pool_fail() {
  if [ "${SHMUTANT_KEEP:-0}" != 1 ]; then
    _shmutant_remove "$2/pristine" || { _shmutant_err "$1: could not remove $2/pristine"; SHMUTANT_CLEANUP_FAILED=1; }
  fi
  if [ -n "${SHMUTANT_STREAM_FD:-}" ]; then exec {SHMUTANT_STREAM_FD}>&-; unset SHMUTANT_STREAM_FD; fi
  unset SHMUTANT_STREAM_OPENED
}

# shmutant_pool <label> <workdir> <prepare> <run> [cap] — run every table row. Prepares the
# tree once, runs each distinct selector uninjected (SHMUTANT_BASELINE), then every row through a
# pool of min(SHMUTANT_JOBS or CPUs, cap or 8) workers. Emits the verdict stream and one stderr
# line per row that was not killed. Returns 0 when every row was killed, 1 when any was not,
# 2 when the harness itself could not run (a refused declaration, empty table, bad workdir,
# prepare failed, root outside the workdir, or a verdict-stream write that failed).
shmutant_pool() {
  local label="$1" wd="$2" prep="$3" run="$4" cap="${5:-}"
  local n jobs root suffix i k sel t0 t1 killed=0 rc=0 verdict detail rjrc
  local -a base_sel=() base_verdict=()
  n="${#SHMUTANT_ROWS_NAME[@]}"
  t0="$(_shmutant_now)"
  SHMUTANT_EMIT_FAILED=0; SHMUTANT_CLEANUP_FAILED=0
  if [ "${SHMUTANT_DECL_ERRORS:-0}" -ne 0 ]; then
    _shmutant_err "$label: $SHMUTANT_DECL_ERRORS declaration(s) were refused — a table missing rows it was meant to carry proves nothing"
    return 2
  fi
  if [ "$n" -eq 0 ]; then
    _shmutant_err "$label: the mutation table is EMPTY — this harness proves nothing"
    return 2
  fi
  [ -n "$wd" ] || { _shmutant_err "$label: a workdir is required"; return 2; }
  mkdir -p -- "$wd" 2>/dev/null || { _shmutant_err "$label: cannot create workdir $wd"; return 2; }
  wd="$(_shmutant_abs "$wd")" || { _shmutant_err "$label: cannot resolve workdir"; return 2; }
  if ! declare -F -- "$prep" > /dev/null 2>&1 && ! command -v -- "$prep" > /dev/null 2>&1; then
    _shmutant_err "$label: prepare callback not found: $prep"; return 2
  fi
  if ! declare -F -- "$run" > /dev/null 2>&1 && ! command -v -- "$run" > /dev/null 2>&1; then
    _shmutant_err "$label: run callback not found: $run"; return 2
  fi
  _shmutant_validate_settings "$label" "$wd" || return 2
  case "$cap" in
    '') ;;
    *[!0-9]*) _shmutant_err "$label: the pool cap must be a positive integer, got [$cap]"; return 2 ;;
    *) if [ "${#cap}" -gt 4 ] || [ "$cap" -lt 1 ]; then _shmutant_err "$label: the pool cap must be a positive integer of at most four digits, got [$cap]"; return 2; fi ;;
  esac
  _shmutant_open_stream "$label" || return 2
  _shmutant_fresh_dir "$wd/pristine" || { _shmutant_pool_fail "$label" "$wd"; _shmutant_err "$label: cannot recreate $wd/pristine — stale contents there would be prepared over"; return 2; }
  local pout prc errexit_before=0
  pout="$(mktemp "$wd/.prepare.XXXXXX" 2>/dev/null)" || { _shmutant_err "$label: cannot create a capture file in $wd"; return 2; }
  # Called directly, not in a command substitution and not as a condition: state prepare
  # establishes in this shell must still be there when the workers fork, and its own errexit
  # must keep meaning what it says. The errexit state it leaves behind is put back afterwards.
  case "$-" in *e*) errexit_before=1 ;; esac
  # prepare runs in this function's scope, where bash lets it assign any local by name (`n=0`
  # as its own counter). The bookkeeping still needed afterwards is copied out under names no
  # ordinary callback uses and copied back when it returns.
  local _shmutant_pool_label="$label" _shmutant_pool_wd="$wd" _shmutant_pool_run="$run" _shmutant_pool_cap="$cap"
  local _shmutant_pool_n="$n" _shmutant_pool_t0="$t0" _shmutant_pool_pout="$pout" _shmutant_pool_errexit="$errexit_before"
  "$prep" "$wd/pristine" >| "$pout"; prc=$?
  label="$_shmutant_pool_label"; wd="$_shmutant_pool_wd"; run="$_shmutant_pool_run"; cap="$_shmutant_pool_cap"
  n="$_shmutant_pool_n"; t0="$_shmutant_pool_t0"; pout="$_shmutant_pool_pout"; errexit_before="$_shmutant_pool_errexit"
  killed=0; rc=0; base_sel=(); base_verdict=()
  if [ "$errexit_before" = 1 ]; then set -e; else set +e; fi
  if [ "$prc" -ne 0 ]; then
    rm -f -- "$pout"; _shmutant_err "$label: prepare failed (status $prc) — no tree to mutate"; _shmutant_pool_fail "$label" "$wd"; return 2
  fi
  root="$(cat "$pout")"; rm -f -- "$pout"
  # prepare ran in this shell and may have assigned any setting; the workers read them next.
  _shmutant_validate_settings "$label" "$wd" || { _shmutant_err "$label: a setting changed by prepare is invalid"; _shmutant_pool_fail "$label" "$wd"; return 2; }
  jobs="$(_shmutant_jobs "$cap")"
  # The settled SHMUTANT_KEEP, for a CLI parent that may have to clean up after an interrupt.
  [ -n "${SHMUTANT_CLI_KEEPFILE:-}" ] && printf '%s\n' "${SHMUTANT_KEEP:-0}" >| "$SHMUTANT_CLI_KEEPFILE"
  _shmutant_open_stream "$label" || { _shmutant_pool_fail "$label" "$wd"; return 2; }
  [ -n "$root" ] || root="$wd/pristine"
  root="$(_shmutant_abs "$root")" || { _shmutant_err "$label: prepare printed a root that is not a directory"; _shmutant_pool_fail "$label" "$wd"; return 2; }
  if ! _shmutant_inside "$wd/pristine" "$root"; then
    _shmutant_err "$label: prepare printed a root outside the workdir ($root) — refusing to mutate what may be the working tree"; _shmutant_pool_fail "$label" "$wd"; return 2
  fi
  suffix="${root#"$wd/pristine"}"
  for (( i = 0; i < n; i++ )); do
    if ! _shmutant_target_ok "$root" "${SHMUTANT_ROWS_FILE[$i]}"; then
      _shmutant_err "$label: row '${SHMUTANT_ROWS_NAME[$i]}' targets ${SHMUTANT_ROWS_FILE[$i]}, which the prepared tree does not contain as a regular file (missing, a symlink, or under one)"
      _shmutant_pool_fail "$label" "$wd"; return 2
    fi
    # Link count is `ls -l` column 2. A clone gives each hard link its own inode, so a test
    # reading the alias would see pristine code while the named target carries the defect.
    if [ "$(ls -ld -- "$root/${SHMUTANT_ROWS_FILE[$i]}" | awk '{ print $2 }')" -gt 1 ]; then
      _shmutant_err "$label: row '${SHMUTANT_ROWS_NAME[$i]}' targets ${SHMUTANT_ROWS_FILE[$i]}, which has more than one hard link — a clone cannot keep them joined"
      _shmutant_pool_fail "$label" "$wd"; return 2
    fi
  done

  if [ "${SHMUTANT_BASELINE:-1}" != 0 ]; then
    for (( i = 0; i < n; i++ )); do
      sel="${SHMUTANT_ROWS_SEL[$i]}"
      for k in "${base_sel[@]}"; do [ "$k" = "$sel" ] && continue 2; done
      base_sel+=("$sel")
    done
    SHMUTANT_BASE_SEL=("${base_sel[@]}")
    _shmutant_run_jobs base "${#base_sel[@]}" "$wd" "$run" "$suffix" "$jobs"; rjrc=$?
    [ "$rjrc" -eq 0 ] || { _shmutant_pool_fail "$label" "$wd"; return 2; }
    for (( k = 0; k < ${#base_sel[@]}; k++ )); do
      _shmutant_read_verdict "$wd/base-$k"
      base_verdict+=("$SHMUTANT_V_VERDICT")
      case "$SHMUTANT_V_VERDICT" in
        green)   detail="green before injection" ;;
        timeout) detail="did not finish within ${SHMUTANT_TIMEOUT:-300}s before any injection" ;;
        red)     detail="exited $SHMUTANT_V_STATUS (red) before any injection" ;;
        aborted) detail="exited $SHMUTANT_V_STATUS, neither green nor red, before any injection — the selector matched nothing, or the suite aborted" ;;
        *)       detail="$(_shmutant_detail "$SHMUTANT_V_VERDICT" "$SHMUTANT_V_STATUS" "" "${base_sel[$k]}")" ;;
      esac
      _shmutant_emit shmutant 1 baseline "${base_sel[$k]}" "$SHMUTANT_V_VERDICT" "$(_shmutant_secs "$SHMUTANT_V_US")" "$detail"
      [ "$SHMUTANT_V_VERDICT" = green ] || _shmutant_err "$label: baseline [${base_sel[$k]}]: $detail"
    done
  fi

  SHMUTANT_SKIP=()
  for (( i = 0; i < n; i++ )); do
    SHMUTANT_SKIP[i]=0
    for (( k = 0; k < ${#base_sel[@]}; k++ )); do
      if [ "${base_sel[$k]}" = "${SHMUTANT_ROWS_SEL[$i]}" ] && [ "${base_verdict[$k]}" != green ]; then
        SHMUTANT_SKIP[i]=1
        _shmutant_fresh_dir "$wd/mut-$i" || { _shmutant_err "$label: cannot recreate $wd/mut-$i"; _shmutant_pool_fail "$label" "$wd"; return 2; }
        printf 'baseline\n0\n\n' > "$wd/mut-$i/verdict"
      fi
    done
  done
  # Bare, status captured after: as a condition, every callback the workers fork would run in
  # an errexit-ignored context.
  _shmutant_run_jobs mut "$n" "$wd" "$run" "$suffix" "$jobs"; rjrc=$?
  [ "$rjrc" -eq 0 ] || { _shmutant_pool_fail "$label" "$wd"; return 2; }

  for (( i = 0; i < n; i++ )); do
    _shmutant_read_verdict "$wd/mut-$i"
    verdict="$SHMUTANT_V_VERDICT"
    detail="$(_shmutant_detail "$verdict" "$SHMUTANT_V_STATUS" "${SHMUTANT_ROWS_WIT[$i]}" "${SHMUTANT_ROWS_SEL[$i]}")"
    _shmutant_emit shmutant 1 row "$verdict" "${SHMUTANT_ROWS_NAME[$i]}" "${SHMUTANT_ROWS_FILE[$i]}" \
      "${SHMUTANT_ROWS_SEL[$i]}" "$(_shmutant_secs "$SHMUTANT_V_US")" "$detail"
    if [ "$verdict" = killed ]; then
      killed=$((killed + 1))
    else
      rc=1
      _shmutant_err "$label: $verdict '${SHMUTANT_ROWS_NAME[$i]}': $detail"
    fi
  done
  t1="$(_shmutant_now)"
  _shmutant_emit shmutant 1 summary "$label" "$n" "$killed" "$jobs" "$(_shmutant_secs $(( t1 - t0 )))"
  _shmutant_err "$label: $killed/$n mutation(s) killed on their own witness (jobs=$jobs, $(_shmutant_secs $(( t1 - t0 )))s)"
  _shmutant_pool_fail "$label" "$wd"
  if [ "${SHMUTANT_CLEANUP_FAILED:-0}" -ne 0 ]; then
    _shmutant_err "$label: the prepared tree could not be removed — the next run in this workdir would find it"
    return 2
  fi
  if [ "$SHMUTANT_EMIT_FAILED" -ne 0 ]; then
    _shmutant_err "$label: the verdict stream could not be written (${SHMUTANT_STREAM:-stdout}) — the records above are incomplete"
    return 2
  fi
  return "$rc"
}

# --- CLI ---------------------------------------------------------------------------------------

_shmutant_usage() {
  cat <<'EOF'
usage: shmutant run <plan.sh> [--jobs N] [--workdir DIR] [--keep] [--no-baseline] [--timeout S]
       shmutant version
       shmutant checksum
       shmutant help

A plan is a bash file. It defines two functions, `prepare <dir>` and `run <root> <select>`,
and declares its rows with `shmutant_target` and `shmutant_mut`. It is sourced with
SHMUTANT_PLAN_DIR set to its own directory, in a subshell: a plan that exits, execs or fails
to load ends the run with status 2. Exit: 0 every row killed, 1 a row was not, 2 the plan or
the harness could not run. A workdir the run created is removed afterwards unless --keep (or
SHMUTANT_KEEP=1); a --workdir you supplied is never removed.
EOF
}

# _shmutant_checksum <file> — the SHA-256 of <file>, from whichever tool the platform has.
_shmutant_checksum() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum -- "$1" | awk '{print $1}'
  elif command -v shasum > /dev/null 2>&1; then shasum -a 256 -- "$1" | awk '{print $1}'
  elif command -v openssl > /dev/null 2>&1; then openssl dgst -sha256 -- "$1" | awk '{print $NF}'
  else _shmutant_err "no sha256sum, shasum or openssl on PATH"; return 2
  fi
}

# _shmutant_cli_load <plan-path> — runs in the CLI's plan subshell: load the plan, check its
# callbacks, run the pool. The pool's status is the subshell's, and only a completed pool writes
# the marker the parent reads. Callbacks come from the plan, never from functions exported by the
# invoking environment; the plan is sourced bare, not in an || list, so its own errexit keeps
# meaning what it says.
_shmutant_cli_load() {
  local plan="$1" rc
  unset -f prepare run
  shmutant_reset
  # shellcheck disable=SC1090
  # Loaded with stdout on stderr: anything a plan prints while loading is prose, and the CLI's
  # stdout carries verdict records only.
  . "$plan" >&2
  rc=$?
  [ "$rc" -eq 0 ] || { _shmutant_err "run: the plan failed while loading (status $rc)"; return 2; }
  declare -F prepare > /dev/null || { _shmutant_err "run: the plan defines no prepare function"; return 2; }
  declare -F run > /dev/null || { _shmutant_err "run: the plan defines no run function"; return 2; }
  # The plan may have turned errexit on for its own preamble; the pool's non-zero returns are
  # answers, not errors.
  set +o errexit
  shmutant_pool "$(basename -- "$plan")" "$SHMUTANT_CLI_WD" prepare run; rc=$?
  printf '%s %s\n' "$rc" "${SHMUTANT_KEEP:-0}" >| "$SHMUTANT_CLI_DONE"
  return "$rc"
}

# _shmutant_cli_abort <signal> — INT or TERM reached the CLI while its plan subshell was running:
# kill the child's tree, remove a workdir this run created, and re-deliver the signal.
_shmutant_cli_abort() {
  local sig="$1"
  if [ -n "${SHMUTANT_CLI_CHILD:-}" ]; then
    _shmutant_kill_tree_twice "$SHMUTANT_CLI_CHILD"
    wait "$SHMUTANT_CLI_CHILD" 2>/dev/null
  fi
  # The pool records the effective SHMUTANT_KEEP once it is settled, so a plan or prepare that
  # asked to keep the workdir is honoured here too.
  if [ -n "${SHMUTANT_CLI_WD_TO_RM:-}" ]; then
    if [ -f "${SHMUTANT_CLI_KEEPFILE:-}" ] && [ "$(cat "$SHMUTANT_CLI_KEEPFILE" 2>/dev/null)" = 1 ]; then
      _shmutant_err "workdir kept: $SHMUTANT_CLI_WD_TO_RM"
    else
      rm -rf -- "$SHMUTANT_CLI_WD_TO_RM"
    fi
  fi
  trap - INT TERM
  kill "-$sig" "$BASHPID"
}

_shmutant_cli_run() {
  local plan="" wd="" keep=0 made=0 rc done_file marker
  # Seeded from the environment for the window before the pool settles the value: an interrupt
  # during plan loading or prepare must not discard artifacts the operator asked to keep.
  [ "${SHMUTANT_KEEP:-0}" = 1 ] && keep=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --jobs)        [ -n "${2:-}" ] || { _shmutant_err "--jobs needs a value"; return 2; }
                     SHMUTANT_JOBS="$2"; shift 2 ;;
      --workdir)     [ -n "${2:-}" ] || { _shmutant_err "--workdir needs a value"; return 2; }
                     wd="$2"; shift 2 ;;
      --timeout)     [ -n "${2:-}" ] || { _shmutant_err "--timeout needs a value"; return 2; }
                     case "$2" in ''|*[!0-9]*) _shmutant_err "--timeout: not an integer: $2"; return 2 ;; esac
                     SHMUTANT_TIMEOUT="$2"; shift 2 ;;
      --keep)        keep=1; SHMUTANT_KEEP=1; shift ;;
      --no-baseline) SHMUTANT_BASELINE=0; shift ;;
      -*)            _shmutant_err "unknown option: $1"; _shmutant_usage >&2; return 2 ;;
      *)             [ -z "$plan" ] || { _shmutant_err "one plan only"; return 2; }
                     plan="$1"; shift ;;
    esac
  done
  [ -n "$plan" ] || { _shmutant_err "run: a plan file is required"; _shmutant_usage >&2; return 2; }
  [ -f "$plan" ] || { _shmutant_err "run: plan not found: $plan"; return 2; }
  SHMUTANT_PLAN_DIR="$(_shmutant_abs "$(dirname -- "$plan")")" || { _shmutant_err "run: cannot resolve $plan"; return 2; }
  export SHMUTANT_PLAN_DIR
  # Every path is settled, absolute, BEFORE the plan runs: a plan may cd, and a relative
  # --workdir, TMPDIR or SHMUTANT_STREAM must mean what it meant where the operator typed it.
  if [ -n "${SHMUTANT_STREAM:-}" ]; then
    case "$SHMUTANT_STREAM" in
      /*) ;;
      *)  SHMUTANT_STREAM="$(_shmutant_abs "$(dirname -- "$SHMUTANT_STREAM")")/$(basename -- "$SHMUTANT_STREAM")" \
            || { _shmutant_err "run: SHMUTANT_STREAM points into a directory that does not exist: $SHMUTANT_STREAM"; return 2; } ;;
    esac
  fi
  if [ -z "$wd" ]; then
    wd="$(mktemp -d "${TMPDIR:-/tmp}/shmutant.XXXXXX")" || { _shmutant_err "run: cannot create a workdir"; return 2; }
    made=1
  else
    mkdir -p -- "$wd" || { _shmutant_err "run: cannot create workdir $wd"; return 2; }
  fi
  wd="$(_shmutant_abs "$wd")" || { _shmutant_err "run: cannot resolve workdir"; return 2; }
  # The plan and the pool run in a SUBSHELL. Whatever a plan does there — exec, exit, a trap, an
  # assignment to any variable — stays there: this shell never executed it, and decides the
  # outcome from the marker only a completed pool writes. No marker means the plan or a callback
  # ended the run before the pool finished, whatever status the subshell reports.
  done_file="$(mktemp "$wd/.done.XXXXXX")" || { _shmutant_err "run: cannot create a marker in $wd"; [ "$made" = 1 ] && rm -rf -- "$wd"; return 2; }
  rm -f -- "$done_file"
  # A signal to this process must not orphan the subshell and its workers: the child's whole
  # tree is killed, the workdir handled, and the signal re-delivered.
  SHMUTANT_CLI_CHILD=""; SHMUTANT_CLI_WD_TO_RM=""
  [ "$made" = 1 ] && [ "$keep" != 1 ] && SHMUTANT_CLI_WD_TO_RM="$wd"
  SHMUTANT_CLI_KEEPFILE="$(mktemp "$wd/.keep.XXXXXX")" || { _shmutant_err "run: cannot create a marker in $wd"; [ "$made" = 1 ] && rm -rf -- "$wd"; return 2; }
  export SHMUTANT_CLI_KEEPFILE
  trap '_shmutant_cli_abort INT' INT
  trap '_shmutant_cli_abort TERM' TERM
  (
    readonly SHMUTANT_CLI_WD="$wd" SHMUTANT_CLI_DONE="$done_file" SHMUTANT_CLI_KEEPFILE
    _shmutant_cli_load "$SHMUTANT_PLAN_DIR/$(basename -- "$plan")"
  ) & SHMUTANT_CLI_CHILD=$!
  wait "$SHMUTANT_CLI_CHILD"; rc=$?
  trap - INT TERM
  SHMUTANT_CLI_CHILD=""
  rm -f -- "$SHMUTANT_CLI_KEEPFILE"; unset SHMUTANT_CLI_KEEPFILE
  if [ -f "$done_file" ] && marker="$(cat "$done_file" 2>/dev/null)" && [ "${marker%% *}" = "$rc" ]; then
    rm -f -- "$done_file"
    # The plan or prepare may have set SHMUTANT_KEEP=1 inside the subshell; the pool honoured it.
    [ "${marker#* }" = 1 ] && keep=1
  else
    rm -f -- "$done_file"
    case "$rc" in
      2) ;;
      *) _shmutant_err "run: the plan or a callback ended the run before the pool completed (status $rc)" ;;
    esac
    rc=2
  fi
  # Only a workdir this run created is removed. A caller-supplied one is theirs: the pool's own
  # artifacts stay in it and nothing else in it is touched.
  if [ "$keep" = 1 ]; then _shmutant_err "workdir kept: $wd"
  elif [ "$made" = 1 ]; then rm -rf -- "$wd"
  fi
  return "$rc"
}

shmutant_main() {
  case "${1:-}" in
    run)          shift; _shmutant_cli_run "$@" ;;
    version)      printf 'shmutant %s\n' "$SHMUTANT_VERSION" ;;
    checksum)     _shmutant_checksum "${BASH_SOURCE[0]}" ;;
    help|-h|--help) _shmutant_usage ;;
    '')           _shmutant_usage >&2; return 2 ;;
    *)            _shmutant_err "unknown command: $1"; _shmutant_usage >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  shmutant_main "$@"
  exit $?
fi

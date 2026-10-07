# shellcheck shell=sh
# parse <text> — print <text> on a line of its own; an empty <text> is refused with status 1.
parse() {
  if [ -z "$1" ]; then
    return 1
  fi
  printf '%s\n' "$1"
}

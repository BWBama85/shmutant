# shellcheck shell=bash
# The ShellSpec fixture's plan: test/adapters/check.sh writes the ShellSpec block of
# docs/integrating.md beside this file as adapter.sh, runs this plan, and requires the verdicts
# ../expected.tsv lists. The rows after the block are the ones not killed, or killed only
# through a selector the pattern escaping must carry.
. "$SHMUTANT_PLAN_DIR/adapter.sh"

shmutant_mut 'the trailing newline is dropped' "printf '%s\n'" "printf '%s'" \
  'parse prints its input' 'prints its input'
shmutant_mut 'empty input exits 2' 'return 1' 'return 2' \
  'parse rejects empty input' 'rejects empty input'
shmutant_mut 'empty input is accepted, pattern-character selector' 'return 1' 'return 0' \
  'parse refuses [empty] input *?' 'refuses [empty] input *?'
shmutant_mut 'a selector no example carries' 'return 1' 'return 0' \
  'parse has no such example' 'has no such example'
shmutant_mut 'twin input is refused, killed through the twin' '[ -z "$1" ]' '[ "$1" = twin ] || [ -z "$1" ]' \
  'parse prints its input' 'prints its input'

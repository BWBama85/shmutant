# shellcheck shell=bash
# The Bats fixture's plan: test/adapters/check.sh writes the Bats block of docs/integrating.md
# beside this file as adapter.sh, runs this plan, and requires the verdicts ../expected.tsv
# lists. The rows after the block are the ones not killed, or killed only through a name the
# regex escaping, or Bats's expansion of a printed name, must carry.
. "$SHMUTANT_PLAN_DIR/adapter.sh"

shmutant_mut 'the trailing newline is dropped' "printf '%s\n'" "printf '%s'" 'parse prints its input'
shmutant_mut 'empty input exits 2' 'return 1' 'return 2' 'parse rejects empty input'
shmutant_mut 'empty input is accepted, bracketed witness' 'return 1' 'return 0' 'parse.empty (status) [1]'
shmutant_mut 'a witness no test carries' 'return 1' 'return 0' 'parse has no such test'
shmutant_mut 'empty input is accepted, printed name as witness' 'return 1' 'return 0' \
  'parse refuses nothing' 'parse refuses "nothing"'
shmutant_mut 'empty input is accepted, written name as witness' 'return 1' 'return 0' \
  'parse refuses "nothing"'

# shellcheck shell=bash
# The Bats fixture's plan: test/adapters/check.sh writes the Bats block of docs/integrating.md
# beside this file as adapter.sh, then runs this plan. The rows after it are the ones the check
# expects not to be killed, or to be killed through a witness the regex escaping must survive.
. "$SHMUTANT_PLAN_DIR/adapter.sh"

shmutant_mut 'the trailing newline is dropped' "printf '%s\n'" "printf '%s'" 'parse prints its input'
shmutant_mut 'empty input exits 2' 'return 1' 'return 2' 'parse rejects empty input'
shmutant_mut 'empty input is accepted, bracketed witness' 'return 1' 'return 0' 'parse.empty (status) [1]'
shmutant_mut 'a witness no test carries' 'return 1' 'return 0' 'parse has no such test'

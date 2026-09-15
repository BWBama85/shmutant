# Decisions

## D1 — DEVIATION: uncapped re-review rounds
- date:          2026-09-09
- category:      deviation
- baseline-rule: `/resolve-pr-threads` stops after 6 re-review requests (built-in `max_rounds`)
- conflict:      the owner asked for the review loop on PR #1 to continue until the reviewer is clean; rounds 1 to 7 each produced real findings and the cap stopped the loop with the head unreviewed
- scope:         `[reviewers] max_rounds = 0` in `agents.toml`, every PR in this repository
- reason:        every round so far fixed a genuine defect; the per-round wait bound, the one-request-per-head rule and the exit on a no-push round still bound the loop

## D2 — gates declared for a stack the detector does not cover
- date:      2026-09-14
- category:  project-delta
- unknown:   project-gates.sh detects no ecosystem in a bash-only repository, so the gate step of /implement-issue and the turn-end precommit gate ran nothing and reported success
- decision:  declare lint (shellcheck with CI's flags), checksum (CHECKSUMS matches shmutant.sh) and test (bash test/run.sh, cadence full); typecheck and format declared N/A
- placement: agents.toml [gates], [gates.cadence], [gates.state]
- reason:    the owner chose it during the run for #2; the suite takes about ten minutes, so it runs in a full gate run rather than at the end of every turn
- baseline-issue: n/a (the [gates] override covers the case)

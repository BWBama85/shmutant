# Decisions

## D1 — DEVIATION: uncapped re-review rounds
- date:          2026-09-09
- category:      deviation
- baseline-rule: `/resolve-pr-threads` stops after 6 re-review requests (built-in `max_rounds`)
- conflict:      the owner asked for the review loop on PR #1 to continue until the reviewer is clean; rounds 1 to 7 each produced real findings and the cap stopped the loop with the head unreviewed
- scope:         `[reviewers] max_rounds = 0` in `agents.toml`, every PR in this repository
- reason:        every round so far fixed a genuine defect; the per-round wait bound, the one-request-per-head rule and the exit on a no-push round still bound the loop

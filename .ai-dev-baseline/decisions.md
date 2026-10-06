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

## D3 — the bare suite run is excluded from Claude Code's sandbox, without an ask rule
- date:      2026-10-06
- category:  project-delta
- unknown:   inside Claude Code's macOS sandbox the setuid /bin/ps cannot be executed, so test/run.sh cannot check what a unit leaves behind and stops before any unit (#6)
- decision:  `.claude/settings.json` lists `bash test/run.sh` in `sandbox.excludedCommands`, with no `permissions.ask` rule for it
- placement: .claude/settings.json; README "Testing shmutant"
- reason:    the owner specified the entry in #6. An excluded command still goes through the permission flow, but not through the guards a user may put on unsandboxed retries: retries turned off in their own settings, an ask rule on `Bash(dangerouslyDisableSandbox:true)`, or `permissions.blockReadsOutsideWorkingDirectories`. For that user the exclusion runs the suite unsandboxed where a retry would have been refused or prompted. The ask rule the vendor docs pair with an excluded script restores a prompt, on every suite run and in bypassPermissions mode too. The exclusion runs whatever test/run.sh and shmutant.sh hold. The [gates] test command (run under `sh -c` by the gate runner) does not match it, stays sandboxed, and stops at once with exit 2. Nor does the self-mutation command: sandboxed, its baseline aborts, every row is scored `baseline`, and it exits 1.
- alternative: `"permissions": {"ask": ["Bash(bash test/run.sh)"]}` beside the exclusion: each run approved by hand; not taken for the prompt it adds to every run
- baseline-issue: n/a (agent sandbox settings are per project)

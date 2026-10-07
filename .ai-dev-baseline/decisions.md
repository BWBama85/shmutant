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
- reason:    the owner specified the entry in #6. An excluded command still goes through the permission flow, but not through the guards a user may put on unsandboxed retries: retries turned off in their own settings, an ask rule on `Bash(dangerouslyDisableSandbox:true)`, or `permissions.blockReadsOutsideWorkingDirectories`. For that user the exclusion runs the suite unsandboxed where a retry would have been refused or prompted. The ask rule the vendor docs pair with an excluded script restores a prompt in bypassPermissions and auto modes, where the excluded command otherwise runs unprompted or under the classifier's review; in the modes that prompt for it anyway it adds nothing. The exclusion runs whatever test/run.sh and shmutant.sh hold. The [gates] test command (run under `sh -c` by the gate runner) does not match it, stays sandboxed, and stops at once with exit 2. Nor does the self-mutation command: sandboxed, its baseline aborts, every row is scored `baseline`, and it exits 1.
- alternative: `"permissions": {"ask": ["Bash(bash test/run.sh)"]}` beside the exclusion: each run approved by hand; not taken for the prompt it adds to every suite run in bypassPermissions and auto modes
- baseline-issue: n/a (agent sandbox settings are per project)

## D4 — Bats and ShellSpec are CI-only, pinned, and Bats is pinned by commit
- date:      2026-10-06
- category:  project-delta
- unknown:   #7 runs the documented Bats and ShellSpec adapters in CI with each framework pinned by checksum, as bash 5.3 is. bats-core v1.14.0 has no release asset (only the archives GitHub generates for a tag) and is not on npm, and GitHub's archive documentation promises an archive's contents (a tag's only while the tag does not move), never its bytes.
- decision:  ShellSpec 0.28.1 is pinned by the SHA-256 of its release asset. Bats 1.14.0 is pinned by the commit its tag names: a shallow clone of the tag whose HEAD must equal `BATS_COMMIT`. Both run in one `adapters` job on ubuntu-latest. Neither is a `[gates]` entry, since neither is installed where the gates run.
- placement: .github/workflows/ci.yml (env, `adapters` job); test/adapters/check.sh; README "Testing shmutant"
- reason:    a SHA-256 of a generated tag archive can change with GitHub's archiver while the contents do not, failing CI for no reason; a commit pins the contents, by git's SHA-1 object id, which is weaker than the SHA-256 pins beside it. The macOS job's bash comes from Homebrew unpinned, so the adapter verdicts are claimed for the pinned Linux setup only.
- baseline-issue: n/a (CI dependencies are per project)

## D5 — the release procedure is a project skill over a tested script
- date:      2026-10-06
- category:  project-delta
- unknown:   #8 asks for a project-owned release command that the roadmap artifact's `release-command` marker can name. The baseline ships no `/release` skill, so each project writes its own.
- decision:
  - `.claude/skills/release/SKILL.md` settles the version, runs `scripts/release.sh --dry-run`, gets the operator's go-ahead, cuts, and hands off to `baseline release roll`. Only the operator can invoke it (`disable-model-invocation: true`).
  - The script holds every step. `test/release.sh` runs it against a local bare origin, with `gh`, `curl` and `sleep` stubbed. It runs in the `release` CI job (ubuntu, plus macOS under `/bin/bash` 3.2) and as the `release-test` gate (cadence `full`).
  - CI is green on origin's main head when all of these hold:
    - every check run GitHub lists there with `filter=latest` is `completed` with conclusion `success`, so `skipped` and `neutral` refuse, and at least one exists;
    - the `ci.yml` workflow has run on that SHA and each of its runs concluded `success`. A finished run means every job reported, however it is named or matrixed, so ci.yml itself is never parsed;
    - its commit statuses, if it has any, combine to `success`. With none, GitHub reports `pending`, which is ignored.
  - A pending check refuses at once; the script does not wait.
  - `CHECKSUMS` is checked as `sha256sum -c` would check it, without needing `sha256sum`: it must be exactly one `<sha256>  shmutant.sh` line, and the digest must match the file. The digest helper is the script's own, not `shmutant.sh`'s `_shmutant_checksum`: that one needs bash 5.3 and a file, and the script runs on macOS's bash 3.2 and hashes git blobs on stdin.
  - The install URL in `docs/integrating.md` must already name the tag being cut, so the docs at the tag install that release. #8 suggested substituting the version; a doc naming an older tag refuses instead.
  - When a cut fails or is interrupted after its tag may have reached origin, the script prints how to finish by hand and never deletes the tag.
- placement: .claude/skills/release/SKILL.md; scripts/release.sh; test/release.sh; .github/workflows/ci.yml (`release` job); agents.toml [gates] `release-test`, [gates.cadence]; README "Releasing"
- reason:    a script can be shellchecked and tested where fenced shell in a skill cannot. No check reads a remote-tracking ref (origin and GitHub are asked directly), so the dry run needs no fetch.
- baseline-issue: n/a (release execution is project-owned)

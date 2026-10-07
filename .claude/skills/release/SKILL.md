---
name: release
description: Cut a shmutant release. Checks every precondition with a dry run, then tags main's CI-green head, publishes the GitHub release with shmutant.sh and CHECKSUMS attached, verifies the documented install URL, and hands off to the milestone roll.
argument-hint: "<version> (X.Y.Z; defaults to SHMUTANT_VERSION in shmutant.sh)"
user-invocable: true
---

# /release — cut a shmutant release

`scripts/release.sh` is the procedure. This skill decides the version, runs the driver in its dry
run, gets the operator's go-ahead, and then runs it for real. The driver's header is its contract:
what each precondition is, what it publishes and how it verifies.

## Steps

1. **The version.** Use the argument if one was given. Otherwise read it from the source:
   `bash shmutant.sh version` prints `shmutant <X.Y.Z>`. The driver refuses a version that
   `SHMUTANT_VERSION` in `shmutant.sh` does not carry. Bumping the version and regenerating
   `CHECKSUMS` is an ordinary pull request that lands before the cut.

2. **The dry run**, from the root of a clean checkout of `main`:

   ```sh
   bash scripts/release.sh --dry-run <X.Y.Z>
   ```

   It prints `release: ok: …` for each precondition that holds and `release: refused: …` for each
   that does not. It creates no tag, release or file, and it does not fetch. Exit 1 means at least
   one refusal: report each line to the operator and stop, because every refusal names a state only
   the operator can change. Exit 2 means it could not run (a missing tool, an unreadable GitHub
   API, or a bad argument). Report that and stop as well.

3. **The go-ahead.** A pushed tag and a published release are permanent and public. Show the
   operator the dry run's output, including the commit it would tag, and ask before you go on. Do
   not take an earlier approval as approval for this cut.

4. **The cut:**

   ```sh
   bash scripts/release.sh <X.Y.Z>
   ```

   It repeats every check, then tags, pushes, publishes, and verifies. If it fails after the tag
   reached origin, it prints the commands that finish the release by hand. Pass those on as
   printed. Never delete or move a pushed tag. Once the release is finished,
   `bash scripts/release.sh --verify <X.Y.Z>` checks what was published.

5. **The hand-off.** On success the driver's last line is
   `release: next: baseline release roll --version v<X.Y.Z>`. Tell the operator to run that
   command, which moves the release milestone. This skill does not run it.

## Notes

- The driver needs `github.com`, `api.github.com` and `raw.githubusercontent.com`. In an agent
  sandbox that refuses those hosts, the operator runs steps 2 and 4 themselves.
- Its tests are `bash test/release.sh`. They run it against a local bare origin with `gh`, `curl`
  and `sleep` stubbed, so they never reach GitHub.

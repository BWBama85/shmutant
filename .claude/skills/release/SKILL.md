---
name: release
description: Cut a shmutant release. Picks the next version when none is given, lands the version bump as a PR when main lacks it, checks every precondition with a dry run, then tags main's CI-green head, publishes the GitHub release with shmutant.sh and CHECKSUMS attached, verifies the documented install URL, and hands off to the milestone roll.
argument-hint: "[<version> (X.Y.Z)]"
user-invocable: true
disable-model-invocation: true
---

# /release — cut a shmutant release

`scripts/release.sh` is the procedure. This skill settles the version, lands the version bump when
`main` does not carry it yet, runs the driver in its dry run, gets the operator's go-ahead, and then
runs it for real. The driver's header is its contract: what each precondition is, what it publishes
and how it verifies. `/roadmap` emits a bare `/release` when the release is ready, so running this
skill with no argument must reach the go-ahead without any other step from the operator.

## Steps

1. **The version.** From the root of a clean checkout of `main` at origin's head
   (`git fetch origin main --tags`, then `git status --short` empty and `git rev-parse HEAD`
   equal to `git rev-parse origin/main`; if not, report the state and stop):
   - With an argument, the version is the argument.
   - Without one, read the current version as text, as the driver reads it
     (`grep '^SHMUTANT_VERSION=' shmutant.sh`; running `shmutant.sh` needs bash 5.3 and the driver
     does not). When origin has no tag for it (`git ls-remote --tags origin "refs/tags/v<current>"`
     prints nothing), the version is the current one. Otherwise it is already released, and the
     version is the next one after it: list the commits since its tag
     (`git log --format=%s "v<current>..origin/main"`). None means nothing has changed since the
     last release: say so and stop. A subject that is a `feat` (`feat:` or `feat(<scope>):`) or
     marks a breaking change (`<type>!:` or `<type>(<scope>)!:`) makes it the next minor version;
     otherwise it is the next patch.

   Have the operator confirm the version in step 4, not before.

2. **The bump**, only when `shmutant.sh` does not carry the version yet. The driver refuses a
   version that `SHMUTANT_VERSION` in `shmutant.sh` does not carry, that the install URL in
   `docs/integrating.md` does not name, or whose `CHECKSUMS` is stale, so the bump lands on `main` as
   an ordinary pull request before the cut. Do it without asking: the operator asked for this
   release by running `/release`, the bump changes only version text, and step 4's go-ahead still
   guards the tag.

   ```sh
   git switch -c release-v<X.Y.Z>
   bash scripts/bump.sh <X.Y.Z>        # its last line on stdout: bump: <old> -> <X.Y.Z>
   git commit -am "chore: bump the version to <X.Y.Z> for the release cut"
   git push -u origin release-v<X.Y.Z>
   gh pr create --base main --head release-v<X.Y.Z> \
     --title "chore: bump the version to <X.Y.Z> for the release cut" --body "<what changed and why>"
   ```

   The commit message and PR body carry the session's attribution lines. A `bump.sh` exit other
   than 0 is a refusal or a failure it explains on stderr: report it and stop. Then:
   - Wait for the PR's checks with `gh pr checks <n> --watch --fail-fast`, as a background task.
     When any check is not a pass, report it and stop, leaving the PR open.
   - Merge it pinned to the head CI passed on:
     `gh pr merge <n> --squash --match-head-commit <head sha>`. Then `git switch main`,
     `git pull --ff-only`, and delete the local branch.
   - Wait for CI on `main`'s new head, which the driver needs green: find the ci.yml run
     (`gh run list --workflow ci.yml --commit <sha> --json databaseId,status,conclusion`; it can
     take a few seconds to appear) and `gh run watch <id> --exit-status` as a background task. A red
     run: report it and stop.

   The remote branch is left for `/cleanup remote`.

3. **The dry run**, from the root of a clean checkout of `main`:

   ```sh
   env -u SHELLOPTS -u BASHOPTS -u BASH_ENV bash scripts/release.sh --dry-run <X.Y.Z>
   ```

   The `env -u` matters: shell options exported into the driver's environment can stop it from
   running anything while it still exits 0 (see the script's header). For the same reason, the dry
   run passed only when it exits 0 **and** its last line on stdout is
   `release: dry run: every precondition holds for v<X.Y.Z> …`.

   It prints `release: ok: …` for each precondition that holds and `release: refused: …` for each
   that does not. It creates no tag, release or file, and it does not fetch. Exit 1 means at least
   one refusal: report each line to the operator and stop, because every refusal names a state only
   the operator can change. Exit 2 means it could not run (a missing tool, an unreadable GitHub
   API, or a bad argument), or that every precondition held but its report could not be written
   to stdout, which it says on stderr.
   Report that and stop as well.

4. **The go-ahead.** A pushed tag and a published release are public, and this project never
   moves or deletes one once it is out. Show the
   operator the dry run's output, including the version, the commit it would tag, and the bump PR
   when step 2 merged one, and ask before
   you go on. Do not take an earlier approval as approval for this cut.

5. **The cut:**

   ```sh
   env -u SHELLOPTS -u BASHOPTS -u BASH_ENV bash scripts/release.sh <X.Y.Z>
   ```

   It repeats every check, re-reads origin's main just before tagging, then tags, pushes,
   publishes, and verifies. The cut succeeded only when it exits 0 **and** its last line on stdout
   is the hand-off in step 6. When origin has the tag but the release could not be created, or the
   run was interrupted once the tag may exist, it prints the commands that finish the release by
   hand, from the commit it checked. When origin's tag names another commit, or the published
   release does not verify, it says to investigate before anything else. When it cannot read
   something it needs, it stops with exit 2, and when it succeeded but could not write its report
   it exits 2 saying what it did, which may be a published release. Pass every one of these on as printed. Run a
   later check the same protected way, and take it as passed only when its last line on stdout is
   `release: verified: the release v<X.Y.Z> carries shmutant.sh and CHECKSUMS as tagged`:

   ```sh
   env -u SHELLOPTS -u BASHOPTS -u BASH_ENV bash scripts/release.sh --verify <X.Y.Z>
   ```

   Never delete or move a pushed tag.

6. **The hand-off.** On success the driver's last line on stdout is
   `release: next: baseline release roll --version v<X.Y.Z>`. Tell the operator to run that
   command, which moves the release milestone. This skill does not run it.

## Notes

- The driver reaches `github.com` (git), `api.github.com`, `uploads.github.com` (the release's
  assets), `raw.githubusercontent.com`, and the `*.githubusercontent.com` host a release asset
  download redirects to. Run it with the agent sandbox lifted; where that is not allowed, the
  operator runs steps 3 and 5 themselves.
- Its tests, and `scripts/bump.sh`'s, are `bash test/release.sh`. They run the driver against a
  local bare origin with `gh`, `curl` and `sleep` stubbed, so they never reach GitHub, and check
  that a bump yields files the driver's dry run accepts.

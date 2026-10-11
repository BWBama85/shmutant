---
name: release
description: Cut a shmutant release. Checks every precondition with a dry run, then tags main's CI-green head, publishes the GitHub release with shmutant.sh and CHECKSUMS attached, verifies the documented install URL, and hands off to the milestone roll.
argument-hint: "<version> (X.Y.Z)"
user-invocable: true
disable-model-invocation: true
---

# /release — cut a shmutant release

`scripts/release.sh` is the procedure. This skill settles the version, runs the driver in its dry
run, gets the operator's go-ahead, and then runs it for real. The driver's header is its contract:
what each precondition is, what it publishes and how it verifies.

## Steps

1. **The version.** Use the argument. Without one, propose the version on the
   `SHMUTANT_VERSION=` line of `shmutant.sh` (`grep '^SHMUTANT_VERSION=' shmutant.sh`; read as text,
   as the driver reads it, since running `shmutant.sh` needs bash 5.3 and the driver does not) and
   have the operator confirm it in step 3. The driver refuses a version that
   `SHMUTANT_VERSION` in `shmutant.sh` does not carry, or that the install URL in
   `docs/integrating.md` does not name. Bumping both, and regenerating `CHECKSUMS`, is an ordinary
   pull request that lands before the cut.

2. **The dry run**, from the root of a clean checkout of `main`:

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

3. **The go-ahead.** A pushed tag and a published release are public, and this project never
   moves or deletes one once it is out. Show the
   operator the dry run's output, including the version and the commit it would tag, and ask before
   you go on. Do not take an earlier approval as approval for this cut.

4. **The cut:**

   ```sh
   env -u SHELLOPTS -u BASHOPTS -u BASH_ENV bash scripts/release.sh <X.Y.Z>
   ```

   It repeats every check, re-reads origin's main just before tagging, then tags, pushes,
   publishes, and verifies. The cut succeeded only when it exits 0 **and** its last line on stdout
   is the hand-off in step 5. When origin has the tag but the release could not be created, or the
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

5. **The hand-off.** On success the driver's last line on stdout is
   `release: next: baseline release roll --version v<X.Y.Z>`. Tell the operator to run that
   command, which moves the release milestone. This skill does not run it.

## Notes

- The driver reaches `github.com` (git), `api.github.com`, `uploads.github.com` (the release's
  assets), `raw.githubusercontent.com`, and the `*.githubusercontent.com` host a release asset
  download redirects to. In an agent sandbox that refuses any of them, the operator runs steps 2
  and 4 themselves.
- Its tests are `bash test/release.sh`. They run it against a local bare origin with `gh`, `curl`
  and `sleep` stubbed, so they never reach GitHub.

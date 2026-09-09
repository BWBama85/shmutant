# Pattern ledger

**What this project has already learned from its own review threads.** Every entry below was a
review finding somebody fixed: the class of defect, where it was found, and the commit that closed
it. It is written automatically by `/resolve-pr-threads` as each thread is resolved, and read
automatically by `/implement-issue` — the gap-analysis dispatch and the pre-PR self-review sweep
both receive the promoted checklist.

**The checklist is the operative half.** A class seen more than once is a pattern rather than an
incident, and is owed a rule: a sweep to run before the next pull request opens. Rules land here
through the normal pull-request path, so a rule only takes effect once a change carrying it has
been merged — which takes repository write access, and is reviewable in the diff like any other
change. (Write access is what the guarantee actually rests on; whether a human read the diff is up
to the project's own review settings.)

**Editing by hand is fine.** Reword a rule that reads badly, delete one that stopped being true.
The only lines with a machine-read grammar are the ones between the markers below; the prose
around them is yours.

**Resolving a `fix` sha after the pull request merged.** On a squash-merging repo the per-thread
commits never become ancestors of the default branch, so a bare `git show <fix>` fails once the
branch is gone. GitHub keeps the pull request's own commits, so fetch them by PR number — which is
why every entry carries one:

```sh
git fetch origin "refs/pull/<pr>/head" && git show <fix>
```

**Two branches can both append here, and that is handled by ordinary means.** Git may report a
conflict when two pull requests add hits at the same point — take both sides; the entries are
independent and are keyed on their review-thread ids, so nothing is lost by keeping them. Promotion
is decided by *reading this file*, never by a counter carried in a branch: two branches that each
recorded a class's first hit merge into a file holding two, and the class is then due.

**What makes that converge is a check on the CLEAN-PASS path**, not the ordinary one. A resolver run
that finds nothing to fix exits before it would ever ask which classes are due, so "the next run
promotes it" was only true of a run that happened to have other findings. `/resolve-pr-threads`
therefore reconciles due promotions before exiting on a clean pass — the one thing a clean run still
does.

## Promoted checklist

Sweep each of these before opening a pull request.

<!-- adb:checklist:begin -->
- `rewrite-loses-file-shape` — For every place that rewrites a file through a temporary and renames it over the original, check that the mode bits, the final-newline shape, and the symlink status of the original survive the rewrite; test each with a file that has the non-default property, not only the default one.
- `host-shell-option-leak` — For a library that is sourced into a caller shell, list every shell option or variable that changes the meaning of the constructs it uses (nocasematch for case, noclobber for redirects, CDPATH for cd, IFS, set -e, set -u, extglob) and either neutralise each one inside a subshell or make the construct immune; test each with the option deliberately turned on around the call.
- `path-escapes-root` — For every path built as <root>/<caller-supplied relative path>, resolve the result physically (cd -P, pwd -P) and require it to stay at or below <root> before reading or writing it; test with a .. component, an absolute symlink, and a symlinked parent directory, not only a plain file.
- `caller-owned-path-deleted` — For every rm -rf, list the paths it can reach and prove each one was created by this code in this run; anything the caller could have supplied or written into (a --workdir, an output file, a stream path) is either refused when it overlaps the removal, or excluded from it. Test with a caller file placed inside the removal target.
- `config-value-unvalidated` — For every environment variable or option the code reads, validate its domain before the first use (numeric range, non-empty, existing directory, not inside a disposable tree) and exit 2 on a violation; a value outside the domain must never reach a comparison that changes a verdict. Test each with 0, empty, non-numeric and out-of-range.
<!-- adb:checklist:end -->

## Hits

One line per resolved review thread, newest last.

<!-- adb:hits:begin -->
- `caller-owned-path-deleted` `shmutant.sh:535` `1ffd64f` `PRRT_kwDOUT7q9s6gzb0G` PR #1 2026-09-09 — CLI removed a caller-supplied --workdir; now only a workdir the run created is removed
- `stale-artifact-reuse` `shmutant.sh:361` `1ffd64f` `PRRT_kwDOUT7q9s6gzb0M` PR #1 2026-09-09 — worker dirs were reused with a stale timeout marker; now recreated per run and the marker cleared
- `rewrite-loses-file-shape` `shmutant.sh:179` `1ffd64f` `PRRT_kwDOUT7q9s6gzb0R` PR #1 2026-09-09 — mutate rewrote through a fresh temp file and dropped the mode bits; now cp -p carries them
- `rewrite-loses-file-shape` `shmutant.sh:176` `1ffd64f` `PRRT_kwDOUT7q9s6gzb0Z` PR #1 2026-09-09 — awk print appended a final newline the target lacked; now preserved via a NL flag
- `timeout-escalation-cancelled` `shmutant.sh:260` `1ffd64f` `PRRT_kwDOUT7q9s6gzb0f` PR #1 2026-09-09 — watchdog killed after the leader died so TERM-ignoring descendants survived; now allowed to reach KILL
- `early-return-skips-cleanup` `shmutant.sh:290` `1ffd64f` `PRRT_kwDOUT7q9s6gzb0i` PR #1 2026-09-09 — early worker verdicts returned before clone removal; now every exit goes through one finish helper
- `aggregate-status-lost` `shmutant.sh:528` `1ffd64f` `PRRT_kwDOUT7q9s6gzb0l` PR #1 2026-09-09 — sourcing a plan returned the last command status so a refused row was skipped; refusals are now counted and fail the pool
- `predictable-temp-path` `shmutant.sh:177` `1ffd64f` `PRRT_kwDOUT7q9s6gzb0t` PR #1 2026-09-09 — mutate wrote to file.shmutant-tmp which could be a symlink out of the tree; now mktemp in the target dir
- `write-failure-swallowed` `shmutant.sh:96` `1ffd64f` `PRRT_kwDOUT7q9s6gzb0w` PR #1 2026-09-09 — stream write failures were ignored and the pool could return 0; now tracked and exit 2
- `path-escapes-root` `shmutant.sh:205` `ddc2655` `PRRT_kwDOUT7q9s6g07P5` PR #1 2026-09-09 — a target with .. components could resolve outside the clone; .. components are now refused at declaration
- `rewrite-loses-file-shape` `shmutant.sh:198` `ddc2655` `PRRT_kwDOUT7q9s6g07P-` PR #1 2026-09-09 — renaming over a symlink target swapped the link for a file and left the referent; symlink targets are now refused
- `host-shell-option-leak` `shmutant.sh:196` `ddc2655` `PRRT_kwDOUT7q9s6g07QE` PR #1 2026-09-09 — a sourcing shell with set -C made the temp redirect fail; now a forced >| redirect
- `path-lookup-ambiguity` `shmutant.sh:575` `ddc2655` `PRRT_kwDOUT7q9s6g07QK` PR #1 2026-09-09 — a bare plan name was sourced via PATH lookup; now sourced by its resolved directory path
- `option-surface-mismatch` `shmutant.sh:586` `ddc2655` `PRRT_kwDOUT7q9s6g07QQ` PR #1 2026-09-09 — SHMUTANT_KEEP=1 kept clones but the CLI still deleted its created workdir; the env form now sets keep
- `pipeline-status-lost` `README.md:132` `ddc2655` `PRRT_kwDOUT7q9s6g07Qa` PR #1 2026-09-09 — documented CI pipeline returned awk status not shmutant; docs now capture rc before the awk
- `path-escapes-root` `shmutant.sh:465` `3095609` `PRRT_kwDOUT7q9s6g1ZJM` PR #1 2026-09-09 — a symlinked parent component let a relative target resolve outside the clone; the target directory is now resolved physically and required under root
- `host-shell-option-leak` `shmutant.sh:241` `3095609` `PRRT_kwDOUT7q9s6g1ZJR` PR #1 2026-09-09 — the caller nocasematch made witness case patterns case-insensitive; workers now unset it
- `host-shell-option-leak` `shmutant.sh:148` `3095609` `PRRT_kwDOUT7q9s6g1ZJX` PR #1 2026-09-09 — CDPATH made cd print a second line from the path resolver; unset inside the subshell
- `self-referential-copy` `shmutant.sh:167` `3095609` `PRRT_kwDOUT7q9s6g1ZJe` PR #1 2026-09-09 — a destination inside the source was copied into itself; now refused with a message
- `undeclared-dependency` `shmutant.sh:199` `3095609` `PRRT_kwDOUT7q9s6g1ZJk` PR #1 2026-09-09 — cmp (diffutils) was used and its absence read as files differ; awk now reports the miss by exit status
- `rewrite-loses-file-shape` `shmutant.sh:212` `a380a98` `PRRT_kwDOUT7q9s6g16Bp` PR #1 2026-09-09 — cp -p made the temp read-only before the write so 0444 targets failed; now chmod u+w for the write and u-w restored after
- `rewrite-loses-file-shape` `shmutant.sh:212` `a380a98` `PRRT_kwDOUT7q9s6g16B2` PR #1 2026-09-09 — duplicate of the read-only target finding
- `host-shell-option-leak` `shmutant.sh:186` `a380a98` `PRRT_kwDOUT7q9s6g16Br` PR #1 2026-09-09 — set -f, failglob, GLOBIGNORE, dotglob changed what copy_tree enumerated; now neutralised in a subshell
- `host-shell-option-leak` `shmutant.sh:190` `a380a98` `PRRT_kwDOUT7q9s6g16B5` PR #1 2026-09-09 — duplicate of the glob-settings finding
- `host-shell-option-leak` `shmutant.sh:190` `a380a98` `PRRT_kwDOUT7q9s6g16CP` PR #1 2026-09-09 — duplicate of the glob-settings finding
- `config-value-unvalidated` `shmutant.sh:360` `a380a98` `PRRT_kwDOUT7q9s6g16Bw` PR #1 2026-09-09 — SHMUTANT_RED_STATUS=0 or non-numeric changed verdict semantics silently; now validated 1..255 and prefix non-empty
- `config-value-unvalidated` `shmutant.sh:360` `a380a98` `PRRT_kwDOUT7q9s6g16B-` PR #1 2026-09-09 — duplicate of the red-status validation finding
- `config-value-unvalidated` `shmutant.sh:360` `a380a98` `PRRT_kwDOUT7q9s6g16CV` PR #1 2026-09-09 — duplicate of the red-status validation finding
- `host-shell-option-leak` `shmutant.sh:611` `a380a98` `PRRT_kwDOUT7q9s6g16CE` PR #1 2026-09-09 — a plan preamble set -e aborted the CLI at the pool call before cleanup; errexit is now turned off after sourcing
- `host-shell-option-leak` `shmutant.sh:611` `a380a98` `PRRT_kwDOUT7q9s6g16CZ` PR #1 2026-09-09 — duplicate of the plan errexit finding
- `caller-owned-path-deleted` `shmutant.sh:542` `a380a98` `PRRT_kwDOUT7q9s6g16CJ` PR #1 2026-09-09 — a stream inside the workdir was deleted by pristine cleanup; stream paths inside the workdir are now refused
- `caller-owned-path-deleted` `shmutant.sh:542` `a380a98` `PRRT_kwDOUT7q9s6g16Cg` PR #1 2026-09-09 — duplicate of the stream-under-pristine finding
<!-- adb:hits:end -->

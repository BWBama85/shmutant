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
- `path-lookup-ambiguity` — For every path the caller supplies (a file to source, a workdir, an output), resolve it to an absolute physical path at the moment it is received and before any code that may cd, source, or change PATH runs; never let a bare name reach source, ., or a relative open after that point. Test with a relative path plus a cd, and a bare name plus a decoy on PATH.
- `timeout-escalation-cancelled` — For every timeout that kills a run, enumerate what can outlive the first signal (a TERM-ignoring child, a descendant in its own process group or session, a watchdog cancelled before its KILL) and test each with a run that does exactly that, asserting a marker the survivor would have written does not appear.
- `early-return-skips-cleanup` — For every function that creates something it must later remove (a clone, a temp file, a workdir, a trap), list every return, exit and trap path out of it and route each one through a single finish helper; grep the function for return and exit and check each line reaches that helper. Test each early exit by asserting the artifact is gone.
- `stale-artifact-reuse` — For every directory or file a run reads a result from, prove it was written by this run: recreate it before use and treat a failed removal or creation as an abort, never as a warning. Test by planting a stale result (a marker, a verdict) that the run must not report, and one the run cannot delete.
- `predictable-temp-path` — For every file the code opens for writing under a directory it does not fully own (a workdir, a target directory), grep for redirections and cp/mv targets built from a fixed name and replace each with a mktemp file in that directory; test by planting a symlink at the old fixed name pointing at a file outside and asserting it is untouched.
- `contract-not-honoured` — For every statement in a contract header (which shell a callback runs in, which statuses mean what, what a record field can contain), find the line of code that implements it and write the unit that would fail if the code did the nearest plausible other thing; a contract line with no such unit is either untested or false.
- `option-surface-mismatch` — For every setting that has two surfaces (a flag and an environment variable, a value the caller sets and one a callback sets), trace both to the single place that consumes it and test each surface separately; a value that one surface honours and the other silently drops is a defect in whichever reads it too early.
- `pipeline-status-lost` — For every documented command that runs the tool (README, guide, migration steps), grep the docs for the tool name followed by | or || and for && and check each example carries the tool exit status to its consumer on its own line; a doc example that loses the status ships the defect to every reader.
- `write-failure-swallowed` — For every command whose failure would leave a promise unkept (a record written, metadata restored, a file replaced), grep for it and check its status reaches the function return; a 2>/dev/null with no || rc=1 beside it is the defect. Test by making the command fail (a read-only target, a closed descriptor, a foreign owner) and asserting the caller reports it.
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
- `host-shell-option-leak` `shmutant.sh:633` `53cf30a` `PRRT_kwDOUT7q9s6g2Wz3` PR #1 2026-09-09 — sourcing the plan in an || list muted its own errexit; now sourced bare under an EXIT trap that normalises failure to 2
- `path-escapes-root` `shmutant.sh:492` `53cf30a` `PRRT_kwDOUT7q9s6g2Wz7` PR #1 2026-09-09 — a symlink stream outside the workdir could point inside pristine; symlink streams refused
- `config-value-unvalidated` `shmutant.sh:484` `53cf30a` `PRRT_kwDOUT7q9s6g2W0C` PR #1 2026-09-09 — an all-digit red status past integer range fell through the range check; width bounded to 3 digits
- `config-value-unvalidated` `shmutant.sh:479` `53cf30a` `PRRT_kwDOUT7q9s6g2W0G` PR #1 2026-09-09 — an all-digit timeout past integer range silently disabled the watchdog; width bounded to 9 digits
- `path-lookup-ambiguity` `shmutant.sh:614` `53cf30a` `PRRT_kwDOUT7q9s6g2W0L` PR #1 2026-09-09 — a relative --workdir was resolved after a plan cd; now absolute before sourcing
- `timeout-escalation-cancelled` `shmutant.sh:314` `53cf30a` `PRRT_kwDOUT7q9s6g2W0S` PR #1 2026-09-09 — descendants in their own process group survived the group kill; timeout now also walks descendants via ps
- `host-shell-option-leak` `shmutant.sh:633` `53cf30a` `PRRT_kwDOUT7q9s6g2W0a` PR #1 2026-09-09 — a sourced plan could assign the CLI cleanup locals by dynamic scope; cleanup inputs frozen read-only before sourcing
- `host-shell-option-leak` `shmutant.sh:635` `53cf30a` `PRRT_kwDOUT7q9s6g2W0c` PR #1 2026-09-09 — exported prepare/run functions from the environment satisfied the callback check; unset before sourcing
- `timeout-escalation-cancelled` `shmutant.sh:340` `8757c31` `PRRT_kwDOUT7q9s6g2tVE` PR #1 2026-09-09 — the KILL walk ran after the leader died so a reparented TERM-ignoring descendant was missed; the pre-TERM pid set is now reused
- `host-shell-option-leak` `shmutant.sh:508` `8757c31` `PRRT_kwDOUT7q9s6g2tVG` PR #1 2026-09-09 — bare length expansions aborted under a caller set -u; every setting is now read through a default first
- `early-return-skips-cleanup` `shmutant.sh:693` `8757c31` `PRRT_kwDOUT7q9s6g2tVJ` PR #1 2026-09-09 — load-failure returns and the EXIT trap skipped the automatic workdir cleanup; all routed through one finish helper
- `config-value-unvalidated` `shmutant.sh:519` `8757c31` `PRRT_kwDOUT7q9s6g2tVN` PR #1 2026-09-09 — an invalid SHMUTANT_JOBS silently fell back to the CPU count; now validated
- `config-value-unvalidated` `shmutant.sh:525` `8757c31` `PRRT_kwDOUT7q9s6g2tVU` PR #1 2026-09-09 — a FIFO stream with no reader blocked the pool forever; non-regular existing streams are refused
- `rewrite-loses-file-shape` `shmutant.sh:377` `8757c31` `PRRT_kwDOUT7q9s6g2tVY` PR #1 2026-09-09 — cp -RP clones split hard links so an alias stayed pristine; multiply linked targets are refused
- `rewrite-loses-file-shape` `shmutant.sh:229` `8757c31` `PRRT_kwDOUT7q9s6g2tVc` PR #1 2026-09-09 — writing cleared setuid/setgid and only owner-write was restored; the full ls -l mode is reapplied
- `path-lookup-ambiguity` `shmutant.sh:670` `8757c31` `PRRT_kwDOUT7q9s6g2tVf` PR #1 2026-09-09 — a relative TMPDIR gave a relative automatic workdir that a plan cd moved; resolved absolute before sourcing
- `path-lookup-ambiguity` `shmutant.sh:520` `8757c31` `PRRT_kwDOUT7q9s6g2tVg` PR #1 2026-09-09 — a relative SHMUTANT_STREAM was interpreted after a plan cd; resolved absolute before sourcing
- `host-shell-option-leak` `shmutant.sh:748` `33bb02b` `PRRT_kwDOUT7q9s6g3Jdp` PR #1 2026-09-09 — a plan could replace the EXIT load-failure trap and exit around it; trap is shadowed to refuse EXIT while the plan loads
- `host-shell-option-leak` `shmutant.sh:362` `33bb02b` `PRRT_kwDOUT7q9s6g3Jd1` PR #1 2026-09-09 — the descendant pid list was an unquoted string split by the caller IFS; now an array with a local IFS
- `rewrite-loses-file-shape` `shmutant.sh:237` `33bb02b` `PRRT_kwDOUT7q9s6g3Jd5` PR #1 2026-09-09 — as root the mktemp replacement was root-owned; cp -p now carries owner and group before the rewrite
- `contract-not-honoured` `shmutant.sh:572` `33bb02b` `PRRT_kwDOUT7q9s6g3JeA` PR #1 2026-09-09 — prepare ran in a command-substitution subshell despite the contract saying the pool shell; now called directly with stdout to a file
- `config-value-unvalidated` `shmutant.sh:272` `33bb02b` `PRRT_kwDOUT7q9s6g3JeG` PR #1 2026-09-09 — surplus shmutant_mut arguments were silently dropped; more than five is now refused
- `stale-artifact-reuse` `shmutant.sh:484` `33bb02b` `PRRT_kwDOUT7q9s6g3JeJ` PR #1 2026-09-09 — an unremovable worker dir was ignored and its stale verdict read; recreation failure now aborts with 2
- `path-lookup-ambiguity` `shmutant.sh:577` `56761ce` `PRRT_kwDOUT7q9s6g7D8H` PR #1 2026-09-10 — a relative library SHMUTANT_STREAM stayed relative while prepare could cd; now replaced by the validated absolute path
- `stale-artifact-reuse` `shmutant.sh:586` `56761ce` `PRRT_kwDOUT7q9s6g7D8M` PR #1 2026-09-10 — pristine was rm -rf then mkdir -p unchecked; now the checked recreation helper
- `timeout-escalation-cancelled` `shmutant.sh:365` `56761ce` `PRRT_kwDOUT7q9s6g7D8P` PR #1 2026-09-10 — descendants that detached before the deadline were never seen; the watchdog now snapshots twice a second while the run lives (setsid double-fork within a poll remains out of reach)
- `host-shell-option-leak` `shmutant.sh:778` `56761ce` `PRRT_kwDOUT7q9s6g7D8R` PR #1 2026-09-10 — builtin trap and command trap bypassed the function shadow; a DEBUG trap now re-arms the EXIT guard before every plan command
- `predictable-temp-path` `shmutant.sh:589` `56761ce` `PRRT_kwDOUT7q9s6g7D8T` PR #1 2026-09-10 — prepare.out was a fixed name that could be a symlink; now mktemp in the workdir
- `config-value-unvalidated` `shmutant.sh:279` `56761ce` `PRRT_kwDOUT7q9s6g7D8Z` PR #1 2026-09-10 — a witness with a newline could never match a single red line; refused at declaration
- `host-shell-option-leak` `shmutant.sh:589` `56761ce` `PRRT_kwDOUT7q9s6g7D8b` PR #1 2026-09-10 — prepare ran as an if condition, muting its own errexit; now called bare with status captured and the caller errexit restored, and the CLI arms an EXIT guard around the pool
- `rewrite-loses-file-shape` `shmutant.sh:405` `56761ce` `PRRT_kwDOUT7q9s6g7D8f` PR #1 2026-09-10 — cp -RP clones dropped ownership and timestamps; now cp -RPp in clones and copy_tree
- `config-value-unvalidated` `shmutant.sh:606` `73983af` `PRRT_kwDOUT7q9s6g7Y1E` PR #1 2026-09-10 — prepare could reassign a validated setting; settings are revalidated after prepare returns
- `config-value-unvalidated` `shmutant.sh:606` `73983af` `PRRT_kwDOUT7q9s6g7Y1I` PR #1 2026-09-10 — duplicate of the revalidation finding
- `host-shell-option-leak` `shmutant.sh:804` `73983af` `PRRT_kwDOUT7q9s6g7Y1G` PR #1 2026-09-10 — exec in a plan replaced the CLI process; the plan and pool now run in a subshell with a completion marker
- `host-shell-option-leak` `shmutant.sh:804` `73983af` `PRRT_kwDOUT7q9s6g7Y1N` PR #1 2026-09-10 — duplicate of the exec finding
- `config-value-unvalidated` `shmutant.sh:579` `73983af` `PRRT_kwDOUT7q9s6g7Y1O` PR #1 2026-09-10 — a multiline red prefix could never match; refused
- `config-value-unvalidated` `shmutant.sh:128` `73983af` `PRRT_kwDOUT7q9s6g7Y1Q` PR #1 2026-09-10 — an invalid pool cap silently became 8; validated
- `stale-artifact-reuse` `shmutant.sh:340` `73983af` `PRRT_kwDOUT7q9s6g7Y1U` PR #1 2026-09-10 — a retained pid could be reused by an unrelated process; identity checked via elapsed time before signalling
- `host-shell-option-leak` `shmutant.sh:802` `73983af` `PRRT_kwDOUT7q9s6g7Y1W` PR #1 2026-09-10 — functrace carried the DEBUG guard into plan subshells; the trap machinery is replaced by the subshell and marker design
- `contract-not-honoured` `shmutant.sh:436` `73983af` `PRRT_kwDOUT7q9s6g7Y1Y` PR #1 2026-09-10 — a baseline exit neither green nor red was labelled red; now aborted
- `config-value-unvalidated` `shmutant.sh:656` `883f690` `PRRT_kwDOUT7q9s6g8O5q` PR #1 2026-09-10 — jobs was computed before prepare could set SHMUTANT_JOBS; now after the post-prepare validation
- `config-value-unvalidated` `shmutant.sh:577` `883f690` `PRRT_kwDOUT7q9s6g8O5t` PR #1 2026-09-10 — SHMUTANT_BASELINE and SHMUTANT_KEEP were not validated as 0/1; now they are
- `stale-artifact-reuse` `shmutant.sh:353` `883f690` `PRRT_kwDOUT7q9s6g8O5y` PR #1 2026-09-10 — a zero-age elapsed time made the pid identity check vacuous; identity is now etime plus pgid plus args
- `host-shell-option-leak` `shmutant.sh:665` `883f690` `PRRT_kwDOUT7q9s6g8O50` PR #1 2026-09-10 — prepare could clobber pool locals like n by dynamic scope; bookkeeping is copied out and restored around it
- `early-return-skips-cleanup` `shmutant.sh:182` `883f690` `PRRT_kwDOUT7q9s6g8O53` PR #1 2026-09-10 — a refused nested copy left the directory mkdir created; the first created component is removed on refusal
- `config-value-unvalidated` `shmutant.sh:398` `883f690` `PRRT_kwDOUT7q9s6g8O56` PR #1 2026-09-10 — a leading-zero timeout like 08 was octal to arithmetic and disarmed the watchdog; forced base 10
- `timeout-escalation-cancelled` `shmutant.sh:554` `883f690` `PRRT_kwDOUT7q9s6g8O58` PR #1 2026-09-10 — an interrupted pool left its workers running; INT and TERM now kill every active worker tree and re-deliver the signal
- `timeout-escalation-cancelled` `shmutant.sh:922` `5392317` `PRRT_kwDOUT7q9s6g8uTT` PR #1 2026-09-10 — a signal to the CLI parent orphaned the plan subshell and workers; the parent now traps INT/TERM, kills the child tree, cleans up and re-delivers
- `host-shell-option-leak` `shmutant.sh:736` `5392317` `PRRT_kwDOUT7q9s6g8uTW` PR #1 2026-09-10 — the documented pool || bad pattern put the whole pool in an errexit-ignored context; docs now capture the status on its own line and state the bash limit
- `contract-not-honoured` `shmutant.sh:590` `5392317` `PRRT_kwDOUT7q9s6g8uTb` PR #1 2026-09-10 — restoring a saved trap re-spelled it and appended SIGTERM to the handler; the trap -p declaration is now restored verbatim
- `config-value-unvalidated` `shmutant.sh:269` `5392317` `PRRT_kwDOUT7q9s6g8uTc` PR #1 2026-09-10 — shmutant_target accepted surplus arguments; exactly one is required
- `option-surface-mismatch` `shmutant.sh:939` `5392317` `PRRT_kwDOUT7q9s6g8uTe` PR #1 2026-09-10 — SHMUTANT_KEEP=1 set inside the plan was honoured by the pool but not the CLI cleanup; carried back through the marker
- `host-shell-option-leak` `shmutant.sh:751` `5392317` `PRRT_kwDOUT7q9s6g8uTg` PR #1 2026-09-10 — root containment used case under the caller nocasematch; containment now runs with it off
- `predictable-temp-path` `shmutant.sh:493` `5392317` `PRRT_kwDOUT7q9s6g8uTj` PR #1 2026-09-10 — the timeout marker was a predictable name a callback could write; now a mktemp name
- `config-value-unvalidated` `shmutant.sh:285` `5392317` `PRRT_kwDOUT7q9s6g8uTl` PR #1 2026-09-10 — an old literal with a newline could never apply; refused at declaration
- `timeout-escalation-cancelled` `shmutant.sh:580` `e587baf` `PRRT_kwDOUT7q9s6g9Q2D` PR #1 2026-09-10 — abort handlers did not retain TERM victims for KILL; both now snapshot before TERM
- `timeout-escalation-cancelled` `shmutant.sh:457` `e587baf` `PRRT_kwDOUT7q9s6g9Q2I` PR #1 2026-09-10 — a callback returning normally left its backgrounded helpers running; the wrapper snapshots at return and the runner ends them
- `predictable-temp-path` `shmutant.sh:469` `e587baf` `PRRT_kwDOUT7q9s6g9Q2L` PR #1 2026-09-10 — the verdict was written straight to a fixed name a callback could pre-link; now temp plus rename
- `path-escapes-root` `shmutant.sh:157` `e587baf` `PRRT_kwDOUT7q9s6g9Q2N` PR #1 2026-09-10 — root / produced the pattern //* and contained nothing; special-cased
- `rewrite-loses-file-shape` `shmutant.sh:205` `e587baf` `PRRT_kwDOUT7q9s6g9Q2P` PR #1 2026-09-10 — copy_tree split hard links so the later check could not see them; hard-linked sources are refused
- `stale-artifact-reuse` `shmutant.sh:378` `e587baf` `PRRT_kwDOUT7q9s6g9Q2V` PR #1 2026-09-10 — pgid and args identity rejected a legitimately daemonised descendant; identity is now the start time
- `host-shell-option-leak` `shmutant.sh:746` `e587baf` `PRRT_kwDOUT7q9s6g9Q2Y` PR #1 2026-09-10 — prepare could clobber rc and killed; reset after prepare
- `host-shell-option-leak` `shmutant.sh:411` `e587baf` `PRRT_kwDOUT7q9s6g9Q2b` PR #1 2026-09-10 — a glob under caller failglob aborted the runner; the glob is gone
- `option-surface-mismatch` `shmutant.sh:947` `e587baf` `PRRT_kwDOUT7q9s6g9Q2f` PR #1 2026-09-10 — KEEP set inside the plan was not known to the CLI interrupt path; the pool now records it in a CLI-provided file
- `host-shell-option-leak` `shmutant.sh:808` `e587baf` `PRRT_kwDOUT7q9s6g9Q2j` PR #1 2026-09-10 — the worker pools ran as || conditions so callback errexit was ignored; called bare with status captured
- `host-shell-option-leak` `shmutant.sh:453` `2a21cfc` `PRRT_kwDOUT7q9s6g-lEN` PR #1 2026-09-10 — the run callback could assign mark and redirect the leftover record; the wrapper copies the path under a private name first
- `contract-not-honoured` `shmutant.sh:195` `2a21cfc` `PRRT_kwDOUT7q9s6g-lEZ` PR #1 2026-09-10 — the hard-link preflight scanned the top-level .git the copy skips; now pruned
- `pipeline-status-lost` `docs/integrating.md:238` `2a21cfc` `PRRT_kwDOUT7q9s6g-lEi` PR #1 2026-09-10 — the migration step still recommended pool || bad; corrected to a bare call with status capture
- `timeout-escalation-cancelled` `shmutant.sh:430` `2a21cfc` `PRRT_kwDOUT7q9s6g-lEs` PR #1 2026-09-10 — kill_tree signalled only the presumed group, missing a root that shares its parent group; the root pid is now a target
- `contract-not-honoured` `shmutant.sh:629` `2a21cfc` `PRRT_kwDOUT7q9s6g-lE8` PR #1 2026-09-10 — the abort handler waited for every job including the caller own; now only its helpers
- `contract-not-honoured` `shmutant.sh:927` `2a21cfc` `PRRT_kwDOUT7q9s6g-lFB` PR #1 2026-09-10 — plan-load stdout reached the verdict stream; redirected to stderr
- `stale-artifact-reuse` `shmutant.sh:432` `1e01f36` `PRRT_kwDOUT7q9s6g_IuM` PR #1 2026-09-10 — the reaped root pid was signalled by number after a normal return; the root is now an identity-checked victim
- `early-return-skips-cleanup` `shmutant.sh:822` `1e01f36` `PRRT_kwDOUT7q9s6g_IuX` PR #1 2026-09-10 — post-prepare validation failures left the pristine tree; every such exit now goes through the pool failure helper
- `predictable-temp-path` `shmutant.sh:105` `1e01f36` `PRRT_kwDOUT7q9s6g_Iuf` PR #1 2026-09-10 — the stream path was reopened per record and could be swapped for a symlink by a callback; opened once as a descriptor
- `rewrite-loses-file-shape` `shmutant.sh:200` `1e01f36` `PRRT_kwDOUT7q9s6g_Iuk` PR #1 2026-09-10 — copy_tree left the destination root with default metadata; source root owner, mode and mtime applied after the copy
- `option-surface-mismatch` `shmutant.sh:812` `94ab7d5` `PRRT_kwDOUT7q9s6g_9Zo` PR #1 2026-09-10 — a stream path assigned by prepare passed validation but the descriptor stayed on the old path; reopened after prepare
- `path-escapes-root` `shmutant.sh:199` `94ab7d5` `PRRT_kwDOUT7q9s6g_9Zr` PR #1 2026-09-10 — a symlinked source root was scanned by find without following but copied by glob; resolved first
- `write-failure-swallowed` `shmutant.sh:228` `94ab7d5` `PRRT_kwDOUT7q9s6g_9Zx` PR #1 2026-09-10 — root metadata restore failures did not affect the copy status; folded in
- `timeout-escalation-cancelled` `shmutant.sh:694` `94ab7d5` `PRRT_kwDOUT7q9s6g_9Z5` PR #1 2026-09-10 — a directory recreation failure waited on running workers; they are now ended, and the kill freezes the tree first
- `option-surface-mismatch` `shmutant.sh:1045` `94ab7d5` `PRRT_kwDOUT7q9s6g_9Z9` PR #1 2026-09-10 — SHMUTANT_KEEP=1 in the environment was not honoured by an interrupt before the pool settled it; seeded in the parent
- `path-escapes-root` `shmutant.sh:203` `94ab7d5` `PRRT_kwDOUT7q9s6g_9aF` PR #1 2026-09-10 — a symlink at the copy destination was written through; refused
- `write-failure-swallowed` `shmutant.sh:492` `3535839` `PRRT_kwDOUT7q9s6hBFNc` PR #1 2026-09-10 — the leftover record was written by path after the callback could lock its dir; channels are descriptors opened before the callback
- `contract-not-honoured` `shmutant.sh:715` `3535839` `PRRT_kwDOUT7q9s6hBFNn` PR #1 2026-09-10 — the directory-failure abort waited on roots not its kill helpers; helper pids are waited for
- `path-escapes-root` `shmutant.sh:553` `3535839` `PRRT_kwDOUT7q9s6hBFNs` PR #1 2026-09-10 — cleanup followed a worker directory a callback replaced with a symlink; the directory is verified before removing beneath it
- `early-return-skips-cleanup` `shmutant.sh:806` `3535839` `PRRT_kwDOUT7q9s6hBFNy` PR #1 2026-09-10 — a preserved read-only root defeated rm -rf silently; trees are made writable first and a failed removal is a harness error
- `timeout-escalation-cancelled` `shmutant.sh:524` `3535839` `PRRT_kwDOUT7q9s6hBFN2` PR #1 2026-09-10 — the watchdog sent raw signals without freezing; it uses the freezing kill, which now stops in bulk before any identity work
- `timeout-escalation-cancelled` `shmutant.sh:432` `3535839` `PRRT_kwDOUT7q9s6hBFN5` PR #1 2026-09-10 — retained victims were not frozen or searched from; they are stopped and used as discovery roots
- `host-shell-option-leak` `shmutant.sh:565` `aa81620` `PRRT_kwDOUT7q9s6hDYRt` PR #1 2026-09-10 — the channel opens were plain redirections a caller noclobber refused; forced with >|
- `predictable-temp-path` `shmutant.sh:599` `aa81620` `PRRT_kwDOUT7q9s6hDYR0` PR #1 2026-09-10 — the timeout marker was still created by path after the callback started; now a FIFO opened before it
- `path-escapes-root` `shmutant.sh:657` `aa81620` `PRRT_kwDOUT7q9s6hDYR6` PR #1 2026-09-10 — after detecting a swapped worker directory the verdict was still written beneath it; now nothing is
- `stale-artifact-reuse` `shmutant.sh:650` `aa81620` `PRRT_kwDOUT7q9s6hDYR9` PR #1 2026-09-10 — a fresh directory with the worker directory name passed the spelling check; identity is by inode
- `stale-artifact-reuse` `shmutant.sh:498` `aa81620` `PRRT_kwDOUT7q9s6hDYSA` PR #1 2026-09-10 — the freeze stopped the root by number without identity after it was reaped; identity from spawn is required
- `contract-not-honoured` `shmutant.sh:838` `aa81620` `PRRT_kwDOUT7q9s6hDYSF` PR #1 2026-09-10 — with no worker started the failure path issued a bare wait that blocked on caller jobs; guarded
- `predictable-temp-path` `shmutant.sh:702` `aa81620` `PRRT_kwDOUT7q9s6hDYSJ` PR #1 2026-09-10 — the callback output was reopened by path for scoring; read once through the capturing descriptor
- `pipeline-status-lost` `docs/integrating.md:192` `aa81620` `PRRT_kwDOUT7q9s6hDYSO` PR #1 2026-09-10 — the timeout doc still claimed TERM then KILL; corrected
- `path-escapes-root` `shmutant.sh:194` `aa81620` `PRRT_kwDOUT7q9s6hDYSS` PR #1 2026-09-10 — a symlink component in the destination parent was followed; the destination is rebuilt on the physical path of its nearest existing ancestor
- `host-shell-option-leak` `shmutant.sh:988` `aa81620` `PRRT_kwDOUT7q9s6hDYSV` PR #1 2026-09-10 — prepare could pre-fill the baseline arrays; reset after prepare
- `early-return-skips-cleanup` `shmutant.sh:590` `e269c85` `PRRT_kwDOUT7q9s6hEhsU` PR #1 2026-09-10 — a callback with errexit that failed exited the wrapper before its snapshot; the snapshot is an EXIT trap
- `stale-artifact-reuse` `shmutant.sh:746` `e269c85` `PRRT_kwDOUT7q9s6hEhsZ` PR #1 2026-09-10 — the pool read a verdict by path from whatever directory had the name; verdicts are bound to the created inode
- `stale-artifact-reuse` `shmutant.sh:946` `e269c85` `PRRT_kwDOUT7q9s6hEhsf` PR #1 2026-09-10 — the stream cache was set before the open succeeded so a retry skipped the open; set after
- `predictable-temp-path` `shmutant.sh` `35a01fa` `PRRT_kwDOUT7q9s6hFRb5` PR #1 2026-09-10
- `host-shell-option-leak` `shmutant.sh` `35a01fa` `PRRT_kwDOUT7q9s6hFRb_` PR #1 2026-09-10
- `stale-artifact-reuse` `shmutant.sh` `35a01fa` `PRRT_kwDOUT7q9s6hFRcF` PR #1 2026-09-10
- `timeout-escalation-cancelled` `shmutant.sh` `35a01fa` `PRRT_kwDOUT7q9s6hFRcK` PR #1 2026-09-10
- `early-return-skips-cleanup` `shmutant.sh` `35a01fa` `PRRT_kwDOUT7q9s6hFRcQ` PR #1 2026-09-10
- `write-failure-swallowed` `shmutant.sh` `35a01fa` `PRRT_kwDOUT7q9s6hFRcb` PR #1 2026-09-10
- `config-value-unvalidated` `shmutant.sh` `35a01fa` `PRRT_kwDOUT7q9s6hFRce` PR #1 2026-09-10
<!-- adb:hits:end -->

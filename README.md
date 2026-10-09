# shmutant

Mutation testing for bash and POSIX shell: inject a defect, require the test that claims to
cover it to go red.

## The goal

Frameworks exist for *running* shell tests (Bats, ShellSpec, shtk) and for static analysis
(ShellCheck). None of them answers the question mutation testing answers: **does this test
actually detect the bug it claims to cover, or does it merely pass?**

`shmutant` is that tool. Its contract, in one sentence:

> Inject a specific defect into a shell file, run the test that claims to cover it, and require
> that test to go **red**. A test that stays green over an injected defect is not a test. It
> costs CI time and reports safety it never checked.

It is one vendorable file, `shmutant.sh`, with no runtime dependencies beyond bash 5.3,
the POSIX utilities. Source it as a library or run it as a CLI.

## The three verdicts

Each row of a mutation table names a defect (an old literal and its replacement) and a
**witness**: the assertion that must fail. A harness that only checks for "red" banks three
very different outcomes as passes. `shmutant` scores them apart, and only the first one counts:

| Verdict | Meaning |
|---|---|
| `killed` | The suite went red **on its witness**. The test detects the defect. |
| `survived` | The suite stayed green. Nothing here can detect this defect. |
| `accidental` | The suite went red, but not on its witness. Caught by accident, not by the assertion that claims to cover it. |

Two more verdicts guard the harness itself, because a mutation harness fails silently in
exactly the way the tests it checks do:

| Verdict | Meaning |
|---|---|
| `unapplied` | The old literal matched nothing. The row injected no defect and tests **nothing**. |
| `baseline` | The selected tests were not green before any defect was injected (red, or aborted: the red status with no red line), or, with `SHMUTANT_COUNTS=1`, did not count for each of their units the assertions the whole suite counts for it. A red result would prove nothing. |

And four that describe a run that never produced an answer: `aborted` (the suite exited
with a status other than green or red, or red without a failure line), `timeout`, `unsettled`
(the run's process tree kept forking out of reach while it was being ended, so nothing it did can
be trusted), and `lost` (the worker died without reporting). An empty mutation table is a hard
failure, not a pass.

## A worked example

A library, a test that covers it, and a mutation plan. The test exposes selectable units by
checking `SHMUTANT_SELECT`, so each row runs only the unit that claims to cover it.

```sh
# lib.sh
add() { echo $(( $1 + $2 )); }
```

```sh
# test.sh — prints "FAIL: <unit>: …" on failure, exits 1
. "$(dirname "$0")/lib.sh"
sel="${SHMUTANT_SELECT:-}"
if [ -z "$sel" ] || [ "$sel" = add-works ]; then
  [ "$(add 2 3)" = 5 ] || { echo "FAIL: add-works: got $(add 2 3)"; exit 1; }
fi
```

```sh
# mutants.sh — the plan
prepare() { shmutant_copy_tree "$SHMUTANT_PLAN_DIR" "$1"; }
run()     { bash "$1/test.sh"; }
shmutant_target lib.sh
shmutant_mut 'add subtracts'     '$1 + $2' '$1 - $2' 'add-works'
shmutant_mut 'add multiplies'    '$1 + $2' '$1 * $2' 'add-works'
```

```console
$ bash shmutant.sh run mutants.sh
shmutant	1	baseline	add-works	green	0.059	green before injection
shmutant	1	row	killed	add subtracts	lib.sh	add-works	0.320	went red on its witness
shmutant	1	row	killed	add multiplies	lib.sh	add-works	0.286	went red on its witness
shmutant	1	summary	mutants.sh	2	2	8	0.930
shmutant: mutants.sh: 2/2 mutation(s) killed on their own witness (jobs=8, 0.930s)
```

Change `'$1 * $2'` to `'$2 + $1'` and the second row comes back `survived`: the defect is
real, the test is green over it, and the exit status is 1.

## How a row is run

1. `prepare <dir>` is called **once** to build a pristine copy of the tree. The working tree is
   never mutated; a prepare that points outside its directory is refused. A row whose old
   literal occurs more than once in its target there is refused: the rewrite takes the first
   copy, which might not be the one the row means.
2. Every distinct selector is run once, uninjected, and must come back green (`baseline`). With
   `SHMUTANT_COUNTS=1` the whole suite also runs once, unselected, and each selection must count,
   per unit, the assertions the whole suite counts ([docs/integrating.md](docs/integrating.md)
   section 3).
3. For each row, the pristine tree is cloned, the old literal is replaced on its line, and
   `run <root> <select>` executes only the tests covering that selector.
4. The exit status and the output decide the verdict. Red is exit 1 with a line starting
   `FAIL: ` that carries the witness as a whole token (`parse-empty` is not found in
   `parse-empty-list`); both are configurable for TAP-style suites.

Rows run through a bounded pool (`SHMUTANT_JOBS`, capped at 8 by default), each with a timeout
that kills the whole process tree, so a mutated loop condition cannot hang CI.

## Why selection matters

The predecessor of this tool ran the **entire suite for every mutant**. On one project a
118-row table took 4,600 to 5,200 seconds per pass. The coverage map was already there, every
row declared its witness, but nothing used it to select work. `shmutant` passes the row's
selector to `run` and ships `shmutant_selected` so a hand-rolled suite can honour it in one line.

Its own self-mutation pass shows what selection buys. At commit `e139aca`, as timed by the steps
of [CI run 37385016734](https://github.com/BWBama85/shmutant/actions/runs/37385016734), the pass
over more than 350 rows took 940 seconds on `ubuntu-latest`, four rows at a time, where one run of
the whole suite took 412 seconds: running the whole suite for every row at that concurrency would
have taken over ten hours. On `macos-latest`, three rows at a time, the pass took 2,037 seconds
against a 451-second suite, where whole-suite runs would have taken over fourteen hours.

## Installation

Copy `shmutant.sh` into your project. Verify it against the published digest:

```sh
bash shmutant.sh version
bash shmutant.sh checksum          # compare with CHECKSUMS at the same tag
```

No submodules. Upgrading is copying a newer file. See [docs/integrating.md](docs/integrating.md)
for the adapter contract, Bats and ShellSpec adapters (CI runs both, as written, against pinned
releases), and migrating an existing harness.

## Machine-readable verdicts

Everything on stdout is a tab-separated record; prose goes to stderr. Fields never contain a raw
tab or newline (they are escaped as `\t` and `\n`).

```
shmutant  1  baseline  <select>  <verdict>  <seconds>  <detail>
shmutant  1  row       <verdict> <name>  <target>  <select>  <seconds>  <detail>
shmutant  1  summary   <label>   <rows>  <killed>  <jobs>  <seconds>
```

The second field is the stream format version. A baseline record's verdict is `green`, `red`,
`aborted`, `timeout`, `unprepared`, `unsettled`, `lost` or, with `SHMUTANT_COUNTS=1`, `incomplete`; that setting
adds one baseline record with an empty `<select>`, the unselected run. CI can consume it with
`awk -F'\t'`. Keep the
exit status of `shmutant` itself; behind a pipe it would be replaced by `awk`'s:

```sh
bash shmutant.sh run test/mutants.sh > mutants.tsv; rc=$?
awk -F'\t' '$3 == "row" && $4 != "killed"' mutants.tsv
exit "$rc"
```

Exit status: 0 when every row was killed, 1 when any row was not, 2 when the harness itself
could not run.

## Requirements

- bash 5.3 or newer. The entry point re-executes itself under a newer bash when it finds one
  (Homebrew paths, then `PATH`) and otherwise fails loudly with the platform's install command.
  macOS ships bash 3.2; put Homebrew's bin directory before `/bin` on `PATH`.
- the POSIX utilities: coreutils, `find` and `awk`, reached through `command -p`. Neither `jq` nor `cmp` is required. POSIX `ps`, when present, lets a timeout reach descendants that left the run's process group.
- `shellcheck --severity=warning -e SC1091` clean.

## Testing shmutant

```sh
bash test/run.sh                      # the suite: every `t_*` unit, one at a time
bash shmutant.sh run test/mutants.sh  # the suite, mutation-tested by shmutant itself
bash test/adapters/check.sh bats      # the doc's Bats adapter, on its fixture
bash test/adapters/check.sh shellspec # the same for ShellSpec
bash test/release.sh                  # the release driver, against a local origin with gh stubbed
```

The two adapter checks need the framework on `PATH` at the version CI pins (`BATS_VERSION`,
`SHELLSPEC_VERSION` in `.github/workflows/ci.yml`), which is the version the doc names. The
release test needs `git` and `jq`.

The second command is the tool's own proof: every guard in `shmutant.sh` is broken in a clone
and the unit that claims to cover it must go red. If `shmutant` could not mutation-test its own
assertions, it would not work.

The first two commands need to execute `ps`, the second because it runs `test/run.sh` for its
baseline and every row. The suite's units read process state through it, and some of their checks that a process
is gone would pass vacuously without it. Where there is no `/proc`, as on macOS, the leak check
after every unit reads the process table through it too, and fails a unit whose table it cannot
read instead of passing it. So
`test/run.sh` first checks that `ps` runs; where it cannot, it runs no unit, prints one
`run.sh: ps cannot run here …` line and exits 2.

An agent sandbox is the usual cause: on macOS `/bin/ps` is setuid root, and Claude Code's sandbox
refuses to execute it. This repository's `.claude/settings.json` lists `bash test/run.sh` in
`sandbox.excludedCommands`, which runs that command outside the sandbox. The entry has no wildcard,
and some call shapes stay sandboxed whatever the entry says: the suite stays sandboxed with an extra
argument, a `SHMUTANT_SELECT=…` prefix, a `cd` before it, a pipe after it or its output redirected
to a file. So do the second command and a gate script that runs the suite; run those outside the
sandbox another way, such as approving an unsandboxed retry. Sandboxed, the second command does not
name `ps`: its baseline aborts, every row is scored `baseline`, and it exits 1. A sandbox made
admin-required, by turning unsandboxed retries off in managed settings or with `--settings`,
ignores this repository's exclusion. The exclusion runs whatever `test/run.sh` and the
`shmutant.sh` it sources hold at the time with your full access.

## Releasing

The maintainer cuts a release with the project's `/release` skill
([.claude/skills/release/SKILL.md](.claude/skills/release/SKILL.md)), which drives
`scripts/release.sh`. To check a cut without making it:

```sh
env -u SHELLOPTS -u BASHOPTS -u BASH_ENV bash scripts/release.sh --dry-run 0.1.0
```

The `env -u` keeps shell options exported by the caller (such as `noexec`, which makes any bash
script exit 0 without running) from reaching the driver, and a run counts as passed only when its
last line says so, not on exit 0 alone.

The driver refuses unless a clean `main` at origin's head is green in CI and carries the version
being cut. It then tags that commit, publishes the GitHub release with `shmutant.sh` and
`CHECKSUMS` attached, and verifies that the install URL in `docs/integrating.md` serves the digest
in `CHECKSUMS`. The script's header lists every check.

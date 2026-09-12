# Integrating shmutant

How a project vendors `shmutant.sh`, wires its own suite to it, and migrates an existing
`check-lib.sh`-style mutation harness.

## 1. Vendor the file

Copy `shmutant.sh` into the project. One file, no submodule, no install step.

```sh
curl -fsSL -o scripts/shmutant.sh https://raw.githubusercontent.com/BWBama85/shmutant/v0.1.0/shmutant.sh
bash scripts/shmutant.sh version      # shmutant 0.1.0
bash scripts/shmutant.sh checksum     # compare against CHECKSUMS at that tag
```

`CHECKSUMS` in this repository carries the SHA-256 of `shmutant.sh` at every tag. Record the
digest you vendored beside the file (a comment in the plan, a line in your own CHECKSUMS) so an
upgrade or a local edit is visible in review.

Upgrading is copying a newer file and re-checking the digest.

## 2. The adapter contract

`shmutant` does not know your test framework. It calls two functions you write:

```
prepare <dir>          populate <dir> with the tree under test; optionally print the tree root
                       (default <dir>, must lie inside <dir>). Called ONCE per pool.
run <root> <select>    run the tests covering <select> inside <root>. SHMUTANT_SELECT carries
                       the same value. Exit 0 = green; exit 1 = red; anything else = aborted.
                       A red line starts with "FAIL: " and carries the row's witness.
```

The red status and prefix are configurable: `SHMUTANT_RED_STATUS`, `SHMUTANT_RED_PREFIX`.

What `prepare` copies decides most of the run time. Every row clones the prepared tree, so
copy only what the suite needs. `shmutant_copy_tree <src> <dst>` copies a checkout without its
`.git` directory, which on one measured repository was 14 MB of a 25 MB copy per row.

## 3. Make the suite selectable

This is the core of the design and the one thing a suite has to offer. A row's **witness** is
the text a red line must carry; its **selector** (defaulting to the witness) is what `run`
receives so it can execute only the tests that cover the defect. A suite that cannot select
still works: `run` ignores its second argument and runs everything, which is correct and slow.
Add selection when the pass gets long.

### Hand-rolled suites

`shmutant_selected <unit>` is true when no selection is active or when `SHMUTANT_SELECT`
equals `<unit>`. It counts every selected unit in `SHMUTANT_SELECTED_N`, so a suite can refuse
to pass on zero.

```sh
. scripts/shmutant.sh
if shmutant_selected 'removal keeps operator edits'; then
  ... assertions, each failing with: FAIL: removal keeps operator edits: <detail>
fi
[ "$SHMUTANT_SELECTED_N" -gt 0 ] || { echo "nothing selected"; exit 2; }
```

Prefix every `FAIL:` line inside a unit with the unit name, and witness and selector are the
same string. Where a unit holds several assertions and you want the witness to be one exact
assertion, pass a fifth argument to `shmutant_mut`: the witness is the assertion label, the
selector is the unit. A witness is matched as a whole token, never as a substring: where a
character precedes or follows it on the red line, that character is not a letter, a digit, `_`,
`-` or `.`. So `parse-empty` is carried by `FAIL: t_parse: parse-empty: got []` and not by
`FAIL: t_parse: parse-empty-list: got []`, whose assertion is a different one.

This repository's own suite (`test/run.sh`) is the reference: `t_*` functions selected by
name, a runner that exits 2 when nothing matched.

### Bats

Bats filters by test name with `--filter <regex>` and its `tap` formatter prints
`not ok <n> <name>` for a failure. Use test names as witnesses and anchor the filter:

```sh
prepare() { shmutant_copy_tree "$SHMUTANT_PLAN_DIR/.." "$1"; }
run() {
  local re
  re="$(printf '%s' "$2" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  bats --formatter tap --filter "^${re}\$" "$1/test"
}
shmutant_target lib/parse.sh
shmutant_mut 'empty input is accepted' 'return 1' 'return 0' 'parse rejects empty input'
```

Run with `SHMUTANT_RED_PREFIX='not ok '`. Confirm the exit status Bats uses for a failed test
on the version you run (`bats --version`; a one-test failing file is a five-second probe) and set
`SHMUTANT_RED_STATUS` if it is not 1.

### ShellSpec

ShellSpec selects examples with `--example <pattern>` and has a `--format tap` formatter.

```sh
run() { shellspec --format tap --example "$2" "$1/spec"; }
```

Run with `SHMUTANT_RED_PREFIX='not ok '`, and probe the failure exit status as above.

## 4. Write the plan

A plan is a bash file. The CLI sources it with `SHMUTANT_PLAN_DIR` set to its directory, then
runs the table, both in a subshell of the CLI: whatever the plan does there (an `exit`, an
`exec`, a trap, an assignment) stays there, and the CLI reports status 2 whenever the pool did
not run to completion. That completion is recorded through a descriptor whose file is unlinked
before the plan loads, so nothing a plan does by path can stand in for a finished pool (a plan
that writes to the descriptor itself is forging on purpose, which no harness sharing its process
can prevent). Anything the plan prints while loading goes to stderr; the CLI's stdout
carries verdict records only. Its `prepare` and `run` must be defined in the plan; functions exported
by the invoking environment are discarded first. `prepare` runs in the pool's own shell, so state it exports is visible to
`run`, and its own `set -e` is honoured: a prepare that aborts ends the run as a harness error.
Rows `prepare` declares with `shmutant_mut` are run too, and a declaration refused inside it is
the same harness error as one refused before it. `run` executes with errexit OFF whatever the
caller had: turn it on inside the callback if you want it. A pool refuses to run in POSIX mode,
or while a function in the shell stands in for `kill`, `wait`, `read`, `trap`, `printf`, `mapfile`,
`exec`, `cd` or `pwd`. Every utility the harness itself runs (`ps`, `awk`, `find`, `cp`, `ls`,
`mktemp`, …) is reached through `command -p`, so neither a function a plan defines under such a
name nor a `PATH` that `prepare` points at the tree's own `bin` is consulted by the harness; the
callbacks still see the shell as they left it.
`shmutant_copy_tree` and the per-row clones keep mode, ownership and timestamps, the root
directory included (a root whose metadata cannot be reproduced is a copy failure); a symlinked
source root is resolved first, a symlink at the destination is refused, and an existing
destination must be empty (the copy never removes or overwrites a caller's entries); a source with a multiply linked regular file outside its top-level `.git`
is refused by `shmutant_copy_tree`, since a copy cannot keep the links joined. A pool that
stops after `prepare` (a target the tree lacks, a setting `prepare` broke) removes the prepared
tree unless `SHMUTANT_KEEP=1`. The prepared tree is proven unmodified before every clone, by a
fingerprint of every entry's metadata and every file's content (POSIX `cksum`) taken after
`prepare` (the root's own mode, owner and timestamp included), and every clone is checked
against that fingerprint after the copy: a callback that writes into pristine (say through
`../../pristine` from its clone), adds to it, removes from it or changes a mode or a timestamp
— before a clone or while one is being taken — makes the affected rows
`unprepared`, with the reason, rather than running on what it left, whatever the timestamps
say. A prepared tree holding a regular file whose content the pool cannot read is refused
(status 2), since it could not be fingerprinted. A `prepare` that moves the workdir away and
puts another directory at its path stops the pool (status 2) and nothing at that path is
removed, by the CLI either. A `SHMUTANT_STREAM` file is checked at the end not only to be the
file the records went to but to hold, past what was there when it was opened, exactly the
records the pool wrote: a callback that truncates, overwrites or appends to it in place is a
harness error (status 2). The rewrite of a row's target is
pinned to the target's directory and re-checked to be inside the tree from there, so a
concurrent callback that swaps a directory component of a sibling's clone for a link cannot
redirect it (that row is `unprepared`). Both callbacks must be functions, builtins or
executables: an alias, which cannot be called by name, is refused (status 2). From the moment
`prepare` returns until the pool is done, the shell's CHLD, DEBUG, RETURN and ERR traps are
held (saved, disarmed, put back at the end): a handler `prepare` left cannot run inside the
pool. A setting the caller made `readonly` is accepted when it is already canonical (a plain
decimal; for `SHMUTANT_STREAM`, an absolute physical path) and refused with status 2 otherwise,
never assigned. `SHMUTANT_SELECT` is set by the pool for every run, so a readonly one is
refused (status 2) before any worker starts. Inside `shmutant_pool`, `shmutant_copy_tree` and
`shmutant_mutate` the shell's `expand_aliases` is off (bash parses a command substitution when
it runs it, so a caller's alias would otherwise reach the library at run time); callbacks run
there too, with the bodies they were given when defined; the caller's setting is put back on
return.

```sh
# test/mutants.sh
prepare() { shmutant_copy_tree "$SHMUTANT_PLAN_DIR/.." "$1"; }
run()     { bash "$1/test/run.sh"; }

shmutant_target lib/common.sh
shmutant_mut 'a leaf already present no longer blocks' \
  '| select( present($p) )' \
  '| select( false )' \
  'must refuse the whole fragment'

shmutant_target install.sh
shmutant_mut 'a below-floor CLI is written to anyway' \
  '[ "$major" -ge 5 ] ||' \
  'true ||' \
  'refuses a below-floor CLI'
```

Rules a row must satisfy, all enforced when the row is appended or the pool starts:

- literals only, never regexes; the **first** occurrence on a **single** line is replaced, and
  the file's mode and final-newline shape are preserved so the literal is the only change;
- the old literal is non-empty, contains no newline, and differs from the new one;
- the target file is relative to the tree root, carries no `..` component, and exists in the
  prepared tree as a regular file with one hard link (a symlink, a path whose physical location
  lies outside the tree because a directory component is a symlink, or a multiply linked file is
  refused, as is a directory component that is an absolute symlink, or a chain of links ending
  in one; a relative symlinked directory that stays inside the tree resolves to the real file);
- the witness is non-empty.

A refused declaration is counted, and a pool whose table carries one exits 2 rather than running
the rows that happened to be valid.

```sh
bash scripts/shmutant.sh run test/mutants.sh                # from the repo root
bash scripts/shmutant.sh run test/mutants.sh --jobs 4 --keep --workdir /tmp/mut
```

Or, as a library inside an existing suite:

```sh
. scripts/shmutant.sh
shmutant_target lib/common.sh
shmutant_mut ...
shmutant_pool "common-lib" "$work/mut" prepare run 6; rc=$?
[ "$rc" -eq 0 ] || bad "mutation pool failed ($rc)"
```

Capture the status on its own line, as above. Bash ignores `set -e` everywhere inside a function
that is the left side of `||` or `&&`, or the condition of `if`, so `shmutant_pool … || bad`
would also switch off a `set -e` inside your `prepare`; nothing inside the pool can undo that.
A `prepare` that must not continue past a failure should return non-zero explicitly.

## 5. Consume the verdicts in CI

Everything on stdout is a tab-separated record; prose goes to stderr.

```sh
bash scripts/shmutant.sh run test/mutants.sh > mutants.tsv; rc=$?
awk -F'\t' '$3 == "row" && $4 != "killed" { print $4 ": " $5 " (" $9 ")" }' mutants.tsv
exit "$rc"
```

Capture the status before the `awk`, and never put `shmutant` on the left of a pipe without
`pipefail`: the pipeline's status would be `awk`'s. Exit 0 means every row was killed; 1 means
at least one was not; 2 means the harness did not run (a refused declaration, empty table,
prepare failed, a target missing from the tree or a symlink, a root outside the workdir, a
stream write failure).
Keep `SHMUTANT_KEEP=1` and `--workdir` on a CI failure to upload `mut-<n>/output` as an
artifact: it is the full output of the run that produced the verdict. A `--workdir` you supply
is never removed; the pool's `base-<n>`, `mut-<n>` and `pristine` entries inside it are recreated
on every run. Those entries are only ever removed from a workdir shmutant marked as its own on
first use (a `.shmutant` file): a directory that already holds entries by those names and no
marker is refused, not emptied. Each worker reports its verdict on a descriptor the pool opened
before the worker forked, on a file with no name; nothing planted in a worker directory, by that
worker or by a sibling, can stand in for it, and a worker that did not exit normally is `lost`. A workdir the CLI created for itself is removed unless `--keep`, read-only trees
included; one that cannot be removed is reported and the run exits 2.

## 6. Tuning

| Variable | Default | Use |
|---|---|---|
| `SHMUTANT_JOBS` | CPU count | Worker budget, a positive integer. The pool's cap (argument 5, default 8, validated the same way) still applies. |
| `SHMUTANT_TIMEOUT` | 300 | Seconds per run before the run is killed. The kill freezes the tree first (SIGSTOP the root, then every descendant found, until a pass finds nothing new), adds every descendant the watchdog saw while the run was alive (snapshotted twice a second), and then sends KILL. There is no TERM and no grace, so a test runner's TERM handler does not run: after a deadline nothing may run. When a run returns normally, whatever it backgrounded is ended the same way before its verdict is accepted: its descendants are recorded on return, on `exit`, and by an EXIT trap of the wrapper the run executes in (a run that removes that trap and leaves through `builtin exit` or a signal to itself has dismantled the wrapper on purpose). The run's process group is kept in being by a holder process until that cleanup is over, so the group is ended by number whether or not `ps` can identify anything. A clone a run left behind that cannot be removed afterwards is a harness error (exit 2), and so is a `SHMUTANT_STREAM` file that a callback removed or replaced while the pool wrote to it. A run's output is scanned once, streaming, for the red prefix and the witness, so a suite that prints until its deadline costs disk, not memory. A process that detached into its own session within half a second of forking is out of reach; that needs cgroups or `setsid`, which this tool does not depend on. Raise the bound for a suite that cannot select; 0 disables. |
| `SHMUTANT_BASELINE` | 1 | Run every distinct selector once, uninjected, and require green. Set 0 when the suite was proven green in a previous step. 0 or 1 only. |
| `SHMUTANT_KEEP` | 0 | Keep every clone and the pristine tree. 0 or 1 only. |
| `SHMUTANT_STREAM` | stdout | Append the verdict stream to a file instead. Its directory must exist; it must be a regular file or absent (no symlink, no FIFO), outside the workdir. It is opened once, before any callback runs, and every record goes to that descriptor; a path `prepare` assigns is validated and opened the same way when it returns. A relative path is resolved where the CLI was invoked. |
| `SHMUTANT_RED_STATUS` | 1 | The exit status that means red, 1 to 255. |
| `SHMUTANT_RED_PREFIX` | `FAIL: ` | The prefix of a red line; must not be empty or contain a newline. |

Every setting is validated before the first run and again after `prepare` returns, since
`prepare` runs in the pool's shell and can assign any of them; the worker count is computed
after that second check, so a `SHMUTANT_JOBS` set by `prepare` is honoured. The pool's own
bookkeeping is protected from a `prepare` that uses ordinary names (`n`, `label`, `wd`) as its
own variables. While workers run, the pool traps INT and TERM to kill every active worker's
process tree, then restores the caller's own traps verbatim and re-delivers the signal. The CLI
does the same around its plan subshell, and removes a workdir it created unless `SHMUTANT_KEEP=1`.
A `SHMUTANT_KEEP=1` assigned inside the plan or `prepare` is honoured by the CLI's cleanup too. A baseline run that exits with a
status that is neither green nor red is recorded as `aborted`, not `red`.

## 7. Migrating a `check-lib.sh`-style harness

The predecessor API and its shmutant equivalent:

| Before | After |
|---|---|
| `check_mut <name> <old> <new> <witness>` | `shmutant_mut <name> <old> <new> <witness> [select]` |
| `check_mutation_pool <label> <workdir> <prepare> <run> <cap>` | `shmutant_pool <label> <workdir> <prepare> <run> [cap]` |
| `check_mutate_literal <file> <old> <new>` | `shmutant_mutate <file> <old> <new>` (same exit codes) |
| `check_mut_reset` | `shmutant_reset` |
| one prepare function per target file | `shmutant_target <file>` before the rows for that file |
| prepare prints the file to mutate, per row | prepare builds the tree once and prints its root (or nothing) |
| `run <copy-dir>` | `run <root> <select>` |
| scores into the caller's pass/fail counters | returns 0/1/2 and emits the verdict stream |

Steps, in the order that keeps the pass green throughout:

1. **Swap the harness, keep the shape.** Replace the four calls, add one `shmutant_target`
   line per group of rows, collapse the per-target prepare functions into one that builds the
   tree and prints its root. Let `run` ignore its second argument. Every row should still be
   killed, at the old speed.
2. **Point `shmutant_pool` at the tree, not at `.git`.** Use `shmutant_copy_tree` or copy only
   the directories the suite reads.
3. **Group assertions into selectable units.** Wrap each group of assertions that a row targets
   in `if shmutant_selected '<unit>'; then … fi`, and prefix that group's `FAIL:` lines with the
   unit name. Fixture setup the group depends on stays outside the guard. Do this one file at a
   time; a unit the suite does not yet guard simply runs on every selector.
4. **Pass the selector through.** `run` exports `SHMUTANT_SELECT` already; the suite only has to
   read it. Rows whose witness is not a unit name get a fifth argument naming the unit.
5. **Watch the `accidental` column.** Narrowing the run makes a witness that used to match a
   different assertion's echo show up as `accidental`. Each one is a row whose claim was never
   true; fix the witness, not the verdict.
6. **Drop the counters.** `shmutant_pool` returns 1 when any row was not killed, so the wrapper
   becomes `shmutant_pool …; rc=$?` followed by `[ "$rc" -eq 0 ] || bad "…"` (never
   `shmutant_pool … || bad`, for the errexit reason in section 4), and the stream carries the
   per-row detail CI used to parse out of prose.

## 8. What shmutant does not do

- It does not generate mutants from operators. Rows are literal and hand-written, which is what
  has been proven in production; an operator model can be layered on top later, deliberately.
- It does not measure line coverage. The coverage map is the table: every row names its
  witness and its selector.
- It does not require `jq`, `bats`, or any framework. It requires bash 5.3.

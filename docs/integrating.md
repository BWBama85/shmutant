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
selector is the unit.

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
runs the table.

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
- the old literal is non-empty and differs from the new one;
- the target file is relative to the tree root, carries no `..` component, and exists in the
  prepared tree as a regular file (a symlink is refused: name the file it points at);
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
shmutant_pool "common-lib" "$work/mut" prepare run 6 || bad "mutation pool failed"
```

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
on every run. A workdir the CLI created for itself is removed unless `--keep`.

## 6. Tuning

| Variable | Default | Use |
|---|---|---|
| `SHMUTANT_JOBS` | CPU count | Worker budget. The pool's cap (argument 5, default 8) still applies. |
| `SHMUTANT_TIMEOUT` | 300 | Seconds per run before the process group is killed. Raise it for a suite that cannot select; 0 disables. |
| `SHMUTANT_BASELINE` | 1 | Run every distinct selector once, uninjected, and require green. Set 0 when the suite was proven green in a previous step. |
| `SHMUTANT_KEEP` | 0 | Keep every clone and the pristine tree. |
| `SHMUTANT_STREAM` | stdout | Append the verdict stream to a file instead. |

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
   becomes `shmutant_pool … || bad "…"`, and the stream carries the per-row detail CI used to
   parse out of prose.

## 8. What shmutant does not do

- It does not generate mutants from operators. Rows are literal and hand-written, which is what
  has been proven in production; an operator model can be layered on top later, deliberately.
- It does not measure line coverage. The coverage map is the table: every row names its
  witness and its selector.
- It does not require `jq`, `bats`, or any framework. It requires bash 5.3.

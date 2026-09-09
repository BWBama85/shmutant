# shmutant

Mutation testing for bash and POSIX shell: inject a defect, require the test that claims to
cover it to go red.

## The goal

Frameworks exist for *running* shell tests (Bats, shellspec, shtk) and for static analysis
(ShellCheck). None of them answers the question mutation testing answers: **does this test
actually detect the bug it claims to cover, or does it merely pass?**

`shmutant` is that tool. Its contract, in one sentence:

> Inject a specific defect into a shell file, run the test that claims to cover it, and require
> that test to go **red**. A test that stays green over an injected defect is not a test. It
> costs CI time and reports safety it never checked.

It is one vendorable file, `shmutant.sh`, with no runtime dependencies beyond bash 5.3,
coreutils, `awk`, `grep` and `sed`. Source it as a library or run it as a CLI.

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
| `baseline` | The selected tests were already red before any defect was injected. A red result would prove nothing. |

And three that describe a run that never produced an answer: `aborted` (the suite exited
with a status other than green or red, or red without a failure line), `timeout`, and `lost`
(the worker died without reporting). An empty mutation table is a hard failure, not a pass.

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
   never mutated; a prepare that points outside its directory is refused.
2. Every distinct selector is run once, uninjected, and must come back green (`baseline`).
3. For each row, the pristine tree is cloned, the first occurrence of the old literal on a single
   line is replaced, and `run <root> <select>` executes only the tests covering that selector.
4. The exit status and the output decide the verdict. Red is exit 1 with a line starting
   `FAIL: ` that carries the witness; both are configurable for TAP-style suites.

Rows run through a bounded pool (`SHMUTANT_JOBS`, capped at 8 by default), each with a timeout
that kills the whole process tree, so a mutated loop condition cannot hang CI.

## Why selection matters

The predecessor of this tool ran the **entire suite for every mutant**. On one project a
118-row table took 4,600 to 5,200 seconds per pass. The coverage map was already there, every
row declared its witness, but nothing used it to select work. `shmutant` passes the row's
selector to `run` and ships `shmutant_selected` so a hand-rolled suite can honour it in one line.
Its own 45-row self-mutation pass finishes in under 20 seconds against a suite that takes 15 seconds to run once.

## Installation

Copy `shmutant.sh` into your project. Verify it against the published digest:

```sh
bash shmutant.sh version
bash shmutant.sh checksum          # compare with CHECKSUMS at the same tag
```

No submodules. Upgrading is copying a newer file. See [docs/integrating.md](docs/integrating.md)
for the adapter contract, Bats and shellspec adapters, and migrating an existing harness.

## Machine-readable verdicts

Everything on stdout is a tab-separated record; prose goes to stderr. Fields never contain a raw
tab or newline (they are escaped as `\t` and `\n`).

```
shmutant  1  baseline  <select>  <verdict>  <seconds>  <detail>
shmutant  1  row       <verdict> <name>  <target>  <select>  <seconds>  <detail>
shmutant  1  summary   <label>   <rows>  <killed>  <jobs>  <seconds>
```

The second field is the stream format version. CI can consume it with `awk -F'\t'`:

```sh
bash shmutant.sh run test/mutants.sh | awk -F'\t' '$3 == "row" && $4 != "killed"'
```

Exit status: 0 when every row was killed, 1 when any row was not, 2 when the harness itself
could not run.

## Requirements

- bash 5.3 or newer. The entry point re-executes itself under a newer bash when it finds one
  (Homebrew paths, then `PATH`) and otherwise fails loudly with the platform's install command.
  macOS ships bash 3.2; put Homebrew's bin directory before `/bin` on `PATH`.
- coreutils, `awk`, `grep`, `sed`. `jq` is never required.
- `shellcheck --severity=warning -e SC1091` clean.

## Testing shmutant

```sh
bash test/run.sh                     # the suite, 37 units
bash shmutant.sh run test/mutants.sh # the suite, mutation-tested by shmutant itself
```

The second command is the tool's own proof: every guard in `shmutant.sh` is broken in a clone
and the unit that claims to cover it must go red. If `shmutant` could not mutation-test its own
assertions, it would not work.

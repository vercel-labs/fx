# TLA+ models

One model per step of the design. Each one checks the protocol described in
`system-design.md`, not the Zig code. The bridge to the code is that every
invariant below also becomes a test assertion for the step it models.

**Status on 2026-09-27, when the first eight specs existed: all eight parsed
(SANY) and passed TLC, and each caught its planted bugs (`./mutants.py`).**
TLC2 2.19 (rev 5a47802), OpenJDK 27 on macOS arm64. The table below is from
that run; later specs and later model changes are not in it.

| Spec | States generated | Distinct states | Search depth | Result |
|---|---|---|---|---|
| `SessionLog` | 686 | 110 | 15 | No error |
| `TurnLifecycle` | 21,684 | 19,352 | 14 | No error |
| `WriterLock` | 3,257 | 1,016 | 24 | No error |
| `ResumeSnapshot` | 5,461 | 5,461 | 7 | No error |
| `Fork` | 375,727 | 51,776 | 16 | No error |
| `Subagents` | 204,097 | 120,297 | 23 | No error |
| `Catalog` | 645,269 | 94,482 | 19 | No error |
| `Lifecycle` | 9,553 | 144 | 13 | No error |

Every run explored the whole bounded state space (0 states left on the queue).

`Lifecycle`'s `PowerLoss` was widened on 2026-09-27, when trace validation
compared it with real disk behavior. A renamed but unsynced publish may also
vanish from both folders (when the `mkdir` of `.tmp/{id}` was never synced
either), and unsynced line 1 bytes may survive as well as vanish. The spec
still passes, and both of its mutants are still caught.

`Catalog`'s `Rebuild` was widened the same day to keep a `del` for every
tombstoned id after its fresh `put` lines, as the code does, so a deleted id
stays deleted through a rebuild and cannot be re-imported. The spec still
passes, and its mutant is still caught.

`Subagents` was widened on 2026-09-27 for D22 (the pre-wiring API check):
work numbers per child, at most one unfinished work item per child, `failed`
finishes and a parent `cancelled`. `LostMeansNoLog` became an action
property, checked on the step that writes the line, because a persistent
child marked lost for one work item may create its log with a later one.

`./mutants.py` plants realistic bugs, one or more per spec, and requires TLC
to report the matching invariant or action property as violated. The first
14, all caught on 2026-09-27:

- fsync acknowledging a half-written line
- open() keeping a torn tail
- reopen skipping `turn_interrupted`
- accepting an item outside a turn
- open ignoring the flock
- a snapshot with the wrong state
- a fork forgetting blob links
- a fork inside an open turn
- repair marking every child lost
- a spawn while the child's work is open
- reopen skipping child repair
- list skipping the folder check
- rename before the line 1 fsync
- ack before the directory fsync

## The specs

| Spec | Step (level) | What it proves | Invariants |
|---|---|---|---|
| `SessionLog.tla` | Log append, fsync, fx crash, machine crash, torn tail (L1) | Acknowledged lines survive a machine crash; only the final line can be torn; open() leaves no torn line | `SeqContiguous`, `OnlyTailTorn`, `AckedSurvive`, `OpenIsClean` |
| `TurnLifecycle.tla` | Turn rules, close, crash, reopen (L2) | The manager only writes valid turn transitions; close and reopen never leave a stale open turn; the log is only ever extended | `StartsWithCreated`, `AtMostOneOpenTurn`, `ItemsInsideTurns`, `EndsCloseATurn`, `ClosedOnlyBetweenTurns`, `NoStaleTurnAfterReopen`, property `AppendOnly` |
| `WriterLock.tla` | flock across processes, Session mutex across threads (L0, L2) | One writing process; file order equals seq order across threads and after takeover | `OneWriter`, `OnlyHolderOpen`, `MutexInsideOpenSession`, `SeqIsPosition` |
| `ResumeSnapshot.tla` | Fold and resume from a snapshot (L2) | Resuming from the newest snapshot equals a full replay; snapshots can be dropped | `ResumeEqualsFullReplay`, `SnapshotsAreIgnorable` |
| `Lifecycle.tla` | Lazy creation and publish (L2) | Nothing on disk before the first turn; a visible session has a durable line 1; an acknowledged first turn survives a machine crash | `VisibleHasLine1`, `AckedIsVisible`, `NothingBeforeFirstTurn` |
| `Fork.tla` | Fork and blobs (L2) | Every referenced blob exists; a fork keeps its prefix after the source changes or is deleted; forks start at turn boundaries | `RefsExist`, `ForkKeepsPrefix`, `ForkAtBoundary`, `FirstLine` |
| `Subagents.tla` | Children, persistent work, cancel, parent crash and repair (L2) | Every work item ends in a known state; one unfinished work item per child; `lost` only without a log; no orphan child logs | `OneOpenWork`, `FinishClosesOpenWork`, `NoOrphanChild`, `NoIndeterminate`, property `LostMeansNoLog` |
| `Catalog.tla` | index.jsonl, list self-heal, delete, rebuild (L3) | list never returns a missing session; a deleted id never comes back; rebuild is exact | `ListedAreLive`, `NoResurrection`, `IndexNamesPublished`, property `RebuildIsExact` |

Every spec also checks `TypeOK` where one is defined.

**What the `PowerLoss` action means.** It models a machine crash: the OS
goes down without flushing the page cache, and only synced bytes survive.
With D3's plain `fsync`, that covers:

- an OS crash (kernel panic or freeze) on every platform;
- a power cut on Linux.

A power cut on macOS can also lose recently synced data from the drive's own
cache. D3 accepts that, and it is outside these models. The action keeps its
name so the trace event contract and the mutants stay stable.

## Running

```sh
./check.sh                  # all specs
./check.sh SessionLog Fork  # some specs
./mutants.py                # every planted bug must still be caught
```

Requirements:

- OpenJDK: `brew install openjdk`. It is keg-only, so it is not on PATH;
  both scripts find it at `/opt/homebrew/opt/openjdk/bin/java`.
- `tla2tools.jar`: `~/.local/share/tla/tla2tools.jar`. Override the location
  with `TLA2TOOLS_JAR`.

`check.sh` runs TLC with `-deadlock`, because every model is bounded and stops
at its bound, and it keeps TLC's state files outside this folder. When you add
an invariant, add a mutant to `mutants.py` that breaks it.

## Checking the code, not just the design

The models above check the design. To check that the Zig code actually
behaves like them, the code writes a trace of its steps in test builds, and
TLC validates that trace against the same specs. See
[trace/README.md](trace/README.md).
fx's build compiles that hook out, so in this repository the trace tooling
runs on its self-tests, on logs fx saved, and on fx's `wiring` debug traces.

```sh
./trace/validate.sh SessionLog run.ndjson  # ACCEPTED, or REJECTED at step N
./trace/selftest.sh                        # the validator must accept and reject
```

The Bun drivers in `../drivers/session_manager/` run the real binary and have
TLC judge each run's saved logs and `wiring` trace: `runtime.test.ts` through
`fx ask`, and `fork.test.ts` through `/fork` in a terminal, including a fork's
log against `trace/ForkLog.tla` and planted faults that must be rejected.
`conversion/` opens, converts and salvages v1 sessions through every way fx
opens one, and `trace/check_conversion.py` judges each run against
`V1Conversion.tla`. Its v1 sessions come from built v1 writers: the last
commit with v1, older releases for older formats, and a scrubbed real session
in `conversion/fixtures/`. An older release builds only with its own Zig, which
`FX_RELEASE_ZIG` names; `FX_TLA_V1_WRITER` picks another release of the
current format, such as `v0.0.14`.

```sh
bun test ../drivers/session_manager/       # from this folder; needs tmux
FX_RELEASE_ZIG=/path/to/zig-0.16 bun test ../drivers/session_manager/conversion/
```

## What the models do not cover

- Byte encoding, JSON parsing and line size caps. Those are covered by unit
  tests.
- Byte offsets. `Fork.tla` copies lines as values, so it cannot see that a
  snapshot's `compaction_offset` moves when the fork's line 1 is longer; the
  driver found that, and the fork now encodes each copied snapshot again
  (`src/core/session_manager/session.zig` test "a fork after a compaction and snapshots").
- Which bytes open reads. `SessionLog.tla` recovers a whole log; the manager
  reads only line 1, the newest snapshot and what follows, so older damage
  is found by `read` and `verify` (`system-design.md` Reliability And
  Recovery; the driver's bit-flip cells cover every region).
- Code paths that no test runs. Trace validation (above) covers only the
  runs we execute.
- Performance. That is the benchmark in `system-design.md` Performance
  And Capacity.
- The fx adapter and host policy, such as when to offer "continue". Those are
  covered by fx E2E tests.
- Liveness (for example "every child eventually finishes"). The models check
  safety only. Liveness would need fairness assumptions about the model
  provider, which the manager does not control.
- Model bounds. Small bounds (2 or 3 ids, logs of 4 to 7 lines) find ordering
  and crash-window bugs, but they do not prove behavior at every size. Raise
  a bound in a spec's `.cfg` when a bug is suspected past it.

## Keeping the models honest

When a decision in `system-design.md` changes, update the spec that models
it in the same change. If TLC finds a counterexample:

1. If the spec is wrong, fix the spec.
2. If the design is wrong, fix `system-design.md` first, then the spec.

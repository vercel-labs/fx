# Trace validation: checking the code against the specs

TLC cannot read Zig. Instead, the implementation writes one JSON line per
step it takes, and TLC checks that the whole sequence is a behavior the spec
allows. A trace is **accepted** only if some behavior of the spec produces
exactly the logged states, step by step. Otherwise it is **rejected**, and
`validate.sh` names the first step the spec does not allow.

The models in `..` check the design exhaustively within their bounds. Trace
validation checks that the real code stays inside the design on every run
we execute: unit tests, the standalone driver, and the `kill -9` and
machine-crash matrix.

In fx, the manager's trace hook is compiled out: `build.zig` sets the
`hooks` option to false for every artifact it ships. `zig build test` also
runs the manager's own tests with `hooks` on, and they write their traces to
`zig-out/session-manager-traces/`, but nothing checks those traces against
the specs yet. The standalone driver and crash matrix are not part of this
repository. What runs here is `selftest.sh`, each checker's
`--selftest` mode, `check_saved_logs.py` on logs fx saved, and
`check_wiring_traces.py` on traces from a run with
`FX_TRACE_SCOPES=wiring`.

## How it works

```text
Zig test build             trace.ndjson            to_tla.py         TLC
------------------         --------------          ---------         ---
each L1/L2 step  ------->  {"event": "Fsync",  -->  TraceData.tla -->  SpecTrace.tla
emits one line              "log_len": 2, ...}      (Trace == <<...>>)  EXTENDS Spec, TraceData
                                                                        step l must be action
                                                                        Trace[l].event, and the
                                                                        next state must equal
                                                                        Trace[l]'s fields
```

- `SpecTrace.tla` extends the spec unchanged. It adds a counter `l` over the
  trace, and each TLC step must be the action named by `Trace[l].event`,
  landing in a state whose variables equal that line's fields.
- Nondeterministic actions such as `PowerLoss` are resolved by the logged
  state: TLC tries every choice and keeps the ones that match.
- The trick for the verdict: the invariant `TraceIncomplete == l <= Len(Trace)`
  is violated exactly when the whole trace was matched, so TLC reporting a
  violation means ACCEPTED. A state constraint prints the furthest line
  matched, which names the rejected step.

## Files

| File | Purpose |
|---|---|
| `validate.sh SPEC trace.ndjson` | Runs the check in a temp directory. Exit 0 accepted, 1 rejected, 2 tool error |
| `to_tla.py` | Converts JSON lines into `TraceData.tla`. Lists become sequences, objects records, `{"$set": [...]}` sets |
| `SessionLogTrace.tla`, `.cfg` | Wrapper for `SessionLog.tla`. The event contract is in its header |
| `stand_in_log.py` | A small Python stand-in for L1, used only to self-test this tooling |
| `check_saved_logs.py ROOT...` | Checks logs fx saved (`{id}/log.jsonl` under each ROOT) after the fact: every log against `TurnLifecycle`, every parent with child lines against `Subagents`, and every fork against its source with `ForkLog`. `--selftest` requires 7 good and 9 planted logs to get their verdicts |
| `ForkLog.tla` | A fork's copied lines against its source's: accepted only when they are the source's first lines byte for byte (snapshots aside, which a fork encodes again) and end at a turn boundary |
| `TurnLifecycleLog.tla`, `SubagentsLog.tla` | Its wrappers. Only the disk is known, so TLC searches the process state between lines; accepted when some behavior writes exactly the saved lines |
| `check_wiring_traces.py LOG...` | Checks the adapter's `wiring` trace lines (a run with `FX_TRACE_SCOPES=wiring`) against `Wiring.tla`: each process's lines become Start, the host steps and Exit, or Crash when it stops without Exit. A log where two processes overlap is skipped. `--selftest` requires 6 good and 8 planted traces to get their verdicts, the fork cases included |
| `WiringTrace.tla` | Its wrapper. Accepted when every step is allowed in turn; the usage steps change nothing a traced step reads, so they are left out |
| `check_conversion.py --request R --report D` | Checks a recorded v1-to-v2 conversion run against `V1Conversion.tla` (D59): each step's result on disk and through fx's own readers and listing. Exit 0 ACCEPTED only when TLC matched every observation, 1 REJECTED, 2 INCONCLUSIVE, 3 TOOL_ERROR. `--selftest` requires its good and planted runs to get their verdicts |
| `V1ConversionTrace.tla` | Its wrapper. Each observation's step kind limits the model actions that may run before it; a request step makes exactly one request, and only a writer an earlier hold step left running may write during it |
| `PromptImagesTrace.tla`, `.cfg` | Checks a run of `drivers/session_manager/prompt-images.test.ts` against `PromptImages.tla` (D89): each turn's first request, its user item, and the session's blobs folder, with every save, failed save and process exit between them left to TLC. A note counts only when it names the image's own blob |
| `selftest.sh` | Proves the tooling both accepts and rejects (below) |

## Self-test

`./selftest.sh` runs the stand-in three ways and requires these verdicts:

| Case | Required verdict |
|---|---|
| Correct stand-in (writes, fsync, a crash in the middle of a write, recovery, a machine crash that tears a line, recovery) | ACCEPTED, 15 steps |
| Recovery keeps a torn tail (planted bug) | REJECTED at step 8, the `Recover` |
| Good trace with `acked` changed from 2 to 3 on line 5 | REJECTED at step 5 |

Last run: 2026-09-27, TLC2 2.19. All three verdicts matched.

## The contract for the Zig trace hook

These rules apply to the test-only trace hook, `src/core/session_manager/trace.zig`:

1. **Test builds only.** The hook is behind a build option and compiles to
   nothing in release builds, so it adds no cost and no I/O to fx.
2. **One line per spec action,** named exactly like the action in the spec
   (`BeginWrite`, `Fsync`, `Recover`, ...), with one field per spec variable
   under the names in the wrapper header.
3. **Real state, not bookkeeping.** Fields that model the disk (line count,
   torn tail, seq numbers, which folders exist) are computed by reading the
   actual files after the step. Fields that model memory (status, acked, open
   turn) come from the manager's own state. A trace built only from the
   writer's counters would agree with itself and prove nothing.
4. **One order.** Steps inside a Session are emitted while holding the
   Session mutex, so the trace order is the real order. Multi-process tests
   (`WriterLock`) run through the standalone driver, which serializes the
   steps of all processes into one trace.
5. **Crashes are logged by the driver.** A killed process cannot log its own
   crash. After `kill -9` or a simulated machine crash, the driver appends the
   `ProcessCrash` or `PowerLoss` line, reading the disk state itself.
6. **Every trace gets checked.** The driver runs `validate.sh` on every trace
   it produces, and any rejection fails the run.

## Adding a wrapper for another spec

Copy `SessionLogTrace.tla` and change three things:

- `EXTENDS` names the new spec.
- `Matches(e)` compares every variable of that spec with the fields of `e`.
- `Act(e)` maps each event name to the spec's action. For an action with
  parameters, such as `Write(k)` or `Open(p)`, the line carries the argument,
  and `Act` passes it on, for example
  `[] e.event = "Write" -> Write(e.kind)`.

Keep `TraceInit`, `TraceNext`, `Progress` and `TraceIncomplete` as they are,
and copy the `.cfg`, setting the spec's constants large enough for real
traces. Then add a stand-in case, or a real Zig test, that the new wrapper
must reject. A wrapper that has never rejected anything is not yet trusted.

Each of these wrappers has rejected its planted bug: `TurnLifecycleTrace`,
`WriterLockTrace`, `ResumeSnapshotTrace`, `LifecycleTrace`, `ForkTrace`,
`SubagentsTrace` and `CatalogTrace`.

## Limits

- **Guard with IF, never with `\/`, inside `Matches`.** Within an action,
  TLC explores both sides of a disjunction, so
  `Len(log') = 0 \/ log'[Len(log')].done` still indexes an empty sequence and
  ends in a tool error. The first Zig traces (an `Fsync` and a `Recover` on an
  empty log) found this in `SessionLogTrace.tla`; it now uses IF.

- **Give every TLC run its own `java.io.tmpdir`.** TLC unpacks `TLC.tla`,
  `Naturals.tla` and the other standard modules there. With a shared
  folder, parallel checks read each other's half-written copies and fail
  with "Fatal errors while parsing". `validate.sh` points it into the
  run's private work folder, and `check_saved_logs.py` and
  `check_wiring_traces.py` give each parallel check its own (`JOBS`,
  default 6).
- **A batch is one write; trace views end at the observed line.** The
  manager writes each batch in one append, observed or not, so traced runs
  and the crash matrix see production's write pattern (a process kill never
  splits a batch). Its lines are observed one by one after the write, so
  a tracer that reads the log bounds its view by the observed line's seq.
- **Only what runs is checked.** Trace validation checks the runs we
  execute. That is why the driver's crash matrix matters: it decides which
  code paths get traced.
- **The mapping from files to spec state must be right.** A wrong mapping can
  hide a bug. Keep it small, and read the real files (rule 3).
- **Traces must fit the model's constants.** `SessionLogTrace.cfg` raises
  `MaxLines` to 64 for that reason, and `TurnLifecycleTrace.tla` sets
  `TraceMaxLen` to 4096 for the driver's host models, whose logs run to
  hundreds of lines. A longer trace is rejected at the bound, so raise the
  constant or split the trace. In a trace check the bound adds no states:
  the trace fixes every step.
- **TLC 2.19 plus the Community Modules jar crashes**
  (`NoClassDefFoundError: tlc2/value/impl/KSubsetValue`). That is why the
  converter exists instead of `Json!ndJsonDeserialize`. Revisit when a TLC
  release matches the modules jar.

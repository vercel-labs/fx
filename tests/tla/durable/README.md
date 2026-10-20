# Durable libfx models

One model per safety boundary of durable libfx sessions (`sdk/fx-sdk.js`). Each
checks the protocol, not the code. `check.sh` runs every spec, and `mutants.py`
plants realistic bugs and requires TLC to catch each one.

| Spec | Boundary | What it proves |
|---|---|---|
| `Journal.tla` | Pipelined appends, barriers, rejected writes, crash, restore | Durable plus in-flight is exactly what the kernel sent, in order; the kernel only passes a durable barrier |
| `ToolReplay.tla` | Intent before effect, `replay: "safe" \| "never"`, crash anywhere | A never tool runs at most once and only after its durable intent |
| `ParallelBatch.tla` | Parallel by default, `writes: true` as a fence, results in model order | A writer never overlaps another call, and nothing passes a writer |
| `Fencing.tla` | Two processes on one World log with conditional appends | One intent, one outcome, one run across processes |
| `Inbox.tla` | Prompts, steers, and follow-ups through the journal; withdraw | A resolved promise means durable, and each input is placed once |
| `Resumption.tla` | Resuming a turn a crash cut off, including after its reply was saved; inputs the turn accepted and never placed | fx never asks, every crash of an open turn is resumed, the model is told, a saved reply is delivered without asking the model again unless an input waits, every input reaches the model or is handed back, the turn's durable end says how it ended, `turn.result` waits for that end and says what it says, even when a cancel came while that end was on its way |
| `SnapshotTail.tla` | `load()` returning a snapshot plus the events after it | Snapshots only cover durable events, and restore replays the tail exactly once |

Every spec also checks `TypeOK`.

```sh
./check.sh                   # all specs
./check.sh Journal Fencing   # some specs
./mutants.py                 # every planted bug caught, every witness reached
./mutants.py ParallelBatch   # checks for one spec
```

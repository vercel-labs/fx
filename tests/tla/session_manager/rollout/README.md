# Session rollout models

Protocol models for the pull requests that moved fx onto the session manager:
`fx ask`, interactive sessions, running tools, ACP, subagents, commands, the
test harness, steering, queued input, and blobs, checkpoints, migration,
records, and terminals. Each folder holds one or more models, a smoke and a
stress config for each, and the planted bugs in `mutants.json`.

| Model | What it covers |
|---|---|
| `pr-1072/PR1072Ask.tla` | Ask backend selection, no-save, acknowledged pieces, usage markers and interrupted resume |
| `pr-1073/PR1073Interactive.tla` | Interactive resume/switch, busy picker admission, continuation, relaunch and child join ordering |
| `pr-1076/PR1076RunningTools.tla` | Call-before-execution, real/partial results, sticky first OS failure |
| `pr-1079/PR1079ACP.tla` | ACP lazy creation, whole-history replay, compaction boundary, preferences and workspace updates |
| `pr-1081/PR1081Subagents.tla` | Persistent child work, backend inheritance, crash repair, parent lifetime and hidden child discovery |
| `pr-1082/PR1082Commands.tla` | Read-only inspection, safe-prefix recovery, root listing, tombstones and orphan cleanup |
| `pr-1091/PR1091Harness.tla` | tmux backend environment and explicit 168-cell end/fault/reentry coverage accounting, not product fault semantics |
| `pr-1092/PR1092Steering.tla` | Cancelled turn selection of marked steering/restored steering/feedback with stable tool-step anchors |
| `pr-1099/PR1099FIFO.tla` | FIFO cleanup reader lifetime and eventual join under explicit scheduler/I/O fairness |
| `pr-1116/PR1116Blobs.tla` | Whole streamed bodies, immutable session blobs, references and original-file deletion |
| `pr-1116/PR1116Migration.tla` | Resumable older-v2 handle/settings migration with blob/map/terminal/removal order |
| `pr-1116/PR1116Terminal.tla` | Hosted-terminal state independent of app lifetime, resume lookup and age-gated orphan folder cleanup |
| `pr-1116/PR1116ChildCheckpoint.tla` | Child turn checkpoint before effects; crash repair distinguishes not-started lost work from interrupted work |
| `pr-1116/PR1116Records.tla` | Compactor record aliases, durable client settings and fork-owned record blobs |

Models that mention usage markers describe the usage ledger fx had when these
changes landed; fx no longer records one.

```sh
./run.py list
./run.py check                 # every model, smoke configs
./run.py check --preset stress
./run.py mutate                # every planted bug must be caught
```

`../../drivers/session_manager/runtime.test.ts` runs the real fx binary and
checks its saved sessions and wiring traces against the trace wrappers in
`../trace/`.

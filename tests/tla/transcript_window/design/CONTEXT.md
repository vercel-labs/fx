# Context: the transcript today

Line numbers are for `main` at 15bb35bae, before the window. They move with
edits; the symbol names do not. This file describes the transcript before the
window, which removed the byte cap and its trimming; those rows are kept as
the baseline.

## Entry points

| Trigger | First owner | Where |
|---|---|---|
| A worker event (text, tool lifecycle, notice) | `drainEvents`, once per loop iteration, applying the whole queued batch | `src/core/app/app_worker_runtime.zig:895` |
| Streamed assistant text | the pacer emits complete prefixes into `pacerEmit` | `src/ui/assistant/pacer.zig:257`, `src/main.zig:2552` |
| The pacer's text reaching the transcript | `streamAssistantChunk` | `src/ui/transcript/runtime.zig:6833` → `src/ui/transcript/store.zig:3661` |
| A tool status line changing in place | `replacePinnedToolStatusAtomicInternal` | `src/ui/transcript/store.zig:1729` |
| A compaction | `workerBridgeContextCompaction` → the session runtime, not the transcript | `src/core/app/app_callbacks.zig:1564` |
| The loop | collect facts, poll with a timeout, commit a frame | `src/ui/event_loop.zig:76`, `src/main.zig:2846`, `:2992` |
| A settled resize | clears scrollback and replays the viewport | tests `settled resize emits a replay_viewport pass` and `settled resize with rows-only change resets terminal scrollback` in `src/ui/resize_tests.zig` |
| Ctrl+O | a page of at most 256 in-memory entries, prepared by a worker | `src/core/output/full_transcript_page.zig:3`, `:25`; `src/ui/transcript/full_transcript_worker.zig:15`, `:66` |
| Resume | the saved log projected into entries under the retention cap | `src/ui/transcript/resume_projection.zig:21`, `:35` |

## Data flow on one update

```text
worker event
  -> drainEvents applies the whole batch                    app_worker_runtime.zig:895
  -> streamAssistantChunk
       fast path when the chunk fits under the cap          store.zig:3103
       slow path: clone the runtime state                   store.zig:2104
                  prepare the whole transcript source       source_preparation.zig:456
                  rebase when retention changed             store.zig:3496
  -> commit: prepare the whole source again                 store.zig:2189
             rebase when painted rows were rewritten        store.zig:3496
  -> frame: prepare the source unless a commit's is adopted runtime.zig:10561
            index every line                                source_preparation.zig:360
```

Rendering every retained entry into one flow happens in `renderEntriesToBytes`
(`src/ui/render_engine/transcript_blocks.zig:2545`), and tool groups are formatted
again on each preparation (`src/ui/transcript/tool_group_projection.zig:1164`).

## Who owns each piece of state

| State | Owner | Where |
|---|---|---|
| Entries, tool details, command output blocks | `TranscriptRuntime` | `src/ui/transcript/runtime.zig` |
| Retention cap, 1 MiB by default (removed by the window) | `TranscriptRuntime.max_retained_transcript_bytes` | `runtime.zig:4295`, `:4643` |
| Which bytes count against the cap | `retainedStructuredBytes`, `entryRetainedBytes` | `store.zig:167`, `:175` |
| Trimming to the cap (removed by the window; the orphan cleanup it ran is `pruneOrphanedCommandState`) | `enforceStructuredRetentionAndReport`, `enforceStructuredRetentionWithTrims` | `store.zig:924`, `:945` |
| What the committed frame painted | the commit state and its retention identity | `runtime.zig:7380` |
| Released rows waiting to publish | `settleTranscriptPublication` | `store.zig:3458` |
| A tool's full record | `ToolDetailRecord`: name, arguments, result or blob handle, replay | `src/ui/render_engine/transcript_blocks.zig:55` |
| The session history | the session log and its blobs | `src/core/session/session_adapter.zig:10` |
| Where the newest compaction starts | `snapshot.compaction_offset` | `src/core/session_manager/fold.zig:234`; `tests/tla/session_manager/system-design.md:221`, `:240` |

## Saved formats and contracts that stay

- The session log is append-only JSON lines: items per completed turn piece,
  `turn_started`, `turn_committed`, `compacted` records, `set` values, and
  `snapshot` records; large bodies are blobs named by hash
  (`session_adapter.zig:10`). This design reads it and changes nothing in it.
- `snapshot.compaction_offset` is the byte offset of the newest `compacted`
  record, written after each compaction and about every 64 KB
  (`tests/tla/session_manager/system-design.md:221`, `:240`, `:248`).
- `--no-save` sessions write no log (`src/builtins/commands.zig:52`).
- Inline rendering: the conversation is printed into the normal terminal, so
  rows that scroll off belong to the terminal. Only the alternate-screen owners
  (approval review, Ctrl+O, menus) take the other buffer (`AGENTS.md`,
  "Reproducing Render Bugs").

## Measurements behind the problem

Measured on this machine during the investigation that led here, not committed:

- 677 saved sessions, 68 with compactions, 345 cycles that ended in a compaction.
  Text you and the assistant wrote per cycle: typical 1.1 MB, 9 in 10 under
  1.4 MB, largest 3.9 MB. Tool calls per cycle: typical about 330, largest 1,243.
- A 40-turn workload with 2,400 tool calls: once past the cap, each streamed
  chunk of the last answer took the slow path, about 50 commits of 37 to 39 ms.
  Trimming to 1/16 below the cap removed all but one and cut that turn from
  7.3 s to 3.1 s, which confirmed the cause.
- Long interactive sessions use 47 to 111 MB of resident memory; the 1 MiB cap
  is a small part of what the transcript holds.

## Code that makes the wrong design look easy

- `max_retained_transcript_bytes` (`runtime.zig:4643`) invites tuning a byte cap,
  but trimming the front of the list breaks every prefix-based reuse, so each trim
  is a full rebuild.
- `adoptCommittedTranscriptSource` (`runtime.zig:10561`) invites caching a
  prepared source. It removes one preparation but none of the rebuilds the
  retention trims cause; an experiment that adopted every commit's source gave no
  gain on the slow turn.
- `full_transcript_worker.Source` copies entries (`full_transcript_worker.zig:66`),
  which makes Ctrl+O from memory look natural and ties its reach to the cap.
- `commitAssistantStreamChunkFast` (`store.zig:3103`) refuses a chunk only because
  the cap is exceeded, which hides that the cap itself sets the cost.

## Fakes the drivers may use

The drivers run the real core through `tests/tla/drivers/transcript_window/harness.zig`.
The only fakes are the shell's effect handlers at the edge:

| Fake | Stands in for | Why it is allowed |
|---|---|---|
| A recorded paint list | painting rows and slices to the terminal | the core decides what is painted, not how |
| A recorded drop list | freeing a block's text | freeing is a shell effect |
| A simulated log | reading older blocks from the session log | the reply is an event; faults are injected here |
| Driver-chosen save watermarks | the session log confirming writes | the confirmation is an event the shell feeds in |

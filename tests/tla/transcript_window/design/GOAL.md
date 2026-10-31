# Goal: one compaction cycle on the main screen, all of history in Ctrl+O

The core this model checks is `src/ui/transcript/transcript_window.zig`. The
transcript runtime drives it for every session, and it replaces the
transcript's byte cap.

## Problem

In a long session every transcript update costs time proportional to everything
the main screen keeps, not to the change:

- The main screen keeps up to 1 MiB of structured entries
  (`src/ui/transcript/runtime.zig:4295`, `:4643`), and that budget counts only
  entry text (`src/ui/transcript/store.zig:175`). Tool records, their copies, and
  caches are not counted.
- A recorded mutation clones the entries (`store.zig:2104`), prepares the whole
  transcript source again (`store.zig:2189`), and rebases against what was
  painted when it rewrote painted rows (`store.zig:3496`).
- Past the cap, each growing chunk trims exactly to the cap
  (`store.zig:945`), so the next chunk is over it again and takes the slow path
  (`store.zig:3103`, `:3661`). Measured: about 50 slow commits of 37 to 39 ms each
  in one 150-line answer.
- Ctrl+O builds its pages from the same in-memory entries
  (`src/core/output/full_transcript_page.zig:3`, `:25`;
  `src/ui/transcript/full_transcript_worker.zig:66`), so it cannot show history
  older than what the main screen kept.

## Success criteria

Each criterion is a check that passes.

| ID | Criterion | Check |
|---|---|---|
| G1 | The main screen holds the current compaction cycle and, until the first turn end after a compaction, the previous one. Nothing older. | TLC invariant `HeldIsRecentCycles`; code-to-spec traces |
| G2 | A live block (streaming answer, running tool, open tool group) is never dropped. | TLC invariant `LiveNeverDropped` |
| G3 | In a saved session, a finished block leaves memory only after the session log holds it. | TLC invariant `DropOnlySaved` |
| G4 | A transcript update produces effects for the changed block only. | TLC invariant `UpdateIsLocal`; core unit tests |
| G5 | Every finished block is painted once per screen, in finish order. | TLC invariant `PaintOnceInOrder` |
| G6 | A settled resize clears and reprints exactly the held blocks, in order, in slices of at most `Slice` blocks, and finishes unless another resize or a resume starts over. | TLC invariants `ReprintInOrder`, `ReprintSliceBound`; property `ReprintFinishes` |
| G7 | Ctrl+O opens on the newest blocks from memory without reading the log; scrolling past memory reads the log; it never holds more than `Window` blocks or more than one read. | TLC invariants `CtrlOWindowBound`, `OneReadInFlight`, `OpenReadsNothing` |
| G8 | A stale, duplicate, lost, or reordered log read changes nothing it should not. | TLC invariant `StaleReadIgnored`; fault actions in the model and the drivers |
| G9 | Scrolling up in Ctrl+O reaches the start of the session when reads keep answering. | TLC property `CtrlOReachesStart` |
| G10 | After a compaction, the previous cycle is dropped once its turn has ended and the log holds it. | TLC property `PreviousCycleDropped` |
| G11 | The core is pure: it imports only `std`, reads no clock, does no I/O. | `verify` source check on `transcript_window.zig` |
| G12 | A crash keeps only what the log holds, and recovery holds exactly the last cycle. | TLC invariant `RecoveredFromLog`; crash actions in the drivers |

## Non-goals

- Changing how in-place lines work: tool status lines, tool groups, and
  streaming blocks keep today's logic. The core sees them only as live blocks.
  Any change to that logic needs the user's approval first.
- Changing the session log format or what it records.
- A memory cap per cycle. Compaction is always on, and a cycle's text is bounded
  by the model's context (assumption A1 in `DESIGN.md`).
- Faster rendering of one block. The core decides what is painted and read, not
  how a block is drawn.

## 100% done

All of these hold at the same commit:

1. `tests/tla/transcript_window/check.sh` exits 0: TLC on every config, spec to
   code over every graph edge, code to spec with faults, every planted bug in the
   spec and in the core caught, and the traceability check.
2. `zig build test` passes with the core's inline tests.
3. The binary driver runs the built
   `zig-out/bin/fx` through streaming, compaction, resize, and Ctrl+O, and TLC
   accepts every observed run.
4. The S1 workload (40 agentic turns, 2,400 tool calls) has no main-thread
   stretch over 100 ms from transcript work, and its last turn is no slower than
   on `origin/main`.
5. Every limit that remains is listed under Final design in `DESIGN.md`.

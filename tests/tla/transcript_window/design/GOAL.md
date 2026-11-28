# Goal: full current session on the main screen, full history in Ctrl+O

The core this model checks is `src/ui/transcript/transcript_window.zig`. The
transcript runtime drives it for every session, and it replaces the
transcript's byte cap.

## Problem

In a long session:

- The main screen previously kept up to 1 MiB of structured entries
  (`src/ui/transcript/runtime.zig:4295`, `:4643`), or dropped previous
  compaction cycles from memory at the next turn end. Resizing after a
  compaction then lost earlier prompts and steps of the current session.
- Conversely, retaining post-head command output lines, full `tool_details.result`
  buffers, `command_output_replay`, and closed Ctrl+O caches
  (`full_transcript_installed_page`, empty `transcript_archive`) dominates
  transcript runtime memory even though a resize never needs them.
- Ctrl+O still needs access to older cycles after a `/resume` and to full
  command/tool output from the session log when opened.

## Success criteria

Each criterion is a check that passes.

| ID | Criterion | Check |
|---|---|---|
| G1 | The main screen holds the whole current session across compactions and turn ends, dropping blocks only on session change (`/new`, `/resume`, `/clear`). | TLC properties `HeldIsCurrentSession`, `NoDropDuringSession`, `CompactionKeepsHistory`; code-to-spec traces |
| G2 | A live block (streaming answer, running tool, open tool group) is never dropped. | TLC invariant `LiveNeverDropped` |
| G3 | Every drop occurs only on session change and covers only the departing session's held range. | TLC invariant `DropOnlyOldSession` |
| G4 | A transcript update produces effects for the changed block only. | TLC invariant `UpdateIsLocal`; core unit tests |
| G5 | Every finished block is painted once per screen, in finish order. | TLC invariant `PaintOnceInOrder` |
| G6 | A settled resize clears and reprints exactly the held blocks, in order, in slices of at most `Slice` blocks, and finishes unless another resize, a resume, or a session clear starts over. | TLC invariants `ReprintInOrder`, `ReprintSliceBound`; property `ReprintFinishes` |
| G7 | Ctrl+O opens on the newest blocks from memory without reading the log; in a fresh session every block is in memory, while in a resumed session scrolling past memory reads the log; it never holds more than `Window` blocks or more than one read. | TLC invariants `CtrlOWindowBound`, `OneReadInFlight`, `OpenReadsNothing` |
| G8 | A stale, duplicate, lost, or reordered log read changes nothing it should not. | TLC invariant `StaleReadIgnored`; fault actions in the model and the drivers |
| G9 | Scrolling up in Ctrl+O reaches the start of the session when reads keep answering. | TLC property `CtrlOReachesStart` |
| G10 | Leaving or clearing a session drops all held blocks of the departing session. | TLC property `OldSessionDroppedOnChange` |
| G11 | The core is pure: it imports only `std`, reads no clock, does no I/O. | `verify` source check on `transcript_window.zig` |
| G12 | A crash keeps only what the log holds, and recovery holds the log's last cycle. | TLC invariant `RecoveredFromLog`; crash actions in the drivers |

## Non-goals

- Changing how in-place lines work: tool status lines, tool groups, and
  streaming blocks keep today's logic. The core sees them only as live blocks.
- Changing the session log format or what it records.
- Faster rendering of one block. The core decides what is painted and read, not
  how a block is drawn.

## 100% done

All of these hold at the same commit:

1. `tests/tla/transcript_window/check.sh` exits 0: TLC on every config, spec to
   code over every graph edge, code to spec with faults, every planted bug in the
   spec and in the core caught, and the traceability check.
2. `zig build test` passes with the core's inline tests and the new retention and
   payload-freeing tests.
3. The binary driver runs the built
   `zig-out/bin/fx` through compaction cycles, resize, Ctrl+O, and resume, and
   TLC accepts every observed run.
4. Heavy repro memory census shows reduced RSS/PSS and identical resize reprints.
5. Every limit that remains is listed under Final design in `DESIGN.md`.

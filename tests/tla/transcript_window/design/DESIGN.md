# Design: the transcript window core

`src/ui/transcript/transcript_window.zig` is the core. With
`FX_TLA_NEXT_TRANSCRIPT_WINDOW=1` the transcript runtime drives it through
`src/ui/transcript/transcript_window_shell.zig`; "In fx" below says which of
its effects fx runs.

The architect questionnaire was skipped at the user's request: the design was
worked out with the user directly and is recorded below as decisions D1 to D10.
`GOAL.md` holds the criteria, `VISION.md` the positions, and `CONTEXT.md` the
current code.

## Decisions

- D1: The main screen holds the current compaction cycle as finished blocks plus
  the live blocks. A finished block is kept as drawn text; the shell owns that
  text, keyed by the block's sequence number. Tool records are not kept.
- D2: The previous cycle stays held after a compaction until the first turn end
  at which the log holds it. A compaction can land mid-turn while a tool line is
  still changing.
- D3: A settled resize clears the screen and reprints every held block in finish
  order, at most `Slice` blocks per loop iteration, then repaints the live blocks.
- D4: Ctrl+O opens on the newest `Window` blocks from memory, reads older blocks
  from the session log when scrolling past memory, and holds at most `Window`
  blocks and one read at a time.
- D5: Blocks are ordered by finish order. A block gets its sequence number when it
  finishes; live blocks have none and are always drawn below the finished ones.
- D6: A finished block leaves memory only after the log holds it
  (`saved_through`), except in `--no-save` sessions, which have no log.
- D7: After a crash or on resume, the core starts from the log: the held range is
  the last cycle the log holds.
- D8: In-place updates keep today's logic. The core sees a changed live block as
  one event and returns one effect for that block.
- D9: The core is pure. Time, I/O results, saves, and failures arrive as events.
- D10: Read replies carry a token. Only the reply to the one pending read counts.
- D11: Notices are not saved to the session log, so Ctrl+O shows only turn
  content for cycles it reads from the log. Notices of the held cycles stay in
  memory like any finished block. Checked before the window was wired in: the
  log holds everything else the main screen and Ctrl+O show.

## In fx

- One transcript entry is one block, keyed by its entry id. The shell walks
  the entries it has not reported at sync points (a turn summary or
  cancellation line, cleared lifecycle pins, a compaction): a user prompt
  starts a turn, a pinned tool line or a notice pending replacement opens a
  live block, a summary or cancellation ends the turn, anything else arrives
  final. A turn summary confirms the save: the app commits the turn to the
  log before it appends the summary.
- fx runs `drop` through `dropEntriesAtomic`, the commit and rebase the
  byte cap used before the window replaced it; it never removes a pinned
  entry. An entry with a row still on screen is held
  (`applyTranscriptWindowDrops`) until it scrolls into terminal history or a
  resize clears the screen, because the painter repaints the live area from
  the entries. Nothing trims the transcript by bytes any more, so command
  output is bounded per command (`command_output_block_cap`, 1 MiB).
- Resume replays the log from the newest compaction line, or from the start
  of the turn it splits: an overflow compacts after the prompt, and that
  turn shows whole in the cycle the compaction opens, as Ctrl+O shows it.
- Ctrl+O does not run `ctrlo_*`, `read_log` or `log_read_*`: it pages by
  entries, 256 to a page. Its newest pages show the held cycle together with
  the one before it, read from the log when Ctrl+O opens (or from memory while
  the window still holds it); older cycles page in one whole cycle per log
  read, one held at a time, and nothing is read while Ctrl+O is closed. The
  model's Ctrl+O laws hold for the model
  and the core; on the binary, `binary-to-spec.ts` checks what the user sees
  (every prompt once, in order) and the retention steps.
- The paint, reprint and repaint effects are not run: the main screen keeps
  its painter, and a resize keeps its clear and replay, now of the held
  entries only.
- A frame feeds the terminal parser only the bytes it has not fed before.
  The transcript anchor keeps the parser state at three points of the flow
  (the history replay base, and where the last append started and ended), and
  a frame resumes from the latest kept state at or before its base. A kept
  state is used only while the bytes before it are unchanged (a memcmp unless
  the base is the plain stable one), and a rebase clears all three; an
  oracle (`FX_TRANSCRIPT_PREFIX_ORACLE=1`) compares every resumed boundary
  with a full feed.
- The cursor walk over the plain transcript advances runs of printable ASCII
  a row at a time, with the same results as the byte-at-a-time walk.
- The interactive loop applies worker events in 32 ms slices
  (`tickWithinBudget`): past the deadline it puts the rest back with its turn
  segment scan and runs the next iteration without waiting. A take that
  carries a cancellation snapshot is applied whole.

## Assumptions

- A1: A cycle's text is bounded by the model's context, because compaction is
  always on. Measured on 345 completed cycles: at most 3.9 MB of text.
- A2: The session log commits a compaction before the transcript hears of it
  (`src/core/app/app_callbacks.zig:1564` hands it to the session runtime first),
  so recovery can find it. The core does not treat a compaction as proof that
  earlier blocks are saved; only `saved_through` says that.
- A3: The log confirms finished blocks in finish order, so one watermark,
  `saved_through`, says which blocks it holds.
- A4: A turn ends only after its live blocks finished.

## Shape

```text
step(state, event) -> { state, effects[] }
```

`State` is a small fixed-size value: counters, a bounded set of live block ids,
and the Ctrl+O window. It holds no text and copies in constant time. `abstract`
maps it onto the TLA+ variables.

### State

| Field | Meaning |
|---|---|
| `cycle` | current compaction cycle |
| `cycle_first` | sequence number of the current cycle's first block |
| `prev_first` | first block of the previous cycles still held, or none |
| `next_seq` | the next finished block's number; held blocks are `[held_first, next_seq)` |
| `saved_through` | blocks below this number are in the log |
| `live` | ids of live blocks, at most `max_live` |
| `turn_open` | a turn is running |
| `save` | `saved` or `unsaved` (`--no-save`) |
| `epoch`, `painted_through`, `reprinting` | the screen: blocks below `painted_through` are painted in this epoch |
| `ctrlo` | `open`, window `[lo, hi)`, `at_start`, `pending` read token |
| `next_token` | the next read token |

`held_first` is `prev_first` when set, otherwise `cycle_first`.

### Events

`turn_started`, `turn_ended`, `block_opened(id)`, `block_changed(id)`,
`block_finished(id)`, `saved_through(seq)`, `compacted`, `resized`,
`reprint_tick`, `ctrlo_opened`, `ctrlo_scrolled(dir)`, `ctrlo_closed`,
`log_read_done(token, count)`, `log_read_failed(token)`,
`resumed(cycle, cycle_first, next_seq)`.

### Effects

`paint_final(seq)`, `repaint_block(id)`, `reprint_begin`,
`reprint_slice(from, to)`, `repaint_live`, `drop(from, to)`,
`ctrlo_show(lo, hi)`, `read_log(token, dir, from, count)`.

### Transitions in one line each

- `block_finished(id)`: remove `id` from `live`, give it `next_seq`; when not
  reprinting, emit `paint_final(seq)` and advance `painted_through`.
- `block_changed(id)` of a live block: emit `repaint_block(id)`, nothing else.
- `compacted`: `cycle + 1`; `prev_first` keeps the oldest held start;
  `cycle_first := next_seq`.
- `turn_ended` and `saved_through`: then try the drop: when `prev_first` is set,
  no turn is open, and the log holds `[prev_first, cycle_first)` or the session
  is unsaved, emit `drop(prev_first, cycle_first)` and clear `prev_first`.
- `resized`: new epoch, `painted_through := held_first`, `reprinting`, emit
  `reprint_begin`. `reprint_tick` emits the next slice of at most `Slice` blocks,
  and `repaint_live` once it reaches `next_seq`.
- `ctrlo_opened`: window = the newest `Window` held blocks, emit `ctrlo_show`.
- `ctrlo_scrolled(older)`: inside memory, move the window and show it; at
  `held_first` in a saved session, emit `read_log(token, older, lo, Step)` unless a
  read is pending. `newer` is the mirror image.
- `log_read_done(token, count)`: only for the pending token: move the window by
  `count`, keep it at most `Window` blocks, show it; `count = 0` going older marks
  `at_start`. Other tokens change nothing.
- `resumed(cycle, cycle_first, next_seq)`: the window starts over from the log's
  last cycle, after a crash in a new process or in the same process on a
  `/resume`: everything held is saved, a reprint begins, read tokens restart,
  and nothing of the earlier state survives.
- `block_finished(id)` of an id that is not live is a block that arrived final
  (a prompt, a notice); it gets the next number like any other.
- Events the state does not allow (a change to an unknown block, a turn end with
  live blocks, a stale reply) are rejected: the state is unchanged and the shell
  logs what it dropped.

## Laws

| Law | Statement |
|---|---|
| L1 HeldIsRecentCycles | When no turn is open and the log holds the previous cycles (or the session is unsaved), no block before `cycle_first` is held. |
| L2 LiveNeverDropped | No drop range contains a live block, and a drop never changes `live`. |
| L3 DropOnlySaved | In a saved session every drop range is below `saved_through`. |
| L4 UpdateIsLocal | `block_changed(id)` emits exactly `repaint_block(id)` and changes no state. |
| L5 PaintOnceInOrder | Outside a reprint, `painted_through = next_seq`; every `paint_final(seq)` has `seq` equal to the old `painted_through`. |
| L6 ReprintInOrder | During a reprint, the painted blocks are exactly `[held_first, painted_through)`, in order. |
| L7 ReprintSliceBound | Every `reprint_slice(from, to)` has `to - from <= Slice`. |
| L8 CtrlOWindowBound | While Ctrl+O is open, `hi - lo <= Window`, `0 <= lo <= hi <= next_seq`. |
| L9 OneReadInFlight | At most one read is pending, and none while Ctrl+O is closed. |
| L10 OpenReadsNothing | `ctrlo_opened` shows the newest held blocks (`hi = next_seq`, `lo >= held_first`) and never emits `read_log`. |
| L11 StaleReadIgnored | A read reply whose token is not the pending one leaves the state unchanged. |
| L12 NoReadWhenUnsaved | An unsaved session never emits `read_log`. |
| L13 RecoveredFromLog | After `resumed`, the held blocks are all in the log, and nothing of the earlier state survives: no previous cycle, live block, open turn, Ctrl+O, or pending read. |
| L14 PreviousCycleDropped | After a compaction, once the turn ends and saves land, the previous cycle is dropped (liveness). |
| L15 ReprintFinishes | A reprint that no later resize or resume starts over finishes (liveness). |
| L16 CtrlOReachesStart | Scrolling older while the log answers each read with the true count eventually reaches the start of the log (liveness). |
| L18 DropBetweenTurns | Every drop happens while no turn is open, so a resize mid-turn reprints the whole current turn, the prompt included. |
| L19 ScreenHoldsHeld | Outside a reprint, every held block is on the screen. |
| L20 PaintedOnce | No step paints a block already on the screen in this epoch. |
| L21 ReadBounded | One log reply moves the window by at most `Step` blocks, so a reply costs a bounded amount of work. |
| L17 PureCore | `transcript_window.zig` imports only `std` and reads no clock, environment, or global. |

## Enforcement

| Law | Enforced by |
|---|---|
| L1 | `inv:HeldIsRecentCycles`, `trace:HeldIsRecentCycles` |
| L2 | `inv:LiveNeverDropped`, `trace:LiveNeverDropped` |
| L3 | `inv:DropOnlySaved`, `trace:DropOnlySaved` |
| L4 | `prop:UpdateIsLocal`, `test:block change touches only that block` |
| L5 | `inv:PaintOnceInOrder`, `trace:PaintOnceInOrder` |
| L6 | `inv:ReprintInOrder`, `trace:ReprintInOrder` |
| L7 | `inv:ReprintSliceBound`, `trace:ReprintSliceBound` |
| L8 | `inv:CtrlOWindowBound`, `trace:CtrlOWindowBound` |
| L9 | `inv:OneReadInFlight`, `trace:OneReadInFlight` |
| L10 | `prop:OpenReadsNothing`, `trace:OpenReadsNothing` |
| L11 | `prop:StaleReadIgnored`, `test:a stale read reply changes nothing` |
| L12 | `inv:NoReadWhenUnsaved`, `trace:NoReadWhenUnsaved` |
| L13 | `inv:RecoveredFromLog`, `trace:RecoveredFromLog` |
| L14 | `prop:PreviousCycleDropped` |
| L15 | `prop:ReprintFinishes` |
| L16 | `prop:CtrlOReachesStart` |
| L18 | `inv:DropBetweenTurns`, `trace:DropBetweenTurns` |
| L19 | `inv:ScreenHoldsHeld`, `trace:ScreenHoldsHeld` |
| L20 | `prop:PaintedOnce`, `trace:PaintedOnce` |
| L21 | `prop:ReadBounded`, `trace:ReadBounded` |
| L17 | `check:pure-core-imports` (the verify source check), not model checkable |

Prefixes: `inv:` is an invariant in `spec/TranscriptWindow.tla` checked by
`MCTranscriptWindow.cfg`; `trace:` is the same invariant checked on code traces
by `spec/TraceTranscriptWindow.tla`; `prop:` is a temporal or action property
(`[][A]_vars`) in `MCTranscriptWindow.cfg` or `MCCtrlOReachesStart.cfg`; `test:` is an inline test in the core; `check:` is a
step of `verify.ts`.

## Final design

The core above, with a shell in the transcript runtime that owns block text by
sequence number, feeds saves, resizes, loop ticks, and log replies in as events,
and runs the effects. It breaks no law above. What it does not yet cover:

- Ctrl+O following new blocks while it is open (today's reader swaps in fresh
  pages). Not modeled.
- A resize reprints the held entries in one pass, not in slices of `Slice`
  blocks (G6 holds for the model and the core).
- A per-cycle memory cap (A1 makes it unnecessary today).
- Below a status line that stays pinned, rows past the screen's height wait
  for the pin to end. This is the in-place region, unchanged from main; the
  byte cap used to hide it in tests by pruning.

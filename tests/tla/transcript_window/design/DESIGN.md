# Design: the transcript window core

`src/ui/transcript/transcript_window.zig` is the core. With
`FX_TLA_NEXT_TRANSCRIPT_WINDOW=1` the transcript runtime drives it through
`src/ui/transcript/transcript_window_shell.zig`; "In fx" below says which of
its effects fx runs.

The architect questionnaire was skipped at the user's request: the design was
worked out with the user directly and is recorded below as decisions D1 to D11.
`GOAL.md` holds the criteria, `VISION.md` the positions, and `CONTEXT.md` the
current code.

## Decisions

- D1: The main screen holds the whole current session as finished blocks plus the
  live blocks. Nothing finished in the current session leaves memory until the
  session changes (`/new`, `/resume`, `/clear`), so a resize redraws every
  prompt, step, and answer of the current session across compactions.
- D2: Heavy non-resize payloads are freed in the shell as soon as a tool or
  command finishes: command output lines beyond the compact head (`<= 5` lines,
  keeping `total_lines`), `tool_details.result` (keeping only the small flags or
  reasons needed for projection wordings), `command_output_replay`, spare
  `entries` capacity, and while Ctrl+O is closed both
  `full_transcript_installed_page` and `transcript_archive`.
- D3: A settled resize clears the screen and reprints every held block in finish
  order, at most `Slice` blocks per loop iteration, then repaints the live blocks.
- D4: Ctrl+O opens on the newest `Window` blocks from memory. In a fresh
  session (`held_first = 0`) the whole session is in memory, so Ctrl+O pages
  everything from memory and never reads older cycles from the session log. In
  a resumed session (`held_first > 0` in the log) Ctrl+O reads `[held_first,
  next_seq)` from memory and reads older cycles `[0, held_first)` from the
  session log while Ctrl+O is open, holding at most `Window` blocks and one
  read at a time.
- D5: Blocks are ordered by finish order. A block gets its sequence number when it
  finishes; live blocks have none and are always drawn below the finished ones.
- D6: In a `--no-save` session there is no log, so every block stays held in the
  current session and Ctrl+O never reads a log.
- D7: After a crash or on `/resume`, the core starts from the log's newest
  compaction cycle (`held_first = cycle_first`, `next_seq = saved_through`).
  Keeping only the newest cycle at startup on resume is intended because
  nothing older was painted on this screen. An in-process session change
  (`/new`, `/clear`, or `/resume` from another session) clears and drops the
  old session's held blocks first.
- D8: In-place updates keep today's logic. The core sees a changed live block as
  one event and returns one effect for that block.
- D9: The core is pure. Time, I/O results, saves, and failures arrive as events.
- D10: Read replies carry a token. Only the reply to the one pending read counts.
- D11: Notices are not saved to the session log, so Ctrl+O shows only turn
  content for cycles it reads from the log. Notices of the held session stay in
  memory like any finished block.

## In fx

- One transcript entry is one block, keyed by its entry id. The shell walks
  the entries it has not reported at sync points (a turn summary or
  cancellation line, cleared lifecycle pins, a compaction): a user prompt
  starts a turn, a pinned tool line or a notice pending replacement opens a
  live block, a summary or cancellation ends the turn, anything else arrives
  final. A turn summary stores its turn's recap when it is created
  (`appendTurnSummaryEntry`).
- No finished entry of the current session is dropped by `transcript_window`:
  `compacted`, `turn_ended`, and `saved_through` never emit `drop`. Drops happen
  only in `clearTranscript` (`/new`, `/clear`, or before switching sessions in
  `/resume`), which emits `session_cleared` and frees the departing session's
  entries.
- Heavy payloads that a resize never needs (command output lines past the 5-line
  head, `tool_details.result`, `command_output_replay`, closed Ctrl+O installed
  pages and prewarmed `transcript_archive` capacity, and spare `entries`
  capacity) are freed without altering `entries` IDs or `transcript_window`
  block sequence numbers. Ctrl+O reads full command output and tool results from
  the session log (`command_replay_store`, `result_store`, `log.jsonl`) when
  open.
- Resume replays the log from the newest compaction line, or from the start of
  the turn it splits. When no turn finished after the newest compaction, resume
  replays the cycle before it and then applies `compacted`; because the current
  session never drops finished blocks, those entries stay held across later
  turns and resizes.
- Ctrl+O pages by entries, 256 to a page. In a fresh session every entry is in
  memory so `transcript_archive` is not used. In a resumed session, older cycles
  page in one whole cycle per log read, one held at a time, and only while
  Ctrl+O is open (`transcript_archive` and `full_transcript_installed_page` are
  released when Ctrl+O closes).
- The paint, reprint and repaint effects are not run: the main screen keeps
  its painter, and a resize keeps its clear and replay over the current
  session's held entries.
- A frame feeds the terminal parser only the bytes it has not fed before.
  The transcript anchor keeps the parser state at three points of the flow
  (the history replay base, and where the last append started and ended), and
  a frame resumes from the latest kept state at or before its base. A kept
  state is used only while the bytes before it are unchanged (a memcmp unless
  the base is the plain stable one), and a rebase clears all three. In test
  builds an oracle compares every resumed boundary with a full feed.
- The cursor walk over the plain transcript advances runs of printable ASCII
  a row at a time, with the same results as the byte-at-a-time walk.
- The interactive loop applies worker events in 32 ms slices
  (`tickWithinBudget`): past the deadline it puts the rest back with its turn
  segment scan and runs the next iteration without waiting. A take that
  carries a cancellation snapshot is applied whole.

## Assumptions

- A1: Resize-essential text for a session stays small once completed command
  output tails, `tool_details.result`, and closed Ctrl+O caches are freed.
- A2: The session log commits a compaction before the transcript hears of it
  (`src/core/app/app_callbacks.zig:1564`), so recovery finds it.
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
| `held_first` | first block held in memory (`0` in a fresh session; `cycle_first` on resume) |
| `next_seq` | the next finished block's number; held blocks are `[held_first, next_seq)` |
| `saved_through` | blocks below this number are in the log |
| `live` | ids of live blocks, at most `max_live` |
| `turn_open` | a turn is running |
| `save` | `saved` or `unsaved` (`--no-save`) |
| `epoch`, `painted_through`, `reprinting` | the screen: blocks below `painted_through` are painted in this epoch |
| `ctrlo` | `open`, window `[lo, hi)`, `at_start`, `pending` read token |
| `next_token` | the next read token |

### Events

`turn_started`, `turn_ended`, `block_opened(id)`, `block_changed(id)`,
`block_finished(id)`, `saved_through(seq)`, `compacted`, `resized`,
`reprint_tick`, `session_cleared`, `ctrlo_opened`, `ctrlo_scrolled(dir)`,
`ctrlo_closed`, `log_read_done(token, count)`, `log_read_failed(token)`,
`resumed(cycle, cycle_first, next_seq)`.

### Effects

`paint_final(seq)`, `repaint_block(id)`, `reprint_begin`,
`reprint_slice(from, to)`, `repaint_live`, `drop(from, to)`,
`ctrlo_show(lo, hi)`, `read_log(token, dir, from, count)`.

### Transitions in one line each

- `block_finished(id)`: remove `id` from `live`, give it `next_seq`; when not
  reprinting, emit `paint_final(seq)` and advance `painted_through`.
- `block_changed(id)` of a live block: emit `repaint_block(id)`, nothing else.
- `compacted`: `cycle + 1`; `cycle_first := next_seq`; keep `held_first`
  unchanged and emit no drop.
- `turn_ended` and `saved_through`: update state and emit no drop.
- `session_cleared`: (`/new`, `/clear`, or clearing before `/resume`): if
  `held_first < next_seq`, emit `drop(held_first, next_seq)` and reset the core
  to its empty initial state.
- `resized`: new epoch, `painted_through := held_first`, `reprinting`, emit
  `reprint_begin`. `reprint_tick` emits the next slice of at most `Slice` blocks,
  and `repaint_live` once it reaches `next_seq`.
- `ctrlo_opened`: window = the newest `Window` held blocks, emit `ctrlo_show`.
- `ctrlo_scrolled(older)`: inside memory, move the window and show it; at
  `held_first` in a saved session (`held_first > 0`), emit `read_log(token,
  older, lo, Step)` unless a read is pending. `newer` is the mirror image.
- `log_read_done(token, count)`: only for the pending token: move the window by
  `count`, keep it at most `Window` blocks, show it; `count = 0` going older marks
  `at_start`. Other tokens change nothing.
- `resumed(cycle, cycle_first, next_seq)`: the window starts over from the log's
  last cycle (`held_first = cycle_first`, `next_seq = saved_through`), after a
  crash in a new process or after `session_cleared` on `/resume`: everything
  held is saved, a reprint begins, read tokens restart, and nothing of the
  earlier state survives.
- `block_finished(id)` of an id that is not live is a block that arrived final
  (a prompt, a notice); it gets the next number like any other.
- Events the state does not allow (a change to an unknown block, a turn end with
  live blocks, a stale reply, a `resumed` with un-cleared held blocks) are
  rejected: the state is unchanged and the shell logs what it dropped.

## Laws

| Law | Statement |
|---|---|
| L1 HeldIsCurrentSession | While the current session stays active, `held_first` never advances (compactions, turn ends, and saves never drop or hide earlier blocks of the current session). |
| L2 LiveNeverDropped | No drop happens while the current session has live blocks or an open turn; drops occur only on `session_cleared` with `live = {}` and `~turn_open`. |
| L3 DropOnlyOldSession | Every `drop` effect comes only from `session_cleared` and frees `[old_held_first, old_next_seq)` of the departing session, leaving `next_seq = 0` and `held_first = 0`. |
| L4 UpdateIsLocal | `block_changed(id)` emits exactly `repaint_block(id)` and changes no state. |
| L5 PaintOnceInOrder | Outside a reprint, `painted_through = next_seq`; every `paint_final(seq)` has `seq` equal to the old `painted_through`. |
| L6 ReprintInOrder | During a reprint, the painted blocks are exactly `[held_first, painted_through)`, in order. |
| L7 ReprintSliceBound | Every `reprint_slice(from, to)` has `to - from <= Slice`. |
| L8 CtrlOWindowBound | While Ctrl+O is open, `hi - lo <= Window`, `0 <= lo <= hi <= next_seq`. |
| L9 OneReadInFlight | At most one read is pending, and none while Ctrl+O is closed. |
| L10 OpenReadsNothing | `ctrlo_opened` shows the newest held blocks (`hi = next_seq`, `lo >= held_first`) and never emits `read_log`. |
| L11 StaleReadIgnored | A read reply whose token is not the pending one leaves the state unchanged. |
| L12 NoReadWhenUnsaved | An unsaved session never emits `read_log`. |
| L13 RecoveredFromLog | After `resumed`, `held_first = cycle_first`, the held blocks are all in the log, and nothing of the earlier state survives: no live block, open turn, Ctrl+O, or pending read. |
| L14 OldSessionDroppedOnChange | On `session_cleared` (`/new`, `/clear`, or clearing before `/resume`), every held block `[held_first, next_seq)` of the departing session is dropped. |
| L15 ReprintFinishes | A reprint that no later resize, resume, or session clear starts over finishes (liveness). |
| L16 CtrlOReachesStart | Scrolling older while the log answers each read with the true count eventually reaches the start of the log (liveness). |
| L18 NoDropDuringSession | No step other than `session_cleared` ever emits a `drop` effect, so any resize reprints the whole current session. |
| L19 ScreenHoldsHeld | Outside a reprint, every held block is on the screen. |
| L20 PaintedOnce | No step paints a block already on the screen in this epoch. |
| L21 ReadBounded | One log reply moves the window by at most `Step` blocks, so a reply costs a bounded amount of work. |
| L22 CompactionKeepsHistory | `compacted` leaves `held_first` unchanged and emits no `drop`, even between turns when the log already holds everything. |
| L17 PureCore | `transcript_window.zig` imports only `std` and reads no clock, environment, or global. |

## Enforcement

| Law | Enforced by |
|---|---|
| L1 | `prop:HeldIsCurrentSession`, `trace:HeldIsCurrentSession` |
| L2 | `inv:LiveNeverDropped`, `trace:LiveNeverDropped` |
| L3 | `inv:DropOnlyOldSession`, `trace:DropOnlyOldSession` |
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
| L14 | `prop:OldSessionDroppedOnChange`, `trace:OldSessionDroppedOnChange` |
| L15 | `prop:ReprintFinishes` |
| L16 | `prop:CtrlOReachesStart` |
| L18 | `prop:NoDropDuringSession`, `trace:NoDropDuringSession` |
| L19 | `inv:ScreenHoldsHeld`, `trace:ScreenHoldsHeld` |
| L20 | `prop:PaintedOnce`, `trace:PaintedOnce` |
| L21 | `prop:ReadBounded`, `trace:ReadBounded` |
| L22 | `prop:CompactionKeepsHistory`, `trace:CompactionKeepsHistory` |
| L17 | `check:pure-core-imports` (the verify source check), not model checkable |

Prefixes: `inv:` is an invariant in `spec/TranscriptWindow.tla` checked by
`MCTranscriptWindow.cfg`; `trace:` is the same invariant or property checked on
code traces by `spec/TraceTranscriptWindow.tla`; `prop:` is a temporal or
action property (`[][A]_vars`) in `MCTranscriptWindow.cfg` or
`MCCtrlOReachesStart.cfg`; `test:` is an inline test in the core; `check:` is a
step of `verify.ts`.

## Final design

The core above, with a shell in the transcript runtime that owns block text by
sequence number, frees heavy non-resize payloads once tools finish and keeps
Ctrl+O archive/page caches unloaded while Ctrl+O is closed, feeds saves,
resizes, session clears, loop ticks, and log replies in as events, and runs the
effects. It breaks no law above. What it does not yet cover:

- Ctrl+O following new blocks while it is open (today's reader swaps in fresh
  pages). Not modeled.
- A resize reprints the held entries in one pass, not in slices of `Slice`
  blocks (G6 holds for the model and the core).
- Below a status line that stays pinned, rows past the screen's height wait
  for the pin to end. This is the in-place region, unchanged from main.

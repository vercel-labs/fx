# Vision

## What the system is

The transcript window is the policy that decides what fx keeps in memory for the
main screen, what it paints, what it reprints after a resize, what it drops, and
what Ctrl+O reads. It is one pure function, `step(state, event)`, that returns
the next state and a list of effects. A thin shell in the transcript runtime
runs the effects: it paints rows, writes slices, frees text, and reads the
session log.

## Positions

1. **The unit of memory is a compaction cycle.** The main screen holds what was
   written since the last compaction. Before it is old news for the user and for
   the model alike, and it lives in terminal scrollback and in the session log.
2. **Memory holds text, not records.** A finished block is kept as the text the
   screen draws, plus the few words a width-dependent layout needs again. Tool
   arguments and results stay in the session log and its blobs.
3. **The session log is the only full history.** Ctrl+O reads it, newest first,
   one window at a time. Nothing else keeps a second copy of old history.
4. **An update costs the size of the change.** Finishing a block appends it once.
   Changing a live block touches that block. Nothing walks the whole transcript
   on an update.
5. **Live blocks are untouchable.** A block that can still change is never
   dropped, and the existing in-place logic keeps owning how it changes.
6. **Disk is the truth, memory is a view.** A block leaves memory only after the
   log holds it. After a crash, recovery rebuilds the last cycle from the log.
7. **Resize is a full reprint of what is held,** done in bounded slices so the
   loop keeps reading keys and painting.

## What it refuses to be

- A cache layered over a whole-transcript rebuild. The rebuild is what goes away.
- A second store of history. Ctrl+O does not keep old cycles; it reads them.
- A byte budget that trims on every chunk.
- An owner of tool or streaming semantics. It only knows which blocks are live.

## Tradeoffs made on purpose

| Choice | Cost accepted | Why |
|---|---|---|
| Drop the previous cycle at the first turn end after a compaction | Memory briefly holds two cycles during that turn | A tool line can still be updating when a compaction lands mid-turn |
| Ctrl+O reads older cycles from disk | A read when scrolling past memory | Full history without holding it; the newest part opens from memory |
| No per-cycle byte cap | A pathological cycle could be large | Compaction is always on and bounds a cycle by the model's context; measured at most 3.9 MB of text (assumption A1) |
| `--no-save` keeps only the held cycles | Ctrl+O cannot reach older cycles there | There is no log to read, and the user asked not to save one |
| Blocks are ordered by finish order | A block opened early but finished late is printed where it finished | The live region is always at the bottom, so this matches what the screen showed |

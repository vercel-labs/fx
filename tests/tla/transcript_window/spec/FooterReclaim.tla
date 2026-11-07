---- MODULE FooterReclaim ----
\* The main screen's rows under a footer that grows and shrinks: which rows
\* are in the terminal's native history, which are on the screen above the
\* footer, and which are held between the two while a footer surface (the
\* slash picker, a question, an approval) is open.
\*
\* Rows are the transcript's visual rows, numbered from 0 in order. Rows
\* [0, hist) are in native history and final: no frame paints them again.
\* The screen shows rows [top, rows) above the footer, at most Cap(open) of
\* them. Rows [hist, top) are held: off the screen, not in history yet, and
\* owed a paint. The transcript runtime owns hist and top (the committed
\* anchor's history_visual_offset and visual_offset in
\* src/ui/transcript/runtime.zig). TranscriptWindow.tla's core decides which
\* entries leave memory; the shell frees a dropped entry only once its rows
\* are in history (applyTranscriptWindowDrops), which `freed` models.
\*
\* Release = "base" is the design: history advances only as far as the idle
\* footer's screen (composer and status line) would release it, so the rows a
\* surface adds are held (release_offset in planTranscriptScrollForFrame).
\* Release = "current" is main before it: history follows the footer on the
\* screen, so opening a surface pushes the rows it covers into history.
EXTENDS Integers

CONSTANTS
    MaxRows,     \* visual rows written over a run
    Burst,       \* rows one output frame may add
    BaseCap,     \* screen rows above the base footer (composer and status line)
    Extra,       \* rows an open surface adds to the footer
    MaxResizes,  \* settled resizes over a run
    Release      \* "base" (the design) or "current" (main before it)

VARIABLES rows, hist, top, open, exited, epochFirst, dropTo, freed, resizes, act

vars == <<rows, hist, top, open, exited, epochFirst, dropTo, freed, resizes, act>>

Max(a, b) == IF a > b THEN a ELSE b
Min(a, b) == IF a < b THEN a ELSE b

Cap(o) == IF o THEN BaseCap - Extra ELSE BaseCap
\* The first row a full screen above a footer of `o` shows.
Natural(n, o, first) == Max(first, n - Cap(o))
\* How far one frame may advance history.
ReleaseTarget(n, o, first) ==
    IF Release = "base" THEN Natural(n, FALSE, first) ELSE Natural(n, o, first)
\* The shell frees a dropped row only once it is in history.
Freed(to, h) == Max(freed, Min(to, h))

Init ==
    /\ rows = 0 /\ hist = 0 /\ top = 0 /\ open = FALSE /\ exited = FALSE
    /\ epochFirst = 0 /\ dropTo = 0 /\ freed = 0 /\ resizes = 0 /\ act = "Init"

\* One committed frame at `n` rows under a footer of `o`. History advances
\* toward the release target and never moves back; a frame may release less
\* than the target (a deferred materialization) and a later one catches up.
\* The screen follows the tail but never shows a row already in history.
Frame(n, o, name) ==
    \E h \in hist..Max(hist, ReleaseTarget(n, o, epochFirst)) :
        /\ hist' = h
        /\ top' = Max(h, Natural(n, o, epochFirst))
        /\ freed' = Freed(dropTo, h)
        /\ act' = name

Output(k) ==
    /\ ~exited /\ rows + k <= MaxRows
    /\ rows' = rows + k
    /\ Frame(rows + k, open, "Output")
    /\ UNCHANGED <<open, exited, epochFirst, dropTo, resizes>>

Opened ==
    /\ ~exited /\ ~open
    /\ open' = TRUE
    /\ Frame(rows, TRUE, "Opened")
    /\ UNCHANGED <<rows, exited, epochFirst, dropTo, resizes>>

Closed ==
    /\ ~exited /\ open
    /\ open' = FALSE
    /\ Frame(rows, FALSE, "Closed")
    /\ UNCHANGED <<rows, exited, epochFirst, dropTo, resizes>>

\* The window core drops the entries before `to`; the shell frees what is in
\* history now and the rest as history reaches it.
Dropped(to) ==
    /\ ~exited /\ dropTo < to /\ to <= rows
    /\ dropTo' = to
    /\ freed' = Freed(to, hist)
    /\ act' = "Dropped"
    /\ UNCHANGED <<rows, hist, top, open, exited, epochFirst, resizes>>

\* A settled resize clears the screen and its scrollback and reprints the
\* held entries (transcriptWindowScreenCleared frees the held drops first);
\* the reprint releases rows by the same rule as any frame.
Resized ==
    /\ ~exited /\ resizes < MaxResizes
    /\ resizes' = resizes + 1
    /\ freed' = dropTo
    /\ epochFirst' = dropTo
    /\ hist' = ReleaseTarget(rows, open, dropTo)
    /\ top' = Natural(rows, open, dropTo)
    /\ act' = "Resized"
    /\ UNCHANGED <<rows, open, exited, dropTo>>

\* Exit, suspend, and a fresh session's scrollback handoff first draw one
\* frame that releases every held row, so erasing the footer leaves each row
\* in history or on the screen.
Exited ==
    /\ ~exited
    /\ exited' = TRUE
    /\ hist' = Max(hist, Natural(rows, open, epochFirst))
    /\ top' = Max(hist, Natural(rows, open, epochFirst))
    /\ freed' = Freed(dropTo, Max(hist, Natural(rows, open, epochFirst)))
    /\ act' = "Exited"
    /\ UNCHANGED <<rows, open, epochFirst, dropTo, resizes>>

Done == exited /\ UNCHANGED vars

Next ==
    \/ \E k \in 1..Burst : Output(k)
    \/ Opened \/ Closed
    \/ \E to \in 1..MaxRows : Dropped(to)
    \/ Resized \/ Exited \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Laws (design/DESIGN.md).

TypeOK ==
    /\ rows \in 0..MaxRows /\ hist \in 0..MaxRows /\ top \in 0..MaxRows
    /\ open \in BOOLEAN /\ exited \in BOOLEAN
    /\ epochFirst \in 0..MaxRows /\ dropTo \in 0..MaxRows /\ freed \in 0..MaxRows
    /\ resizes \in 0..MaxResizes

\* L22 (TUI-32): the footer is on the bottom rows: the screen above it is full
\* whenever the transcript has the rows to fill it.
FooterAtBottom == ~exited => rows - top = Min(Cap(open), rows - epochFirst)

\* L23 (native-history finality): no row in native history is on the screen,
\* so no frame shows a row twice.
HistoryOnce == hist <= top

\* L24: every row on the screen or held is still in memory.
OwedRowsHeld == freed <= Min(hist, top)

\* L25: after exit no row is held: each one is in history or was on the screen
\* when the footer was erased.
ExitKeepsRows == exited => top = hist
====

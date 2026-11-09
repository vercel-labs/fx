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
\*
\* fx ends three ways with the footer erased. /quit (and the terminal closing
\* on end of input) draws the exit frame from the main thread. Suspend and a
\* fresh session draw it too, then go on. SIGTERM and SIGHUP end fx from the
\* closer thread, which cannot touch the rows the main thread holds: it asks
\* the main thread for the exit frame and restores the terminal only once the
\* frame is drawn (`closerMain` and `signalClosePending` in
\* src/core/app/app_lifecycle.zig). SignalExits = "settle" is that design;
\* SignalExits = "erase" is the head before it, where the closer restored the
\* terminal at once and the held rows never reached the terminal's scrollback.
\* SignalExits = "stable_only" is the head after that repair: the closer asked
\* for the exit frame, but the main thread drew it only when the transcript
\* anchor was stable. A resize while an alternate screen covers the main one
\* (Ctrl+O's full transcript, the approval review screen) leaves the anchor
\* invalid with no frame to recover it, and an invalid or recovering anchor has
\* lost which rows it holds, so the signal ended fx with them still held.
\* SignalExits = "debounce_blocked" is the head after that one: a window
\* resize starts a debounce during which no frame commits (`blocksFrameCommit`
\* in src/ui/render_request.zig), so a signal that arrived inside it got no
\* exit frame before the closer's wait ended. The design ends the debounce: the
\* main thread lets the pending resize settle without waiting for its deadline
\* and draws the exit frame once nothing is in flight (`settleForSignalClose`).
\* ExitFrames = "signal_only" is the head after that one: only the signal close
\* ended the debounce. /quit, suspend, and a fresh session settle the rows
\* through the same `settleHeldTranscriptRows`, but nothing ended the debounce
\* for them, and with the loop over (or, for suspend, paused) no later pass
\* finished the resize, so a /quit or a Ctrl+Z inside the debounce erased the
\* footer with the rows still held. The design is ExitFrames = "settle": the
\* shared settle itself ends the debounce and finishes the resize before it
\* draws its frame, for every caller.
\*
\* `anchor` is the state of the transcript runtime's committed anchor
\* (`transcript_commit_state` in src/ui/transcript/runtime.zig): "stable" after
\* a frame that released all it owed, "recovering" after one that released
\* less, and "invalid" before the first frame and after a resize or takeover,
\* until a frame recovers it.
EXTENDS Integers

CONSTANTS
    MaxRows,     \* visual rows written over a run
    Burst,       \* rows one output frame may add
    BaseCap,     \* screen rows above the base footer (composer and status line)
    Extra,       \* rows an open surface adds to the footer
    MaxResizes,  \* settled resizes over a run
    Release,     \* "base" (the design) or "current" (main before it)
    SignalExits, \* "settle" (the design), or "debounce_blocked", "stable_only", "erase" (the heads before it)
    ExitFrames   \* "settle" (the design), or "signal_only" (the head before it)

VARIABLES rows, hist, top, open, exited, epochFirst, dropTo, freed, resizes, anchor, act

vars == <<rows, hist, top, open, exited, epochFirst, dropTo, freed, resizes, anchor, act>>

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
    /\ epochFirst = 0 /\ dropTo = 0 /\ freed = 0 /\ resizes = 0
    /\ anchor = "invalid" /\ act = "Init"

\* One committed frame at `n` rows under a footer of `o`. History advances
\* toward the release target and never moves back; a frame may release less
\* than the target (a deferred materialization) and a later one catches up.
\* The screen follows the tail but never shows a row already in history. The
\* frame recovers an invalid anchor, and leaves it stable or recovering.
Frame(n, o, name) ==
    \E h \in hist..Max(hist, ReleaseTarget(n, o, epochFirst)) :
        /\ hist' = h
        /\ top' = Max(h, Natural(n, o, epochFirst))
        /\ freed' = Freed(dropTo, h)
        /\ anchor' \in {"stable", "recovering"}
        /\ act' = name

Output(k) ==
    /\ ~exited /\ rows + k <= MaxRows
    /\ rows' = rows + k
    /\ Frame(rows + k, open, "Output")
    /\ UNCHANGED <<open, exited, epochFirst, dropTo, resizes>>

\* A surface opens, in the same frame as the `k` rows that arrive with it (an
\* approval comes with the rows of its tool call).
Opened(k) ==
    /\ ~exited /\ ~open /\ rows + k <= MaxRows
    /\ open' = TRUE
    /\ rows' = rows + k
    /\ Frame(rows + k, TRUE, "Opened")
    /\ UNCHANGED <<exited, epochFirst, dropTo, resizes>>

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
    /\ UNCHANGED <<rows, hist, top, open, exited, epochFirst, resizes, anchor>>

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
    /\ anchor' \in {"stable", "recovering"}
    /\ act' = "Resized"
    /\ UNCHANGED <<rows, open, exited, dropTo>>

\* A settled resize while an alternate screen covers the main one: Ctrl+O's
\* full transcript, or the approval review screen, which an open approval moves
\* to when the narrower window leaves it no room inline (`surfaceLeaves`: the
\* surface is no longer an open footer of the main screen). Nothing draws on
\* the main screen, so no frame recovers the anchor: it is invalid, and the
\* rows, history, and screen stay as they were, the held rows still held. The
\* reprint the resize owes is the next frame's, which releases rows by the
\* same rule as any frame.
CoveredResize(name, surfaceLeaves) ==
    /\ ~exited /\ resizes < MaxResizes
    /\ surfaceLeaves => open
    /\ resizes' = resizes + 1
    /\ anchor' = "invalid"
    /\ open' = IF surfaceLeaves THEN FALSE ELSE open
    /\ act' = name
    /\ UNCHANGED <<rows, hist, top, exited, epochFirst, dropTo, freed>>

\* A screen takeover (Ctrl+O's full transcript, external damage) gives the
\* screen back with the same rows and footer; the frame after it releases
\* rows by the same rule as any frame, so recovery never releases a row the
\* open surface holds (normal-buffer and invalid-anchor recovery in
\* planTranscriptScrollForFrame).
TookOver ==
    /\ ~exited
    /\ Frame(rows, open, "TookOver")
    /\ UNCHANGED <<rows, open, exited, epochFirst, dropTo, resizes>>

\* The exit frame: exit, suspend, and a fresh session's scrollback handoff
\* first draw one frame that releases every held row, so erasing the footer
\* leaves each row in history or on the screen. It does so from any anchor: an
\* invalid or recovering one has lost which rows it holds, so the frame
\* releases what is owed rather than what the anchor says.
ExitFrame(name) ==
    /\ ~exited
    /\ exited' = TRUE
    /\ anchor' \in {"stable", "recovering"}
    /\ hist' = Max(hist, Natural(rows, open, epochFirst))
    /\ top' = Max(hist, Natural(rows, open, epochFirst))
    /\ freed' = Freed(dropTo, Max(hist, Natural(rows, open, epochFirst)))
    /\ act' = name
    /\ UNCHANGED <<rows, open, epochFirst, dropTo, resizes>>

\* /quit, suspend, and a fresh session's handoff, with a resize debounce pending
\* (`resizing`) or not: a window resize arrived less than the debounce ago, and
\* no frame commits until its settled replay has been drawn. The design ends the
\* debounce and finishes the resize first (`finishResizeBeforeSettle`), so the
\* exit frame is drawn whatever is pending. With the head's rule ("signal_only")
\* the frame is drawn only when no debounce is pending, so the footer is erased
\* with rows held. (A fresh session also waits for the resize before it settles,
\* `freshSessionResizeReady`, so the head never lost rows there; the model does
\* not tell the three apart.)
ExitSettles(resizing) == ExitFrames = "settle" \/ ~resizing

\* Lines the resume hint /quit prints after the exit frame can take, at most.
HintLines == 4

Exited ==
    \E resizing \in BOOLEAN :
        IF ExitSettles(resizing)
        THEN ExitFrame("Exited")
        ELSE /\ ~exited
             /\ exited' = TRUE
             /\ act' = "Exited"
             /\ UNCHANGED <<rows, hist, top, open, epochFirst, dropTo, freed, resizes, anchor>>

\* SIGTERM or SIGHUP, at any step between two frames, with a resize debounce
\* pending (`resizing`) or not: a window resize arrived less than the debounce
\* ago, and no frame commits until its settled replay has been drawn. With the
\* design the closer waits for the main thread's exit frame, whatever the
\* anchor and whatever is pending; with the head's rules it restores the
\* terminal at once ("erase"), or the main thread draws the frame only from a
\* stable anchor ("stable_only") or only when no debounce is pending
\* ("debounce_blocked"), so the footer is erased with rows held.
SignalSettles(name, resizing) ==
    \/ SignalExits = "settle"
    \/ (SignalExits = "stable_only" /\ anchor = "stable")
    \/ (SignalExits = "debounce_blocked" /\ ~resizing)

SignalExit(name) ==
    \E resizing \in BOOLEAN :
        IF SignalSettles(name, resizing)
        THEN ExitFrame(name)
        ELSE /\ ~exited
             /\ exited' = TRUE
             /\ act' = name
             /\ UNCHANGED <<rows, hist, top, open, epochFirst, dropTo, freed, resizes, anchor>>

\* /quit typed in the composer, whatever is open: Enter submits the command,
\* which closes the surface, so the exit frame draws the idle footer and paints
\* the held rows back, and fx then prints its resume hint where the footer was.
\* The hint's lines that do not fit below the screen's rows scroll it up, so up
\* to `HintLines` more rows reach history. The signals print nothing, and the
\* exit frame of an exit with the surface open (`Exited`) leaves it drawn.
Quit ==
    \E resizing \in BOOLEAN :
        /\ ~exited
        /\ exited' = TRUE
        /\ open' = FALSE
        /\ act' = "Quit"
        /\ UNCHANGED <<rows, epochFirst, dropTo, resizes>>
        /\ IF ExitSettles(resizing)
           THEN \E k \in 0..HintLines :
                    LET to == Max(hist, Natural(rows, FALSE, epochFirst)) + k IN
                    /\ to <= rows
                    /\ hist' = to
                    /\ top' = to
                    /\ freed' = Freed(dropTo, to)
                    /\ anchor' \in {"stable", "recovering"}
           ELSE UNCHANGED <<hist, top, freed, anchor>>

Done == exited /\ UNCHANGED vars

Next ==
    \/ \E k \in 1..Burst : Output(k)
    \/ \E k \in 0..Burst : Opened(k)
    \/ Closed
    \/ \E to \in 1..MaxRows : Dropped(to)
    \/ Resized \/ TookOver \/ Exited \/ Quit \/ Done
    \/ CoveredResize("CoveredResize", FALSE) \/ CoveredResize("ReviewResize", TRUE)
    \/ SignalExit("SigTerm") \/ SignalExit("SigHup")

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Laws (design/DESIGN.md).

TypeOK ==
    /\ rows \in 0..MaxRows /\ hist \in 0..MaxRows /\ top \in 0..MaxRows
    /\ open \in BOOLEAN /\ exited \in BOOLEAN
    /\ epochFirst \in 0..MaxRows /\ dropTo \in 0..MaxRows /\ freed \in 0..MaxRows
    /\ resizes \in 0..MaxResizes
    /\ anchor \in {"stable", "invalid", "recovering"}

\* L22 (TUI-32): the footer is on the bottom rows: the screen above it is full
\* whenever the transcript has the rows to fill it, except while an invalid
\* anchor leaves the main screen as an alternate screen last drew it.
FooterAtBottom == (~exited /\ anchor /= "invalid") => rows - top = Min(Cap(open), rows - epochFirst)

\* L23 (native-history finality): no row in native history is on the screen,
\* so no frame shows a row twice.
HistoryOnce == hist <= top

\* L24: every row on the screen or held is still in memory.
OwedRowsHeld == freed <= Min(hist, top)

\* L25: after exit, by /quit, suspend, a fresh session, SIGTERM or SIGHUP, from
\* any anchor, no row is held: each one is in history or was on the screen when
\* the footer was erased.
ExitKeepsRows == exited => top = hist
====

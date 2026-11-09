---- MODULE TraceFooterReclaim ----
\* Checks traces the real transcript runtime produced against FooterReclaim.
\*
\* tests/tla/drivers/transcript_window/footer-runtime-to-spec.ts runs event
\* scripts (output, slash picker open and close, resizes, screen takeovers,
\* exit, SIGTERM, SIGHUP) through
\* TranscriptRuntime in the resize harness ("footer reclaim runtime trace
\* driver" in src/ui/resize_tests.zig) and writes each run as a sequence of
\* states into FooterTraceData.tla: the committed anchor's total visual rows,
\* history_visual_offset and visual_offset (an invalid anchor keeps those of
\* the last frame), its state, whether the picker is open, and how many window
\* resizes the script made.
\* The driver sets BaseCap and Extra from the rows the screen showed above
\* the idle and the open footer. TLC walks every trace: ConformsToSpec holds
\* when each recorded step is a step of FooterReclaim's Next, and the laws
\* below are checked on what the code did.
EXTENDS Integers, Sequences, FooterTraceData

CONSTANTS MaxRows, Burst, BaseCap, Extra, MaxResizes, Release, SignalExits, ExitFrames

VARIABLES rows, hist, top, open, exited, epochFirst, dropTo, freed, resizes, anchor, act, trace, at

FR == INSTANCE FooterReclaim

vars == <<rows, hist, top, open, exited, epochFirst, dropTo, freed, resizes, anchor, act>>

Load(s) ==
    /\ rows = s.rows /\ hist = s.hist /\ top = s.top /\ open = s.open
    /\ exited = s.exited /\ act = s.act /\ resizes = s.resizes /\ anchor = s.anchor
    /\ epochFirst = 0 /\ dropTo = 0 /\ freed = 0

LoadNext(s) ==
    /\ rows' = s.rows /\ hist' = s.hist /\ top' = s.top /\ open' = s.open
    /\ exited' = s.exited /\ act' = s.act /\ resizes' = s.resizes /\ anchor' = s.anchor
    /\ epochFirst' = 0 /\ dropTo' = 0 /\ freed' = 0

TraceInit == trace \in 1..Len(Traces) /\ at = 1 /\ Load(Traces[trace][1])

TraceNext ==
    /\ at < Len(Traces[trace])
    /\ at' = at + 1
    /\ trace' = trace
    /\ LoadNext(Traces[trace][at + 1])

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, trace, at>>

\* Every trace starts where the model starts.
StartsAtInit == at = 1 => FR!Init

\* Every recorded step is a step of the model.
ConformsToSpec == [][FR!Next]_vars

TypeOK == FR!TypeOK
FooterAtBottom == FR!FooterAtBottom
HistoryOnce == FR!HistoryOnce
OwedRowsHeld == FR!OwedRowsHeld
ExitKeepsRows == FR!ExitKeepsRows
====

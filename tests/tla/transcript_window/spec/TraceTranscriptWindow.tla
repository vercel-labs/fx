---- MODULE TraceTranscriptWindow ----
\* Checks traces the real core produced against TranscriptWindow.
\*
\* tests/tla/drivers/transcript_window/code-to-spec.ts runs event sequences,
\* with crashes that kill the harness process, lost, stale, duplicate and
\* garbage log replies, saves past the end, and events the state does not
\* allow, through the harness around src/ui/transcript/transcript_window.zig.
\* It writes each run as one sequence of states into TraceData.tla: what the
\* core showed (abstract(state) and the step's effects), the event as the
\* model's `act`, the environment's `alive` and `cycleStarts`, and `painted`,
\* the blocks the effects put on the screen. An event the
\* core rejected is recorded as a repeat of the previous state.
\*
\* TLC walks every trace. ConformsToSpec holds when every recorded step is a
\* step of TranscriptWindow's Next, so each trace is a behavior of the model;
\* the law names below re-export the model's laws, checked on what the code did.
EXTENDS Integers, Sequences, FiniteSets, TraceData

CONSTANTS MaxSeq, Ids, MaxCycles, Window, Step, Slice, MaxTokens, Saved, OnlyOlder

VARIABLES
    cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live, turnOpen,
    paintedThrough, reprinting,
    coOpen, coLo, coHi, coAtStart, pending, pendingDir, nextToken,
    out, act,
    alive, cycleStarts, painted,
    trace, at

TW == INSTANCE TranscriptWindow

vars == <<cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live, turnOpen,
          paintedThrough, reprinting, coOpen, coLo, coHi, coAtStart, pending,
          pendingDir, nextToken, out, act, alive, cycleStarts, painted>>

Load(s) ==
    /\ cycle = s.cycle /\ cycleFirst = s.cycleFirst /\ prevFirst = s.prevFirst
    /\ nextSeq = s.nextSeq /\ savedThrough = s.savedThrough /\ live = s.live
    /\ turnOpen = s.turnOpen /\ paintedThrough = s.paintedThrough
    /\ reprinting = s.reprinting /\ coOpen = s.coOpen /\ coLo = s.coLo
    /\ coHi = s.coHi /\ coAtStart = s.coAtStart /\ pending = s.pending
    /\ pendingDir = s.pendingDir /\ nextToken = s.nextToken /\ out = s.out
    /\ act = s.act /\ alive = s.alive /\ cycleStarts = s.cycleStarts
    /\ painted = s.painted

LoadNext(s) ==
    /\ cycle' = s.cycle /\ cycleFirst' = s.cycleFirst /\ prevFirst' = s.prevFirst
    /\ nextSeq' = s.nextSeq /\ savedThrough' = s.savedThrough /\ live' = s.live
    /\ turnOpen' = s.turnOpen /\ paintedThrough' = s.paintedThrough
    /\ reprinting' = s.reprinting /\ coOpen' = s.coOpen /\ coLo' = s.coLo
    /\ coHi' = s.coHi /\ coAtStart' = s.coAtStart /\ pending' = s.pending
    /\ pendingDir' = s.pendingDir /\ nextToken' = s.nextToken /\ out' = s.out
    /\ act' = s.act /\ alive' = s.alive /\ cycleStarts' = s.cycleStarts
    /\ painted' = s.painted

TraceInit == trace \in 1..Len(Traces) /\ at = 1 /\ Load(Traces[trace][1])

TraceNext ==
    /\ at < Len(Traces[trace])
    /\ at' = at + 1
    /\ trace' = trace
    /\ LoadNext(Traces[trace][at + 1])

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, trace, at>>

\* Every trace starts where the model starts.
StartsAtInit == at = 1 => TW!Init

\* Every recorded step is a step of the model.
ConformsToSpec == [][TW!Next]_vars

TypeOK == TW!TypeOK
HeldIsRecentCycles == TW!HeldIsRecentCycles
LiveNeverDropped == TW!LiveNeverDropped
DropOnlySaved == TW!DropOnlySaved
PaintOnceInOrder == TW!PaintOnceInOrder
ReprintInOrder == TW!ReprintInOrder
ReprintSliceBound == TW!ReprintSliceBound
CtrlOWindowBound == TW!CtrlOWindowBound
OneReadInFlight == TW!OneReadInFlight
NoReadWhenUnsaved == TW!NoReadWhenUnsaved
RecoveredFromLog == TW!RecoveredFromLog
DropBetweenTurns == TW!DropBetweenTurns
ScreenHoldsHeld == TW!ScreenHoldsHeld
PaintedOnce == TW!PaintedOnce
ReadBounded == TW!ReadBounded
UpdateIsLocal == TW!UpdateIsLocal
OpenReadsNothing == TW!OpenReadsNothing
StaleReadIgnored == TW!StaleReadIgnored
====

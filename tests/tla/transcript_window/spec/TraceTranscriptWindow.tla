---- MODULE TraceTranscriptWindow ----
\* Checks traces the real core produced against TranscriptWindow.
EXTENDS Integers, Sequences, FiniteSets, TraceData

CONSTANTS MaxSeq, Ids, MaxCycles, Window, Step, Slice, MaxTokens, Saved, OnlyOlder

VARIABLES
    cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live, turnOpen,
    paintedThrough, reprinting,
    coOpen, coLo, coHi, coAtStart, pending, pendingDir, nextToken,
    out, act,
    alive, cycleStarts, painted,
    trace, at

TW == INSTANCE TranscriptWindow

vars == <<cycle, cycleFirst, heldFirst, nextSeq, savedThrough, live, turnOpen,
          paintedThrough, reprinting, coOpen, coLo, coHi, coAtStart, pending,
          pendingDir, nextToken, out, act, alive, cycleStarts, painted>>

Load(s) ==
    /\ cycle = s.cycle /\ cycleFirst = s.cycleFirst /\ heldFirst = s.heldFirst
    /\ nextSeq = s.nextSeq /\ savedThrough = s.savedThrough /\ live = s.live
    /\ turnOpen = s.turnOpen /\ paintedThrough = s.paintedThrough
    /\ reprinting = s.reprinting /\ coOpen = s.coOpen /\ coLo = s.coLo
    /\ coHi = s.coHi /\ coAtStart = s.coAtStart /\ pending = s.pending
    /\ pendingDir = s.pendingDir /\ nextToken = s.nextToken /\ out = s.out
    /\ act = s.act /\ alive = s.alive /\ cycleStarts = s.cycleStarts
    /\ painted = s.painted

LoadNext(s) ==
    /\ cycle' = s.cycle /\ cycleFirst' = s.cycleFirst /\ heldFirst' = s.heldFirst
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
LiveNeverDropped == TW!LiveNeverDropped
DropOnlyOldSession == TW!DropOnlyOldSession
PaintOnceInOrder == TW!PaintOnceInOrder
ReprintInOrder == TW!ReprintInOrder
ReprintSliceBound == TW!ReprintSliceBound
CtrlOWindowBound == TW!CtrlOWindowBound
OneReadInFlight == TW!OneReadInFlight
NoReadWhenUnsaved == TW!NoReadWhenUnsaved
RecoveredFromLog == TW!RecoveredFromLog
ScreenHoldsHeld == TW!ScreenHoldsHeld
HeldIsCurrentSession == TW!HeldIsCurrentSession
OldSessionDroppedOnChange == TW!OldSessionDroppedOnChange
NoDropDuringSession == TW!NoDropDuringSession
CompactionKeepsHistory == TW!CompactionKeepsHistory
PaintedOnce == TW!PaintedOnce
ReadBounded == TW!ReadBounded
UpdateIsLocal == TW!UpdateIsLocal
OpenReadsNothing == TW!OpenReadsNothing
StaleReadIgnored == TW!StaleReadIgnored
====

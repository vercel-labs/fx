-------------------------- MODULE WriterLockTrace --------------------------
(***************************************************************************)
(* Trace validation for WriterLock.tla (flock plus the Session mutex).    *)
(*                                                                         *)
(* One trace line per action:                                              *)
(*   event    Open | Close | Crash | Restart (with p) |                    *)
(*            Acquire | WriteAndRelease (with p and t)                     *)
(*   p, t     "p1" | "p2" and "t1" | "t2"                                  *)
(*   holder   the process holding the flock, or "none"                     *)
(*   alive, opened, nextSeq, mutex   per process                           *)
(*   file     [seq, by] for each line written since the trace began,       *)
(*            parsed from log.jsonl: seq counts from 1 at the first traced *)
(*            line, `by` is the writer named in the line. `closed` lines   *)
(*            are bookkeeping outside this spec and are left out, and the  *)
(*            seqs after them shift down, so a skipped or duplicated seq   *)
(*            still shows as a mismatch.                                   *)
(***************************************************************************)
EXTENDS WriterLock, TraceData, TLC

VARIABLE l
tvars == <<vars, l>>

TraceProcs == {"p1", "p2"}
TraceThreads == {"t1", "t2"}
TraceMaxLines == 64
TraceNone == "none"

ASSUME TLCSet(1, 0)

Matches(e) ==
    /\ holder' = e.holder
    /\ alive' = e.alive
    /\ opened' = e.opened
    /\ nextSeq' = e.nextSeq
    /\ mutex' = e.mutex
    /\ file' = e.file

Act(e) ==
    CASE e.event = "Open"            -> Open(e.p)
      [] e.event = "Close"           -> Close(e.p)
      [] e.event = "Crash"           -> Crash(e.p)
      [] e.event = "Restart"         -> Restart(e.p)
      [] e.event = "Acquire"         -> Acquire(e.p, e.t)
      [] e.event = "WriteAndRelease" -> WriteAndRelease(e.p, e.t)

TraceInit == Init /\ l = 1

TraceNext ==
    /\ l <= Len(Trace)
    /\ Act(Trace[l])
    /\ Matches(Trace[l])
    /\ l' = l + 1

TraceSpec == TraceInit /\ [][TraceNext]_tvars

Progress ==
    IF l - 1 > TLCGet(1)
    THEN TLCSet(1, l - 1) /\ PrintT(<<"matched_lines", l - 1>>)
    ELSE TRUE

TraceIncomplete == l <= Len(Trace)
=============================================================================

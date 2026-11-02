------------------------ MODULE TurnLifecycleTrace ------------------------
(***************************************************************************)
(* Trace validation for TurnLifecycle.tla (turn rules, close, reopen).    *)
(*                                                                         *)
(* One trace line per action:                                              *)
(*   event   Create | Write (with kind) | Close | Crash | Reopen           *)
(*   kind    for Write: start | item | compacted | commit | interrupt | set *)
(*   log     the kinds on disk, in order, parsed from log.jsonl; snapshot  *)
(*           and child lines are outside this spec and left out            *)
(*   status  "new" | "open" | "closed" | "down"                            *)
(*   fresh   TRUE from a reopen until the next turn starts                 *)
(***************************************************************************)
EXTENDS TurnLifecycle, TraceData, TLC

VARIABLE l
tvars == <<vars, l>>

\* Only bounds the log a trace may build; the trace fixes every step, so
\* a large bound adds no states. The driver's host models run to hundreds
\* of lines.
TraceMaxLen == 4096

ASSUME TLCSet(1, 0)

Matches(e) ==
    /\ log' = e.log
    /\ status' = e.status
    /\ fresh' = e.fresh

Act(e) ==
    CASE e.event = "Create" -> Create
      [] e.event = "Write"  -> Write(e.kind)
      [] e.event = "Close"  -> Close
      [] e.event = "Crash"  -> Crash
      [] e.event = "Reopen" -> Reopen

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

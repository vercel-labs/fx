------------------------------ MODULE WiringTrace ------------------------------
(***************************************************************************)
(* Trace validation for Wiring.tla, from fx's `wiring` trace lines.        *)
(*                                                                         *)
(* One trace line per step the adapter logs, in order (`Trace`, from       *)
(* WiringData.tla): a record [a, s, e] with                                *)
(*   a   Start | Open | BeginTurn | EndTurn | Spawn | ChildDone | Close    *)
(*       | Fork | Exit | Crash                                             *)
(*   s   the session, "s1".. (Open, Close, and Fork's new session), else  *)
(*       "none"                                                            *)
(*   e   "commit" | "interrupt" (EndTurn only), else "none"                *)
(* Start and Exit are the store's first open and last close in a process  *)
(* (a process whose tracing starts after its store opened starts at its  *)
(* first line);                                                          *)
(* Crash is added by check_wiring_traces.py when a process's lines stop    *)
(* without Exit. Accepted when every line is an allowed step in turn:     *)
(* `NotDone` then fails.                                                   *)
(***************************************************************************)
EXTENDS Wiring, WiringData, Naturals, Sequences, TLC

VARIABLE l
tvars == <<vars, l>>

ASSUME TLCSet(1, 0)

Act(e) ==
    CASE e.a = "Start"     -> Start
      [] e.a = "Open"      -> Open(e.s)
      [] e.a = "BeginTurn" -> BeginTurn
      [] e.a = "EndTurn"   -> EndTurn(e.e)
      [] e.a = "Spawn"     -> Spawn
      [] e.a = "ChildDone" -> ChildDone
      [] e.a = "Close"     -> Close(e.s)
      [] e.a = "Fork"      -> Fork(e.s)
      [] e.a = "Exit"      -> Exit
      [] e.a = "Crash"     -> Crash

TraceInit == Init /\ l = 1

TraceNext ==
    /\ l <= Len(Trace)
    /\ Act(Trace[l])
    /\ l' = l + 1

TraceSpec == TraceInit /\ [][TraceNext]_tvars

Progress ==
    IF l - 1 > TLCGet(1)
    THEN TLCSet(1, l - 1) /\ PrintT(<<"matched_lines", l - 1>>)
    ELSE TRUE

NotDone == l <= Len(Trace)
=============================================================================

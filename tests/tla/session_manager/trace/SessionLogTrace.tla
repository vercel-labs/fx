------------------------- MODULE SessionLogTrace -------------------------
(***************************************************************************)
(* Trace validation for SessionLog.tla.                                    *)
(*                                                                         *)
(* TLC accepts an implementation trace only if some behavior of SessionLog *)
(* produces exactly the logged states, step by step. TraceData.tla is      *)
(* generated from the implementation's JSON-lines trace by to_tla.py.      *)
(*                                                                         *)
(* One trace line per L1 step:                                             *)
(*   event      BeginWrite | FinishWrite | Fsync | ProcessCrash |          *)
(*              PowerLoss | Recover                                        *)
(*   log_len    lines in log.jsonl, counting a torn final line             *)
(*   tail_done  whether the file ends in "\n"                              *)
(*   seqs       seq of every complete line, parsed from the file bytes     *)
(*   durable    lines covered by the last fsync                            *)
(*   acked      lines acknowledged to callers as durable                   *)
(*   status     "open" | "writing" | "down"                                *)
(* log_len, tail_done and seqs must come from reading the real file, not   *)
(* from the writer's own counters.                                         *)
(***************************************************************************)
EXTENDS SessionLog, TraceData, TLC

VARIABLE l
tvars == <<vars, l>>

ASSUME TLCSet(1, 0)

\* IF, not \/: inside an action TLC explores both sides of a disjunction,
\* so `Len(log') = 0 \/ log'[Len(log')].done` would index an empty log.
Matches(e) ==
    /\ Len(log') = e.log_len
    /\ IF Len(log') = 0 THEN e.tail_done ELSE log'[Len(log')].done = e.tail_done
    /\ Len(e.seqs) <= Len(log')
    /\ \A i \in 1..Len(e.seqs) : log'[i].seq = e.seqs[i]
    /\ durable' = e.durable
    /\ acked' = e.acked
    /\ status' = e.status

Act(e) ==
    CASE e.event = "BeginWrite"   -> BeginWrite
      [] e.event = "FinishWrite"  -> FinishWrite
      [] e.event = "Fsync"        -> Fsync
      [] e.event = "ProcessCrash" -> ProcessCrash
      [] e.event = "PowerLoss"    -> PowerLoss
      [] e.event = "Recover"      -> Recover

TraceInit == Init /\ l = 1

TraceNext ==
    /\ l <= Len(Trace)
    /\ Act(Trace[l])
    /\ Matches(Trace[l])
    /\ l' = l + 1

TraceSpec == TraceInit /\ [][TraceNext]_tvars

\* State constraint: prints each new furthest trace line matched.
Progress ==
    IF l - 1 > TLCGet(1)
    THEN TLCSet(1, l - 1) /\ PrintT(<<"matched_lines", l - 1>>)
    ELSE TRUE

\* Violated exactly when the whole trace was matched: TLC reporting this
\* invariant as violated means ACCEPTED.
TraceIncomplete == l <= Len(Trace)
=============================================================================

-------------------------- MODULE LifecycleTrace --------------------------
(***************************************************************************)
(* Trace validation for Lifecycle.tla (lazy creation and the first-turn   *)
(* publish).                                                               *)
(*                                                                         *)
(* One trace line per action:                                              *)
(*   event  OpenNew | MkTmp | WriteLine1 | FsyncLog | Rename |             *)
(*          FsyncDirAndAck | Sweep (with s) | ProcessCrash | PowerLoss     *)
(*   s      "s1" or "s2", for the per-session actions                      *)
(*   step   [s1 |-> ..., s2 |-> ...], how far each publish has got         *)
(*   where  per session: "none" | "tmp" | "visible", from the folders      *)
(*   line1  per session: "none" | "cached" | "durable", from the log file  *)
(*          and the fault layer's record of what was synced                *)
(*   acked  per session: the caller was told the first turn was saved      *)
(***************************************************************************)
EXTENDS Lifecycle, Sequences, TraceData, TLC

VARIABLE l
tvars == <<vars, l>>

TraceIds == {"s1", "s2"}

ASSUME TLCSet(1, 0)

Matches(e) ==
    /\ step' = e.step
    /\ where' = e.where
    /\ line1' = e.line1
    /\ acked' = e.acked

Act(e) ==
    CASE e.event = "OpenNew"        -> OpenNew(e.s)
      [] e.event = "MkTmp"          -> MkTmp(e.s)
      [] e.event = "WriteLine1"     -> WriteLine1(e.s)
      [] e.event = "FsyncLog"       -> FsyncLog(e.s)
      [] e.event = "Rename"         -> Rename(e.s)
      [] e.event = "FsyncDirAndAck" -> FsyncDirAndAck(e.s)
      [] e.event = "Sweep"          -> Sweep(e.s)
      [] e.event = "ProcessCrash"   -> ProcessCrash
      [] e.event = "PowerLoss"      -> PowerLoss

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

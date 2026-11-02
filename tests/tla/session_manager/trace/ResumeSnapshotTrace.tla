------------------------ MODULE ResumeSnapshotTrace ------------------------
(***************************************************************************)
(* Trace validation for ResumeSnapshot.tla (the fold and its snapshots).  *)
(*                                                                         *)
(* One trace line per action:                                              *)
(*   event  Set (with v) | Start | Commit | Snapshot                       *)
(*   v      for Set: "v1" | "v2", the prefs value written                  *)
(*   log    every modeled line on disk, parsed from log.jsonl:             *)
(*          [k |-> "set" | "start" | "commit" | "snap", v, st]. For a      *)
(*          snapshot, st is read from the snapshot's own state object:     *)
(*          [pref, turns (committed), open]. Other kinds are outside this  *)
(*          spec and left out.                                             *)
(* The Snapshot action requires st to equal the full fold at that point,   *)
(* so a snapshot that stores the wrong state is rejected.                  *)
(***************************************************************************)
EXTENDS ResumeSnapshot, TraceData, TLC

VARIABLE l
tvars == <<vars, l>>

TraceVals == {"v1", "v2"}
TraceMaxLen == 64
TraceNoVal == "none"

ASSUME TLCSet(1, 0)

Matches(e) == log' = e.log

Act(e) ==
    CASE e.event = "Set"      -> Set(e.v)
      [] e.event = "Start"    -> Start
      [] e.event = "Commit"   -> Commit
      [] e.event = "Snapshot" -> Snapshot

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

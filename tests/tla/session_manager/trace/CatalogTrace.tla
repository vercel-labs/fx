---------------------------- MODULE CatalogTrace ----------------------------
(***************************************************************************)
(* Trace validation for Catalog.tla (index.jsonl, delete, heal, rebuild). *)
(*                                                                         *)
(* One trace line per action:                                              *)
(*   event     Publish | IndexPut | Trash | IndexDel | Purge | Heal (with  *)
(*             s) | Crash | Rebuild                                        *)
(*   s         "s1" | "s2" | "s3"                                          *)
(*   dir       per session, from the folders: "live" ({id}/), "trash"      *)
(*             (.trash/{id}/), else "gone" once published, else "none"     *)
(*   index     [id, op] per put or del line of index.jsonl, in file order; *)
(*             a put that follows a put for the same id only updates the   *)
(*             summary and is left out, as are `opened` lines              *)
(*   pending, everDeleted   what the code still owes, and a ghost          *)
(***************************************************************************)
EXTENDS Catalog, TraceData, TLC

VARIABLE l
tvars == <<vars, l>>

TraceIds == {"s1", "s2", "s3"}

ASSUME TLCSet(1, 0)

Matches(e) ==
    /\ dir' = e.dir
    /\ index' = e.index
    /\ pending' = e.pending
    /\ everDeleted' = e.everDeleted

Act(e) ==
    CASE e.event = "Publish"  -> Publish(e.s)
      [] e.event = "IndexPut" -> IndexPut(e.s)
      [] e.event = "Trash"    -> Trash(e.s)
      [] e.event = "IndexDel" -> IndexDel(e.s)
      [] e.event = "Purge"    -> Purge(e.s)
      [] e.event = "Heal"     -> Heal(e.s)
      [] e.event = "Crash"    -> Crash
      [] e.event = "Rebuild"  -> Rebuild

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

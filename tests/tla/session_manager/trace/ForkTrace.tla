----------------------------- MODULE ForkTrace -----------------------------
(***************************************************************************)
(* Trace validation for Fork.tla (blobs, fork at a boundary, delete).     *)
(*                                                                         *)
(* One trace line per action:                                              *)
(*   event  Create | Start | Commit | Delete (with s) | PutBlob | Item     *)
(*          (with s and b) | Fork (with src, f, at)                        *)
(*   s, src, f   "s1" | "s2" | "s3";  b  "b1" | "b2";  at  the fork's S    *)
(*   st     per session: "none" | "live" | "deleted"                       *)
(*   lg     per session, parsed from its log.jsonl: [k, b] for every       *)
(*          created, start, commit and item line; b is the item's blob     *)
(*   links  per session: the blob files in its blobs/ folder               *)
(*   base   per session: the prefix a fork copied, as the code copied it   *)
(***************************************************************************)
EXTENDS Fork, TraceData, TLC

VARIABLE l
tvars == <<vars, l>>

TraceIds == {"s1", "s2", "s3"}
TraceBlobs == {"b1", "b2"}
TraceMaxLen == 32
TraceNoBlob == "none"

ASSUME TLCSet(1, 0)

Matches(e) ==
    /\ st' = e.st
    /\ lg' = e.lg
    /\ links' = e.links
    /\ base' = e.base

Act(e) ==
    CASE e.event = "Create"  -> Create(e.s)
      [] e.event = "Start"   -> Start(e.s)
      [] e.event = "Commit"  -> Commit(e.s)
      [] e.event = "Delete"  -> Delete(e.s)
      [] e.event = "PutBlob" -> PutBlob(e.s, e.b)
      [] e.event = "Item"    -> Item(e.s, e.b)
      [] e.event = "Fork"    -> Fork(e.src, e.f, e.at)

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

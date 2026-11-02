--------------------------- MODULE SubagentsLog ---------------------------
(***************************************************************************)
(* Checks a parent log fx saved against Subagents.tla, after the fact.     *)
(*                                                                         *)
(* Only the disk is known: the parent's child lines, in order (`Target`,   *)
(* records [k, c, w, o]), and which children have a log at the end         *)
(* (`FinalChildLog`), both from SavedChildren.tla. Threads, crashes,       *)
(* reopens and when each child's log appeared are left to TLC. Accepted    *)
(* when some behavior of the spec writes exactly these lines and ends      *)
(* with those child logs: the invariant `NotWritten` then fails.           *)
(*                                                                         *)
(* check_saved_logs.py writes SavedChildren.tla and runs this.             *)
(***************************************************************************)
EXTENDS Subagents, SavedChildren, TLC

ASSUME TLCSet(1, 0)

LogNext ==
    /\ Next
    /\ Len(plog') <= Len(Target)
    /\ plog' = SubSeq(Target, 1, Len(plog'))

LogSpec == Init /\ [][LogNext]_vars

Progress ==
    IF Len(plog) > TLCGet(1)
    THEN TLCSet(1, Len(plog)) /\ PrintT(<<"matched_lines", Len(plog)>>)
    ELSE TRUE

NotWritten == ~(plog = Target /\ childLog = FinalChildLog)
=============================================================================

------------------------- MODULE AcpToolDiffsTrace -------------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real `fx acp` binary *)
(* against AcpToolDiffs. TraceLog and the T constants come from the       *)
(* generated AcpToolDiffsObs module. Each observation is an update the    *)
(* client read for an edit call: its permission request, or its last      *)
(* update, completed or failed, with whether it had content and the diff  *)
(* it showed as a pair of versions. The driver numbers each file's texts  *)
(* as versions: a file's first text, or 0 if it didn't exist, then each   *)
(* new text a diff showed.                                                *)
(*                                                                         *)
(* fx's own steps, and its pending updates with no content, which change  *)
(* nothing the client shows, may happen between observations.             *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a step of the model. Exhausting the search without *)
(* that violation means the run is not a behavior of the model.            *)
(***************************************************************************)
EXTENDS AcpToolDiffs, AcpToolDiffsObs, Sequences

VARIABLE i

Hidden ==
    \/ \E c \in Calls : \/ Prepare(c) \/ AskClient(c) \/ Approve(c) \/ Deny(c)
                        \/ Commit(c) \/ Finish(c)
    \/ /\ chan # <<>>
       /\ Head(chan).status = "pending"
       /\ ~Head(chan).content
       /\ Deliver

Matches(o) ==
    LET m == Head(chan) IN
    /\ m.c = o.c
    /\ m.status = o.status
    /\ m.content = o.content
    /\ m.diff = o.diff

TraceInit == /\ i = 0
             /\ Init

TraceNext ==
    \/ /\ i < Len(TraceLog)
       /\ chan # <<>>
       /\ Matches(TraceLog[i + 1])
       /\ Deliver
       /\ i' = i + 1
    \/ /\ Hidden
       /\ UNCHANGED i

NotDone == i < Len(TraceLog)
=============================================================================

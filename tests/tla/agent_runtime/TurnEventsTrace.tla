-------------------------- MODULE TurnEventsTrace --------------------------
(***************************************************************************)
(* Trace validation: replays what one front end of the real fx binary     *)
(* showed in one turn against TurnEvents. TraceLog and the T constants     *)
(* come from the generated TurnEventsObs module. Script is the kinds the  *)
(* loop emits, in order, from the fake Gateway's replies, and each        *)
(* observation is one of them that the front end showed, with its place  *)
(* in Script.                                                             *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a step of the model and the turn ended with every   *)
(* event shown. Exhausting the search without that violation means the    *)
(* run is not a behavior of the model.                                     *)
(***************************************************************************)
EXTENDS TurnEvents, TurnEventsObs, Sequences

VARIABLE i

\* The front end showed the observed event next.
Shows(o) == Len(shown') = Len(shown) + 1 /\ shown'[Len(shown')] = o.at /\ Script[o.at] = o.kind

TraceInit == i = 0 /\ Init

TraceNext ==
    \/ /\ i < Len(TraceLog)
       /\ Next
       /\ Shows(TraceLog[i + 1])
       /\ i' = i + 1
    \/ /\ Next
       /\ Len(shown') = Len(shown)
       /\ UNCHANGED i

NotDone == ~(i = Len(TraceLog) /\ Done)
=============================================================================

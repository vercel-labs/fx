-------------------------- MODULE AcpFollowTrace --------------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real `fx acp` binary  *)
(* on one connection against AcpFollow: session/new or session/load opens  *)
(* the session, a prompt runs a turn and saves it, and a restart closes    *)
(* it. TraceLog and the T constants come from the generated AcpFollowObs   *)
(* module. Each open or save observation is what the client then holds:    *)
(* each message's turn, its id as a number (the n of a `turn-{n}-{k}` id,  *)
(* -1 for any other id), and whether a load replayed it.                   *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a step of the model. Exhausting the search without  *)
(* that violation means the run is not a behavior of the model.            *)
(***************************************************************************)
EXTENDS AcpFollow, AcpFollowObs, Sequences

VARIABLE i

Holds(o) == client'["c1"].has = o.has

ClientStep(o) ==
    CASE o.op = "open"  -> \E w \in Folders : Load("c1", w, FALSE) /\ Holds(o)
      [] o.op = "save"  -> TurnSave /\ Holds(o)
      [] o.op = "close" -> Close("c1")

TraceInit == /\ i = 0
             /\ Init

TraceNext ==
    \/ /\ i < Len(TraceLog)
       /\ ClientStep(TraceLog[i + 1])
       /\ i' = i + 1
    \/ /\ TurnStart
       /\ UNCHANGED i

NotDone == i < Len(TraceLog)
=============================================================================

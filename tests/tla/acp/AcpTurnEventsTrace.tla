------------------------ MODULE AcpTurnEventsTrace ------------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real `fx acp` binary *)
(* against AcpTurnEvents. TraceLog and the T constants come from the      *)
(* generated AcpTurnEventsObs module. Each observation is a prompt the    *)
(* client sent or a message it read: turn progress, a model call, a       *)
(* compaction update with its id and status, a shell call's last update   *)
(* with where its command result was, or the response, with whether it    *)
(* carried sh.fx/usage.                                                   *)
(*                                                                         *)
(* The loop's reports are hidden from the client, so the model may take   *)
(* any of its own steps between observations. A response also records    *)
(* what the driver knows from its fake Gateway: how many model calls the  *)
(* turn made, how many shell calls it ran, whether the model streamed     *)
(* output, and whether the turn compacted the context. So a model that    *)
(* sends every event of the parts the client lists must have sent one     *)
(* call message per request.                                              *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a step of the model. Exhausting the search without *)
(* that violation means the run is not a behavior of the model.            *)
(***************************************************************************)
EXTENDS AcpTurnEvents, AcpTurnEventsObs, Sequences

VARIABLE i

Hidden ==
    \/ Progress \/ Call \/ Shell \/ Finish \/ Respond
    \/ \E k \in Ks : \/ Choose(k) \/ Advance(k, "summary") \/ Advance(k, "published")
                     \/ \E o \in Outcomes : Settle(k, o)

\* The message the client reads next is the one observed.
Matches(o) ==
    LET m == Head(chan) IN
    /\ m.kind = o.kind
    /\ o.kind = "comp" => m.k = o.k /\ m.status = o.status
    /\ o.kind = "tool" => m.status = o.status
    /\ o.kind = "response" =>
         /\ m.usage = o.usage
         /\ calls = o.calls
         /\ shells = o.shells
         /\ o.streamed => prog >= 1
         /\ o.compacted => \E k \in Ks : outcome[k] = "succeeded"

ClientStep(o) ==
    IF o.kind = "prompt" THEN Prompt
    ELSE chan # <<>> /\ Matches(o) /\ Deliver

TraceInit == /\ i = 0
             /\ Init

TraceNext ==
    \/ /\ i < Len(TraceLog)
       /\ ClientStep(TraceLog[i + 1])
       /\ i' = i + 1
    \/ /\ Hidden
       /\ UNCHANGED i

NotDone == i < Len(TraceLog)
=============================================================================

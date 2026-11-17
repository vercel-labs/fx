------------------------ MODULE AcpDisconnectTrace ------------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real `fx acp` binary  *)
(* against AcpDisconnect. TraceLog and the T constants come from the       *)
(* generated AcpDisconnectObs module. An observation is a prompt the       *)
(* client sent, queued ones too; the client's disconnect; an `ask`, the    *)
(* moment a turn needs a permission; a prompt's `response`, with how its   *)
(* turn ended; and then fx's exit, with the outcome of each saved turn     *)
(* read from a later session/load, or `stuck` when fx did not exit in      *)
(* time. `stuck` matches only a model state that waits for the gone        *)
(* client. A permission answer is hidden.                                  *)
(*                                                                         *)
(* A turn ends only through an observed response: Respond takes the        *)
(* model's Finish for a completed turn, and an interrupted turn was saved  *)
(* when the client left, so Respond only checks it.                        *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a step of the model. Exhausting the search without  *)
(* that violation means the run is not a behavior of the model.            *)
(***************************************************************************)
EXTENDS AcpDisconnect, AcpDisconnectObs, Sequences

VARIABLES i, responded

Outcomes(s) == [k \in DOMAIN s |-> s[k].outcome]

\* A prompt's response: a completed turn ends here; an interrupted one was
\* saved when the client left. Each saved turn gets exactly one response.
Respond(o) ==
    /\ \/ /\ o.outcome = "completed" /\ Finish
       \/ UNCHANGED vars
    /\ Len(saved') > responded
    /\ saved'[responded + 1].outcome = o.outcome
    /\ responded' = responded + 1

ClientStep(o) ==
    CASE o.op = "prompt"     -> Prompt /\ UNCHANGED responded
      [] o.op = "disconnect" -> Disconnect /\ UNCHANGED responded
      [] o.op = "ask"        -> Ask /\ UNCHANGED responded
      [] o.op = "response"   -> Respond(o)
      [] o.op = "exit"       -> Exit /\ Outcomes(saved') = o.outcomes /\ UNCHANGED responded
      [] o.op = "stuck"      -> /\ ~connected /\ turn = "asking"
                                /\ UNCHANGED vars /\ UNCHANGED responded
      [] OTHER               -> FALSE

TraceInit == /\ i = 0 /\ responded = 0
             /\ Init

TraceNext ==
    \/ /\ i < Len(TraceLog)
       /\ ClientStep(TraceLog[i + 1])
       /\ i' = i + 1
    \/ /\ Answer
       /\ UNCHANGED <<i, responded>>

NotDone == i < Len(TraceLog)
=============================================================================

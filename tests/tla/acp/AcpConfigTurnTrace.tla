------------------------ MODULE AcpConfigTurnTrace ------------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real `fx acp` binary  *)
(* against AcpConfigTurn. TraceLog and the T constants come from the       *)
(* generated AcpConfigTurnObs module. An observation is a prompt the       *)
(* client sent, a model request the fake Gateway got, with the settings    *)
(* version its model names, a set_config_option answer, "ok" or "busy",    *)
(* or a prompt's response. A credential renewal is hidden.                 *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a step of the model. Exhausting the search without  *)
(* that violation means the run is not a behavior of the model.            *)
(***************************************************************************)
EXTENDS AcpConfigTurn, AcpConfigTurnObs, Sequences

VARIABLE i

ClientStep(o) ==
    CASE o.op = "prompt"   -> StartTurn
      [] o.op = "request"  -> Request /\ log'[Len(log')].ver = o.ver
      [] o.op = "config"   -> SetConfig(o.provider) /\ answers'[Len(answers')] = o.answer
      [] o.op = "response" -> EndTurn

TraceInit == /\ i = 0
             /\ Init

TraceNext ==
    \/ /\ i < Len(TraceLog)
       /\ ClientStep(TraceLog[i + 1])
       /\ i' = i + 1
    \/ /\ Renew
       /\ UNCHANGED i

NotDone == i < Len(TraceLog)
=============================================================================

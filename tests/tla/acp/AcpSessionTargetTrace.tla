----------------------- MODULE AcpSessionTargetTrace -----------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real `fx acp` binary *)
(* against AcpSessionTarget. TraceLog and TFixed come from the generated   *)
(* AcpSessionTargetObs module; each element of TraceLog has the fields of  *)
(* Obs.                                                                    *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a step of the model. Exhausting the search without *)
(* that violation means the run is not a behavior of the model.            *)
(***************************************************************************)
EXTENDS AcpSessionTarget, AcpSessionTargetObs, Sequences

VARIABLE i

StepFor(o) ==
    CASE o.op = "new"           -> NewSession
      [] o.op = "restart"       -> Restart
      [] o.op = "oversize"      -> Oversize
      [] o.op \in TargetOps     -> Target(o.op, o.arg)
      [] o.op = "close"         -> Close(o.arg)
      [] o.op \in RestoreOps    -> Restore(o.op, o.arg)
      [] OTHER                  -> FALSE

ASSUME Len(TraceLog) >= 1 /\ TraceLog[1].op = "restart"

TraceInit == /\ i = 1
             /\ Init
             /\ last = TraceLog[1]

TraceNext == /\ i < Len(TraceLog)
             /\ StepFor(TraceLog[i + 1])
             /\ last' = TraceLog[i + 1]
             /\ i' = i + 1

NotDone == i < Len(TraceLog)
=============================================================================

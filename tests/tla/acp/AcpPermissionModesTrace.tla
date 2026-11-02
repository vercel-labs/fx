--------------------- MODULE AcpPermissionModesTrace ---------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real `fx acp` binary *)
(* against AcpPermissionModes. TraceLog comes from the generated           *)
(* AcpPermissionModesObs module; each element has the fields of Obs.       *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a spec step. Exhausting the search without that     *)
(* violation means the run is not a behavior of the spec.                  *)
(***************************************************************************)
EXTENDS AcpPermissionModes, AcpPermissionModesObs, Sequences

VARIABLE i

traceVars == <<vars, i>>

Match(o) ==
    /\ last.op = o.op
    /\ last.arg = o.arg
    /\ last.ok = o.ok
    /\ last.hasView = o.hasView
    /\ o.hasView => (last.view = o.view)
    /\ last.enforce = o.enforce
    /\ last.stored = o.stored

StepFor(o) ==
    CASE o.op = "set"    -> SetConfig(o.arg)
      [] o.op = "legacy" -> SetLegacy(o.arg)
      [] o.op = "prompt" -> Prompt
      [] o.op = "resume" -> Resume
      [] o.op = "fresh"  -> Fresh
      [] o.op = "new"    -> NewSession
      [] o.op = "other"  -> External(o.arg)
      [] o.op = "status" -> Status
      [] OTHER           -> FALSE

ASSUME Len(TraceLog) >= 1 /\ TraceLog[1].op = "new"

TraceInit == /\ i = 1
             /\ Init
             /\ Match(TraceLog[1])

TraceNext == /\ i < Len(TraceLog)
             /\ \E o \in {TraceLog[i + 1]} :
                    /\ StepFor(o)
                    /\ Match(o)'
             /\ i' = i + 1

NotDone == i < Len(TraceLog)
=============================================================================

---------------------------- MODULE AcpSpeedTrace ----------------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real `fx acp` binary *)
(* against AcpSpeed. TraceLog comes from the generated AcpSpeedObs module. *)
(* Each element is                                                         *)
(*   [op, arg, ok, speed, hasView, view]                                   *)
(* where view is the client-visible configOptions projection. Steps that  *)
(* return no config (errors and prompts) set hasView to FALSE and carry a *)
(* placeholder record, so TLC never compares a record with a string.      *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated (exit 12) means every *)
(* observation matched a spec step. Exhausting the search without that    *)
(* violation means the run is not a behavior of the spec.                  *)
(***************************************************************************)
EXTENDS AcpSpeed, AcpSpeedObs, Sequences

VARIABLE i

traceVars == <<vars, i>>

Match(o) ==
    /\ last.op = o.op
    /\ last.arg = o.arg
    /\ last.ok = o.ok
    /\ last.speed = o.speed
    /\ o.hasView => (View = o.view)

StepFor(o) ==
    CASE o.op = "fast"      -> SetFast(o.arg = "true")
      [] o.op = "ultrafast" -> SetUltra(o.arg = "true")
      [] o.op = "model"     -> SetModel(o.arg)
      [] o.op = "unknown"   -> SetUnknown
      [] o.op = "prompt"    -> Prompt
      [] o.op = "resume"    -> Resume
      [] OTHER              -> FALSE

ASSUME Len(TraceLog) >= 1 /\ TraceLog[1].op = "new"

TraceInit == /\ i = 1
             /\ Init
             /\ Match(TraceLog[1])

TraceNext == /\ i < Len(TraceLog)
             /\ \E o \in {TraceLog[i + 1]} :
                    /\ StepFor(o)
                    /\ Match(o)'
             /\ i' = i + 1

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

NotDone == i < Len(TraceLog)
=============================================================================

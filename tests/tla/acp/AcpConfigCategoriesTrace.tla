----------------------- MODULE AcpConfigCategoriesTrace -----------------------
(***************************************************************************)
(* Trace validation: replays the config options one run of the real       *)
(* `fx acp` binary listed against AcpConfigCategories. TraceLog comes from *)
(* the generated AcpConfigCategoriesObs module; each element is            *)
(*   [op, options]                                                         *)
(* where options is the configOptions array as [id, category] records in  *)
(* list order.                                                             *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a spec step.                                        *)
(***************************************************************************)
EXTENDS Naturals, AcpConfigCategories, AcpConfigCategoriesObs

VARIABLE i

traceVars == <<vars, i>>

TraceInit == /\ i = 0
             /\ Init

TraceNext == /\ i < Len(TraceLog)
             /\ \E o \in {TraceLog[i + 1]} :
                    /\ Advertise(o.op)
                    /\ options' = o.options
             /\ i' = i + 1

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

NotDone == i < Len(TraceLog)
=============================================================================

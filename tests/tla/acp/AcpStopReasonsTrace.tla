------------------------- MODULE AcpStopReasonsTrace -------------------------
(***************************************************************************)
(* Trace validation: replays the stop reasons one run of the real `fx acp` *)
(* binary answered against AcpStopReasons. TraceLog and TraceProtocol come *)
(* from the generated AcpStopReasonsObs module; each TraceLog element is   *)
(*   [reason, response, wire]                                              *)
(* where reason is the internal reason the driver's scenario ends the     *)
(* turn with and wire is the stopReason fx sent.                           *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a spec step.                                        *)
(***************************************************************************)
EXTENDS Naturals, Sequences, AcpStopReasons, AcpStopReasonsObs

VARIABLE i

traceVars == <<vars, i>>

TraceInit == /\ i = 0
             /\ Init
             /\ protocol = TraceProtocol

TraceNext == /\ i < Len(TraceLog)
             /\ \E o \in {TraceLog[i + 1]} :
                    /\ Answer(o.reason, o.response)
                    /\ wire' = o.wire
             /\ i' = i + 1

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

NotDone == i < Len(TraceLog)
=============================================================================

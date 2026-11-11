------------------------- MODULE AcpStopReasonsTrace -------------------------
(***************************************************************************)
(* Trace validation: replays the stop reasons one run of the real `fx acp` *)
(* binary answered against AcpStopReasons. TraceLog and TraceProtocol come *)
(* from the generated AcpStopReasonsObs module; each TraceLog element is   *)
(*   [cause, response, wire, history]                                      *)
(* where cause is what the driver's scenario does to end the turn, wire is *)
(* the stopReason fx sent, and history is kept or dropped when the driver  *)
(* sent a next prompt and read whether its request held the turn, and      *)
(* unseen when it did not.                                                 *)
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
                    /\ Answer(o.cause, o.response)
                    /\ wire' = o.wire
                    /\ o.history \in {"unseen", History(o.cause)}
             /\ i' = i + 1

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

NotDone == i < Len(TraceLog)
=============================================================================

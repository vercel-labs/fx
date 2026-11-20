---------------------- MODULE AcpPromptDeliveryTrace ----------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real `fx acp` binary *)
(* against AcpPromptDelivery. TraceLog and the constants come from the     *)
(* generated AcpPromptDeliveryObs module. Each element names one action of *)
(* the model and, where the driver observed it, every prompt's answer so   *)
(* far and what the running turn's model request held.                     *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a step of the model. Exhausting the search without *)
(* that violation means the run is not a behavior of the model.            *)
(***************************************************************************)
EXTENDS AcpPromptDelivery, AcpPromptDeliveryObs, Sequences

VARIABLE i

StepFor(o) ==
    CASE o.act = "send"       -> Send(o.msg)
      [] o.act = "stream_end" -> StreamEnd
      [] o.act = "tool_call"  -> ToolCall
      [] o.act = "tool_end"   -> ToolEnd
      [] o.act = "reply_end"  -> ReplyEnd
      [] o.act = "stop_input" -> StopInput
      [] o.act = "finish"     -> Finish
      [] o.act = "cancel"     -> Cancel
      [] o.act = "withdraw"   -> Withdraw(o.msg)
      [] o.act = "close"      -> Close
      [] OTHER                -> FALSE

Checked(o) ==
    /\ o.checkAnswers => answers' = o.answers
    /\ o.checkCtx => (running' /\ cur'.ctx = o.ctx)

TraceInit == /\ i = 0
             /\ Init

TraceNext == /\ i < Len(TraceLog)
             /\ StepFor(TraceLog[i + 1])
             /\ Checked(TraceLog[i + 1])
             /\ i' = i + 1

NotDone == i < Len(TraceLog)
=============================================================================

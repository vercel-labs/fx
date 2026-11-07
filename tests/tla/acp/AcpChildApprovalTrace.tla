----------------------- MODULE AcpChildApprovalTrace -----------------------
(***************************************************************************)
(* Trace validation: replays what an ACP client saw in one run of the real *)
(* `fx acp` binary against AcpChildApproval. TraceLog comes from the       *)
(* generated AcpChildApprovalObs module                                    *)
(* (tests/tla/drivers/acp/child_approval/driver.ts). Steps the client      *)
(* cannot see (a subagent's own turn, fx reading an answer, a decision)   *)
(* may run between observations, but none of them may show the client a   *)
(* request. A parent's stop is observed when the fake Gateway hands the    *)
(* parent the stop call.                                                   *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a step of the spec. Exhausting the search without  *)
(* that violation means the run is not a behavior of the spec.             *)
(***************************************************************************)
EXTENDS AcpChildApproval, AcpChildApprovalObs, Sequences

VARIABLE i

traceVars == <<vars, i>>

\* A step the client cannot see.
Hidden ==
    /\ \E c \in Children : FxStep(c)
    /\ \A c \in Children : atClient'[c] => atClient[c]

Observed(o) ==
    CASE o.op = "request"     -> /\ \E c \in Children : FxStep(c)
                                 /\ ~atClient[o.c] /\ atClient'[o.c]
      [] o.op = "answer"      -> ClientSend(o.c, o.a)
      [] o.op = "late"        -> LateSend(o.c, o.a)
      [] o.op = "stop"        -> Stop(o.c)
      [] o.op = "cancel"      -> Cancel
      [] o.op = "promptEnd"   -> PromptEnd
      [] o.op = "promptStart" -> Reopen
      [] o.op = "final"       -> /\ UNCHANGED vars
                                 /\ \A c \in Children : child[c] = "done" /\ result[c] = o.results[c]
      [] OTHER                -> FALSE

TraceInit == Init /\ i = 0

TraceNext ==
    \/ /\ i < Len(TraceLog)
       /\ Observed(TraceLog[i + 1])
       /\ i' = i + 1
    \/ /\ Hidden
       /\ UNCHANGED i

NotDone == i < Len(TraceLog)
=============================================================================

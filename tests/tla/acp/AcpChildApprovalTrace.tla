----------------------- MODULE AcpChildApprovalTrace -----------------------
(***************************************************************************)
(* Trace validation: replays what an ACP client saw in one run of the real *)
(* `fx acp` binary against AcpChildApproval. TraceLog comes from the       *)
(* generated AcpChildApprovalObs module                                    *)
(* (tests/tla/drivers/acp/child_approval/driver.ts). Steps the client      *)
(* cannot see (a subagent's own turn, fx reading an answer, a decision,    *)
(* the prompt thread taking and letting go of the card lock) may run       *)
(* between observations, but none of them may show the client a request,   *)
(* announce a card, or end one. A parent's stop is observed when the fake  *)
(* Gateway hands the parent the stop call.                                 *)
(*                                                                         *)
(* A card's call id is observed too: a subagent's must differ from every   *)
(* id the parent's own cards used (ParentIds) and from every earlier       *)
(* subagent card's. That is the model's UniqueIds, read off the run.       *)
(*                                                                         *)
(* The trace lines each request left for how it ended (a cancel's, a      *)
(* stop's withdrawal, a wait that found its entry gone) are counted from   *)
(* the run's trace log and compared with the model's count when the run    *)
(* ends (TraceOnce, CancelTraced).                                         *)
(*                                                                         *)
(* A card's end is observed whoever ended it: the child's runtime, or the  *)
(* prompt's end closing it. The prompt's response is observed too, and     *)
(* once it is, no card may change until the next prompt starts             *)
(* (NoCardChangeAfterResponse).                                            *)
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
    /\ \/ \E c \in Children : FxStep(c)
       \/ BeginClose \/ EndClose
    /\ \A c \in Children : sent'[c] => sent[c]
    /\ \A c \in Children : atClient'[c] => atClient[c]
    /\ \A c \in Children : card[c] = "none" => card'[c] = "none"
    /\ \A c \in Children : card'[c] \in FinalCards => card[c] \in FinalCards

Observed(o) ==
    CASE o.op = "announce"     -> /\ \E c \in Children : FxStep(c)
                                  /\ card[o.c] = "none" /\ card'[o.c] = "pending"
                                  /\ o.tc \notin ParentIds
                                  /\ \A j \in 1..i : TraceLog[j].op = "announce" => TraceLog[j].tc # o.tc
      [] o.op = "request"      -> /\ \E c \in Children : FxStep(c)
                                  /\ ~atClient[o.c] /\ atClient'[o.c]
      [] o.op = "lateRequest"  -> /\ Send(o.c) /\ entry[o.c] = "cancelled"
      [] o.op = "card"         -> /\ \/ FinishCard(o.c)
                                     \/ CloseCard(o.c)
                                  /\ card'[o.c] = o.status
      [] o.op = "answer"       -> ClientSend(o.c, o.a)
      [] o.op = "late"         -> LateSend(o.c, o.a)
      [] o.op = "stop"         -> Stop(o.c)
      [] o.op = "cancel"       -> Cancel
      [] o.op = "promptEnd"    -> PromptEnd
      [] o.op = "response"     -> Respond
      [] o.op = "promptStart"  -> Reopen
      [] o.op = "pRequest"     -> ParentAsk /\ parent' = "open"
      [] o.op = "pAnswer"      -> ParentAnswer
      [] o.op = "otherRequest" -> OtherAsk
      [] o.op = "otherAnswer"  -> OtherAnswer
      [] o.op = "final"        -> /\ UNCHANGED vars
                                  /\ \A c \in Children : child[c] = "done" /\ result[c] = o.results[c]
                                  /\ \A c \in Children : card[c] # "pending"
                                  /\ Lines => \A c \in Children : lines[c] = o.lines[c]
      [] OTHER                 -> FALSE

TraceInit == Init /\ i = 0

TraceNext ==
    \/ /\ i < Len(TraceLog)
       /\ Observed(TraceLog[i + 1])
       /\ i' = i + 1
    \/ /\ Hidden
       /\ UNCHANGED i

NotDone == i < Len(TraceLog)
=============================================================================

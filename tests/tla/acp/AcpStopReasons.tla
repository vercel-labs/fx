---------------------------- MODULE AcpStopReasons ----------------------------
(***************************************************************************)
(* The stop reason fx answers a finished session/prompt with, as           *)
(* PromptProtocol in src/acp/types.zig writes it.                          *)
(*                                                                         *)
(*  - A turn ends for one cause. The cause gives the turn one internal     *)
(*    reason (StopReason in src/acp/types.zig), set by finalizeTurn in     *)
(*    src/acp/prompt.zig. fx acp sends the ACP v1 name for it. libfx, the  *)
(*    only host that sets minimal_kernel, keeps the names its FxStopReason *)
(*    type documents.                                                      *)
(*  - The response to the prompt that started the turn and the response   *)
(*    to each steering prompt the turn absorbed carry the same reason.    *)
(*  - Distinct reasons stay distinct on the wire: a turn reports one named *)
(*    stop reason.                                                         *)
(*  - Only libfx yields a turn for a later resume.                         *)
(*  - The reason agrees with what the next prompt holds. ACP says a        *)
(*    refusal leaves the turn out of the next prompt, and fx drops the     *)
(*    turn of a failed request. The step limit keeps its turn, so it       *)
(*    answers max_turn_requests, which says nothing of the kind.           *)
(*                                                                         *)
(* Mapped = FALSE is fx before the fix, which sent the internal names to  *)
(* ACP clients. LibfxMapped = TRUE is a planted bug: libfx gets the ACP    *)
(* names too. StepLimitNamed = FALSE is fx before the step-limit fix: the *)
(* limit ended the turn as failed, so it answered refusal while keeping    *)
(* the turn. StepLimitDropped = TRUE is a planted bug: the limit names     *)
(* max_turn_requests and leaves its turn out of the next prompt.           *)
(***************************************************************************)
EXTENDS TLC

CONSTANTS Mapped, LibfxMapped, StepLimitNamed, StepLimitDropped

Causes == {"finished", "length_limit", "step_limit", "request_failed", "cancelled", "yielded"}
Reasons == {"end_turn", "max_output_tokens", "max_model_turns", "refused", "cancelled", "yielded"}
AcpReasons == {"end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled"}
Protocols == {"acp", "libfx"}
Responses == {"prompt", "steering"}

ReasonOf(c) == CASE c = "finished" -> "end_turn"
                 [] c = "length_limit" -> "max_output_tokens"
                 [] c = "step_limit" -> IF StepLimitNamed THEN "max_model_turns" ELSE "refused"
                 [] c = "request_failed" -> "refused"
                 [] c = "cancelled" -> "cancelled"
                 [] c = "yielded" -> "yielded"

AcpName(r) == CASE r = "max_output_tokens" -> "max_tokens"
                [] r = "max_model_turns" -> "max_turn_requests"
                [] r = "refused" -> "refusal"
                [] OTHER -> r

Wire(p, r) == IF Mapped /\ (p = "acp" \/ LibfxMapped) THEN AcpName(r) ELSE r

(* What the next prompt holds of the turn: its prompt and its tool calls.  *)
(* A failed request leaves the turn out, and the step limit keeps it. The  *)
(* laws below read this only for the reasons that say something about the *)
(* next prompt.                                                            *)
History(c) == IF c = "request_failed" \/ (c = "step_limit" /\ StepLimitDropped)
                THEN "dropped"
                ELSE "kept"

Reachable(p, r) == r = "yielded" => p = "libfx"

VARIABLES protocol, cause, reason, response, wire, history

vars == <<protocol, cause, reason, response, wire, history>>

Init == /\ protocol \in Protocols
        /\ cause = "none"
        /\ reason = "none"
        /\ response = "none"
        /\ wire = "none"
        /\ history = "none"

(* A turn ends for cause c, and fx answers a response of kind k. *)
Answer(c, k) ==
    /\ Reachable(protocol, ReasonOf(c))
    /\ cause' = c
    /\ reason' = ReasonOf(c)
    /\ response' = k
    /\ wire' = Wire(protocol, ReasonOf(c))
    /\ history' = History(c)
    /\ UNCHANGED protocol

Next == \E c \in Causes, k \in Responses : Answer(c, k)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------

TypeOK == /\ protocol \in Protocols
          /\ cause \in Causes \cup {"none"}
          /\ reason \in Reasons \cup {"none"}
          /\ response \in Responses \cup {"none"}
          /\ history \in {"kept", "dropped", "none"}

(* An ACP client gets a value of the ACP v1 StopReason enum. *)
AcpStopReasonValid == (protocol = "acp" /\ reason # "none") => wire \in AcpReasons

(* libfx's result type keeps fx's own names. *)
LibfxKeepsNames == (protocol = "libfx" /\ reason # "none") => wire = reason

(* No two reasons a host can see share a wire name. *)
OneNamedReason ==
    \A r1, r2 \in Reasons :
        (r1 # r2 /\ Reachable(protocol, r1) /\ Reachable(protocol, r2))
            => Wire(protocol, r1) # Wire(protocol, r2)

(* A refusal says the turn is left out of the next prompt, so the next     *)
(* prompt leaves it out. The libfx name is refused.                        *)
RefusalLeavesTurnOut == wire \in {"refusal", "refused"} => history = "dropped"

(* A turn limit says nothing of the kind, and fx keeps the turn so that a   *)
(* follow-up prompt continues it. The libfx name is max_model_turns.       *)
TurnLimitKeepsTurn == wire \in {"max_turn_requests", "max_model_turns"} => history = "kept"
=============================================================================

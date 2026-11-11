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
(*  - The reason agrees with what the next prompt holds, for every cause.  *)
(*    ACP says a refusal leaves the turn out of the next prompt, so a turn *)
(*    fx leaves out answers refusal and a turn fx keeps never does.        *)
(*                                                                         *)
(* A failed turn is kept or dropped. TurnFinalizationGuard.finish in       *)
(* src/core/agent/runtime/finalization.zig attaches a finished prompt      *)
(* exactly where the turn is saved in the history, and a failed finish     *)
(* with a finished prompt and no disposition of its own is a kept failure. *)
(* The rule, per cause:                                                    *)
(*   finished       a turn that ends normally: end_turn, kept              *)
(*   length_limit   max_tokens, kept                                       *)
(*   step_limit     max_turn_requests, kept                                *)
(*   kept_failure   a failed turn fx keeps in its history: end_turn, kept  *)
(*   dropped_failure a failed turn fx leaves out: refusal, dropped         *)
(*   cancelled      cancelled, kept                                        *)
(*   yielded        yielded (libfx only), kept                             *)
(*                                                                         *)
(* Mapped = FALSE is fx before the fix, which sent the internal names to  *)
(* ACP clients. LibfxMapped = TRUE is a planted bug: libfx gets the ACP    *)
(* names too. StepLimitNamed = FALSE is fx before the step-limit fix: the *)
(* limit ended the turn as failed, so it answered refusal while keeping    *)
(* the turn. StepLimitDropped = TRUE is a planted bug: the limit names     *)
(* max_turn_requests and leaves its turn out of the next prompt.           *)
(* KeptFailureEnds = FALSE is fx before the kept-failure fix: a failed    *)
(* turn it keeps answered refusal, so a client dropped a turn the model   *)
(* still held. DroppedFailureEnds = TRUE is a planted bug: every failure  *)
(* ends with end_turn, so a client shows a turn fx left out.               *)
(***************************************************************************)
EXTENDS TLC

CONSTANTS Mapped, LibfxMapped, StepLimitNamed, StepLimitDropped, KeptFailureEnds, DroppedFailureEnds

Causes == {"finished", "length_limit", "step_limit", "kept_failure", "dropped_failure", "cancelled", "yielded"}
Reasons == {"end_turn", "max_output_tokens", "max_model_turns", "refused", "cancelled", "yielded"}
AcpReasons == {"end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled"}
Protocols == {"acp", "libfx"}
Responses == {"prompt", "steering"}

ReasonOf(c) == CASE c = "finished" -> "end_turn"
                 [] c = "length_limit" -> "max_output_tokens"
                 [] c = "step_limit" -> IF StepLimitNamed THEN "max_model_turns" ELSE "refused"
                 [] c = "kept_failure" -> IF KeptFailureEnds THEN "end_turn" ELSE "refused"
                 [] c = "dropped_failure" -> IF DroppedFailureEnds THEN "end_turn" ELSE "refused"
                 [] c = "cancelled" -> "cancelled"
                 [] c = "yielded" -> "yielded"

AcpName(r) == CASE r = "max_output_tokens" -> "max_tokens"
                [] r = "max_model_turns" -> "max_turn_requests"
                [] r = "refused" -> "refusal"
                [] OTHER -> r

Wire(p, r) == IF Mapped /\ (p = "acp" \/ LibfxMapped) THEN AcpName(r) ELSE r

(* What the next prompt holds of the turn: its prompt and its tool calls.  *)
(* fx leaves out only a failed turn it did not save, and keeps every other *)
(* turn. The laws below read this for every cause.                         *)
History(c) == IF c = "dropped_failure" \/ (c = "step_limit" /\ StepLimitDropped)
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

(* The other direction: a turn the next prompt leaves out says so. A client *)
(* that read end_turn would show a turn the model does not hold.           *)
(* RefusalLeavesTurnOut and DroppedTurnRefuses together are the law of the  *)
(* model: for every cause, the stop reason agrees with what the next       *)
(* prompt holds.                                                           *)
DroppedTurnRefuses == history = "dropped" => wire \in {"refusal", "refused"}
=============================================================================

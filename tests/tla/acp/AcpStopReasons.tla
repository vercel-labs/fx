---------------------------- MODULE AcpStopReasons ----------------------------
(***************************************************************************)
(* The stop reason fx answers a finished session/prompt with, as           *)
(* PromptProtocol in src/acp/types.zig writes it.                          *)
(*                                                                         *)
(*  - A turn ends with one internal reason (StopReason in                  *)
(*    src/acp/types.zig). fx acp sends the ACP v1 name for it. libfx, the  *)
(*    only host that sets minimal_kernel, keeps the names its FxStopReason *)
(*    type documents.                                                      *)
(*  - The response to the prompt that started the turn and the response   *)
(*    to each steering prompt the turn absorbed carry the same reason.    *)
(*  - Distinct reasons stay distinct on the wire: a turn reports one named *)
(*    stop reason.                                                         *)
(*  - Only libfx yields a turn for a later resume.                         *)
(*                                                                         *)
(* Mapped = FALSE is fx before the fix, which sent the internal names to  *)
(* ACP clients. LibfxMapped = TRUE is a planted bug: libfx gets the ACP    *)
(* names too.                                                              *)
(***************************************************************************)
EXTENDS TLC

CONSTANTS Mapped, LibfxMapped

Reasons == {"end_turn", "max_output_tokens", "max_model_turns", "refused", "cancelled", "yielded"}
AcpReasons == {"end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled"}
Protocols == {"acp", "libfx"}
Responses == {"prompt", "steering"}

AcpName(r) == CASE r = "max_output_tokens" -> "max_tokens"
                [] r = "max_model_turns" -> "max_turn_requests"
                [] r = "refused" -> "refusal"
                [] OTHER -> r

Wire(p, r) == IF Mapped /\ (p = "acp" \/ LibfxMapped) THEN AcpName(r) ELSE r

Reachable(p, r) == r = "yielded" => p = "libfx"

VARIABLES protocol, reason, response, wire

vars == <<protocol, reason, response, wire>>

Init == /\ protocol \in Protocols
        /\ reason = "none"
        /\ response = "none"
        /\ wire = "none"

(* A turn ends with reason r, and fx answers a response of kind k. *)
Answer(r, k) ==
    /\ Reachable(protocol, r)
    /\ reason' = r
    /\ response' = k
    /\ wire' = Wire(protocol, r)
    /\ UNCHANGED protocol

Next == \E r \in Reasons, k \in Responses : Answer(r, k)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------

TypeOK == /\ protocol \in Protocols
          /\ reason \in Reasons \cup {"none"}
          /\ response \in Responses \cup {"none"}

(* An ACP client gets a value of the ACP v1 StopReason enum. *)
AcpStopReasonValid == (protocol = "acp" /\ reason # "none") => wire \in AcpReasons

(* libfx's result type keeps fx's own names. *)
LibfxKeepsNames == (protocol = "libfx" /\ reason # "none") => wire = reason

(* No two reasons a host can see share a wire name. *)
OneNamedReason ==
    \A r1, r2 \in Reasons :
        (r1 # r2 /\ Reachable(protocol, r1) /\ Reachable(protocol, r2))
            => Wire(protocol, r1) # Wire(protocol, r2)
=============================================================================

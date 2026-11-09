-------------------------- MODULE BinaryImageRoute --------------------------
(***************************************************************************)
(* Checks what the built fx binary did against ImageRoute.                 *)
(*                                                                         *)
(* tests/tla/drivers/image_route/binary-to-spec.ts runs `fx ask` turns     *)
(* against a fake gateway and records each one in BinaryData.tla, which   *)
(* is generated for each run: the catalog view the turn saw, the request   *)
(* flags the shell must compute from the turn itself (an image attached    *)
(* now, an image an earlier turn left in the history, the vision tool, a   *)
(* down catalog), and what the binary did: the error it failed with, or    *)
(* what its first model request carried and what it told the user.        *)
(*                                                                         *)
(* A turn starts with no notice spent, so the model's answer to the        *)
(* turn's first request is DecideOut under the support the catalog's view  *)
(* derives. Observe maps those effects onto what a request body and the    *)
(* process show. BinaryConforms holds when the binary showed exactly that  *)
(* for every turn, which checks the shell's flags as well as the core.     *)
(***************************************************************************)
EXTENDS Naturals, Sequences, BinaryData

\* at is the turn under check, and expected is what the model says that
\* turn shows, kept as a variable so TLC's error trace prints it.
VARIABLES at, expected

IR == INSTANCE ImageRoute WITH support <- "unknown", resolved <- FALSE, notified <- FALSE,
                               pending <- <<>>, out <- <<>>, act <- [name |-> "Init"]

Kinds(effects) == {effects[i].kind : i \in 1..Len(effects)}
Answer(effects) == CHOOSE e \in {effects[i] : i \in 1..Len(effects)} : e.kind \in {"send", "fail"}

\* What a turn shows for the effects its first request r got. Every field
\* is present for every outcome, so observations compare as plain records.
Observe(effects, r) ==
    LET e == Answer(effects)
        sent == e.kind = "send"
    IN [kind |-> e.kind,
        reason |-> IF sent THEN "none" ELSE e.reason,
        notified |-> "notify" \in Kinds(effects),
        inline_now |-> IF sent THEN r.user_images /\ e.route = "native" ELSE FALSE,
        inline_earlier |-> IF sent THEN e.earlier_images = "attached" ELSE FALSE,
        vision_tool |-> IF sent THEN e.mode # "unavailable" ELSE FALSE,
        vision_required |-> IF sent THEN e.mode = "required" ELSE FALSE,
        references |-> IF sent THEN e.route = "fallback" /\ (r.user_images \/ r.earlier_images) ELSE FALSE,
        earlier_note |-> IF ~sent THEN "none"
                         ELSE CASE e.earlier_images = "withheld_unknown" -> "unknown"
                                [] e.earlier_images = "withheld_dead_end" -> "dead_end"
                                [] OTHER -> "none"]

Expected(o) == Observe(IR!DecideOut(IR!Derive(o.view), o.req, FALSE), o.req)

Init == at = 1 /\ expected = Expected(Observations[1])
Next == at < Len(Observations) /\ at' = at + 1 /\ expected' = Expected(Observations[at + 1])
Spec == Init /\ [][Next]_<<at, expected>>

BinaryConforms == expected = Observations[at].seen
=============================================================================

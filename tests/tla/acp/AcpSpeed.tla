------------------------------- MODULE AcpSpeed -------------------------------
(***************************************************************************)
(* Per-session speed contract for fx's ACP server, mirroring the CLI:     *)
(* one Standard / Fast / Ultrafast choice per chat.                        *)
(*                                                                         *)
(*  - A client sees the `fast` option only for models that offer Fast and  *)
(*    the `ultrafast` option only for models that offer Ultrafast.         *)
(*  - Turning one lane on turns the other off.                            *)
(*  - Enabling a lane the model lacks is rejected; disabling always works. *)
(*  - Switching models turns off a lane the new model lacks.               *)
(*  - The choice is saved with the chat and survives resume.               *)
(*  - Unknown config ids are rejected instead of silently succeeding.      *)
(*  - A prompt carries Ultrafast, else Fast when the model supports it.   *)
(*                                                                         *)
(* `fast` may start on for a model without Fast when the user's settings  *)
(* default enables it (CLI parity); it is then hidden and has no effect.  *)
(* Every value is a string or boolean so TLC never compares mixed types.  *)
(***************************************************************************)
EXTENDS Naturals, TLC

CONSTANTS Models, SupFast, SupUltra

ASSUME SupFast \subseteq Models /\ SupUltra \subseteq Models

VARIABLES model, fast, ultra, last

vars == <<model, fast, ultra, last>>

Ops == {"new", "fast", "ultrafast", "model", "unknown", "prompt", "resume"}
Speeds == {"none", "standard", "fast", "ultrafast"}

Bool(b) == IF b THEN "true" ELSE "false"

(* What a client reads from configOptions after a step. *)
View == [model |-> model,
         fast  |-> IF model \in SupFast THEN Bool(fast) ELSE "absent",
         ultra |-> IF model \in SupUltra THEN Bool(ultra) ELSE "absent"]

(* The lane a prompt sends to the Gateway. *)
RequestSpeed == IF ultra THEN "ultrafast"
                ELSE IF fast /\ model \in SupFast THEN "fast"
                ELSE "standard"

Result(op, arg, ok, speed) == [op |-> op, arg |-> arg, ok |-> ok, speed |-> speed]

Init == /\ model \in Models
        /\ fast \in BOOLEAN
        /\ ultra = FALSE
        /\ last = Result("new", "none", TRUE, "none")

SetFast(b) ==
    IF b /\ model \notin SupFast
    THEN /\ last' = Result("fast", Bool(b), FALSE, "none")
         /\ UNCHANGED <<model, fast, ultra>>
    ELSE /\ fast' = b
         /\ ultra' = (ultra /\ ~b)
         /\ last' = Result("fast", Bool(b), TRUE, "none")
         /\ UNCHANGED model

SetUltra(b) ==
    IF b /\ model \notin SupUltra
    THEN /\ last' = Result("ultrafast", Bool(b), FALSE, "none")
         /\ UNCHANGED <<model, fast, ultra>>
    ELSE /\ ultra' = b
         /\ fast' = (fast /\ ~b)
         /\ last' = Result("ultrafast", Bool(b), TRUE, "none")
         /\ UNCHANGED model

SetModel(m) ==
    /\ model' = m
    /\ fast' = (fast /\ m \in SupFast)
    /\ ultra' = (ultra /\ m \in SupUltra)
    /\ last' = Result("model", m, TRUE, "none")

SetUnknown ==
    /\ last' = Result("unknown", "none", FALSE, "none")
    /\ UNCHANGED <<model, fast, ultra>>

Prompt ==
    /\ last' = Result("prompt", "none", TRUE, RequestSpeed)
    /\ UNCHANGED <<model, fast, ultra>>

(* A new process resumes the saved chat. Assumption: the chat has had a    *)
(* prompt; the v2 store saves a chat at its first turn, so resuming an     *)
(* untouched chat fails on main independently of speed.                    *)
Resume ==
    /\ last' = Result("resume", "none", TRUE, "none")
    /\ UNCHANGED <<model, fast, ultra>>

Next == \/ \E b \in BOOLEAN : SetFast(b) \/ SetUltra(b)
        \/ \E m \in Models : SetModel(m)
        \/ SetUnknown
        \/ Prompt
        \/ Resume

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety properties checked by TLC; planted mutants must violate them. *)

TypeOK == /\ model \in Models
          /\ fast \in BOOLEAN
          /\ ultra \in BOOLEAN
          /\ last.op \in Ops
          /\ last.ok \in BOOLEAN
          /\ last.speed \in Speeds

(* Fast and Ultrafast are never both on. *)
Exclusive == ~(fast /\ ultra)

(* Ultrafast is never on while hidden: a hidden lane would fail prompts. *)
UltraValid == ultra => model \in SupUltra

(* Fast is never left on after a switch to a model without it. *)
SwitchClearsFast == last.op = "model" => (fast => model \in SupFast)

(* An accepted lane request takes effect. *)
RequestHonored ==
    (last.ok /\ last.op = "fast") => Bool(fast) = last.arg
RequestHonoredUltra ==
    (last.ok /\ last.op = "ultrafast") => Bool(ultra) = last.arg

(* Only enabling an unsupported lane is rejected. *)
RejectOnlyUnsupported ==
    /\ (last.op = "fast" /\ ~last.ok) => (last.arg = "true" /\ model \notin SupFast)
    /\ (last.op = "ultrafast" /\ ~last.ok) => (last.arg = "true" /\ model \notin SupUltra)
AcceptOnlySupported ==
    /\ (last.op = "fast" /\ last.ok /\ last.arg = "true") => model \in SupFast
    /\ (last.op = "ultrafast" /\ last.ok /\ last.arg = "true") => model \in SupUltra

(* Unknown config ids are errors. *)
UnknownRejected == last.op = "unknown" => ~last.ok

(* A prompt never sends a lane the model lacks. *)
PromptLaneSupported ==
    /\ (last.op = "prompt" /\ last.speed = "fast") => model \in SupFast
    /\ (last.op = "prompt" /\ last.speed = "ultrafast") => model \in SupUltra
=============================================================================

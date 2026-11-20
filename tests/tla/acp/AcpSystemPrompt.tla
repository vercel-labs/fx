-------------------------- MODULE AcpSystemPrompt --------------------------
(***************************************************************************)
(* How fx's ACP server takes a client's system prompt (src/acp/           *)
(* client_instructions.zig, src/acp/sessions.zig), following ACP v1:      *)
(*                                                                         *)
(*  - `systemPrompt` is the object {"mode": "append", "content": [...]}   *)
(*    on session/new, session/load and session/resume. fx supports the    *)
(*    `append` mode only.                                                  *)
(*  - fx refuses any other shape with -32602 before anything changes: the *)
(*    older bare array, another mode, a missing mode, empty content, or a *)
(*    block that isn't text. It checks the shape first, so a refused load *)
(*    gets -32602 even for a session it doesn't have, and opens nothing.  *)
(*  - A load or resume of a session fx doesn't have fails with -32002     *)
(*    (AcpSessionTarget.tla).                                             *)
(*  - session/new stores the prompt with the session. A load or resume    *)
(*    with a prompt replaces the stored one from the next turn, also for  *)
(*    the session that is already open. Without one, the stored prompt    *)
(*    stays.                                                               *)
(*  - Every turn sends the model the stored prompt. It survives a new fx  *)
(*    acp process, because fx saves it with the session.                  *)
(*  - fx saves a session at its first turn. Before that, only the process *)
(*    that created it can load it again.                                  *)
(*  - initialize lists `sessionCapabilities.systemPrompt`.                *)
(*                                                                         *)
(* `Fixed` set to FALSE gives fx before these rules (origin/main at       *)
(* 15dab7bb4): session/new took the bare array and refused the v1 object, *)
(* session/load and session/resume ignored `systemPrompt`, and a session  *)
(* fx didn't have got -32602. The                                         *)
(* AcpSystemPromptBefore-*.cfg configs show each rule failing then.       *)
(*                                                                         *)
(* The client runs one session, A. Each prompt value is a label: P1 and   *)
(* P2 are v1 objects, "array" is the older bare array, "override" an      *)
(* unsupported mode, "nomode" an object with no mode, "empty" an object   *)
(* with no content, "image" one with an image block, and "none" a request *)
(* without `systemPrompt`. Each label's text carries its own marker, so   *)
(* `sent` names the prompt the model received.                            *)
(*                                                                         *)
(* tests/tla/drivers/acp/system_prompt/driver.ts runs the real fx acp     *)
(* through plans of these steps and has TLC check each run against this   *)
(* model through AcpSystemPromptTrace.tla.                                 *)
(***************************************************************************)
EXTENDS Integers

CONSTANT Fixed   \* TRUE: ACP v1's rules; FALSE: fx before them

ASSUME Fixed \in BOOLEAN

V1 == {"P1", "P2"}
Old == {"array"}
Invalid == {"override", "nomode", "empty", "image"}
Prompts == V1 \cup Old \cup Invalid \cup {"none"}

\* The prompts a request may carry, and the ones fx refuses.
Accepted == IF Fixed THEN V1 \cup {"none"} ELSE Old \cup {"none"}
Refused == Prompts \ Accepted

RestoreOps == {"load", "resume"}

VARIABLES open,     \* whether session A is open in the running process
          exists,   \* whether fx saved session A, so another process can load it
          stored,   \* the prompt fx stores with session A, or "none"
          last      \* what the client observed for the latest step
vars == <<open, exists, stored, last>>
state == <<open, exists, stored>>

Obs(op, arg, ok, code, cap, sent) ==
    [op |-> op, arg |-> arg, ok |-> ok, code |-> code, cap |-> cap, sent |-> sent]

Init ==
    /\ open = FALSE
    /\ exists = FALSE
    /\ stored = "none"
    /\ last = Obs("restart", "none", TRUE, 0, TRUE, "none")

\* session/new, while the client has no session: A is the newest session.
NewSession(p) ==
    /\ ~open
    /\ ~exists
    /\ IF p \in Accepted
       THEN /\ open' = TRUE
            /\ stored' = p
            /\ last' = Obs("new", p, TRUE, 0, FALSE, "none")
            /\ UNCHANGED exists
       ELSE /\ last' = Obs("new", p, FALSE, -32602, FALSE, "none")
            /\ UNCHANGED state

\* session/load or session/resume of A. The prompt's shape is checked first.
Restore(op, p) ==
    CASE Fixed /\ p \in Refused ->
             /\ last' = Obs(op, p, FALSE, -32602, FALSE, "none")
             /\ UNCHANGED state
      [] ~(exists \/ open) ->
             /\ last' = Obs(op, p, FALSE, IF Fixed THEN -32002 ELSE -32602, FALSE, "none")
             /\ UNCHANGED state
      [] Fixed /\ p \in V1 ->
             /\ open' = TRUE
             /\ stored' = p
             /\ last' = Obs(op, p, TRUE, 0, FALSE, "none")
             /\ UNCHANGED exists
      [] OTHER ->
             \* No prompt, or fx before these rules, which ignored it.
             /\ open' = TRUE
             /\ last' = Obs(op, p, TRUE, 0, FALSE, "none")
             /\ UNCHANGED <<exists, stored>>

\* One turn of the open session. Its model request carries the stored prompt,
\* and fx saves the session.
Prompt ==
    /\ open
    /\ exists' = TRUE
    /\ last' = Obs("prompt", "none", TRUE, 0, FALSE, stored)
    /\ UNCHANGED <<open, stored>>

\* A new fx acp process. A is closed and keeps its stored prompt.
Restart ==
    /\ open' = FALSE
    /\ last' = Obs("restart", "none", TRUE, 0, TRUE, "none")
    /\ UNCHANGED <<exists, stored>>

Next ==
    \/ \E p \in Prompts : NewSession(p)
    \/ \E op \in RestoreOps, p \in Prompts : Restore(op, p)
    \/ Prompt
    \/ Restart

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety properties. *)

TypeOK ==
    /\ open \in BOOLEAN
    /\ exists \in BOOLEAN
    /\ stored \in Prompts

CapabilityListed == last.op = "restart" => last.cap

\* A v1 prompt works wherever the session can open.
V1Accepted ==
    [][(last'.op \in {"new"} \cup RestoreOps /\ last'.arg \in V1 /\ (last'.op \in RestoreOps => exists \/ open)) =>
           last'.ok]_vars

\* Every other shape fails with -32602, on every method, whether or not the
\* session exists.
OtherShapesRefused ==
    [][(last'.op \in {"new"} \cup RestoreOps /\ last'.arg \in Old \cup Invalid) =>
           /\ ~last'.ok
           /\ last'.code = -32602]_vars

RefusalChangesNothing == [][~last'.ok => UNCHANGED state]_vars

NewStoresPrompt == [][(last'.op = "new" /\ last'.ok) => stored' = last'.arg]_vars

LoadAppliesPrompt ==
    [][(last'.op \in RestoreOps /\ last'.ok /\ last'.arg \in V1) => stored' = last'.arg]_vars

NoPromptKeepsStored ==
    [][(last'.op \in RestoreOps /\ last'.arg = "none") => stored' = stored]_vars

TurnSendsStored == last.op = "prompt" => last.sent = stored
=============================================================================

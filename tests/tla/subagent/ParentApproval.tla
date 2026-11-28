------------------------------ MODULE ParentApproval --------------------------
(***************************************************************************)
(* A subagent's approval request goes to main, and main answers it.        *)
(*                                                                         *)
(* `Ask` is `requestChildPermission` in src/core/subagent/execution.zig:   *)
(* `registerApproval` puts the exact call in the approval registry         *)
(* (`registerTool` in approval_registry.zig). `PostNote` is                 *)
(* `noteChildApproval` in tool_host.zig, which posts the one note to main,  *)
(* and `MarkNoted` is the registry's `markNoted`, which runs only after the *)
(* post returned true. A post that fails refuses the request at once        *)
(* (`NoteFails`), so a subagent never waits on a note nobody got.          *)
(*                                                                         *)
(* `Block` is the loop in `awaitMailOrQuiet` waiting for something to      *)
(* change, and `Wake` is its `cancel_poll` re-check (or a nudge): only      *)
(* then does it look at `Fallback` again. `MarkNoted` wakes it, so a mark  *)
(* that lands after the loop looked is not lost.                            *)
(*                                                                         *)
(* `TakeMail` is main taking its mail in a turn: `awaitMailOrQuiet` and    *)
(* the fx ask loop in src/core/cli/cli_ask.zig. In that turn main may      *)
(* `approve` or `deny` (`answerApproval` in tool_host.zig) and then        *)
(* `EndTurn`. `approve` runs the subagent's exact call through main's own  *)
(* permission check (`checkNestedCall` in src/core/tooling/tool_runtime.zig *)
(* and `requestPermissionOutcome` in tool_admission.zig): "allow" resolves *)
(* the request allowed, "refuse" resolves it refused with the check's      *)
(* reason. `deny` always refuses. An answer for a request that is not      *)
(* registered finds nothing, which `lost` records.                         *)
(*                                                                         *)
(* `Fallback` is fx ask's refusal of every waiting request once main is    *)
(* idle with no mail, the loop is not blocked, and every waiting request   *)
(* is noted ("your parent ended its turn without answering"). `Stop` is    *)
(* main's stop of a waiting subagent, a tool call in its turn. `Resume`    *)
(* runs an allowed action and withholds a refused one.                     *)
(*                                                                         *)
(* The rules are that an action runs only when main's own check allowed    *)
(* it (RULES.md R4.3), that main's approve always finds the request its    *)
(* note named, and that the fallback refuses only requests main had a turn *)
(* to answer. TLC reports a waiting request that nothing can answer as a   *)
(* deadlock, since every behavior otherwise ends with every subagent       *)
(* resumed or stopped (`Finished`).                                        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
  Kids,  \* subagents whose tool calls need approval
  Bug    \* "none" is the design; the others are fx before it or planted

Bugs == {"none",
         "today",        \* fx before this change: no note and no approve
         "final_answer", \* approve resolves allowed without main's check
         "note_first",   \* the note is posted before the request is registered
         "early_stall",  \* the fallback counts a request that is not yet noted
         "no_fallback",  \* no fallback at all
         "note_lost",    \* a failed note leaves the request registered
         "no_nudge"}     \* the mark does not wake the blocked loop

ASSUME Bug \in Bugs

VARIABLES
  kid,             \* each: "working", "waiting", "ran", "refused", "stopped"
  req,             \* registry binding: "none", "registered", "noted", "allowed", "refused"
  policy,          \* main's own check for each call: "allow" or "refuse"
  mail,            \* notes posted and not yet taken by main
  seen,            \* notes main's turns took
  main,            \* "idle" or "turn"
  authorized,      \* kids whose action main's check allowed
  fallbackRefused, \* kids the fallback refused
  lost,            \* kids whose approve found no request while they waited
  posted,          \* notes posted whose request is not yet marked noted
  blocked,         \* the loop waits with nothing to fall back on
  wake             \* a mark (or a nudge) asks the loop to look again

vars == <<kid, req, policy, mail, seen, main, authorized, fallbackRefused, lost, posted, blocked, wake>>

\* The two states of a registered request `answerApproval` and the fallback
\* act on; "allowed" and "refused" are resolved and wait for `Resume`.
Requested(k) == req[k] \in {"registered", "noted"}

Init ==
  /\ kid = [k \in Kids |-> "working"]
  /\ req = [k \in Kids |-> "none"]
  /\ policy \in [Kids -> {"allow", "refuse"}]
  /\ mail = {}
  /\ seen = {}
  /\ main = "idle"
  /\ authorized = {}
  /\ fallbackRefused = {}
  /\ lost = {}
  /\ posted = {}
  /\ blocked = FALSE
  /\ wake = FALSE

\* `requestChildPermission`: the subagent's call needs approval. The design
\* registers the exact call, then notes it (`PostNote`). Before this change
\* (`today`) it registers and nothing tells main. `note_first` posts the
\* note first and registers after (`LateRegister`). `note_lost` has the one
\* note attempt of the request failed: it is the same registration with no
\* note, and `PostNote` and `NoteFails` are off, since fx posts once.
Ask(k) ==
  /\ kid[k] = "working"
  /\ kid' = [kid EXCEPT ![k] = "waiting"]
  /\ IF Bug = "today" THEN
       /\ req' = [req EXCEPT ![k] = "registered"]
       /\ mail' = mail
       /\ posted' = posted
       /\ blocked' = blocked
     ELSE IF Bug = "note_first" THEN
       /\ req' = req
       /\ mail' = mail \cup {k}
       /\ posted' = posted \cup {k}
       /\ blocked' = FALSE
     ELSE
       /\ req[k] = "none"
       /\ req' = [req EXCEPT ![k] = "registered"]
       /\ mail' = mail
       /\ posted' = posted
       /\ blocked' = blocked
  /\ UNCHANGED <<policy, seen, main, authorized, fallbackRefused, lost, wake>>

\* `noteChildApproval`: one note to main, posted after the request exists.
PostNote(k) ==
  /\ Bug \notin {"today", "note_first", "note_lost"}
  /\ kid[k] = "waiting"
  /\ req[k] = "registered"
  /\ k \notin posted
  /\ posted' = posted \cup {k}
  /\ mail' = mail \cup {k}
  /\ blocked' = FALSE
  /\ UNCHANGED <<kid, req, policy, seen, main, authorized, fallbackRefused, lost, wake>>

\* `markNoted`: the note went out, so the request counts as noted. The design
\* wakes the loop here, so a mark that lands after `Block` is not lost.
MarkNoted(k) ==
  /\ Bug \notin {"today", "note_first", "note_lost"}
  /\ kid[k] = "waiting"
  /\ req[k] = "registered"
  /\ k \in posted
  /\ req' = [req EXCEPT ![k] = "noted"]
  /\ posted' = posted \ {k}
  /\ IF Bug = "no_nudge" THEN wake' = wake ELSE wake' = TRUE
  /\ UNCHANGED <<kid, policy, mail, seen, main, authorized, fallbackRefused, lost, blocked>>

\* Planted `note_first`: the registration that came after the note.
LateRegister(k) ==
  /\ Bug = "note_first"
  /\ kid[k] = "waiting"
  /\ req[k] = "none"
  /\ k \in posted
  /\ req' = [req EXCEPT ![k] = "noted"]
  /\ posted' = posted \ {k}
  /\ wake' = TRUE
  /\ UNCHANGED <<kid, policy, mail, seen, main, authorized, fallbackRefused, lost, blocked>>

\* The note's post fails. The design refuses the request at once, so the
\* subagent never waits on a note nobody got. `note_lost` leaves it
\* registered and waiting, which `Ask` models above. A refusal changes which
\* requests wait, so a blocked loop must look again.
NoteFails(k) ==
  /\ Bug \notin {"today", "note_first", "note_lost"}
  /\ kid[k] = "waiting"
  /\ req[k] = "registered"
  /\ k \notin posted
  /\ req' = [req EXCEPT ![k] = "refused"]
  /\ wake' = TRUE
  /\ UNCHANGED <<kid, policy, mail, seen, main, authorized, fallbackRefused, lost, posted, blocked>>

\* Main takes the notes waiting as mail in its turn.
TakeMail ==
  /\ main = "idle"
  /\ mail # {}
  /\ main' = "turn"
  /\ seen' = seen \cup mail
  /\ mail' = {}
  /\ UNCHANGED <<kid, req, policy, authorized, fallbackRefused, lost, posted, blocked, wake>>

\* What `answerApproval` with `approve` does to the request: main's own check
\* decides, except that `final_answer` resolves it allowed without the
\* check. A request that is not registered while its subagent waits is one
\* main's answer cannot find.
ApproveResolves(k) ==
  \/ /\ Requested(k)
     /\ IF Bug = "final_answer" \/ policy[k] = "allow"
           THEN /\ req' = [req EXCEPT ![k] = "allowed"]
                /\ authorized' = IF Bug = "final_answer" THEN authorized ELSE authorized \cup {k}
           ELSE /\ req' = [req EXCEPT ![k] = "refused"]
                /\ authorized' = authorized
     /\ posted' = posted \ {k}
     /\ lost' = lost
  \/ /\ req[k] = "none"
     /\ kid[k] = "waiting"
     /\ lost' = lost \cup {k}
     /\ req' = req
     /\ posted' = posted
     /\ authorized' = authorized

Approve(k) ==
  /\ Bug # "today"
  /\ main = "turn"
  /\ k \in seen
  /\ ApproveResolves(k)
  /\ UNCHANGED <<kid, policy, mail, seen, main, fallbackRefused, blocked, wake>>

\* `answerApproval` with `deny`: refused, always.
Deny(k) ==
  /\ Bug # "today"
  /\ main = "turn"
  /\ k \in seen
  /\ Requested(k)
  /\ req' = [req EXCEPT ![k] = "refused"]
  /\ posted' = posted \ {k}
  /\ UNCHANGED <<kid, policy, mail, seen, main, authorized, fallbackRefused, lost, blocked, wake>>

\* Main ends its turn.
EndTurn ==
  /\ main = "turn"
  /\ main' = "idle"
  /\ UNCHANGED <<kid, req, policy, mail, seen, authorized, fallbackRefused, lost, posted, blocked, wake>>

\* Whether the fallback has something it may refuse right now.
CanFallback ==
  LET W == {k \in Kids : kid[k] = "waiting" /\ Requested(k)} IN
  Bug \notin {"today", "no_fallback"} /\ W # {} /\
    (IF Bug = "early_stall" THEN TRUE ELSE \A k \in W : req[k] = "noted")

\* fx ask's fallback: main is idle with no mail, the loop is checking rather
\* than waiting, and every waiting request is noted. Every one is refused.
Fallback ==
  /\ main = "idle"
  /\ mail = {}
  /\ ~blocked
  /\ CanFallback
  /\ LET W == {k \in Kids : kid[k] = "waiting" /\ Requested(k)} IN
       /\ req' = [k \in Kids |-> IF k \in W THEN "refused" ELSE req[k]]
       /\ fallbackRefused' = fallbackRefused \cup W
  /\ UNCHANGED <<kid, policy, mail, seen, main, authorized, lost, posted, blocked, wake>>

\* `awaitMailOrQuiet` stops checking and waits: main idle, no mail, and the
\* fallback has nothing it may refuse. Only a wake or new mail clears this.
Block ==
  /\ main = "idle"
  /\ mail = {}
  /\ ~blocked
  /\ ~CanFallback
  /\ blocked' = TRUE
  /\ UNCHANGED <<kid, req, policy, mail, seen, main, authorized, fallbackRefused, lost, posted, wake>>

\* The loop looks again: a mark woke it, or its `cancel_poll` re-check came.
Wake ==
  /\ blocked
  /\ wake
  /\ blocked' = FALSE
  /\ wake' = FALSE
  /\ UNCHANGED <<kid, req, policy, mail, seen, main, authorized, fallbackRefused, lost, posted>>

\* The subagent resumes: an allowed action runs; a refused one does not. A
\* resume changes which requests wait, so a blocked loop must look again.
Resume(k) ==
  /\ kid[k] = "waiting"
  /\ req[k] \in {"allowed", "refused"}
  /\ kid' = [kid EXCEPT ![k] = IF req[k] = "allowed" THEN "ran" ELSE "refused"]
  /\ req' = [req EXCEPT ![k] = "none"]
  /\ wake' = TRUE
  /\ UNCHANGED <<policy, mail, seen, main, authorized, fallbackRefused, lost, posted, blocked>>

\* Main's stop of a waiting subagent, a tool call in its turn: it first refuses
\* the request the subagent waits on (the call is refused, nothing runs), then
\* drops it and any note still waiting.
Stop(k) ==
  /\ main = "turn"
  /\ kid[k] = "waiting"
  /\ kid' = [kid EXCEPT ![k] = "stopped"]
  /\ req' = [req EXCEPT ![k] = "none"]
  /\ mail' = mail \ {k}
  /\ posted' = posted \ {k}
  /\ UNCHANGED <<policy, seen, main, authorized, fallbackRefused, lost, blocked, wake>>

\* Every subagent is done and main has no mail: the behavior is over.
Finished ==
  /\ main = "idle"
  /\ mail = {}
  /\ \A k \in Kids : kid[k] \in {"ran", "refused", "stopped"}
  /\ UNCHANGED vars

Next ==
  \/ \E k \in Kids : Ask(k) \/ PostNote(k) \/ MarkNoted(k) \/ LateRegister(k)
                     \/ NoteFails(k) \/ Approve(k) \/ Deny(k) \/ Resume(k) \/ Stop(k)
  \/ TakeMail
  \/ EndTurn
  \/ Fallback
  \/ Block
  \/ Wake
  \/ Finished

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ kid \in [Kids -> {"working", "waiting", "ran", "refused", "stopped"}]
  /\ req \in [Kids -> {"none", "registered", "noted", "allowed", "refused"}]
  /\ policy \in [Kids -> {"allow", "refuse"}]
  /\ mail \subseteq Kids
  /\ seen \subseteq Kids
  /\ main \in {"idle", "turn"}
  /\ authorized \subseteq Kids
  /\ fallbackRefused \subseteq Kids
  /\ lost \subseteq Kids
  /\ posted \subseteq Kids
  /\ blocked \in BOOLEAN
  /\ wake \in BOOLEAN

\* An action runs only when main's own check allowed it (RULES.md R4.3).
Authority == \A k \in Kids : kid[k] = "ran" => k \in authorized

\* Main's approve always finds the request its note named.
NoLostApprove == lost = {}

\* The fallback refuses only what main had a turn to answer.
FallbackOnlyAfterSeen == fallbackRefused \subseteq seen

=============================================================================

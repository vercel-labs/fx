------------------------------ MODULE WaitNudge ------------------------------
(***************************************************************************)
(* Main's `wait` against subagent works that end with nothing to post.     *)
(*                                                                         *)
(* `wait` (`Runtime.waitForMail` in src/core/subagent/tool_host.zig) first *)
(* registers its worker as the waiter (`setWaiter`), then reads whether    *)
(* any child works (`anyWorking`: the host's busy flags), and if one does  *)
(* it blocks in `WorkerRuntime.waitForPostOrNudge`. A work that ends with  *)
(* nothing to post wakes it by `nudgeWaiter`, which reaches the worker     *)
(* only when a waiter is registered, and then sets the worker's sticky     *)
(* nudge flag, which a wait that has not yet blocked still sees. Mail      *)
(* also wakes a wait; `MainMail.tla` models that, so the ends here post    *)
(* none.                                                                   *)
(*                                                                         *)
(* A child's end tells the owner (`deliverEnd`: nothing to post), clears   *)
(* the child's busy flag (`clearBusyLocked`), and nudges the waiter. The   *)
(* design nudges last: a wait that read the old busy flag registered       *)
(* before that read, so it is registered when the nudge comes. fx before   *)
(* nudged first (`today`), when no waiter was registered yet, and a wait   *)
(* that began in the gap read a busy flag nothing nudged for again.        *)
(*                                                                         *)
(* The rule is that `wait` always returns: no behavior reaches a blocked   *)
(* wait that nothing can wake. TLC reports that as a deadlock, since every *)
(* behavior otherwise ends with the wait returned and every child done     *)
(* (`Finished`).                                                           *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
  Kids,  \* subagents whose works end with nothing to post
  Bug    \* "none" is the design; the others are fx before it or planted

Bugs == {"none",
         "today",        \* the end nudges before it clears the busy flag
         "check_first"}  \* wait reads the busy flags before it registers

ASSUME Bug \in Bugs

VARIABLES
  phase,   \* each child: "working", "told", "cleared", "nudged"
  busy,    \* the children whose busy flag is set
  waiter,  \* "none", "read", "registered", "checked", "blocked", "returned"
  latch,   \* the worker's sticky nudge flag
  said     \* what wait answered: "none", "quiet" or "nudged"

vars == <<phase, busy, waiter, latch, said>>

\* `Runtime.waiter` is set: from `setWaiter(worker)` until the wait returns.
Registered == waiter \in {"registered", "checked", "blocked"}

\* `nudgeWaiter`: it reaches the worker only while a waiter is registered.
Nudge == latch' = (latch \/ Registered)

Init ==
  /\ phase = [k \in Kids |-> "working"]
  /\ busy = Kids
  /\ waiter = "none"
  /\ latch = FALSE
  /\ said = "none"

\* The end tells the owner there is nothing to post. Before the fix it also
\* nudges here.
Tell(k) ==
  /\ phase[k] = "working"
  /\ phase' = [phase EXCEPT ![k] = "told"]
  /\ IF Bug = "today" THEN Nudge ELSE latch' = latch
  /\ UNCHANGED <<busy, waiter, said>>

\* The end clears the child's busy flag.
Clear(k) ==
  /\ phase[k] = "told"
  /\ busy' = busy \ {k}
  /\ phase' = [phase EXCEPT ![k] = IF Bug = "today" THEN "nudged" ELSE "cleared"]
  /\ UNCHANGED <<waiter, latch, said>>

\* The design nudges once the flag is clear.
NudgeAfterClear(k) ==
  /\ Bug # "today"
  /\ phase[k] = "cleared"
  /\ phase' = [phase EXCEPT ![k] = "nudged"]
  /\ Nudge
  /\ UNCHANGED <<busy, waiter, said>>

\* `wait` registers its worker as the waiter.
Register ==
  /\ waiter = IF Bug = "check_first" THEN "read" ELSE "none"
  /\ waiter' = IF Bug = "check_first" THEN "checked" ELSE "registered"
  /\ UNCHANGED <<phase, busy, latch, said>>

\* `wait` reads the busy flags: nothing works, so nothing more will arrive,
\* or something does, so it goes on to block.
Read ==
  /\ waiter = IF Bug = "check_first" THEN "none" ELSE "registered"
  /\ IF busy = {}
        THEN /\ waiter' = "returned"
             /\ said' = "quiet"
        ELSE /\ waiter' = IF Bug = "check_first" THEN "read" ELSE "checked"
             /\ said' = said
  /\ UNCHANGED <<phase, busy, latch>>

\* `waitForPostOrNudge`: a nudge already sent ends it at once; otherwise it
\* blocks.
Park ==
  /\ waiter = "checked"
  /\ IF latch
        THEN /\ waiter' = "returned"
             /\ said' = "nudged"
             /\ latch' = FALSE
        ELSE /\ waiter' = "blocked"
             /\ UNCHANGED <<said, latch>>
  /\ UNCHANGED <<phase, busy>>

\* A nudge wakes a blocked wait.
Wake ==
  /\ waiter = "blocked"
  /\ latch
  /\ waiter' = "returned"
  /\ said' = "nudged"
  /\ latch' = FALSE
  /\ UNCHANGED <<phase, busy>>

\* The wait has returned and every child has ended: the behavior is over.
Finished ==
  /\ waiter = "returned"
  /\ \A k \in Kids : phase[k] = "nudged"
  /\ UNCHANGED vars

Next ==
  \/ \E k \in Kids : Tell(k) \/ Clear(k) \/ NudgeAfterClear(k)
  \/ Register
  \/ Read
  \/ Park
  \/ Wake
  \/ Finished

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ phase \in [Kids -> {"working", "told", "cleared", "nudged"}]
  /\ busy \subseteq Kids
  /\ waiter \in {"none", "read", "registered", "checked", "blocked", "returned"}
  /\ latch \in BOOLEAN
  /\ said \in {"none", "quiet", "nudged"}

\* `wait` says nothing more will arrive only when no child works.
QuietHonest == said = "quiet" => busy = {}

=============================================================================

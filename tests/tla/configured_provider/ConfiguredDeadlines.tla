-------------------------- MODULE ConfiguredDeadlines --------------------------
(***************************************************************************)
(* How long one request to a custom model connection may wait              *)
(* (src/gateway/chat_completions.zig post, with ConnectionWatch in         *)
(* src/gateway/client.zig).                                                *)
(*                                                                         *)
(* A request waits three times: to connect, for the first response, and,   *)
(* once the response has started, for the next bytes. A connection's       *)
(* settings name a bound for each. fx before the change used built-in      *)
(* bounds, which cut off a local model that takes longer to load, and keep *)
(* waiting on a server the person expects to be fast. The model gives the  *)
(* built-in bounds one value, BuiltIn.                                     *)
(*                                                                         *)
(* Time counts in ticks. A wait ends at its bound, and an event that       *)
(* arrives at the bound loses to it. `clock` is the time in the current    *)
(* wait; `quiet` is the time since the response last sent bytes.           *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(* "today" is fx before the change.                                        *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Connect, Head, Stall, BuiltIn, MaxClock, Bug

Waits == {"connecting", "awaiting_head", "streaming"}

VARIABLES
    phase,   \* a wait, "completed", or "failed"
    clock,   \* ticks in the current wait
    quiet,   \* ticks since the response last sent bytes
    cause,   \* the wait that ran out, or "none"
    waited   \* how long that wait had gone without what it waited for

vars == <<phase, clock, quiet, cause, waited>>

Init ==
    /\ phase = "connecting"
    /\ clock = 0
    /\ quiet = 0
    /\ cause = "none"
    /\ waited = 0

\* The bound the connection's settings give a wait.
Configured(p) ==
    CASE p = "connecting" -> Connect
      [] p = "awaiting_head" -> Head
      [] p = "streaming" -> Stall

\* How long a wait has gone without what it waits for.
Silence(p) == IF p = "streaming" THEN quiet ELSE clock

\* The bound fx applies, and the time it holds against it.
Bound(p) ==
    IF Bug = "today" THEN BuiltIn
    ELSE IF Bug = "early" /\ Configured(p) > 0 THEN Configured(p) - 1
    ELSE Configured(p)

Measured(p) == IF p = "streaming" /\ Bug = "stall_counts_whole_response" THEN clock ELSE Silence(p)

\* no_stall_bound: a response that stops sending is never given up on.
Unbounded(p) == Bug = "no_stall_bound" /\ p = "streaming"

Waiting == phase \in Waits
InTime == Waiting /\ (Unbounded(phase) \/ Measured(phase) < Bound(phase))

Tick ==
    /\ InTime
    /\ clock' = IF clock < MaxClock THEN clock + 1 ELSE clock
    /\ quiet' = IF quiet < MaxClock THEN quiet + 1 ELSE quiet
    /\ UNCHANGED <<phase, cause, waited>>

Connects ==
    /\ phase = "connecting"
    /\ InTime
    /\ phase' = "awaiting_head"
    /\ clock' = 0
    /\ quiet' = 0
    /\ UNCHANGED <<cause, waited>>

HeadArrives ==
    /\ phase = "awaiting_head"
    /\ InTime
    /\ phase' = "streaming"
    /\ clock' = 0
    /\ quiet' = 0
    /\ UNCHANGED <<cause, waited>>

Bytes ==
    /\ phase = "streaming"
    /\ InTime
    /\ quiet' = 0
    /\ UNCHANGED <<phase, clock, cause, waited>>

Completes ==
    /\ phase = "streaming"
    /\ InTime
    /\ phase' = "completed"
    /\ UNCHANGED <<clock, quiet, cause, waited>>

Expires ==
    /\ Waiting
    /\ ~Unbounded(phase)
    /\ Measured(phase) >= Bound(phase)
    /\ phase' = "failed"
    /\ cause' = IF Bug = "unnamed_failure" THEN "none" ELSE phase
    /\ waited' = Silence(phase)
    /\ UNCHANGED <<clock, quiet>>

Next == Tick \/ Connects \/ HeadArrives \/ Bytes \/ Completes \/ Expires

Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ WF_vars(Expires)

-----------------------------------------------------------------------------

TypeOK ==
    /\ phase \in Waits \cup {"completed", "failed"}
    /\ clock \in 0..MaxClock
    /\ quiet \in 0..MaxClock
    /\ cause \in Waits \cup {"none"}
    /\ waited \in 0..MaxClock

\* A wait never runs past the bound the connection's settings give it.
NeverPastConfigured == Waiting => Silence(phase) <= Configured(phase)

\* A request fails only by running out a wait, and says which.
FailureNamesItsWait == (phase = "failed") <=> (cause # "none")

\* A wait never ends before the bound the connection's settings give it.
NeverBeforeConfigured == cause # "none" => waited >= Configured(cause)

\* Connecting and waiting for the first response always end.
SetupEnds == [](phase \in {"connecting", "awaiting_head"} => <>(phase \notin {"connecting", "awaiting_head"}))
=============================================================================

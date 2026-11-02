----------------------------- MODULE ToolReplay -----------------------------
(***************************************************************************)
(* Step: tool intents, outcomes and the per-tool crash policy             *)
(*                                                                         *)
(* One model response asked for the calls in `Calls`, which may run at    *)
(* the same time (this also models opt-in parallel host tools). Each call *)
(* writes an intent before its effect and an outcome after it. A          *)
(* `replay: "never"` call waits for its intent to be durable (a barrier); *)
(* a `replay: "safe"` call may run ahead of its intent. The process can   *)
(* crash anywhere; in-flight writes may or may not land. On restore:      *)
(*   - a durable outcome is final;                                        *)
(*   - a safe call with an intent and no outcome runs again;              *)
(*   - a never call with an intent and no outcome gets an "interrupted,  *)
(*     outcome unknown" result instead of running again;                  *)
(*   - a call with no durable intent is dispatched again.                 *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS SafeCalls, NeverCalls, MaxCrashes

ASSUME SafeCalls \cap NeverCalls = {}

Calls == SafeCalls \cup NeverCalls

\* The tool's declared crash policy.
Policy == [c \in Calls |-> IF c \in SafeCalls THEN "safe" ELSE "never"]

VARIABLES
    alive,
    pc,             \* [Calls -> kernel step for the call]
    inflight,       \* calls whose intent write was sent, not yet durable
    jIntent,        \* calls whose intent is durable
    outPending,     \* calls whose result write was sent, not yet durable
    jOutcome,       \* [Calls -> "none" | "result" | "interrupted"], durable
    starts,         \* [Calls -> Nat]: times the external effect started
    outcomeWrites,  \* [Calls -> Nat]: durable outcome records written
    lateStart,      \* TRUE once a call started after its outcome was durable
    crashes

vars == <<alive, pc, inflight, jIntent, outPending, jOutcome, starts,
          outcomeWrites, lateStart, crashes>>

Steps == {"todo", "intent_sent", "may_run", "running", "finished", "resolved", "down"}
Outcomes == {"none", "result", "interrupted"}

TypeOK ==
    /\ alive \in BOOLEAN
    /\ pc \in [Calls -> Steps]
    /\ inflight \subseteq Calls
    /\ jIntent \subseteq Calls
    /\ outPending \subseteq Calls
    /\ jOutcome \in [Calls -> Outcomes]
    /\ starts \in [Calls -> 0..(MaxCrashes + 1)]
    /\ outcomeWrites \in [Calls -> 0..(MaxCrashes + 2)]
    /\ lateStart \in BOOLEAN
    /\ crashes \in 0..MaxCrashes

Init ==
    /\ alive = TRUE
    /\ pc = [c \in Calls |-> "todo"]
    /\ inflight = {}
    /\ jIntent = {}
    /\ outPending = {}
    /\ jOutcome = [c \in Calls |-> "none"]
    /\ starts = [c \in Calls |-> 0]
    /\ outcomeWrites = [c \in Calls |-> 0]
    /\ lateStart = FALSE
    /\ crashes = 0

\* The kernel writes the call's intent (stable id, name, input).
SendIntent(c) ==
    /\ alive
    /\ pc[c] = "todo"
    /\ pc' = [pc EXCEPT ![c] = "intent_sent"]
    /\ inflight' = inflight \cup {c}
    /\ UNCHANGED <<alive, jIntent, outPending, jOutcome, starts, outcomeWrites, lateStart, crashes>>

\* The intent write lands and is acknowledged.
IntentLands(c) ==
    /\ alive
    /\ c \in inflight
    /\ inflight' = inflight \ {c}
    /\ jIntent' = jIntent \cup {c}
    /\ UNCHANGED <<alive, pc, outPending, jOutcome, starts, outcomeWrites, lateStart, crashes>>

\* Barrier rule: a never call waits for its durable intent; a safe call
\* may run ahead of it.
Allow(c) ==
    /\ alive
    /\ pc[c] = "intent_sent"
    /\ (c \in jIntent \/ Policy[c] = "safe")
    /\ pc' = [pc EXCEPT ![c] = "may_run"]
    /\ UNCHANGED <<alive, inflight, jIntent, outPending, jOutcome, starts, outcomeWrites, lateStart, crashes>>

\* The host's execute() starts the external effect.
Start(c) ==
    /\ alive
    /\ pc[c] = "may_run"
    /\ starts[c] < MaxCrashes + 1
    /\ starts' = [starts EXCEPT ![c] = @ + 1]
    /\ lateStart' = (lateStart \/ jOutcome[c] # "none")
    /\ pc' = [pc EXCEPT ![c] = "running"]
    /\ UNCHANGED <<alive, inflight, jIntent, outPending, jOutcome, outcomeWrites, crashes>>

\* execute() returns; the kernel sends the result write (lazy).
Finish(c) ==
    /\ alive
    /\ pc[c] = "running"
    /\ pc' = [pc EXCEPT ![c] = "finished"]
    /\ outPending' = outPending \cup {c}
    /\ UNCHANGED <<alive, inflight, jIntent, jOutcome, starts, outcomeWrites, lateStart, crashes>>

\* The result write lands.
OutcomeLands(c) ==
    /\ alive
    /\ c \in outPending
    /\ outPending' = outPending \ {c}
    /\ jOutcome' = [jOutcome EXCEPT ![c] = "result"]
    /\ outcomeWrites' = [outcomeWrites EXCEPT ![c] = @ + 1]
    /\ pc' = [pc EXCEPT ![c] = "resolved"]
    /\ UNCHANGED <<alive, inflight, jIntent, starts, lateStart, crashes>>

\* The process dies. Any subset of the writes in flight lands.
Crash ==
    /\ alive
    /\ crashes < MaxCrashes
    /\ \E landedIntents \in SUBSET inflight, landedResults \in SUBSET outPending :
        /\ jIntent' = jIntent \cup landedIntents
        /\ jOutcome' = [c \in Calls |->
                          IF c \in landedResults THEN "result" ELSE jOutcome[c]]
        /\ outcomeWrites' = [c \in Calls |->
                               IF c \in landedResults THEN outcomeWrites[c] + 1
                               ELSE outcomeWrites[c]]
    /\ alive' = FALSE
    /\ pc' = [c \in Calls |-> "down"]
    /\ inflight' = {}
    /\ outPending' = {}
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<starts, lateStart>>

\* A new process folds the journal and resolves every unfinished call by
\* its policy. The "interrupted" result is written at a barrier.
Restore ==
    /\ ~alive
    /\ alive' = TRUE
    /\ pc' = [c \in Calls |->
                IF jOutcome[c] # "none" THEN "resolved"
                ELSE IF c \in jIntent /\ Policy[c] = "safe" THEN "may_run"
                ELSE IF c \in jIntent THEN "resolved"
                ELSE "todo"]
    /\ jOutcome' = [c \in Calls |->
                      IF jOutcome[c] = "none" /\ c \in jIntent /\ Policy[c] = "never"
                      THEN "interrupted" ELSE jOutcome[c]]
    /\ outcomeWrites' = [c \in Calls |->
                           IF jOutcome[c] = "none" /\ c \in jIntent /\ Policy[c] = "never"
                           THEN outcomeWrites[c] + 1 ELSE outcomeWrites[c]]
    /\ UNCHANGED <<inflight, jIntent, outPending, starts, lateStart, crashes>>

Next ==
    \/ \E c \in Calls :
        \/ SendIntent(c)
        \/ IntentLands(c)
        \/ Allow(c)
        \/ Start(c)
        \/ Finish(c)
        \/ OutcomeLands(c)
    \/ Crash
    \/ Restore

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* A never call's effect starts at most once, across every crash.
NeverRunsTwice == \A c \in Calls : Policy[c] = "never" => starts[c] <= 1

\* A never call only starts after its intent is durable.
NeverStartsWithoutDurableIntent ==
    \A c \in Calls : Policy[c] = "never" /\ starts[c] > 0 => c \in jIntent

\* No call starts again once its outcome is durable.
NoStartAfterOutcome == ~lateStart

\* Each call gets exactly one durable outcome record, never two.
OneOutcome == \A c \in Calls : outcomeWrites[c] <= 1

\* "Interrupted" is only used where re-running is unsafe and the effect may
\* have started.
InterruptedMeansUnknown ==
    \A c \in Calls :
        jOutcome[c] = "interrupted" => Policy[c] = "never" /\ c \in jIntent

=============================================================================

------------------------------- MODULE Inbox -------------------------------
(***************************************************************************)
(* Step: inputs go through the journal.                                  *)
(*                                                                         *)
(* Prompts, steers and follow-ups get ids. The kernel appends an input   *)
(* at a barrier before it resolves the caller's promise or acts on it.    *)
(* A model request's intent records, in the same barrier write, which    *)
(* pending inputs it carries (placement). A caller may withdraw an input *)
(* until it is placed; after that the answer is "already_placed". The    *)
(* process can crash anywhere; restore recomputes what is pending from    *)
(* the journal alone.                                                     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Inputs, MaxRequests, MaxCrashes

VARIABLES
    alive,
    submitted,   \* inputs the caller handed to libfx (caller side, survives)
    acked,       \* inputs whose prompt()/steer() promise resolved
    jAccepted,   \* inputs durable in the journal
    jWithdrawn,  \* inputs durably withdrawn
    jPlaced,     \* [Inputs -> 0..MaxRequests]: request that carried it, 0 = none
    carried,     \* [1..MaxRequests -> SUBSET Inputs]: what each request body held
    nreq,        \* model request intents written so far
    memPending,  \* the kernel's in-memory pending inputs
    answer,      \* [Inputs -> "none" | "withdrawn" | "already_placed"]
    crashes

vars == <<alive, submitted, acked, jAccepted, jWithdrawn, jPlaced, carried,
          nreq, memPending, answer, crashes>>

Requests == 1..MaxRequests

TypeOK ==
    /\ alive \in BOOLEAN
    /\ submitted \subseteq Inputs
    /\ acked \subseteq Inputs
    /\ jAccepted \subseteq Inputs
    /\ jWithdrawn \subseteq Inputs
    /\ jPlaced \in [Inputs -> 0..MaxRequests]
    /\ carried \in [Requests -> SUBSET Inputs]
    /\ nreq \in 0..MaxRequests
    /\ memPending \subseteq Inputs
    /\ answer \in [Inputs -> {"none", "withdrawn", "already_placed"}]
    /\ crashes \in 0..MaxCrashes

Init ==
    /\ alive = TRUE
    /\ submitted = {}
    /\ acked = {}
    /\ jAccepted = {}
    /\ jWithdrawn = {}
    /\ jPlaced = [i \in Inputs |-> 0]
    /\ carried = [r \in Requests |-> {}]
    /\ nreq = 0
    /\ memPending = {}
    /\ answer = [i \in Inputs |-> "none"]
    /\ crashes = 0

\* The caller calls prompt(), steer() or followUp().
Submit(i) ==
    /\ i \notin submitted
    /\ submitted' = submitted \cup {i}
    /\ UNCHANGED <<alive, acked, jAccepted, jWithdrawn, jPlaced, carried, nreq, memPending, answer, crashes>>

\* The kernel appends the input at a barrier.
Accept(i) ==
    /\ alive
    /\ i \in submitted
    /\ i \notin jAccepted
    /\ jAccepted' = jAccepted \cup {i}
    /\ memPending' = memPending \cup {i}
    /\ UNCHANGED <<alive, submitted, acked, jWithdrawn, jPlaced, carried, nreq, answer, crashes>>

\* The caller's promise resolves.
Ack(i) ==
    /\ alive
    /\ i \in jAccepted
    /\ i \notin acked
    /\ acked' = acked \cup {i}
    /\ UNCHANGED <<alive, submitted, jAccepted, jWithdrawn, jPlaced, carried, nreq, memPending, answer, crashes>>

\* The kernel builds the next model request from some pending inputs and
\* records the placement with the request's intent, in one barrier write.
Prepare ==
    /\ alive
    /\ nreq < MaxRequests
    /\ \E S \in SUBSET memPending :
        /\ carried' = [carried EXCEPT ![nreq + 1] = S]
        /\ jPlaced' = [i \in Inputs |-> IF i \in S THEN nreq + 1 ELSE jPlaced[i]]
        /\ memPending' = memPending \ S
    /\ nreq' = nreq + 1
    /\ UNCHANGED <<alive, submitted, acked, jAccepted, jWithdrawn, answer, crashes>>

\* The caller withdraws an input it already handed over.
Withdraw(i) ==
    /\ alive
    /\ i \in jAccepted
    /\ answer[i] = "none"
    /\ IF jPlaced[i] # 0
       THEN /\ answer' = [answer EXCEPT ![i] = "already_placed"]
            /\ UNCHANGED <<jWithdrawn, memPending>>
       ELSE /\ answer' = [answer EXCEPT ![i] = "withdrawn"]
            /\ jWithdrawn' = jWithdrawn \cup {i}
            /\ memPending' = memPending \ {i}
    /\ UNCHANGED <<alive, submitted, acked, jAccepted, jPlaced, carried, nreq, crashes>>

\* The process dies; memory is lost, the journal and the caller remain.
Crash ==
    /\ alive
    /\ crashes < MaxCrashes
    /\ alive' = FALSE
    /\ memPending' = {}
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<submitted, acked, jAccepted, jWithdrawn, jPlaced, carried, nreq, answer>>

\* A new process recomputes what is pending from the journal.
Restore ==
    /\ ~alive
    /\ alive' = TRUE
    /\ memPending' = {i \in jAccepted : jPlaced[i] = 0 /\ i \notin jWithdrawn}
    /\ UNCHANGED <<submitted, acked, jAccepted, jWithdrawn, jPlaced, carried, nreq, answer, crashes>>

Next ==
    \/ \E i \in Inputs : Submit(i) \/ Accept(i) \/ Ack(i) \/ Withdraw(i)
    \/ Prepare
    \/ Crash
    \/ Restore

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* A resolved prompt()/steer() promise means the input is durable.
AckedAreDurable == acked \subseteq jAccepted

\* The model only ever sees inputs that are in the journal.
ActedInputsAreJournaled == \A r \in Requests : carried[r] \subseteq jAccepted

\* Each input reaches the model in at most one request.
PlacedOnce ==
    \A i \in Inputs, r1, r2 \in Requests :
        i \in carried[r1] /\ i \in carried[r2] => r1 = r2

\* The journal's placement record matches the request bodies exactly.
PlacementMatchesBody ==
    \A i \in Inputs, r \in Requests : i \in carried[r] <=> jPlaced[i] = r

\* A withdrawn input never reaches the model.
WithdrawnNeverPlaced ==
    \A i \in jWithdrawn : jPlaced[i] = 0 /\ \A r \in Requests : i \notin carried[r]

\* The answer to withdraw() is true.
WithdrawAnswerTruthful ==
    \A i \in Inputs :
        /\ answer[i] = "withdrawn" => \A r \in Requests : i \notin carried[r]
        /\ answer[i] = "already_placed" => \E r \in Requests : i \in carried[r]

=============================================================================

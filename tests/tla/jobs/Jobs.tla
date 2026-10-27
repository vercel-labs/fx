-------------------------------- MODULE Jobs --------------------------------
(***************************************************************************)
(* Background jobs reach the model exactly once (D110, D111).              *)
(*                                                                         *)
(* A job settles. Its result is then taken by one consumer: an explicit    *)
(* `jobs wait` that holds a lease on it, or the automatic async-result     *)
(* delivery the supervisor tick runs, never both. A consumer first         *)
(* reserves the result (one reservation at a time, per job), then commits  *)
(* it once the model has it, or releases it so it stays deliverable: a     *)
(* wait whose tool result the turn dropped, a notice the loop refused.     *)
(* A wait leases its targets while it waits, so automatic delivery leaves  *)
(* them to it; when the wait returns, whatever it did not take is          *)
(* delivered automatically.                                                *)
(*                                                                         *)
(* Code: src/core/jobs/jobs.zig (Registry: leases, takeDeliveries, wait),  *)
(* the sources' reservations (shell_source.zig over the managed execution  *)
(* runtime's DeliveryState, turn_source.zig), src/core/jobs/host.zig, and  *)
(* the supervisor tick in src/core/supervisor/session.zig.                 *)
(*                                                                         *)
(* `Mutation` enables one broken rule so TLC shows each property bites:    *)
(*   double_reserve    a second consumer reserves a reserved result        *)
(*   ignore_lease      automatic delivery takes a result a wait leases     *)
(*   release_delivered a release reopens a result already committed        *)
(*   lease_leak        a wait keeps its leases after it returns            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Jobs, Waits, Mutation

ASSUME Mutation \in {"none", "double_reserve", "ignore_lease",
                     "release_delivered", "lease_leak"}

Async == "async"
Consumers == Waits \cup {Async}

VARIABLES
    state,      \* job -> "running" | "settled"
    delivery,   \* job -> "open" | "reserved" | "delivered"
    holders,    \* job -> consumers holding a reservation
    received,   \* job -> how many times a commit gave the model the result
    leases,     \* job -> count of waits leasing it
    pc,         \* wait -> "idle" | "waiting" | "holding" | "done"
    targets,    \* wait -> jobs it waits on
    leased,     \* wait -> jobs whose lease it still holds
    stolen      \* automatic delivery reserved a leased result

vars == <<state, delivery, holders, received, leases, pc, targets, leased, stolen>>

TypeOK ==
    /\ state \in [Jobs -> {"running", "settled"}]
    /\ delivery \in [Jobs -> {"open", "reserved", "delivered"}]
    /\ holders \in [Jobs -> SUBSET Consumers]
    /\ received \in [Jobs -> Nat]
    /\ leases \in [Jobs -> 0..Cardinality(Waits)]
    /\ pc \in [Waits -> {"idle", "waiting", "holding", "done"}]
    /\ targets \in [Waits -> SUBSET Jobs]
    /\ leased \in [Waits -> SUBSET Jobs]
    /\ stolen \in BOOLEAN

Init ==
    /\ state = [j \in Jobs |-> "running"]
    /\ delivery = [j \in Jobs |-> "open"]
    /\ holders = [j \in Jobs |-> {}]
    /\ received = [j \in Jobs |-> 0]
    /\ leases = [j \in Jobs |-> 0]
    /\ pc = [w \in Waits |-> "idle"]
    /\ targets = [w \in Waits |-> {}]
    /\ leased = [w \in Waits |-> {}]
    /\ stolen = FALSE

Settle(j) ==
    /\ state[j] = "running"
    /\ state' = [state EXCEPT ![j] = "settled"]
    /\ UNCHANGED <<delivery, holders, received, leases, pc, targets, leased, stolen>>

\* A result one consumer may reserve now.
Reservable(j) ==
    /\ state[j] = "settled"
    /\ \/ delivery[j] = "open"
       \/ (Mutation = "double_reserve" /\ delivery[j] = "reserved")

Reserve(c, j) ==
    /\ delivery' = [delivery EXCEPT ![j] = "reserved"]
    /\ holders' = [holders EXCEPT ![j] = @ \cup {c}]

ReleaseLeases(w) ==
    IF Mutation = "lease_leak"
    THEN UNCHANGED <<leases, leased>>
    ELSE /\ leases' = [j \in Jobs |-> IF j \in leased[w] THEN leases[j] - 1 ELSE leases[j]]
         /\ leased' = [leased EXCEPT ![w] = {}]

\* Registry.wait: lease the targets (acquireLeases).
WaitStart(w, t) ==
    /\ pc[w] = "idle"
    /\ t # {}
    /\ pc' = [pc EXCEPT ![w] = "waiting"]
    /\ targets' = [targets EXCEPT ![w] = t]
    /\ leased' = [leased EXCEPT ![w] = t]
    /\ leases' = [j \in Jobs |-> IF j \in t THEN leases[j] + 1 ELSE leases[j]]
    /\ UNCHANGED <<state, delivery, holders, received, stolen>>

\* reserveTargets: a target settled; the wait reserves it and returns,
\* ending its leases.
WaitTake(w, j) ==
    /\ pc[w] = "waiting"
    /\ j \in targets[w]
    /\ Reservable(j)
    /\ Reserve(w, j)
    /\ pc' = [pc EXCEPT ![w] = "holding"]
    /\ ReleaseLeases(w)
    /\ UNCHANGED <<state, received, targets, stolen>>

\* The window passed, or every target was delivered elsewhere.
WaitReturnEmpty(w) ==
    /\ pc[w] = "waiting"
    /\ pc' = [pc EXCEPT ![w] = "done"]
    /\ ReleaseLeases(w)
    /\ UNCHANGED <<state, delivery, holders, received, targets, stolen>>

Commit(c, j) ==
    /\ c \in holders[j]
    /\ delivery' = [delivery EXCEPT ![j] = "delivered"]
    /\ holders' = [holders EXCEPT ![j] = @ \ {c}]
    /\ received' = [received EXCEPT ![j] = @ + 1]

Release(c, j) ==
    /\ c \in holders[j]
    /\ holders' = [holders EXCEPT ![j] = @ \ {c}]
    /\ delivery' = [delivery EXCEPT ![j] = IF holders'[j] = {} THEN "open" ELSE "reserved"]
    /\ UNCHANGED received

\* The wait's tool result committed (handOff's result commit token).
WaitCommit(w) ==
    /\ pc[w] = "holding"
    /\ \E j \in Jobs : w \in holders[j] /\ Commit(w, j)
    /\ pc' = [pc EXCEPT ![w] = "done"]
    /\ UNCHANGED <<state, leases, targets, leased, stolen>>

\* The turn dropped the wait's tool result: the reservation is cancelled.
WaitDrop(w) ==
    /\ pc[w] = "holding"
    /\ \E j \in Jobs : w \in holders[j] /\ Release(w, j)
    /\ pc' = [pc EXCEPT ![w] = "done"]
    /\ UNCHANGED <<state, leases, targets, leased, stolen>>

\* Registry.takeDeliveries: a settled result no wait leases.
AsyncTake(j) ==
    /\ Reservable(j)
    /\ (leases[j] = 0 \/ Mutation = "ignore_lease")
    /\ Reserve(Async, j)
    /\ stolen' = (stolen \/ leases[j] > 0)
    /\ UNCHANGED <<state, received, leases, pc, targets, leased>>

\* The supervisor's prompt admitted the notice.
AsyncCommit(j) ==
    /\ Commit(Async, j)
    /\ UNCHANGED <<state, leases, pc, targets, leased, stolen>>

\* The prompt was refused (the session was busy): try again later.
AsyncRelease(j) ==
    /\ Release(Async, j)
    /\ UNCHANGED <<state, leases, pc, targets, leased, stolen>>

\* A broken release that reopens a committed result.
ReopenDelivered(j) ==
    /\ Mutation = "release_delivered"
    /\ delivery[j] = "delivered"
    /\ delivery' = [delivery EXCEPT ![j] = "open"]
    /\ UNCHANGED <<state, holders, received, leases, pc, targets, leased, stolen>>

Next ==
    \/ \E j \in Jobs : Settle(j) \/ AsyncTake(j) \/ AsyncCommit(j) \/ AsyncRelease(j) \/ ReopenDelivered(j)
    \/ \E w \in Waits : \/ \E t \in SUBSET Jobs : WaitStart(w, t)
                        \/ \E j \in Jobs : WaitTake(w, j)
                        \/ WaitReturnEmpty(w) \/ WaitCommit(w) \/ WaitDrop(w)

\* Terminal state: every job delivered and every wait over.
Done ==
    /\ \A j \in Jobs : delivery[j] = "delivered"
    /\ \A w \in Waits : pc[w] \in {"idle", "done"}

SafetySpec == Init /\ [][Next \/ (Done /\ UNCHANGED vars)]_vars

Spec ==
    /\ SafetySpec
    /\ \A j \in Jobs : WF_vars(Settle(j)) /\ WF_vars(AsyncTake(j)) /\ SF_vars(AsyncCommit(j))
    /\ \A w \in Waits : WF_vars(WaitCommit(w) \/ WaitDrop(w)) /\ WF_vars(WaitReturnEmpty(w))

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

\* No result reaches the model twice.
ExactlyOnceDelivery == \A j \in Jobs : received[j] <= 1

\* At most one consumer holds a result at a time.
OneHolder == \A j \in Jobs : Cardinality(holders[j]) <= 1

\* A delivered result reached the model through some consumer.
DeliveredMeansReceived == \A j \in Jobs : delivery[j] = "delivered" => received[j] > 0

\* Automatic delivery never takes a result a wait is waiting for.
NoDeliveryUnderLease == ~stolen

\* Leases are counted exactly: what the waits hold.
LeasesCounted ==
    \A j \in Jobs : Mutation = "lease_leak" \/ leases[j] = Cardinality({w \in Waits : j \in leased[w]})

\* Every settled job's result reaches the model.
EventuallyDelivered == \A j \in Jobs : <>(delivery[j] = "delivered")
=============================================================================

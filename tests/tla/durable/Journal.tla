------------------------------ MODULE Journal ------------------------------
(***************************************************************************)
(* Step: the journal write path.                                          *)
(*                                                                         *)
(* The kernel records every state change as an event. Lazy events are     *)
(* pipelined to the backend without waiting. A barrier event blocks the   *)
(* kernel until the backend acknowledges it, which in an in-order         *)
(* pipeline also means every earlier event is durable. The World can      *)
(* refuse a write; every later pipelined write fails with it and the      *)
(* kernel folds the log again. The kernel can crash at any point; writes  *)
(* already in flight may or may not land. A new process restores from    *)
(* the durable log only after in-flight writes have settled (Fencing.tla  *)
(* covers the case where they have not).                                  *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxEvents, MaxCrashes

VARIABLES
    alive,    \* the kernel process is running
    mem,      \* the kernel's in-memory event sequence
    sent,     \* how many events of mem were handed to the backend, in order
    queue,    \* events in flight to the World, in order
    durable,  \* the World's log
    acked,    \* how many durable events the kernel has been told about
    waiting,  \* index in mem of the barrier the kernel is blocked on, or 0
    passed,   \* ids of barrier events the kernel continued past
    nextId,   \* next fresh event id
    crashes

vars == <<alive, mem, sent, queue, durable, acked, waiting, passed, nextId, crashes>>

Ev == [id : 1..MaxEvents, barrier : BOOLEAN]

Ids(s) == {s[i].id : i \in 1..Len(s)}

IsPrefix(a, b) == Len(a) <= Len(b) /\ SubSeq(b, 1, Len(a)) = a

TypeOK ==
    /\ alive \in BOOLEAN
    /\ mem \in Seq(Ev)
    /\ sent \in 0..MaxEvents
    /\ queue \in Seq(Ev)
    /\ durable \in Seq(Ev)
    /\ acked \in 0..MaxEvents
    /\ waiting \in 0..MaxEvents
    /\ passed \subseteq 1..MaxEvents
    /\ nextId \in 1..(MaxEvents + 1)
    /\ crashes \in 0..MaxCrashes

Init ==
    /\ alive = TRUE
    /\ mem = <<>>
    /\ sent = 0
    /\ queue = <<>>
    /\ durable = <<>>
    /\ acked = 0
    /\ waiting = 0
    /\ passed = {}
    /\ nextId = 1
    /\ crashes = 0

\* The kernel records a state change. A barrier blocks it until durable.
Emit(b) ==
    /\ alive
    /\ waiting = 0
    /\ nextId <= MaxEvents
    /\ mem' = Append(mem, [id |-> nextId, barrier |-> b])
    /\ waiting' = IF b THEN Len(mem) + 1 ELSE 0
    /\ nextId' = nextId + 1
    /\ UNCHANGED <<alive, sent, queue, durable, acked, passed, crashes>>

\* The backend takes the next event. Lazy events are pipelined.
Send ==
    /\ alive
    /\ sent < Len(mem)
    /\ queue' = Append(queue, mem[sent + 1])
    /\ sent' = sent + 1
    /\ UNCHANGED <<alive, mem, durable, acked, waiting, passed, nextId, crashes>>

\* The World makes the head of the queue durable, possibly after the
\* kernel died.
Persist ==
    /\ queue # <<>>
    /\ durable' = Append(durable, Head(queue))
    /\ queue' = Tail(queue)
    /\ UNCHANGED <<alive, mem, sent, acked, waiting, passed, nextId, crashes>>

\* The World acknowledges durable events in order.
Ack ==
    /\ alive
    /\ acked < Len(durable)
    /\ acked' = acked + 1
    /\ UNCHANGED <<alive, mem, sent, queue, durable, waiting, passed, nextId, crashes>>

\* The kernel continues once its barrier is acknowledged.
PassBarrier ==
    /\ alive
    /\ waiting # 0
    /\ acked >= waiting
    /\ passed' = passed \cup {mem[waiting].id}
    /\ waiting' = 0
    /\ UNCHANGED <<alive, mem, sent, queue, durable, acked, nextId, crashes>>

\* The World refuses the head write. Every later pipelined write fails with
\* it, and the kernel drops its run-ahead state and folds the log again.
Reject ==
    /\ alive
    /\ queue # <<>>
    /\ queue' = <<>>
    /\ waiting' = 0
    /\ acked' = Len(durable)
    /\ sent' = Len(durable)
    /\ mem' = durable
    /\ UNCHANGED <<alive, durable, passed, nextId, crashes>>

\* The process dies. Writes already in flight may or may not land.
Crash ==
    /\ alive
    /\ crashes < MaxCrashes
    /\ alive' = FALSE
    /\ mem' = <<>>
    /\ sent' = 0
    /\ acked' = 0
    /\ waiting' = 0
    /\ \E k \in 0..Len(queue) : queue' = SubSeq(queue, 1, k)
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<durable, passed, nextId>>

\* A new process folds the durable log once in-flight writes settled.
Restore ==
    /\ ~alive
    /\ queue = <<>>
    /\ alive' = TRUE
    /\ mem' = durable
    /\ sent' = Len(durable)
    /\ acked' = Len(durable)
    /\ UNCHANGED <<queue, durable, waiting, passed, nextId, crashes>>

Next ==
    \/ \E b \in BOOLEAN : Emit(b)
    \/ Send
    \/ Persist
    \/ Ack
    \/ PassBarrier
    \/ Reject
    \/ Crash
    \/ Restore

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* What is durable plus what is in flight is exactly what the kernel sent,
\* in the kernel's order. No event is lost, reordered or invented.
PipelineInOrder == alive => durable \o queue = SubSeq(mem, 1, sent)

\* The kernel's view always contains everything durable.
KernelSeesDurable == alive => IsPrefix(durable, mem)

\* The kernel is only told about writes that are durable.
AckedAreDurable == acked <= Len(durable)

\* Every barrier the kernel continued past is durable.
PassedBarriersDurable == passed \subseteq Ids(durable)

\* No event is written twice.
NoDuplicateEvents ==
    \A i, j \in 1..Len(durable) : durable[i].id = durable[j].id => i = j

\* Action property: the World log is only ever extended.
DurableOnlyGrows == [][IsPrefix(durable, durable')]_vars

=============================================================================

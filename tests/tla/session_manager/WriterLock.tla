---------------------------- MODULE WriterLock ----------------------------
(***************************************************************************)
(* Step: L0 flock plus the L2 per-session mutex.                          *)
(*                                                                         *)
(* One writing process per session (flock on {id}/lock) and many threads *)
(* per process (the Session mutex inside the manager). The kernel drops  *)
(* the flock when a process dies. Hosts never lock anything; Acquire and *)
(* WriteAndRelease happen inside append(). Busy is modeled as Open being *)
(* disabled while another process holds the lock.                        *)
(*                                                                         *)
(* Design: system-design.md "Concurrency And Ordering".                   *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Procs, Threads, MaxLines, None

VARIABLES
    holder,   \* process holding the flock, or None
    alive,    \* [Procs -> BOOLEAN]
    opened,   \* [Procs -> BOOLEAN]: the process has an open Session
    nextSeq,  \* [Procs -> Nat]: the Session's in-memory next seq
    mutex,    \* [Procs -> Threads \cup {None}]: thread inside append()
    file      \* the log: a sequence of [seq, by]

vars == <<holder, alive, opened, nextSeq, mutex, file>>

TypeOK ==
    /\ holder \in Procs \cup {None}
    /\ alive \in [Procs -> BOOLEAN]
    /\ opened \in [Procs -> BOOLEAN]
    /\ nextSeq \in [Procs -> 1..(MaxLines + 1)]
    /\ mutex \in [Procs -> Threads \cup {None}]
    /\ file \in Seq([seq : 1..MaxLines, by : Procs])

Init ==
    /\ holder = None
    /\ alive = [p \in Procs |-> TRUE]
    /\ opened = [p \in Procs |-> FALSE]
    /\ nextSeq = [p \in Procs |-> 1]
    /\ mutex = [p \in Procs |-> None]
    /\ file = <<>>

\* open(): flock succeeds only when nobody holds it; otherwise Busy.
\* The Session learns the next seq from the file it just locked.
Open(p) ==
    /\ alive[p]
    /\ ~opened[p]
    /\ holder = None
    /\ holder' = p
    /\ opened' = [opened EXCEPT ![p] = TRUE]
    /\ nextSeq' = [nextSeq EXCEPT ![p] = Len(file) + 1]
    /\ UNCHANGED <<alive, mutex, file>>

\* A thread calls append(); the manager takes the Session mutex.
Acquire(p, t) ==
    /\ alive[p]
    /\ opened[p]
    /\ mutex[p] = None
    /\ mutex' = [mutex EXCEPT ![p] = t]
    /\ UNCHANGED <<holder, alive, opened, nextSeq, file>>

\* Under the mutex: assign seq, write the line, release the mutex.
WriteAndRelease(p, t) ==
    /\ alive[p]
    /\ opened[p]
    /\ mutex[p] = t
    /\ Len(file) < MaxLines
    /\ file' = Append(file, [seq |-> nextSeq[p], by |-> p])
    /\ nextSeq' = [nextSeq EXCEPT ![p] = @ + 1]
    /\ mutex' = [mutex EXCEPT ![p] = None]
    /\ UNCHANGED <<holder, alive, opened>>

\* close(): waits for the mutex, then releases the flock.
Close(p) ==
    /\ alive[p]
    /\ opened[p]
    /\ mutex[p] = None
    /\ holder = p
    /\ holder' = None
    /\ opened' = [opened EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<alive, nextSeq, mutex, file>>

\* The process dies; the kernel releases its flock.
Crash(p) ==
    /\ alive[p]
    /\ alive' = [alive EXCEPT ![p] = FALSE]
    /\ opened' = [opened EXCEPT ![p] = FALSE]
    /\ mutex' = [mutex EXCEPT ![p] = None]
    /\ holder' = IF holder = p THEN None ELSE holder
    /\ UNCHANGED <<nextSeq, file>>

Restart(p) ==
    /\ ~alive[p]
    /\ alive' = [alive EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<holder, opened, nextSeq, mutex, file>>

Next ==
    \E p \in Procs :
        \/ Open(p)
        \/ Close(p)
        \/ Crash(p)
        \/ Restart(p)
        \/ \E t \in Threads : Acquire(p, t) \/ WriteAndRelease(p, t)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* At most one process has the session open for writing.
OneWriter == \A p, q \in Procs : opened[p] /\ opened[q] => p = q

\* Only the flock holder has an open Session.
OnlyHolderOpen == \A p \in Procs : opened[p] => holder = p

\* A thread inside append() always belongs to an open Session.
MutexInsideOpenSession == \A p \in Procs : mutex[p] # None => opened[p]

\* File order is seq order: no duplicates, no gaps, across threads and
\* across processes taking over after a crash.
SeqIsPosition == \A i \in 1..Len(file) : file[i].seq = i
=============================================================================

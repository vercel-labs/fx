---------------------------- MODULE OpenCancel ----------------------------
(* A model request's connection open (DNS lookup and connect, in
   src/gateway/client.zig openGatewayRequestBounded) racing Esc.

   The worker waits for the open. The open job may sit in a lookup that
   never returns (a dropped network), so LookupReturns has no fairness.
   The design: on cancel the worker abandons the job by one atomic swap on
   a shared state word and returns at once; the job, when its lookup
   finally returns, publishes by the same swap and closes the connection
   itself when it finds the job abandoned.

   Constants select the design or a planted defect:
     Abandon     FALSE is fx today: cancel waits for the open to finish.
     CloseLate   FALSE abandons without closing the late connection.
     AtomicSwap  FALSE splits each side's read and write of the state. *)
EXTENDS TLC

CONSTANTS Abandon, CloseLate, AtomicSwap

VARIABLES worker,   \* "waiting", "returned", "using"
          job,      \* "lookup", "finished", "reading", "published"
          conn,     \* "none", "open", "closed"
          state,    \* "running", "abandoned", "handed"
          cancelled,
          wseen,    \* the worker's read of state (non-atomic variant)
          jseen     \* the job's read of state (non-atomic variant)

vars == <<worker, job, conn, state, cancelled, wseen, jseen>>

TypeOK ==
    /\ worker \in {"waiting", "returned", "using"}
    /\ job \in {"lookup", "finished", "reading", "published"}
    /\ conn \in {"none", "open", "closed"}
    /\ state \in {"running", "abandoned", "handed"}
    /\ cancelled \in BOOLEAN
    /\ wseen \in {"none", "running", "abandoned", "handed"}
    /\ jseen \in {"none", "running", "abandoned", "handed"}

Init ==
    /\ worker = "waiting" /\ job = "lookup" /\ conn = "none"
    /\ state = "running" /\ cancelled = FALSE
    /\ wseen = "none" /\ jseen = "none"

\* Esc, while the worker still waits for the open.
Cancel ==
    /\ worker = "waiting" /\ ~cancelled
    /\ cancelled' = TRUE
    /\ UNCHANGED <<worker, job, conn, state, wseen, jseen>>

\* The lookup and connect return: maybe soon, maybe never.
LookupReturns ==
    /\ job = "lookup"
    /\ job' = "finished" /\ conn' = "open"
    /\ UNCHANGED <<worker, state, cancelled, wseen, jseen>>

CloseOrKeep == IF CloseLate THEN "closed" ELSE "open"

\* The job publishes its connection, or closes it when abandoned.
JobPublishAtomic ==
    /\ AtomicSwap /\ job = "finished"
    /\ job' = "published"
    /\ IF state = "running"
          THEN state' = "handed" /\ UNCHANGED conn
          ELSE conn' = CloseOrKeep /\ UNCHANGED state
    /\ UNCHANGED <<worker, cancelled, wseen, jseen>>

JobRead ==
    /\ ~AtomicSwap /\ job = "finished"
    /\ job' = "reading" /\ jseen' = state
    /\ UNCHANGED <<worker, conn, state, cancelled, wseen>>

JobWrite ==
    /\ ~AtomicSwap /\ job = "reading"
    /\ job' = "published"
    /\ IF jseen = "running"
          THEN state' = "handed" /\ UNCHANGED conn
          ELSE conn' = CloseOrKeep /\ UNCHANGED state
    /\ UNCHANGED <<worker, cancelled, wseen, jseen>>

\* Design: a cancelled worker abandons the job and returns at once. If the
\* job already handed over, the worker closes what it was handed.
WorkerAbandonAtomic ==
    /\ Abandon /\ AtomicSwap /\ worker = "waiting" /\ cancelled
    /\ worker' = "returned"
    /\ IF state = "running"
          THEN state' = "abandoned" /\ UNCHANGED conn
          ELSE IF state = "handed"
               THEN conn' = "closed" /\ UNCHANGED state
               ELSE UNCHANGED <<state, conn>>
    /\ UNCHANGED <<job, cancelled, wseen, jseen>>

WorkerRead ==
    /\ Abandon /\ ~AtomicSwap /\ worker = "waiting" /\ cancelled /\ wseen = "none"
    /\ wseen' = state
    /\ UNCHANGED <<worker, job, conn, state, cancelled, jseen>>

WorkerWrite ==
    /\ Abandon /\ ~AtomicSwap /\ worker = "waiting" /\ cancelled /\ wseen # "none"
    /\ worker' = "returned"
    /\ IF wseen = "running"
          THEN state' = "abandoned" /\ UNCHANGED conn
          ELSE IF wseen = "handed"
               THEN conn' = "closed" /\ UNCHANGED state
               ELSE UNCHANGED <<state, conn>>
    /\ UNCHANGED <<job, cancelled, wseen, jseen>>

\* fx today: the worker can only act once the open is published.
WorkerAfterPublish ==
    /\ ~Abandon /\ worker = "waiting" /\ job = "published" /\ state = "handed"
    /\ IF cancelled
          THEN worker' = "returned" /\ conn' = "closed"
          ELSE worker' = "using" /\ UNCHANGED conn
    /\ UNCHANGED <<job, state, cancelled, wseen, jseen>>

\* No cancel: the worker takes the connection it was handed.
WorkerTake ==
    /\ Abandon /\ worker = "waiting" /\ ~cancelled /\ state = "handed"
    /\ worker' = "using"
    /\ UNCHANGED <<job, conn, state, cancelled, wseen, jseen>>

WorkerStep == WorkerAbandonAtomic \/ WorkerRead \/ WorkerWrite \/ WorkerAfterPublish \/ WorkerTake
JobStep == JobPublishAtomic \/ JobRead \/ JobWrite

Next == Cancel \/ LookupReturns \/ JobStep \/ WorkerStep

Spec == Init /\ [][Next]_vars /\ WF_vars(WorkerStep) /\ WF_vars(JobStep)

\* A connection is never used after its request was cancelled.
NeverUsedAfterCancel == ~(worker = "using" /\ cancelled)

\* A cancel gives the worker back, however long the lookup takes.
CancelReturns == [](cancelled => <>(worker = "returned"))

\* Once nobody uses it, every late connection ends up closed.
LateClosed == <>[](worker # "using" /\ job = "published" => conn # "open")
=============================================================================

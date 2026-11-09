---------------------------- MODULE OpenCancel ----------------------------
(* A model request's connection open (DNS lookup, then connect and TLS
   setup, in src/gateway/client.zig openGatewayRequestBounded and
   openBoundedPost) racing Esc.

   The worker waits for the open. The open job may sit in a lookup that
   never returns (a dropped network), or in a connect or TLS setup a server
   never answers, so LookupReturns and ConnectReturns have no fairness.
   The design: on cancel the worker abandons the job by one atomic swap on
   a shared state word and returns at once; the job, once it sees the job
   abandoned, stops a connect it is still in (a lookup cannot be stopped),
   then publishes by the same swap and closes the connection itself when it
   finds the job abandoned.

   `client` is the memory the open runs on: for an unpooled open, a client
   the job makes, since the worker's own ends with its attempt. Whichever
   side owns the result frees it, and the job must never be left using it
   freed.

   Constants select the design or a planted defect:
     Abandon      FALSE is fx before the open job: cancel waits for the open.
     CloseLate    FALSE abandons without closing the late connection.
     AtomicSwap   FALSE splits each side's read and write of the state.
     StopConnect  FALSE leaves an abandoned job in a connect nobody answers.
     FreeOnReturn TRUE frees the client whenever the worker returns, as a
                  client made for one attempt is. *)
EXTENDS TLC

CONSTANTS Abandon, CloseLate, AtomicSwap, StopConnect, FreeOnReturn

VARIABLES worker,   \* "waiting", "returned", "using", "done"
          job,      \* "lookup", "connect", "finished", "reading", "published"
          conn,     \* "none", "open", "closed"
          client,   \* "live", "freed"
          state,    \* "running", "abandoned", "handed"
          cancelled,
          wseen,    \* the worker's read of state (non-atomic variant)
          jseen     \* the job's read of state (non-atomic variant)

vars == <<worker, job, conn, client, state, cancelled, wseen, jseen>>

TypeOK ==
    /\ worker \in {"waiting", "returned", "using", "done"}
    /\ job \in {"lookup", "connect", "finished", "reading", "published"}
    /\ conn \in {"none", "open", "closed"}
    /\ client \in {"live", "freed"}
    /\ state \in {"running", "abandoned", "handed"}
    /\ cancelled \in BOOLEAN
    /\ wseen \in {"none", "running", "abandoned", "handed"}
    /\ jseen \in {"none", "running", "abandoned", "handed"}

Init ==
    /\ worker = "waiting" /\ job = "lookup" /\ conn = "none" /\ client = "live"
    /\ state = "running" /\ cancelled = FALSE
    /\ wseen = "none" /\ jseen = "none"

\* Esc, while the worker still waits for the open.
Cancel ==
    /\ worker = "waiting" /\ ~cancelled
    /\ cancelled' = TRUE
    /\ UNCHANGED <<worker, job, conn, client, state, wseen, jseen>>

\* The lookup returns and the connect starts: maybe soon, maybe never.
LookupReturns ==
    /\ job = "lookup"
    /\ job' = "connect" /\ conn' = "open"
    /\ UNCHANGED <<worker, client, state, cancelled, wseen, jseen>>

\* The connect and TLS setup finish: maybe soon, maybe never.
ConnectReturns ==
    /\ job = "connect"
    /\ job' = "finished"
    /\ UNCHANGED <<worker, conn, client, state, cancelled, wseen, jseen>>

\* Design: an abandoned job stops its connect, which closes the half-open
\* connection and fails the open.
JobStopConnect ==
    /\ StopConnect /\ job = "connect" /\ state = "abandoned"
    /\ job' = "finished" /\ conn' = "closed"
    /\ UNCHANGED <<worker, client, state, cancelled, wseen, jseen>>

\* What the job does with a late open it finds abandoned.
CloseLateConn == IF CloseLate /\ conn = "open" THEN "closed" ELSE conn
FreeLateClient == IF CloseLate THEN "freed" ELSE client

\* The job publishes its connection, or closes it and frees the client when
\* abandoned.
JobPublishAtomic ==
    /\ AtomicSwap /\ job = "finished"
    /\ job' = "published"
    /\ IF state = "running"
          THEN state' = "handed" /\ UNCHANGED <<conn, client>>
          ELSE conn' = CloseLateConn /\ client' = FreeLateClient /\ UNCHANGED state
    /\ UNCHANGED <<worker, cancelled, wseen, jseen>>

JobRead ==
    /\ ~AtomicSwap /\ job = "finished"
    /\ job' = "reading" /\ jseen' = state
    /\ UNCHANGED <<worker, conn, client, state, cancelled, wseen>>

JobWrite ==
    /\ ~AtomicSwap /\ job = "reading"
    /\ job' = "published"
    /\ IF jseen = "running"
          THEN state' = "handed" /\ UNCHANGED <<conn, client>>
          ELSE conn' = CloseLateConn /\ client' = FreeLateClient /\ UNCHANGED state
    /\ UNCHANGED <<worker, cancelled, wseen, jseen>>

\* The client the worker leaves behind when it walks away.
WalkAwayClient == IF FreeOnReturn THEN "freed" ELSE client

\* Design: a cancelled worker abandons the job and returns at once. If the
\* job already handed over, the worker closes what it was handed and frees
\* the client.
WorkerAbandonAtomic ==
    /\ Abandon /\ AtomicSwap /\ worker = "waiting" /\ cancelled
    /\ worker' = "returned"
    /\ IF state = "running"
          THEN state' = "abandoned" /\ client' = WalkAwayClient /\ UNCHANGED conn
          ELSE IF state = "handed"
               THEN conn' = "closed" /\ client' = "freed" /\ UNCHANGED state
               ELSE UNCHANGED <<state, conn, client>>
    /\ UNCHANGED <<job, cancelled, wseen, jseen>>

WorkerRead ==
    /\ Abandon /\ ~AtomicSwap /\ worker = "waiting" /\ cancelled /\ wseen = "none"
    /\ wseen' = state
    /\ UNCHANGED <<worker, job, conn, client, state, cancelled, jseen>>

WorkerWrite ==
    /\ Abandon /\ ~AtomicSwap /\ worker = "waiting" /\ cancelled /\ wseen # "none"
    /\ worker' = "returned"
    /\ IF wseen = "running"
          THEN state' = "abandoned" /\ client' = WalkAwayClient /\ UNCHANGED conn
          ELSE IF wseen = "handed"
               THEN conn' = "closed" /\ client' = "freed" /\ UNCHANGED state
               ELSE UNCHANGED <<state, conn, client>>
    /\ UNCHANGED <<job, cancelled, wseen, jseen>>

\* fx before the open job: the worker can only act once the open is
\* published.
WorkerAfterPublish ==
    /\ ~Abandon /\ worker = "waiting" /\ job = "published" /\ state = "handed"
    /\ IF cancelled
          THEN worker' = "returned" /\ conn' = "closed" /\ client' = "freed"
          ELSE worker' = "using" /\ UNCHANGED <<conn, client>>
    /\ UNCHANGED <<job, state, cancelled, wseen, jseen>>

\* No cancel: the worker takes the connection it was handed.
WorkerTake ==
    /\ Abandon /\ worker = "waiting" /\ ~cancelled /\ state = "handed"
    /\ worker' = "using"
    /\ UNCHANGED <<job, conn, client, state, cancelled, wseen, jseen>>

\* The request ends: the worker closes the connection and frees the client.
WorkerDone ==
    /\ worker = "using"
    /\ worker' = "done" /\ conn' = "closed" /\ client' = "freed"
    /\ UNCHANGED <<job, state, cancelled, wseen, jseen>>

WorkerStep == WorkerAbandonAtomic \/ WorkerRead \/ WorkerWrite \/ WorkerAfterPublish \/ WorkerTake \/ WorkerDone
JobStep == JobStopConnect \/ JobPublishAtomic \/ JobRead \/ JobWrite

Next == Cancel \/ LookupReturns \/ ConnectReturns \/ JobStep \/ WorkerStep

Spec == Init /\ [][Next]_vars /\ WF_vars(WorkerStep) /\ WF_vars(JobStep)

\* A connection is never used after its request was cancelled.
NeverUsedAfterCancel == ~(worker = "using" /\ cancelled)

\* The client is never freed while the job still opens on it.
NoFreeUnderJob == client = "freed" => job = "published"

\* The worker never uses a freed client.
NoUseAfterFree == worker = "using" => client = "live"

\* A cancel gives the worker back, however long the lookup takes.
CancelReturns == [](cancelled => <>(worker = "returned"))

\* Once nobody uses it, every late connection ends up closed.
LateClosed == <>[](worker # "using" /\ job = "published" => conn # "open")

\* A job the worker walked away from leaves no connection open, even when
\* the server never answers its connect.
AbandonedOpenCloses == [](state = "abandoned" => <>[](conn # "open"))

\* Once both sides are done with it, the client is freed.
ClientFreed == <>[](worker \in {"returned", "done"} /\ job = "published" => client = "freed")
=============================================================================

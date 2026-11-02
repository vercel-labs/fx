---- MODULE StdioConn ----
\* U03 stdio connection, client side: at most one server process at a time.
\* Rules: STDIO-01 (WritesOnlyWhenOpen), STDIO-02 (NoClientResponsesModern),
\* STDIO-09 (NoRefusedAnswer),
\* STDIO-06 (SignalOrder, SignalsOnTime, Progress), STDIO-07 (OneProcess,
\* NoOrphan, NoStaleDelivery, RestartBounded, NoEarlyRestart).
\* It also models the backoff and attempt limit, an oversized line as a
\* connection error, restart on demand after backoff, invalid lines dropped
\* like stale ones, and the shutdown steps.
\*
\* The process is the environment. While alive it can write lines (EmitLine)
\* and exit at any time (Crash). Crash covers real crashes, the server shutting
\* down on its own, and exiting after stdin closes or SIGTERM arrives. After
\* SIGKILL it must exit (Killed, weakly fair). Lines stay in the pipe after the
\* process exits, so the client can still read them after a restart: `pipe`
\* holds the generations that still have unread lines. stderr is not modeled
\* because it never changes the connection's state (STDIO-05).
\*
\* Time is abstract. Timers are tagged with the generation of the process they
\* were armed for, are never disarmed, and fire eventually (weak fairness), so
\* a timer from an earlier process can fire at any later point.
EXTENDS Naturals

CONSTANTS MaxAttempts, MaxStarts

ASSUME MaxAttempts \in Nat \ {0} /\ MaxStarts \in Nat \ {0}

Conn == {"idle", "starting", "running", "closing", "terminating", "killing", "backoff", "failed", "stopped"}
Live == {"running", "closing", "terminating", "killing"}
Down == {"idle", "backoff", "failed", "stopped"}
Proc == {"none", "alive", "exited", "reaped"}
Era == {"unknown", "modern", "legacy"}
Kind == {"request", "notification", "response"}
Gens == 1..MaxStarts
Timers == {"grace", "term", "backoff"} \X Gens

VARIABLES
    conn,       \* the connection's state
    proc,       \* the current process as the OS sees it; "reaped" once the client waited for it
    gen,        \* generation of the current or last process; 0 before the first start
    attempts,   \* consecutive failures since a message last arrived
    era,        \* set by version detection (U04), reset for each process
    stdinOpen,  \* the client's end of the process's stdin is open
    stopping,   \* the host asked to stop
    errored,    \* this process is being killed for a connection error
    sent,       \* signals sent to this process
    pipe,       \* generations with unread stdout lines
    armed,      \* timers armed and not yet fired
    \* Ghost variables for the safety properties.
    staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly

vars == <<conn, proc, gen, attempts, era, stdinOpen, stopping, errored, sent, pipe, armed,
          staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

Init ==
    /\ conn = "idle"
    /\ proc = "none"
    /\ gen = 0
    /\ attempts = 0
    /\ era = "unknown"
    /\ stdinOpen = FALSE
    /\ stopping = FALSE
    /\ errored = FALSE
    /\ sent = {}
    /\ pipe = {}
    /\ armed = {}
    /\ staleDelivered = FALSE
    /\ badWrite = FALSE
    /\ respondedModern = FALSE
    /\ earlyTerm = FALSE
    /\ restartedEarly = FALSE

\* A failed start, or an exit the client didn't ask for. Changes
\* conn, attempts, and armed.
Failure ==
    /\ attempts' = attempts + 1
    /\ IF attempts + 1 >= MaxAttempts
          THEN conn' = "failed" /\ armed' = armed
          ELSE conn' = "backoff" /\ armed' = armed \cup {<<"backoff", gen>>}

\* The host wants the server running: on demand, and never from backoff.
\* A start after a host stop is a fresh start, so the failure count resets;
\* after a backoff it keeps counting.
StartRequested ==
    /\ conn \in {"idle", "stopped"}
    /\ gen < MaxStarts
    /\ conn' = "starting"
    /\ gen' = gen + 1
    /\ attempts' = IF conn = "stopped" THEN 0 ELSE attempts
    /\ era' = "unknown"
    /\ stopping' = FALSE
    /\ errored' = FALSE
    /\ sent' = {}
    /\ UNCHANGED <<proc, stdinOpen, pipe, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

\* The process started. If the host asked to stop meanwhile, close stdin at once.
Spawned ==
    /\ conn = "starting"
    /\ proc' = "alive"
    /\ IF stopping
          THEN conn' = "closing" /\ stdinOpen' = FALSE /\ armed' = armed \cup {<<"grace", gen>>}
          ELSE conn' = "running" /\ stdinOpen' = TRUE /\ armed' = armed
    /\ UNCHANGED <<gen, attempts, era, stopping, errored, sent, pipe,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

SpawnFailed ==
    /\ conn = "starting"
    /\ IF stopping
          THEN conn' = "stopped" /\ UNCHANGED <<attempts, armed>>
          ELSE Failure
    /\ UNCHANGED <<proc, gen, era, stdinOpen, stopping, errored, sent, pipe,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

\* Environment: the process writes a line to stdout.
EmitLine ==
    /\ proc = "alive"
    /\ pipe' = pipe \cup {gen}
    /\ UNCHANGED <<conn, proc, gen, attempts, era, stdinOpen, stopping, errored, sent, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

\* Only the current process's lines are delivered, while it is live.
Deliverable(g) == g = gen /\ conn \in Live

\* A complete line from process g. A delivered line shows the server works,
\* so the failure count resets. Stale and invalid lines are dropped.
LineReceived(g) ==
    /\ g \in pipe
    /\ pipe' \in {pipe, pipe \ {g}}
    /\ IF Deliverable(g)
          THEN attempts' = 0 /\ staleDelivered' = (staleDelivered \/ g # gen)
          ELSE UNCHANGED <<attempts, staleDelivered>>
    /\ UNCHANGED <<conn, proc, gen, era, stdinOpen, stopping, errored, sent, armed,
                   badWrite, respondedModern, earlyTerm, restartedEarly>>

\* A connection error while running: kill the process at once.
ConnectionError ==
    /\ conn' = "killing"
    /\ stdinOpen' = FALSE
    /\ errored' = TRUE
    /\ sent' = sent \cup {"kill"}

\* A line from the current process over the limit. The rest of the
\* pipe is discarded.
OversizedLine(g) ==
    /\ g \in pipe
    /\ pipe' = pipe \ {g}
    /\ IF g = gen /\ conn = "running"
          THEN ConnectionError
          ELSE UNCHANGED <<conn, stdinOpen, errored, sent>>
    /\ UNCHANGED <<proc, gen, attempts, era, stopping, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

\* Writing to stdin failed: the process closed it or exited.
WriteFailed ==
    /\ conn = "running"
    /\ ConnectionError
    /\ UNCHANGED <<proc, gen, attempts, era, stopping, pipe, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

\* The connection takes a response unless the server is a 2026 one (STDIO-02).
\* Until detection ends the era is unknown, and the host answers only once it
\* has started the 2025 handshake (STDIO-09).
ResponseAllowed == era # "modern"

\* The client writes one message (STDIO-01).
Send(k) ==
    /\ conn = "running"
    /\ k = "response" => ResponseAllowed
    /\ badWrite' = (badWrite \/ ~stdinOpen)
    /\ respondedModern' = (respondedModern \/ (k = "response" /\ era = "modern"))
    /\ UNCHANGED <<conn, proc, gen, attempts, era, stdinOpen, stopping, errored, sent, pipe, armed,
                   staleDelivered, earlyTerm, restartedEarly>>

\* Version detection (U04) finished for this process.
EraDetected(e) ==
    /\ conn = "running"
    /\ era = "unknown"
    /\ era' = e
    /\ UNCHANGED <<conn, proc, gen, attempts, stdinOpen, stopping, errored, sent, pipe, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

\* Environment: the process exits for any reason.
Crash ==
    /\ proc = "alive"
    /\ proc' = "exited"
    /\ UNCHANGED <<conn, gen, attempts, era, stdinOpen, stopping, errored, sent, pipe, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

\* Environment: the operating system honors SIGKILL.
Killed ==
    /\ proc = "alive"
    /\ "kill" \in sent
    /\ proc' = "exited"
    /\ UNCHANGED <<conn, gen, attempts, era, stdinOpen, stopping, errored, sent, pipe, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

\* The client reaps the process. When stopping, the connection is stopped;
\* otherwise the exit is a failure and in-flight requests are lost (STDIO-07).
ProcessExited ==
    /\ proc = "exited"
    /\ proc' = "reaped"
    /\ stdinOpen' = FALSE
    /\ IF stopping
          THEN conn' = "stopped" /\ UNCHANGED <<attempts, armed>>
          ELSE Failure
    /\ UNCHANGED <<gen, era, stopping, errored, sent, pipe,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

\* The host asks to stop (STDIO-06): close stdin first, then wait.
StopRequested ==
    /\ ~stopping
    /\ conn # "stopped"
    /\ stopping' = TRUE
    /\ CASE conn = "running" ->
                conn' = "closing" /\ stdinOpen' = FALSE /\ armed' = armed \cup {<<"grace", gen>>}
         [] conn \in Down ->
                conn' = "stopped" /\ UNCHANGED <<stdinOpen, armed>>
         [] OTHER ->
                UNCHANGED <<conn, stdinOpen, armed>>
    /\ UNCHANGED <<proc, gen, attempts, era, errored, sent, pipe,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

\* The process didn't exit after stdin closed; send SIGTERM. A timer
\* from an earlier process, or one that fires in another state, changes nothing.
GraceTimerFired(g) ==
    /\ <<"grace", g>> \in armed
    /\ IF g = gen /\ conn = "closing"
          THEN /\ conn' = "terminating"
               /\ sent' = sent \cup {"term"}
               /\ armed' = (armed \ {<<"grace", g>>}) \cup {<<"term", gen>>}
               /\ earlyTerm' = (earlyTerm \/ <<"grace", gen>> \in (armed \ {<<"grace", g>>}))
          ELSE /\ armed' = armed \ {<<"grace", g>>}
               /\ UNCHANGED <<conn, sent, earlyTerm>>
    /\ UNCHANGED <<proc, gen, attempts, era, stdinOpen, stopping, errored, pipe,
                   staleDelivered, badWrite, respondedModern, restartedEarly>>

\* The process ignored SIGTERM; send SIGKILL.
TermTimerFired(g) ==
    /\ <<"term", g>> \in armed
    /\ armed' = armed \ {<<"term", g>>}
    /\ IF g = gen /\ conn = "terminating"
          THEN conn' = "killing" /\ sent' = sent \cup {"kill"}
          ELSE UNCHANGED <<conn, sent>>
    /\ UNCHANGED <<proc, gen, attempts, era, stdinOpen, stopping, errored, pipe,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

\* The backoff after a failure is over; the next demand may start again.
BackoffTimerFired(g) ==
    /\ <<"backoff", g>> \in armed
    /\ armed' = armed \ {<<"backoff", g>>}
    /\ IF g = gen /\ conn = "backoff"
          THEN conn' = "idle" /\ restartedEarly' = (restartedEarly \/ <<"backoff", gen>> \in armed')
          ELSE UNCHANGED <<conn, restartedEarly>>
    /\ UNCHANGED <<proc, gen, attempts, era, stdinOpen, stopping, errored, sent, pipe,
                   staleDelivered, badWrite, respondedModern, earlyTerm>>

\* After the attempt limit, only the host can try again.
ReconnectRequested ==
    /\ conn = "failed"
    /\ conn' = "idle"
    /\ attempts' = 0
    /\ UNCHANGED <<proc, gen, era, stdinOpen, stopping, errored, sent, pipe, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

Next ==
    \/ StartRequested
    \/ Spawned
    \/ SpawnFailed
    \/ EmitLine
    \/ \E g \in Gens: LineReceived(g) \/ OversizedLine(g)
    \/ WriteFailed
    \/ \E k \in Kind: Send(k)
    \/ \E e \in {"modern", "legacy"}: EraDetected(e)
    \/ Crash
    \/ Killed
    \/ ProcessExited
    \/ StopRequested
    \/ \E g \in Gens: GraceTimerFired(g) \/ TermTimerFired(g) \/ BackoffTimerFired(g)
    \/ ReconnectRequested

Fairness ==
    /\ WF_vars(Spawned \/ SpawnFailed)
    /\ WF_vars(Killed)
    /\ WF_vars(ProcessExited)
    /\ \A g \in Gens: WF_vars(GraceTimerFired(g)) /\ WF_vars(TermTimerFired(g)) /\ WF_vars(BackoffTimerFired(g))

Spec == Init /\ [][Next]_vars /\ Fairness

TypeOK ==
    /\ conn \in Conn
    /\ proc \in Proc
    /\ gen \in 0..MaxStarts
    /\ attempts \in 0..MaxAttempts
    /\ era \in Era
    /\ stdinOpen \in BOOLEAN
    /\ stopping \in BOOLEAN
    /\ errored \in BOOLEAN
    /\ sent \subseteq {"term", "kill"}
    /\ pipe \subseteq Gens
    /\ armed \subseteq Timers
    /\ staleDelivered \in BOOLEAN
    /\ badWrite \in BOOLEAN
    /\ respondedModern \in BOOLEAN
    /\ earlyTerm \in BOOLEAN
    /\ restartedEarly \in BOOLEAN

\* STDIO-07: a new process starts only after the previous one was reaped.
OneProcess == conn = "starting" => proc \in {"none", "reaped"}

\* STDIO-06, STDIO-07: a connection that is down has no process left running or unreaped.
NoOrphan == conn \in Down => proc \in {"none", "reaped"}

\* STDIO-07: a line from an earlier process is never delivered.
NoStaleDelivery == ~staleDelivered

\* STDIO-01: the client writes only while the process's stdin is open.
WritesOnlyWhenOpen == ~badWrite

\* STDIO-02: no responses to a 2026 server.
NoClientResponsesModern == ~respondedModern

\* STDIO-09: outside the 2026 era the connection takes the host's answer to a
\* server's request, including a ping during the 2025 handshake, before
\* detection ends.
NoRefusedAnswer == (conn = "running" /\ era # "modern") => ResponseAllowed

\* STDIO-06: SIGTERM only after stdin is closed on a host stop; SIGKILL only
\* after SIGTERM, or for a connection error.
SignalOrder ==
    /\ "term" \in sent => (~stdinOpen /\ stopping /\ ~errored)
    /\ "kill" \in sent => ("term" \in sent \/ errored)

\* SIGTERM only after this process's own grace period.
SignalsOnTime == ~earlyTerm

\* The failure count never passes the limit, "failed" means it was
\* reached, and a backoff always has an attempt left.
RestartBounded ==
    /\ attempts <= MaxAttempts
    /\ conn = "failed" => attempts = MaxAttempts
    /\ conn = "backoff" => attempts < MaxAttempts

\* A backoff ends only by its own timer.
NoEarlyRestart == ~restartedEarly

\* STDIO-06: a stop always ends with the connection stopped, and every exited
\* process is reaped.
Progress ==
    /\ stopping ~> conn = "stopped"
    /\ proc = "exited" ~> proc = "reaped"
====

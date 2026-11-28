---- MODULE SharedServers ----
\* fx sessions that share one stdio MCP server through one owner process per
\* profile (src/core/mcp_host/owner_core.zig routing, owner.zig the process).
\*
\* Each session in Sessions is one fx process (a terminal or an ACP session).
\* A session that needs the shared server finds no owner listening (Probe) and
\* starts one (StartOwner). The owner takes the lock itself as it starts
\* (OwnerTake): the one that finds it free takes it and serves; one that finds
\* it taken exits (OwnerBusy), so a session that starts an owner while the
\* previous one is still exiting, and still holds the lock, gets no second
\* owner. A session connects to the serving owner (Connect), which registers it
\* for the server.
\*
\* The serving owner runs the server once for every session, starts it for the
\* first call that waits (ServerStart), and stops it when it is idle (IdleArm,
\* IdleFire). Each call in Calls belongs to session CallSession(c). While a
\* call is in flight the server may ask a question for it (ServerAsks); the
\* owner shows it to a session (Route), which answers it (AnswerQ), or it is
\* declined or withdrawn. A 2026 question is tied to its call; a 2025 one names
\* no call: it shows only when one session alone has calls in flight. A session
\* may exit at any time (Exit), stop using the server while it stays connected
\* (Unregister), or use it again (Register), and the owner may crash, at most
\* MaxCrash times (Crash).
\*
\* With no client and its server stopped, the owner closes its listening
\* socket first (OwnerClose), which also deletes the socket file, and only then
\* releases the lock and exits (OwnerExit). So a waiter that finds the lock
\* taken never finds the socket already gone.
\*
\* OneOwner: never two owners serve.
\* QuestionToCaller: a question shows only in the session whose call it is.
\* IdleEndsNothing: an idle stop ends no session's call ("cut").
\* ExitEndsOwnOnly: a session's exit, or its dropping the server, ends only its
\*   own calls.
\* ServerFollowsSessions: with no session connected, the server stops.
\* ServerFollowsUsers: with no session using the server, it stops, even while
\*   one stays connected to the owner.
\* LostNotRetried: an ended call never goes out again.
\* EveryCallEnds: every call that waits or is in flight ends.
\*
\* One server stands for every key, so the model says nothing about how many
\* keys an owner can hold: `using` and `conn` are per session and a session
\* uses the server or does not. The code frees a key's slot when its last
\* session leaves (`owner_core.zig` `freeSlotIfEmpty`), so the key's next
\* registration is a fresh one; `Register` here already allows exactly that,
\* with no key remembered, so it is the same rule. The model leaves out the
\* bound (a fixed count of keys) rather than the rule.
EXTENDS Naturals, FiniteSets

CONSTANTS Sessions, Calls, CallSession(_), Versions, MaxCrash

ASSUME \A c \in Calls: CallSession(c) \in Sessions

None == "none"
CallStates == {"none", "waiting", "sent", "done"}
Ends == {"none", "answered", "lost", "failed", "cancelled", "cut"}
QStates == {"none", "asked", "shown", "declined", "answered"}

WaitStates == {"none", "waiting", "ready", "eof"}

VARIABLES
    version,  \* the shared server's protocol version, fixed
    owners,   \* owner processes alive, at most 2 while one exits
    lock,     \* the owner lock: None, or "owner" while an owner holds it
    serving,  \* owners listening on the socket: 0, 1, or 2 without the lock
    saw,      \* [Sessions -> BOOLEAN]: it looked and found no owner
    wait,     \* [Sessions -> {"none", "waiting", "ready", "eof"}]: pipe wait to spawned owner
    conn,     \* [Sessions -> BOOLEAN]: connected to the owner
    using,    \* [Sessions -> BOOLEAN]: holds the server, so it may call it
    alive,    \* [Sessions -> BOOLEAN]
    phase,    \* the shared server in the owner: "idle" or "ready"
    call,     \* [Calls -> CallStates]
    ended,    \* [Calls -> Ends]
    ended_by, \* [Calls -> Sessions \cup {None}]: the session that ended it
    armed,    \* the session whose quiet armed the idle timer, or None
    q,        \* the server's one question
    qFor,     \* the call the server asks it for, 0 for none
    qTo,      \* the session it shows in, or None
    crashes

vars == <<version, owners, lock, serving, saw, wait, conn, using, alive, phase, call, ended, ended_by, armed, q, qFor, qTo, crashes>>

InFlight(c) == call[c] \in {"waiting", "sent"}
SentCalls == {c \in Calls: call[c] = "sent"}
QuietFor(x) == \A c \in Calls: CallSession(c) = x => ~InFlight(c)
Quiet == \A x \in Sessions: QuietFor(x)
NoClients == \A x \in Sessions: ~conn[x]
NoUsers == \A x \in Sessions: ~using[x]

TypeOK ==
    /\ version \in Versions
    /\ owners \in 0..2
    /\ lock \in {None, "owner"}
    /\ serving \in 0..2
    /\ saw \in [Sessions -> BOOLEAN]
    /\ wait \in [Sessions -> WaitStates]
    /\ conn \in [Sessions -> BOOLEAN]
    /\ using \in [Sessions -> BOOLEAN]
    /\ alive \in [Sessions -> BOOLEAN]
    /\ phase \in {"idle", "ready"}
    /\ call \in [Calls -> CallStates]
    /\ ended \in [Calls -> Ends]
    /\ ended_by \in [Calls -> Sessions \cup {None}]
    /\ armed \in Sessions \cup {None}
    /\ q \in QStates
    /\ qFor \in Calls \cup {0}
    /\ qTo \in Sessions \cup {None}
    /\ crashes \in 0..MaxCrash

Init ==
    /\ version \in Versions
    /\ owners = 0
    /\ lock = None
    /\ serving = 0
    /\ saw = [x \in Sessions |-> FALSE]
    /\ wait = [x \in Sessions |-> "none"]
    /\ conn = [x \in Sessions |-> FALSE]
    /\ using = [x \in Sessions |-> FALSE]
    /\ alive = [x \in Sessions |-> TRUE]
    /\ phase = "idle"
    /\ call = [c \in Calls |-> "none"]
    /\ ended = [c \in Calls |-> "none"]
    /\ ended_by = [c \in Calls |-> None]
    /\ armed = None
    /\ q = "none"
    /\ qFor = 0
    /\ qTo = None
    /\ crashes = 0

\* ---- Finding and starting the owner ----

Probe(x) ==
    /\ alive[x] /\ ~conn[x] /\ ~saw[x] /\ wait[x] = "none" /\ serving = 0
    /\ saw' = [saw EXCEPT ![x] = TRUE]
    /\ UNCHANGED <<version, owners, lock, serving, wait, conn, using, alive, phase, call, ended, ended_by, armed, q, qFor, qTo, crashes>>

\* It found none a moment ago, so it starts one with a ready pipe. Two
\* processes may overlap while the first is still exiting.
StartOwner(x) ==
    /\ alive[x] /\ saw[x] /\ wait[x] = "none"
    /\ owners < 2
    /\ owners' = owners + 1
    /\ saw' = [saw EXCEPT ![x] = FALSE]
    /\ wait' = [wait EXCEPT ![x] = "waiting"]
    /\ UNCHANGED <<version, lock, serving, conn, using, alive, phase, call, ended, ended_by, armed, q, qFor, qTo, crashes>>

\* The owner takes the lock itself as its first step. The one that finds it
\* free takes it, listens, and signals ready on its pipe; the lock is free
\* only when nobody serves.
OwnerTake ==
    /\ owners >= 1 /\ lock = None
    /\ lock' = "owner"
    /\ serving' = serving + 1
    /\ IF \E x \in Sessions: wait[x] = "waiting"
       THEN \E x \in Sessions: wait[x] = "waiting" /\ wait' = [wait EXCEPT ![x] = "ready"]
       ELSE UNCHANGED wait
    /\ UNCHANGED <<version, owners, saw, conn, using, alive, phase, call, ended, ended_by, armed, q, qFor, qTo, crashes>>

\* A second process, started while the first still held the lock, exits, giving
\* EOF on its pipe.
OwnerBusy ==
    /\ owners = 2 /\ lock # None
    /\ owners' = owners - 1
    /\ IF \E x \in Sessions: wait[x] = "waiting"
       THEN \E x \in Sessions: wait[x] = "waiting" /\ wait' = [wait EXCEPT ![x] = "eof"]
       ELSE UNCHANGED wait
    /\ UNCHANGED <<version, lock, serving, saw, conn, using, alive, phase, call, ended, ended_by, armed, q, qFor, qTo, crashes>>

\* A session whose spawned owner exited sees EOF on its pipe and stops waiting.
WaitEof(x) ==
    /\ alive[x] /\ wait[x] = "eof"
    /\ wait' = [wait EXCEPT ![x] = "none"]
    /\ UNCHANGED <<version, owners, lock, serving, saw, conn, using, alive, phase, call, ended, ended_by, armed, q, qFor, qTo, crashes>>

\* It registers the server as it connects: registration is lazy in fx, but no
\* call can go out before it, so the two steps collapse.
Connect(x) ==
    /\ alive[x] /\ ~conn[x] /\ serving >= 1
    /\ conn' = [conn EXCEPT ![x] = TRUE]
    /\ using' = [using EXCEPT ![x] = TRUE]
    /\ saw' = [saw EXCEPT ![x] = FALSE]
    /\ wait' = [wait EXCEPT ![x] = "none"]
    /\ UNCHANGED <<version, owners, lock, serving, alive, phase, call, ended, ended_by, armed, q, qFor, qTo, crashes>>

\* It takes the server up again after dropping it, as re-adding a removed or
\* changed config does. The owner starts the server at the first call that
\* waits.
Register(x) ==
    /\ alive[x] /\ conn[x] /\ ~using[x] /\ serving >= 1
    /\ using' = [using EXCEPT ![x] = TRUE]
    /\ UNCHANGED <<version, owners, lock, serving, saw, wait, conn, alive, phase, call, ended, ended_by, armed, q, qFor, qTo, crashes>>

\* ---- Calls ----

\* The session's own permission check came first; the owner takes the call.
Ask(c) ==
    LET x == CallSession(c) IN
    /\ alive[x] /\ conn[x] /\ using[x] /\ serving >= 1 /\ call[c] = "none"
    /\ call' = [call EXCEPT ![c] = IF phase = "ready" THEN "sent" ELSE "waiting"]
    /\ UNCHANGED <<version, owners, lock, serving, saw, wait, conn, using, alive, phase, ended, ended_by, armed, q, qFor, qTo, crashes>>

\* The first waiting call starts the server; once ready, every waiting call goes out.
ServerStart ==
    /\ serving >= 1 /\ phase = "idle" /\ \E c \in Calls: call[c] = "waiting"
    /\ phase' = "ready"
    /\ call' = [c \in Calls |-> IF call[c] = "waiting" THEN "sent" ELSE call[c]]
    /\ UNCHANGED <<version, owners, lock, serving, saw, wait, conn, using, alive, ended, ended_by, armed, q, qFor, qTo, crashes>>

\* A call waiting on its question answers only once the question is over.
Answer(c) ==
    /\ call[c] = "sent"
    /\ ~(qFor = c /\ q \in {"asked", "shown"})
    /\ call' = [call EXCEPT ![c] = "done"]
    /\ ended' = [ended EXCEPT ![c] = "answered"]
    /\ UNCHANGED <<version, owners, lock, serving, saw, wait, conn, using, alive, phase, ended_by, armed, q, qFor, qTo, crashes>>

\* ---- Questions ----

ServerAsks(c) ==
    /\ q = "none" /\ call[c] = "sent"
    /\ q' = "asked"
    /\ qFor' = c
    /\ UNCHANGED <<version, owners, lock, serving, saw, wait, conn, using, alive, phase, call, ended, ended_by, armed, qTo, crashes>>

\* A 2026 question names its call, so it shows in that call's session. A
\* 2025 one names none: the owner shows it only when one session alone has
\* calls in flight on the server, and declines it otherwise, as fx answers a
\* question no call can take today.
Route ==
    /\ q = "asked" /\ call[qFor] = "sent"
    /\ LET callers == {CallSession(d): d \in SentCalls} IN
       IF version = "2026"
       THEN /\ q' = "shown"
            /\ qTo' = CallSession(qFor)
       ELSE IF Cardinality(callers) = 1
       THEN /\ q' = "shown"
            /\ qTo' = CHOOSE x \in callers: TRUE
       ELSE /\ q' = "declined"
            /\ qTo' = None
    /\ UNCHANGED <<version, owners, lock, serving, saw, wait, conn, using, alive, phase, call, ended, ended_by, armed, qFor, crashes>>

AnswerQ ==
    /\ q = "shown" /\ alive[qTo]
    /\ q' = "answered"
    /\ UNCHANGED <<version, owners, lock, serving, saw, wait, conn, using, alive, phase, call, ended, ended_by, armed, qFor, qTo, crashes>>

\* The call it was for ended, or the session it showed in left or dropped the
\* server.
Withdraw ==
    /\ q \in {"asked", "shown"}
    /\ call[qFor] = "done" \/ (q = "shown" /\ (~alive[qTo] \/ ~using[qTo]))
    /\ q' = "declined"
    /\ qTo' = None
    /\ UNCHANGED <<version, owners, lock, serving, saw, wait, conn, using, alive, phase, call, ended, ended_by, armed, qFor, crashes>>

\* ---- The idle timer, in the owner ----

\* A session's last call ended. The owner counts every session's calls on
\* the server, as one engine slot holds them all: only when none is in
\* flight does the timer arm.
IdleArm(x) ==
    /\ serving >= 1 /\ phase = "ready" /\ armed = None /\ conn[x] /\ Quiet
    /\ armed' = x
    /\ UNCHANGED <<version, owners, lock, serving, saw, wait, conn, using, alive, phase, call, ended, ended_by, q, qFor, qTo, crashes>>

\* It fires; the server stops only if no session's call is in flight now.
\* Were it to stop, the calls in flight would go with the process.
IdleFire ==
    /\ armed # None
    /\ armed' = None
    /\ IF phase = "ready" /\ Quiet
       THEN /\ phase' = "idle"
            /\ call' = [c \in Calls |-> IF call[c] = "sent" THEN "done" ELSE call[c]]
            /\ ended' = [c \in Calls |-> IF call[c] = "sent" THEN "cut" ELSE ended[c]]
       ELSE UNCHANGED <<phase, call, ended>>
    /\ UNCHANGED <<version, owners, lock, serving, saw, wait, conn, using, alive, ended_by, q, qFor, qTo, crashes>>

\* No session uses the server: the owner stops it now, with the normal stop,
\* so no server outlives its last user. The idle timer is for a server a
\* session still holds but does not use.
StopWithoutUsers ==
    /\ serving >= 1 /\ phase = "ready" /\ NoUsers
    /\ phase' = "idle"
    /\ UNCHANGED <<version, owners, lock, serving, saw, wait, conn, using, alive, call, ended, ended_by, armed, q, qFor, qTo, crashes>>

\* ---- Leaving and failing ----

\* The session drops the server, as a config change that removes or changes
\* its entry does. Its calls there end as cancelled, its question there is
\* withdrawn, and the server stops when no other session uses it. Its
\* connection stays: the owner is still the one for the next server.
Unregister(x) ==
    /\ alive[x] /\ conn[x] /\ using[x]
    /\ LET last == \A y \in Sessions \ {x}: ~using[y] IN
       /\ using' = [using EXCEPT ![x] = FALSE]
       /\ call' = [c \in Calls |-> IF CallSession(c) = x /\ InFlight(c) THEN "done" ELSE call[c]]
       /\ ended' = [c \in Calls |-> IF CallSession(c) = x /\ InFlight(c) THEN "cancelled" ELSE ended[c]]
       /\ ended_by' = [c \in Calls |-> IF CallSession(c) = x /\ InFlight(c) THEN x ELSE ended_by[c]]
       /\ phase' = IF last THEN "idle" ELSE phase
       /\ armed' = IF last THEN None ELSE armed
    /\ UNCHANGED <<version, owners, lock, serving, saw, wait, conn, alive, q, qFor, qTo, crashes>>

\* The owner ends the session's own calls: they were cancelled. A session
\* whose leaving leaves nobody using the server also stops it, in the same
\* step, so no server outlives its last user.
Exit(x) ==
    /\ alive[x]
    /\ LET last == \A y \in Sessions \ {x}: ~using[y] IN
       /\ alive' = [alive EXCEPT ![x] = FALSE]
       /\ conn' = [conn EXCEPT ![x] = FALSE]
       /\ using' = [using EXCEPT ![x] = FALSE]
       /\ saw' = [saw EXCEPT ![x] = FALSE]
       /\ wait' = [wait EXCEPT ![x] = "none"]
       /\ call' = [c \in Calls |-> IF CallSession(c) = x /\ InFlight(c) THEN "done" ELSE call[c]]
       /\ ended' = [c \in Calls |-> IF CallSession(c) = x /\ InFlight(c) THEN "cancelled" ELSE ended[c]]
       /\ ended_by' = [c \in Calls |-> IF CallSession(c) = x /\ InFlight(c) THEN x ELSE ended_by[c]]
       /\ phase' = IF last THEN "idle" ELSE phase
       /\ armed' = IF last THEN None ELSE armed
    /\ UNCHANGED <<version, owners, lock, serving, q, qFor, qTo, crashes>>

\* The owner dies. The exit reaper stops the server; calls in flight may
\* have run and end lost, waiting ones never went out and end failed; none
\* is sent again. The lock goes with the process.
Crash ==
    /\ owners >= 1 /\ crashes < MaxCrash
    /\ crashes' = crashes + 1
    /\ owners' = owners - 1
    /\ IF lock = "owner"
       THEN /\ serving' = 0
            /\ lock' = None
            /\ wait' = [x \in Sessions |-> IF wait[x] = "ready" THEN "eof" ELSE wait[x]]
       ELSE /\ UNCHANGED <<serving, lock>>
            /\ IF \E x \in Sessions: wait[x] = "waiting"
               THEN \E x \in Sessions: wait[x] = "waiting" /\ wait' = [wait EXCEPT ![x] = "eof"]
               ELSE UNCHANGED wait
    /\ conn' = [x \in Sessions |-> FALSE]
    /\ using' = [x \in Sessions |-> FALSE]
    /\ phase' = "idle"
    /\ call' = [c \in Calls |-> IF InFlight(c) THEN "done" ELSE call[c]]
    /\ ended' = [c \in Calls |-> IF call[c] = "sent" THEN "lost"
                                 ELSE IF call[c] = "waiting" THEN "failed" ELSE ended[c]]
    /\ armed' = None
    /\ UNCHANGED <<version, saw, alive, ended_by, q, qFor, qTo>>

\* No client and its server stopped: the owner closes its listening socket,
\* and with it the socket file, but still holds the lock.
OwnerClose ==
    /\ serving >= 1 /\ phase = "idle" /\ NoClients
    /\ serving' = serving - 1
    /\ wait' = [x \in Sessions |-> IF wait[x] = "ready" THEN "eof" ELSE wait[x]]
    /\ armed' = None
    /\ UNCHANGED <<version, owners, lock, saw, conn, using, alive, phase, call, ended, ended_by, q, qFor, qTo, crashes>>

\* Only now does it release the lock and exit.
OwnerExit ==
    /\ owners = 1 /\ serving = 0
    /\ owners' = 0
    /\ lock' = None
    /\ wait' = [x \in Sessions |-> IF wait[x] = "waiting" THEN "eof" ELSE wait[x]]
    /\ UNCHANGED <<version, serving, saw, conn, using, alive, phase, call, ended, ended_by, armed, q, qFor, qTo, crashes>>

Next ==
    \/ \E x \in Sessions: Probe(x) \/ StartOwner(x) \/ WaitEof(x) \/ Connect(x) \/ Register(x) \/ Unregister(x) \/ IdleArm(x) \/ Exit(x)
    \/ \E c \in Calls: Ask(c) \/ Answer(c) \/ ServerAsks(c)
    \/ OwnerTake \/ OwnerBusy \/ ServerStart \/ Route \/ AnswerQ \/ Withdraw \/ IdleFire \/ StopWithoutUsers \/ Crash \/ OwnerClose \/ OwnerExit

Fairness ==
    /\ \A x \in Sessions: WF_vars(StartOwner(x)) /\ WF_vars(WaitEof(x)) /\ WF_vars(Connect(x))
    /\ WF_vars(OwnerTake) /\ WF_vars(OwnerBusy) /\ WF_vars(OwnerExit)
    /\ WF_vars(ServerStart) /\ WF_vars(Route) /\ WF_vars(AnswerQ) /\ WF_vars(Withdraw)
    /\ WF_vars(StopWithoutUsers)
    /\ \A c \in Calls: WF_vars(Answer(c))

Spec == Init /\ [][Next]_vars /\ Fairness

\* Calls 1 and 3 belong to session "a", call 2 to "b".
TwoSessions(c) == IF c = 2 THEN "b" ELSE "a"

\* ---- Invariants ----

OneOwner == serving <= 1

QuestionToCaller == q = "shown" => qTo = CallSession(qFor)

IdleEndsNothing == \A c \in Calls: ended[c] # "cut"

\* Two things end a call cancelled: its session exits, or its session drops
\* the server. Both end only the calls of the session that does it.
ExitEndsOwnOnly == \A c \in Calls: ended[c] = "cancelled" => ended_by[c] = CallSession(c)

ReadyMeansServing == \A x \in Sessions: wait[x] = "ready" => serving >= 1

\* ---- Properties ----

WaitEnds == \A x \in Sessions: wait[x] \in {"waiting", "ready", "eof"} ~> wait[x] = "none"

LostNotRetried == [][\A c \in Calls: call[c] = "done" => call'[c] = "done"]_vars

EveryCallEnds == \A c \in Calls: InFlight(c) ~> call[c] = "done"

\* A server never outlives its last session: with no session connected, its
\* process stops (or no owner serves at all).
ServerFollowsSessions == (\A x \in Sessions: ~conn[x]) ~> (phase = "idle" \/ serving = 0)

\* Nor its last user: a session that dropped the server and stays connected
\* does not keep it running.
ServerFollowsUsers == (\A x \in Sessions: ~using[x]) ~> (phase = "idle" \/ serving = 0)
====

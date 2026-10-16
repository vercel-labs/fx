---- MODULE Engine ----
\* U12 engine: several servers, each connected only when something needs it,
\* the host's permission before every tool call, and calls that wait for
\* their server. Rules: SEC-01, STDIO-08.
\*
\* Each s in Servers is one configured server. Its phase is what the engine
\* knows of its link: idle (not started, or stopped), connecting (a process
\* start or detection running), ready, backoff (after a failure, until it may
\* start again; on stdio the process core's backoff), or failed (it gave
\* up after MaxAttempts tries in a row, until the host reconnects). A server
\* first starts only when the host needs its tool list or a call waits for it
\* (LazyConnect). After a failure it starts again by itself once its backoff
\* is over, and its tries in a row start over only once it has stayed
\* up (Stable: a minute, in the code), so one that dies soon after every start
\* still gives up. Each c in Calls is one tool call the host may make, once, to
\* server Owner(c). The host's permission comes first: a call it refuses
\* never reaches a server (PermissionBeforeCall). A call to a ready server
\* goes out at once; one to any other server waits, goes out the moment its
\* server is ready, and ends when the server gives up. A call in flight ends
\* with its server's answer, or as lost when its process dies. The host may
\* reconnect or disconnect a server at most MaxHost times in all. The ghosts
\* record what the invariants need: whether the host allowed a call, whether
\* something needed the server (or its own failure) when it started, whether
\* it stayed up since it last started, whether the host dropped it since it
\* last went down, and whether the host waits for an answer to its tool list
\* need. Whatever clears a need answers it: a listing, a refusal once the
\* server gave up, or a disconnect, which refuses it too.
EXTENDS Naturals, FiniteSets

CONSTANTS Servers, Calls, Owner(_), MaxAttempts, MaxHost

ASSUME MaxAttempts \in Nat \ {0} /\ MaxHost \in Nat /\ \A c \in Calls: Owner(c) \in Servers

Phases == {"idle", "connecting", "ready", "backoff", "failed"}
CallStates == {"none", "waiting", "sent", "done"}
\* How a call ended: refused by the host, its server gave up, the host
\* cancelled it or dropped its server, the server answered, or its process died.
Ends == {"none", "denied", "failed", "cancelled", "answered", "lost"}

VARIABLES phase, attempts, need, call, ended, allowed, cause, host,
    retry,   \* [Servers -> BOOLEAN]: down by a failure, it starts again by itself
    stayed,  \* ghost: [Servers -> BOOLEAN], it stayed up since it last started
    dropped, \* ghost: [Servers -> BOOLEAN], the host dropped it since it last went down
    asked    \* ghost: [Servers -> BOOLEAN], the host waits for an answer to its tool list need

vars == <<phase, attempts, need, call, ended, allowed, cause, host, retry, stayed, dropped, asked>>

Waiting(s) == {c \in Calls: Owner(c) = s /\ call[c] = "waiting"}
Sent(s) == {c \in Calls: Owner(c) = s /\ call[c] = "sent"}
Demand(s) == need[s] \/ Waiting(s) # {}

TypeOK ==
    /\ phase \in [Servers -> Phases]
    /\ attempts \in [Servers -> 0..MaxAttempts]
    /\ need \in [Servers -> BOOLEAN]
    /\ call \in [Calls -> CallStates]
    /\ ended \in [Calls -> Ends]
    /\ allowed \in [Calls -> BOOLEAN]
    /\ cause \in [Servers -> BOOLEAN]
    /\ host \in 0..MaxHost
    /\ retry \in [Servers -> BOOLEAN]
    /\ stayed \in [Servers -> BOOLEAN]
    /\ dropped \in [Servers -> BOOLEAN]
    /\ asked \in [Servers -> BOOLEAN]

Init ==
    /\ phase = [s \in Servers |-> "idle"]
    /\ attempts = [s \in Servers |-> 0]
    /\ need = [s \in Servers |-> FALSE]
    /\ call = [c \in Calls |-> "none"]
    /\ ended = [c \in Calls |-> "none"]
    /\ allowed = [c \in Calls |-> FALSE]
    /\ cause = [s \in Servers |-> FALSE]
    /\ host = 0
    /\ retry = [s \in Servers |-> FALSE]
    /\ stayed = [s \in Servers |-> FALSE]
    /\ dropped = [s \in Servers |-> FALSE]
    /\ asked = [s \in Servers |-> FALSE]

\* ---- The host ----

\* The host calls c and its permission answers `ok` (SEC-01). Refused, the
\* call ends there; allowed, it goes out to a ready server, ends at once on a
\* failed one, and otherwise waits.
Ask(c, ok) ==
    /\ call[c] = "none"
    /\ allowed' = [allowed EXCEPT ![c] = ok]
    /\ LET s == Owner(c) IN
       /\ call' = [call EXCEPT ![c] =
              IF ~ok \/ phase[s] = "failed" THEN "done"
              ELSE IF phase[s] = "ready" THEN "sent" ELSE "waiting"]
       /\ ended' = [ended EXCEPT ![c] =
              IF ~ok THEN "denied" ELSE IF phase[s] = "failed" THEN "failed" ELSE "none"]
    /\ UNCHANGED <<phase, attempts, need, cause, host, retry, stayed, dropped, asked>>

\* The host needs the tool list. A ready server lists at once (the catalog
\* answers every need, U05); a failed one says so at once.
Need(s) ==
    /\ ~need[s]
    /\ phase[s] \notin {"ready", "failed"}
    /\ need' = [need EXCEPT ![s] = TRUE]
    /\ asked' = [asked EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<phase, attempts, call, ended, allowed, cause, host, retry, stayed, dropped>>

\* A waiting call is cancelled before it went out. One in flight is the
\* server's to end (U02).
Cancel(c) ==
    /\ call[c] = "waiting"
    /\ call' = [call EXCEPT ![c] = "done"]
    /\ ended' = [ended EXCEPT ![c] = "cancelled"]
    /\ UNCHANGED <<phase, attempts, need, allowed, cause, host, retry, stayed, dropped, asked>>

\* The host drops a server's link and its tries in a row. Reconnect keeps what
\* waits for it, which starts it again; disconnect ends that too. Either way
\* the calls in flight end with the link, and it no longer starts again by
\* itself.
Drop(s, keep) ==
    /\ host < MaxHost
    /\ host' = host + 1
    /\ phase' = [phase EXCEPT ![s] = "idle"]
    /\ attempts' = [attempts EXCEPT ![s] = 0]
    /\ need' = [need EXCEPT ![s] = need[s] /\ keep]
    /\ call' = [c \in Calls |-> IF c \in Sent(s) \/ (~keep /\ c \in Waiting(s)) THEN "done" ELSE call[c]]
    /\ ended' = [c \in Calls |-> IF c \in Sent(s) \/ (~keep /\ c \in Waiting(s)) THEN "cancelled" ELSE ended[c]]
    /\ retry' = [retry EXCEPT ![s] = FALSE]
    /\ dropped' = [dropped EXCEPT ![s] = TRUE]
    \* Disconnect refuses a waiting tool list need.
    /\ asked' = [asked EXCEPT ![s] = asked[s] /\ keep]
    /\ UNCHANGED <<allowed, cause, stayed>>

\* ---- The link ----

\* LazyConnect: an idle server starts only when something needs it, or by
\* itself after its own failure.
Connect(s) ==
    /\ phase[s] = "idle"
    /\ Demand(s) \/ retry[s]
    /\ attempts[s] < MaxAttempts
    /\ phase' = [phase EXCEPT ![s] = "connecting"]
    /\ attempts' = [attempts EXCEPT ![s] = @ + 1]
    /\ cause' = [cause EXCEPT ![s] = Demand(s) \/ retry[s]]
    /\ stayed' = [stayed EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<need, call, ended, allowed, host, retry, dropped, asked>>

\* Ready: the tool list need goes to the server, and every waiting call goes
\* out. Its tries in a row start over only once it stays up (Stable).
Up(s) ==
    /\ phase[s] = "connecting"
    /\ phase' = [phase EXCEPT ![s] = "ready"]
    /\ need' = [need EXCEPT ![s] = FALSE]
    /\ call' = [c \in Calls |-> IF c \in Waiting(s) THEN "sent" ELSE call[c]]
    /\ retry' = [retry EXCEPT ![s] = FALSE]
    /\ asked' = [asked EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<attempts, ended, allowed, cause, host, stayed, dropped>>

\* It stayed up: its tries in a row start over.
Stable(s) ==
    /\ phase[s] = "ready" /\ attempts[s] > 0
    /\ attempts' = [attempts EXCEPT ![s] = 0]
    /\ stayed' = [stayed EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<phase, need, call, ended, allowed, cause, host, retry, dropped, asked>>

\* The start or the link failed. The calls in flight are lost. After
\* MaxAttempts tries in a row the server gives up, and what waits for it ends.
Down(s) ==
    /\ phase[s] \in {"connecting", "ready"}
    /\ LET gaveUp == attempts[s] >= MaxAttempts IN
       /\ phase' = [phase EXCEPT ![s] = IF gaveUp THEN "failed" ELSE "backoff"]
       /\ need' = [need EXCEPT ![s] = need[s] /\ ~gaveUp]
       /\ call' = [c \in Calls |-> IF c \in Sent(s) \/ (gaveUp /\ c \in Waiting(s)) THEN "done" ELSE call[c]]
       /\ ended' = [c \in Calls |-> IF c \in Sent(s) THEN "lost"
                                    ELSE IF gaveUp /\ c \in Waiting(s) THEN "failed" ELSE ended[c]]
       /\ retry' = [retry EXCEPT ![s] = ~gaveUp]
       /\ asked' = [asked EXCEPT ![s] = asked[s] /\ ~gaveUp]
    /\ dropped' = [dropped EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<attempts, allowed, cause, host, stayed>>

BackoffOver(s) ==
    /\ phase[s] = "backoff"
    /\ phase' = [phase EXCEPT ![s] = "idle"]
    /\ UNCHANGED <<attempts, need, call, ended, allowed, cause, host, retry, stayed, dropped, asked>>

\* The server answers a call in flight.
Answer(c) ==
    /\ call[c] = "sent"
    /\ call' = [call EXCEPT ![c] = "done"]
    /\ ended' = [ended EXCEPT ![c] = "answered"]
    /\ UNCHANGED <<phase, attempts, need, allowed, cause, host, retry, stayed, dropped, asked>>

Next ==
    \/ \E c \in Calls, ok \in BOOLEAN: Ask(c, ok)
    \/ \E c \in Calls: Cancel(c) \/ Answer(c)
    \/ \E s \in Servers: Need(s) \/ Connect(s) \/ Up(s) \/ Down(s) \/ BackoffOver(s) \/ Stable(s)
    \/ \E s \in Servers, keep \in BOOLEAN: Drop(s, keep)

Fairness ==
    /\ \A s \in Servers: WF_vars(Connect(s)) /\ WF_vars(Up(s) \/ Down(s)) /\ WF_vars(BackoffOver(s))
    /\ \A c \in Calls: WF_vars(Answer(c))

Spec == Init /\ [][Next]_vars /\ Fairness

\* Owners for the configs: calls 1 and 2 to server 1, call 3 (and 4) to server 2.
SmokeOwner(c) == IF c <= 2 THEN 1 ELSE 2

\* ---- Invariants ----

\* SEC-01: nothing reaches a server without the host's permission.
PermissionBeforeCall ==
    \A c \in Calls: (call[c] \in {"waiting", "sent"} \/ ended[c] \in {"answered", "lost"}) => allowed[c]

\* A refused call never waits or goes out.
DeniedEndsThere == \A c \in Calls: ended[c] = "denied" => call[c] = "done" /\ ~allowed[c]

\* Nothing starts a server but a need, or its own failure.
LazyConnect == \A s \in Servers: phase[s] = "connecting" => cause[s]

\* A server starts again by itself only after its own failure, never
\* after the host dropped it, and never once it gave up.
RetryOnlyAfterFailure ==
    \A s \in Servers: retry[s] => ~dropped[s] /\ phase[s] \in {"backoff", "idle", "connecting"}

\* A ready server's tries have started over only if it stayed up, so
\* one that dies soon after every start gives up instead of looping.
StayedBeforeFreshTries == \A s \in Servers: phase[s] = "ready" /\ attempts[s] = 0 => stayed[s]

\* At most MaxAttempts tries in a row, and a failed server has used them all.
BoundedReconnect ==
    \A s \in Servers: phase[s] = "failed" => attempts[s] = MaxAttempts

\* What the host is told matches what is going on: calls are in flight only
\* on a ready server, and a failed server holds no need and no waiting call.
StatusConsistent ==
    /\ \A c \in Calls: call[c] = "sent" => phase[Owner(c)] = "ready"
    /\ \A s \in Servers: phase[s] = "failed" => ~need[s] /\ Waiting(s) = {}
    /\ \A s \in Servers: phase[s] = "ready" => ~need[s] /\ Waiting(s) = {}

\* The host waits for a tool list only while the engine holds its need,
\* so clearing a need always answers it.
AskedHasNeed == \A s \in Servers: asked[s] => need[s]

\* ---- Properties ----

\* One server's step changes no other server and no other server's calls.
Isolation ==
    [][\A s \in Servers:
        (phase'[s] # phase[s]) =>
            /\ \A t \in Servers \ {s}: phase'[t] = phase[t]
            /\ \A c \in Calls: Owner(c) # s => call'[c] = call[c]]_vars

\* Every allowed call ends, and every need is served or refused.
EveryCallEnds == \A c \in Calls: call[c] \in {"waiting", "sent"} ~> call[c] = "done"
NeedServed == \A s \in Servers: need[s] ~> ~need[s]

\* A server down by a failure comes back or gives up, with nothing
\* needing it.
RetriesEnd == \A s \in Servers: retry[s] ~> ~retry[s]
====

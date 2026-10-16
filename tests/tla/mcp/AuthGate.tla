---- MODULE AuthGate ----
\* U09 the credential gate, client side: the requests to one MCP server and
\* the token they carry. Rules: AUTH-19, AUTH-22, AUTH-25 (rules.md).
\* Signing in is AuthFlow.tla.
\*
\*   - A token is named by its generation: each sign-in or refresh brings the
\*     next one. Every request carries the token held, if any (AUTH-19).
\*   - The server accepts some generations. A request with an expired token,
\*     or none, is rejected with 401 before the server reads it, so the client
\*     sends it again, once, with a newer token: at once if one arrived since
\*     it went out, else after a refresh. Without a refresh token, or when the
\*     second send is rejected too, it ends needing sign-in.
\*   - One refresh at a time. A request that would go out during a
\*     refresh, or with a token close to expiry, waits for it.
\*   - The refresh token may rotate, and the client always presents the latest
\*     (AUTH-25). A refusal, any answer naming an error at 200 or a 4xx other
\*     than 429, drops both tokens: the authorization server won't take that
\*     refresh token again (AUTH-27). A 429, a 5xx or no answer keeps
\*     them and fails the requests waiting.
\*   - Signing in brings a new token; signing out cancels the refresh in flight.
EXTENDS Naturals

CONSTANTS
    Keys,     \* requests
    MaxGen    \* tokens per run

ASSUME MaxGen \in Nat \ {0}

Phases == {"idle", "sent", "waiting", "done", "needs_sign_in", "failed", "cancelled"}

VARIABLES
    gen,          \* generation of the newest token, 0 before the first
    held,         \* a token is held
    refreshable,  \* a refresh token is held
    rt,           \* the refresh token held, by the generation that brought it
    inflight,     \* refreshes in flight
    req,          \* [Keys -> [phase, g: the token it carries, again: a second send]]
    \* Server.
    valid,        \* generations the server accepts; 0 when it needs no token
    serverRt,     \* the refresh token the authorization server accepts
    deadRt,       \* refresh tokens it refused for good
    \* Ghosts.
    usedRt,       \* the refresh token the refresh in flight presented
    sends,        \* [Keys -> times sent]
    rejectedG     \* [Keys -> the token its rejected send carried]

vars == <<gen, held, refreshable, rt, inflight, req, valid, serverRt, deadRt, usedRt, sends, rejectedG>>

Init ==
    /\ gen = 0
    /\ held = FALSE
    /\ refreshable = FALSE
    /\ rt = 0
    /\ inflight = 0
    /\ req = [k \in Keys |-> [phase |-> "idle", g |-> 0, again |-> FALSE]]
    /\ valid \in {{}, {0}}
    /\ serverRt = 0
    /\ deadRt = {}
    /\ usedRt = 0
    /\ sends = [k \in Keys |-> 0]
    /\ rejectedG = [k \in Keys |-> 0]

Token == IF held THEN gen ELSE 0

\* ---- Client ----

\* A request goes out with the token held. During a refresh, or with a token
\* close to expiry and a refresh token, it waits for the refresh.
Send(k, expiring) ==
    /\ req[k].phase = "idle"
    /\ IF inflight > 0 \/ (expiring /\ held /\ refreshable)
       THEN /\ req' = [req EXCEPT ![k].phase = "waiting"]
            /\ IF inflight = 0
               THEN inflight' = 1 /\ usedRt' = rt
               ELSE UNCHANGED <<inflight, usedRt>>
            /\ UNCHANGED sends
       ELSE /\ req' = [req EXCEPT ![k].phase = "sent", ![k].g = Token]
            /\ sends' = [sends EXCEPT ![k] = @ + 1]
            /\ UNCHANGED <<inflight, usedRt>>
    /\ UNCHANGED <<gen, held, refreshable, rt, valid, serverRt, deadRt, rejectedG>>

\* The server accepts the request.
Accept(k) ==
    /\ req[k].phase = "sent"
    /\ req[k].g \in valid
    /\ req' = [req EXCEPT ![k].phase = "done"]
    /\ UNCHANGED <<gen, held, refreshable, rt, inflight, valid, serverRt, deadRt, usedRt, sends, rejectedG>>

\* The server rejects it with 401.
Reject(k) ==
    /\ req[k].phase = "sent"
    /\ req[k].g \notin valid
    /\ rejectedG' = [rejectedG EXCEPT ![k] = req[k].g]
    /\ IF req[k].again
       THEN /\ req' = [req EXCEPT ![k].phase = "needs_sign_in"]
            /\ UNCHANGED <<inflight, usedRt, sends>>
       ELSE IF Token > req[k].g
       THEN \* A newer token arrived since it went out.
            /\ req' = [req EXCEPT ![k].g = Token, ![k].again = TRUE]
            /\ sends' = [sends EXCEPT ![k] = @ + 1]
            /\ UNCHANGED <<inflight, usedRt>>
       ELSE IF inflight > 0
       THEN /\ req' = [req EXCEPT ![k].phase = "waiting", ![k].again = TRUE]
            /\ UNCHANGED <<inflight, usedRt, sends>>
       ELSE IF held /\ refreshable
       THEN /\ req' = [req EXCEPT ![k].phase = "waiting", ![k].again = TRUE]
            /\ inflight' = 1
            /\ usedRt' = rt
            /\ UNCHANGED sends
       ELSE /\ req' = [req EXCEPT ![k].phase = "needs_sign_in"]
            /\ UNCHANGED <<inflight, usedRt, sends>>
    /\ UNCHANGED <<gen, held, refreshable, rt, valid, serverRt, deadRt>>

\* Waiting requests go out once the refresh ends with a token, or end.
Release(next) ==
    [k \in Keys |-> IF req[k].phase = "waiting" THEN [req[k] EXCEPT !.phase = next, !.g = gen + 1] ELSE req[k]]

Released(next) ==
    [k \in Keys |-> IF req[k].phase = "waiting" THEN sends[k] + 1 ELSE sends[k]]

\* The client gives up on a request: its timeout, or the host cancels it.
Forget(k) ==
    /\ req[k].phase \in {"sent", "waiting"}
    /\ req' = [req EXCEPT ![k].phase = "cancelled"]
    /\ UNCHANGED <<gen, held, refreshable, rt, inflight, valid, serverRt, deadRt, usedRt, sends, rejectedG>>

\* ---- Authorization server ----

\* A new token, and maybe a new refresh token (rotation, AUTH-25).
RefreshOk(rotate) ==
    /\ inflight > 0
    /\ gen < MaxGen
    /\ gen' = gen + 1
    /\ held' = TRUE
    /\ valid' = valid \cup {gen + 1}
    /\ serverRt' = IF rotate THEN gen + 1 ELSE serverRt
    /\ rt' = IF rotate THEN gen + 1 ELSE rt
    /\ inflight' = 0
    /\ req' = Release("sent")
    /\ sends' = Released("sent")
    /\ UNCHANGED <<refreshable, deadRt, usedRt, rejectedG>>

\* The answer names an error, at 200 or a 4xx other than 429 (RFC 6749 §5.2, or
\* Slack's ok:false): the refresh token is dead for good, and both tokens are
\* dropped (AUTH-27).
RefreshRefused ==
    /\ inflight > 0
    /\ deadRt' = deadRt \cup {usedRt}
    /\ held' = FALSE
    /\ refreshable' = FALSE
    /\ inflight' = 0
    /\ req' = [k \in Keys |-> IF req[k].phase = "waiting" THEN [req[k] EXCEPT !.phase = "needs_sign_in"] ELSE req[k]]
    /\ UNCHANGED <<gen, rt, valid, serverRt, usedRt, sends, rejectedG>>

\* A 429, a 5xx, or no answer: the refresh token may work later, so the
\* tokens are kept.
RefreshFailed ==
    /\ inflight > 0
    /\ inflight' = 0
    /\ req' = [k \in Keys |-> IF req[k].phase = "waiting" THEN [req[k] EXCEPT !.phase = "failed"] ELSE req[k]]
    /\ UNCHANGED <<gen, held, refreshable, rt, valid, serverRt, deadRt, usedRt, sends, rejectedG>>

\* ---- Environment ----

\* A token expires, or the server stops accepting it, or starts asking for one.
Expire(g) ==
    /\ g \in valid
    /\ valid' = valid \ {g}
    /\ UNCHANGED <<gen, held, refreshable, rt, inflight, req, serverRt, deadRt, usedRt, sends, rejectedG>>

\* A sign-in (AuthFlow.tla) brings a token, with or without a refresh token.
\* It replaces the refresh in flight, whose answer is ignored, and the requests
\* waiting go out with it.
SignedIn(withRefresh) ==
    /\ gen < MaxGen
    /\ gen' = gen + 1
    /\ held' = TRUE
    /\ refreshable' = withRefresh
    /\ rt' = gen + 1
    /\ serverRt' = gen + 1
    /\ valid' = valid \cup {gen + 1}
    /\ inflight' = 0
    /\ req' = Release("sent")
    /\ sends' = Released("sent")
    /\ UNCHANGED <<deadRt, usedRt, rejectedG>>

\* Signing out drops the tokens and cancels the refresh in flight.
SignOut ==
    /\ held' = FALSE
    /\ refreshable' = FALSE
    /\ inflight' = 0
    /\ req' = [k \in Keys |-> IF req[k].phase = "waiting" THEN [req[k] EXCEPT !.phase = "needs_sign_in"] ELSE req[k]]
    /\ UNCHANGED <<gen, rt, valid, serverRt, deadRt, usedRt, sends, rejectedG>>

Answer(k) == Accept(k) \/ Reject(k)
Refreshed == (\E r \in BOOLEAN : RefreshOk(r)) \/ RefreshRefused \/ RefreshFailed

Next ==
    \/ \E k \in Keys, e \in BOOLEAN : Send(k, e)
    \/ \E k \in Keys : Answer(k) \/ Forget(k)
    \/ Refreshed
    \/ \E g \in valid : Expire(g)
    \/ \E r \in BOOLEAN : SignedIn(r)
    \/ SignOut

\* The server answers every request, and the authorization server every
\* refresh.
Fairness ==
    /\ \A k \in Keys : WF_vars(Answer(k))
    /\ WF_vars(Refreshed)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ---- Properties ----

TypeOK ==
    /\ gen \in 0..MaxGen
    /\ held \in BOOLEAN /\ refreshable \in BOOLEAN
    /\ inflight \in Nat
    /\ \A k \in Keys : req[k].phase \in Phases /\ req[k].g \in 0..MaxGen /\ req[k].again \in BOOLEAN
    /\ valid \subseteq 0..MaxGen
    /\ deadRt \subseteq 0..MaxGen

\* One refresh at a time.
SingleFlightRefresh == inflight <= 1

\* AUTH-25: a refresh presents the refresh token the server accepts, the latest
\* one it issued.
RefreshUsesLatest == inflight > 0 => usedRt = serverRt

\* AUTH-27, A refresh never presents a refresh token the authorization
\* server refused for good, so a refusal can't repeat with every request.
NoDeadRefresh == inflight > 0 => usedRt \notin deadRt

\* A request goes out at most twice, and its second send carries a newer
\* token than the one rejected.
SendsBound == \A k \in Keys : sends[k] <= 2
NewerOnResend == \A k \in Keys : (req[k].phase = "sent" /\ req[k].again) => req[k].g > rejectedG[k]

\* A request waits only while a refresh is in flight, so nothing waits forever.
WaitingHasRefresh == (\E k \in Keys : req[k].phase = "waiting") => inflight > 0

\* Every request ends: accepted, needing sign-in, failed, or cancelled.
EveryRequestEnds == \A k \in Keys : req[k].phase \in {"sent", "waiting"} ~> req[k].phase \in {"done", "needs_sign_in", "failed", "cancelled"}
====

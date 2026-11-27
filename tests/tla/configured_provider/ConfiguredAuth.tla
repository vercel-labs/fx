---------------------------- MODULE ConfiguredAuth ----------------------------
(***************************************************************************)
(* Models the `command` auth type of a custom model connection,            *)
(* "auth": {"type": "command", "command": [...]}, in                       *)
(* src/core/auth/command_token.zig, src/core/auth/command_auth.zig,        *)
(* src/core/auth/command_helper.zig, and                                   *)
(* src/gateway/configured_transport.zig.                                   *)
(*                                                                         *)
(* A connection's helper program prints a token, and the connection's      *)
(* requests send it. The server takes only tokens printed since it last    *)
(* revoked them, and fx learns when a cached token passes the expiry its   *)
(* helper printed. Requests run at once: r1 and r2 on connection c1, and   *)
(* r3, when Requests holds it, on c2.                                      *)
(*                                                                         *)
(* Design "a" runs the helper once for every request and caches nothing.   *)
(* Design "b" keeps each connection's token in memory, runs at most one    *)
(* helper per connection at a time, and gives every request that waits on  *)
(* a run the token it prints. In both designs fx's deadline stops a helper *)
(* that hangs, and cancelling the last request that waits on a run stops   *)
(* the run.                                                                *)
(*                                                                         *)
(* A 401 is handled in two places, as in fx. The transport drops the       *)
(* refused token from the connection's cache. The agent's replay decision  *)
(* (src/core/auth/auth_transition.zig decideAuthReplay) sends the request  *)
(* once more as a new attempt, and that attempt asks for a token the way a *)
(* new request does: phase "replay", then Replay.                          *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(* "none" is the design. "today" is fx before the change: a connection     *)
(* sends the same token from an environment variable and gives up on the   *)
(* first 401. Nonideal turns on the bad events: revoked and expired        *)
(* tokens, failing helpers, and cancels.                                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Requests, MaxGen, Design, Bug, Nonideal

Conns == {"c1", "c2"}
ConnOf(r) == IF r = "r3" THEN "c2" ELSE "c1"
Owners == Requests \cup Conns
\* Who owns the helper run a request waits on: the request itself in design
\* "a", its connection in design "b".
Owner(r) == IF Design = "a" THEN r ELSE ConnOf(r)
ConnOfOwner(o) == IF o \in Conns THEN o ELSE ConnOf(o)

Tokens == [conn: Conns, gen: 1..MaxGen]
NoToken == [conn |-> "none", gen |-> 0]
Phases == {"idle", "waiting", "sending", "replay", "done", "failed", "cancelled"}
Reasons == {"none", "helper", "rejected", "cancelled"}
\* Two runs at once can only happen under the no_single_flight defect.
MaxRuns == 2

ASSUME Requests \subseteq {"r1", "r2", "r3"} /\ Requests # {}
ASSUME MaxGen \in Nat /\ MaxGen >= 1
ASSUME Design \in {"a", "b"}
ASSUME Bug \in {"none", "today", "no_single_flight", "refresh_loop",
                "resend_same", "send_expired", "no_deadline", "orphan_helper",
                "shared_cache", "silent_failure"}
ASSUME Nonideal \in BOOLEAN

VARIABLES
    phase,        \* each request: idle, waiting for a token, sending, or ended
    reason,       \* why an ended request ended
    used,         \* the token each request sends, or NoToken
    rejected,     \* the token the server refused for each request, or NoToken
    refreshes,    \* how many times each request ran the helper after a 401
    cache,        \* design "b": the token fx holds for each connection
    expired,      \* tokens fx knows have passed their expiry
    runs,         \* helper runs in flight for each owner
    issued,       \* the newest token generation each connection's helper printed
    valid_from,   \* the oldest generation each connection's server still takes
    sent_expired  \* whether a request ever sent a token fx knew had expired

vars == <<phase, reason, used, rejected, refreshes, cache, expired, runs,
          issued, valid_from, sent_expired>>

TypeOK ==
    /\ phase \in [Requests -> Phases]
    /\ reason \in [Requests -> Reasons]
    /\ used \in [Requests -> Tokens \cup {NoToken}]
    /\ rejected \in [Requests -> Tokens \cup {NoToken}]
    /\ refreshes \in [Requests -> 0..2]
    /\ cache \in [Conns -> Tokens \cup {NoToken}]
    /\ expired \subseteq Tokens
    /\ runs \in [Owners -> 0..MaxRuns]
    /\ issued \in [Conns -> 0..MaxGen]
    /\ valid_from \in [Conns -> 1..(MaxGen + 1)]
    /\ sent_expired \in BOOLEAN

Init ==
    /\ phase = [r \in Requests |-> "idle"]
    /\ reason = [r \in Requests |-> "none"]
    /\ used = [r \in Requests |-> NoToken]
    /\ rejected = [r \in Requests |-> NoToken]
    /\ refreshes = [r \in Requests |-> 0]
    /\ cache = [c \in Conns |-> NoToken]
    /\ expired = {}
    /\ runs = [o \in Owners |-> 0]
    /\ issued = [c \in Conns |-> 0]
    /\ valid_from = [c \in Conns |-> 1]
    /\ sent_expired = FALSE

Waiters(o) == {r \in Requests : phase[r] = "waiting" /\ Owner(r) = o}

\* The token fx holds for a request's connection.
Cached(r) == IF Bug = "shared_cache" THEN cache["c1"] ELSE cache[ConnOf(r)]
Usable(t) == t # NoToken /\ (t \notin expired \/ Bug = "send_expired")

\* The runs after asking owner o for a token: a new run unless one runs.
WithRun(o) ==
    IF runs[o] = 0 \/ (Bug = "no_single_flight" /\ runs[o] < MaxRuns)
        THEN [runs EXCEPT ![o] = @ + 1]
        ELSE runs

\* A request asks for a token: it sends a usable cached one, or waits on a
\* helper run, starting one unless one runs.
Acquire(r) ==
    /\ IF Bug = "today"
          THEN /\ phase' = [phase EXCEPT ![r] = "sending"]
               /\ used' = [used EXCEPT ![r] = [conn |-> ConnOf(r), gen |-> 1]]
               /\ UNCHANGED <<runs, sent_expired>>
       ELSE IF Design = "b" /\ Usable(Cached(r))
          THEN /\ phase' = [phase EXCEPT ![r] = "sending"]
               /\ used' = [used EXCEPT ![r] = Cached(r)]
               /\ sent_expired' = (sent_expired \/ Cached(r) \in expired)
               /\ UNCHANGED runs
       ELSE /\ phase' = [phase EXCEPT ![r] = "waiting"]
            /\ runs' = WithRun(Owner(r))
            /\ UNCHANGED <<used, sent_expired>>
    /\ UNCHANGED <<reason, rejected, refreshes, cache, expired, issued, valid_from>>

\* A request needs a token.
Begin(r) == phase[r] = "idle" /\ Acquire(r)

\* The agent sends a request the server refused once more, as a new attempt.
Replay(r) == phase[r] = "replay" /\ Acquire(r)

\* A helper run exits 0 and prints a new token for its connection. Every
\* request waiting on the run sends it.
HelperPrints(o) ==
    LET c == ConnOfOwner(o)
        t == [conn |-> c, gen |-> issued[c] + 1]
    IN /\ runs[o] > 0
       /\ issued[c] < MaxGen
       /\ issued' = [issued EXCEPT ![c] = @ + 1]
       /\ runs' = [runs EXCEPT ![o] = @ - 1]
       /\ cache' = IF Design = "b" THEN [cache EXCEPT ![c] = t] ELSE cache
       /\ phase' = [r \in Requests |-> IF r \in Waiters(o) THEN "sending" ELSE phase[r]]
       /\ used' = [r \in Requests |-> IF r \in Waiters(o) THEN t ELSE used[r]]
       /\ UNCHANGED <<reason, rejected, refreshes, expired, valid_from, sent_expired>>

\* A helper run ends without a token, and every request waiting on it fails.
EndRunFailed(o) ==
    /\ runs' = [runs EXCEPT ![o] = @ - 1]
    /\ phase' = [r \in Requests |-> IF r \in Waiters(o) THEN "failed" ELSE phase[r]]
    /\ reason' = [r \in Requests |->
                     IF r \in Waiters(o)
                         THEN IF Bug = "silent_failure" THEN "none" ELSE "helper"
                         ELSE reason[r]]
    /\ UNCHANGED <<used, rejected, refreshes, cache, expired, issued, valid_from, sent_expired>>

\* The helper exits non-zero, prints something that is not a token, or
\* prints more than fx reads.
HelperFails(o) == Nonideal /\ runs[o] > 0 /\ EndRunFailed(o)

\* fx's deadline stops a helper that has not finished.
Deadline(o) == Bug # "no_deadline" /\ runs[o] > 0 /\ EndRunFailed(o)

\* The server takes a token printed for its own connection since it last
\* revoked its tokens.
Valid(r) == used[r].conn = ConnOf(r) /\ used[r].gen >= valid_from[ConnOf(r)]

Accept(r) ==
    /\ phase[r] = "sending"
    /\ Valid(r)
    /\ phase' = [phase EXCEPT ![r] = "done"]
    /\ UNCHANGED <<reason, used, rejected, refreshes, cache, expired, runs,
                   issued, valid_from, sent_expired>>

\* The server answers 401. The transport drops the refused token when the
\* connection still holds it, on every 401; another request may already hold
\* a newer one. The replay decision allows one replay for each request.
Reject(r) ==
    LET c == ConnOf(r) IN
    /\ phase[r] = "sending"
    /\ ~Valid(r)
    /\ cache' = IF Design = "b" /\ cache[c] = used[r] /\ Bug # "resend_same"
                   THEN [cache EXCEPT ![c] = NoToken]
                   ELSE cache
    /\ IF Bug # "today" /\ (refreshes[r] = 0 \/ (Bug = "refresh_loop" /\ refreshes[r] < 2))
          THEN /\ phase' = [phase EXCEPT ![r] = "replay"]
               /\ refreshes' = [refreshes EXCEPT ![r] = @ + 1]
               /\ rejected' = [rejected EXCEPT ![r] = used[r]]
               /\ UNCHANGED reason
          ELSE /\ phase' = [phase EXCEPT ![r] = "failed"]
               /\ reason' = [reason EXCEPT ![r] =
                                IF Bug = "silent_failure" THEN "none" ELSE "rejected"]
               /\ UNCHANGED <<refreshes, rejected>>
    /\ UNCHANGED <<used, runs, expired, issued, valid_from, sent_expired>>

\* The newest token a connection may have sent: under "today", the one token
\* from its environment variable.
Newest(c) == IF Bug = "today" THEN 1 ELSE issued[c]

\* The server stops taking every token a connection has sent so far: they
\* were revoked, or expired before fx learned it.
Revoke(c) ==
    /\ Nonideal
    /\ valid_from[c] <= Newest(c)
    /\ valid_from' = [valid_from EXCEPT ![c] = Newest(c) + 1]
    /\ UNCHANGED <<phase, reason, used, rejected, refreshes, cache, expired,
                   runs, issued, sent_expired>>

\* The token fx holds for a connection passes the expiry its helper printed.
Expire(c) ==
    /\ Nonideal
    /\ cache[c] # NoToken
    /\ cache[c] \notin expired
    /\ expired' = expired \cup {cache[c]}
    /\ UNCHANGED <<phase, reason, used, rejected, refreshes, cache, runs,
                   issued, valid_from, sent_expired>>

\* The person cancels a request. Cancelling the last request that waits on
\* a run stops the helper.
Cancel(r) ==
    LET o == Owner(r) IN
    /\ Nonideal
    /\ phase[r] \in {"waiting", "sending", "replay"}
    /\ phase' = [phase EXCEPT ![r] = "cancelled"]
    /\ reason' = [reason EXCEPT ![r] = "cancelled"]
    /\ runs' = IF phase[r] = "waiting" /\ Waiters(o) = {r} /\ Bug # "orphan_helper"
                  THEN [runs EXCEPT ![o] = 0]
                  ELSE runs
    /\ UNCHANGED <<used, rejected, refreshes, cache, expired, issued, valid_from, sent_expired>>

Next ==
    \/ \E r \in Requests : Begin(r) \/ Replay(r) \/ Accept(r) \/ Reject(r) \/ Cancel(r)
    \/ \E o \in Owners : HelperPrints(o) \/ HelperFails(o) \/ Deadline(o)
    \/ \E c \in Conns : Revoke(c) \/ Expire(c)

\* The helper itself may hang, so only fx's deadline, the server's answer and
\* the agent's replay are fair.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ \A o \in Owners : WF_vars(Deadline(o))
    /\ \A r \in Requests : WF_vars(Accept(r) \/ Reject(r))
    /\ \A r \in Requests : WF_vars(Replay(r))

\* Every token a request sends was printed by its connection's helper.
TokenFromHelper ==
    \A r \in Requests : used[r] # NoToken => used[r].gen <= issued[used[r].conn]

\* A request sends only its own connection's token.
TokenStaysWithItsConnection ==
    \A r \in Requests : used[r] # NoToken => used[r].conn = ConnOf(r)

\* Design "b" runs at most one helper per connection at a time.
OneRunPerConnection == Design = "b" => \A c \in Conns : runs[c] <= 1

\* A request runs the helper again at most once after a 401.
RefreshCapped == \A r \in Requests : refreshes[r] <= 1

\* After a 401, a request sends a newer token than the one refused.
ResendHasNewToken ==
    \A r \in Requests :
        (phase[r] = "sending" /\ refreshes[r] > 0) => used[r].gen > rejected[r].gen

\* fx never sends a token it knows has expired.
NoExpiredTokenSent == ~sent_expired

\* A helper runs only while a request waits on it, so cancelling stops it.
NoOrphanRun == \A o \in Owners : runs[o] > 0 => Waiters(o) # {}

\* A request that waits always has a run that will answer it.
WaitingHasRun == \A r \in Requests : phase[r] = "waiting" => runs[Owner(r)] > 0

\* A failed request says why.
FailureSaysSo ==
    \A r \in Requests : phase[r] = "failed" => reason[r] \in {"helper", "rejected"}

\* fx gives up on a 401 only after it tried one new token.
RejectedOnlyAfterRefresh ==
    \A r \in Requests :
        (phase[r] = "failed" /\ reason[r] = "rejected") => refreshes[r] >= 1

\* Every request that waits, sends or replays ends: done, failed with a
\* reason, or cancelled.
RequestSettles ==
    \A r \in Requests :
        phase[r] \in {"waiting", "sending", "replay"} ~> phase[r] \in {"done", "failed", "cancelled"}
=============================================================================

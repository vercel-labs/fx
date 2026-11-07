---- MODULE KeychainLockTrace ----
\* Runs of the real fx login refresh checked against KeychainLock.tla's
\* rules. tests/tla/drivers/oauth_session/driver.ts generates
\* KeychainLockObs.tla from one run: the steps its lab processes printed
\* (lab.zig, which runs the real src/core/auth/oauth_session.zig and
\* credentials.zig refresh) and its local issuer's, merged on the awake clock.
\* Every record has every field; the ones a step doesn't use are empty.
\*   init {token}               the saved login's refresh token, which the issuer takes
\*   take {p}                   p took the login's lock
\*   load {p, token}            p loaded the saved login under it ("" for none)
\*   recv {token, ok, issued}   the issuer got a refresh token and rotated it,
\*                              issuing the next, or refused it
\*   reply {p, outcome, token}  refreshFxSession returned "ok", having saved
\*                              token, or an error; the Retiring ones deleted the login
\*   revoke                     the issuer stopped taking every token
\*   release {p}, crash {p}     p let the lock go, or the driver killed it
\*   final {token}              the saved login after the run ("" for none)
\* Others (start, send, nologin, error) change nothing.
\*
\* The rules, KeychainLock.tla's on real runs:
\*   OneRefresher         no process takes the lock while another holds it
\*   NoReuse              the issuer never refuses a token while the saved login is one it takes
\*   NoValidLoginDeleted  a refused refresh never deletes a saved login the issuer takes
\*   LoadSeesSaved        a load under the lock returns the saved login
\*   Consistent           the run agrees with itself: the issuer rotates only
\*                        tokens it takes, and the final login is the saved one
EXTENDS Naturals, Sequences, KeychainLockObs

Retiring == {"InvalidGrant", "AccessDenied", "ExpiredToken", "InvalidClient",
             "NoRefreshToken", "OAuthSessionCleanupUncertain"}

VARIABLES
    i,      \* records replayed
    bad,    \* rules broken so far
    crit,   \* processes holding the lock
    store,  \* the saved login's refresh token, "" for none
    live    \* the tokens the issuer takes

traceVars == <<i, bad, crit, store, live>>

TraceInit == i = 0 /\ bad = {} /\ crit = {} /\ store = "" /\ live = {}

Broken(r) ==
    (IF r.ev = "take" /\ crit # {} THEN {"OneRefresher"} ELSE {})
    \cup (IF r.ev = "load" /\ r.token # store THEN {"LoadSeesSaved"} ELSE {})
    \cup (IF r.ev = "recv" /\ ~r.ok /\ store \in live THEN {"NoReuse"} ELSE {})
    \cup (IF r.ev = "recv" /\ r.ok /\ r.token \notin live THEN {"Consistent"} ELSE {})
    \cup (IF r.ev = "reply" /\ r.outcome \in Retiring /\ store \in live THEN {"NoValidLoginDeleted"} ELSE {})
    \cup (IF r.ev = "final" /\ r.token # store THEN {"Consistent"} ELSE {})

Step(r) ==
    CASE r.ev = "init" ->
            store' = r.token /\ live' = {r.token} /\ UNCHANGED crit
      [] r.ev = "take" ->
            crit' = crit \cup {r.p} /\ UNCHANGED <<store, live>>
      [] r.ev \in {"release", "crash"} ->
            crit' = crit \ {r.p} /\ UNCHANGED <<store, live>>
      [] r.ev = "recv" ->
            live' = (IF r.ok THEN (live \ {r.token}) \cup {r.issued} ELSE live)
            /\ UNCHANGED <<crit, store>>
      [] r.ev = "reply" ->
            store' = (IF r.outcome = "ok" THEN r.token
                      ELSE IF r.outcome \in Retiring THEN "" ELSE store)
            /\ UNCHANGED <<crit, live>>
      [] r.ev = "revoke" ->
            live' = {} /\ UNCHANGED <<crit, store>>
      [] OTHER ->
            UNCHANGED <<crit, store, live>>

TraceNext ==
    /\ i < Len(Observed)
    /\ Step(Observed[i + 1])
    /\ bad' = bad \cup Broken(Observed[i + 1])
    /\ i' = i + 1

\* Violated once every record replayed; the error trace's last state holds
\* `bad`, the rules the run broke. Not violated: the run left the model.
NotDone == i < Len(Observed)
====

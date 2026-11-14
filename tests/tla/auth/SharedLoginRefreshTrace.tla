---- MODULE SharedLoginRefreshTrace ----
\* Real runs of fx processes that share one saved fx, Codex, or Grok login, checked against
\* SharedLoginRefresh.tla's rules. tests/tla/drivers/auth/trace.ts writes
\* TraceObs.tla from the ordered log that tests/e2e/shared-login-fakes.ts
\* keeps of what its fake gateway and issuer saw and what the harness did:
\*   send {p, tok}            process p sent a request with access token tok
\*   answer {p, tok, ok}      the gateway took it (ok) or answered 401
\*   redeem {rt, saved}       a refresh with refresh token rt, while the saved
\*                            login held generation saved (-1 for none)
\*   issue {tok}              the issuer rotated the login to generation tok
\*   refuse {rt}              the issuer refused rt and revoked the login
\*   fail {rt, status}        the issuer failed the request without redeeming it
\*   revoke {tok}             the harness made the gateway stop taking tok
\*   replace {tok, expired}   the harness rotated and saved generation tok,
\*                            as another fx would, past its refresh deadline
\*                            when expired
\*   remove {none}            the harness signed the login out
\*   kill {p}                 the harness killed p
\* Rules:
\*   NoRedundantRotation  a refresh happens only while the gateway rejects the
\*                        saved token or it is past its refresh deadline
\*                        (SharedLoginRefresh.tla NoRedundantRotation)
\*   RedeemSaved          fx presents the saved login's refresh token
\*   OneReplay            a process sends at most twice: once, and once more
\*                        after a 401
\*   ReplayAfterReject    a process sends again only after a 401
\*   SendKnownToken       fx sends only tokens the issuer or the harness made
\*   NoSendAfterKill      a killed process sends nothing
\*   GatewayAnswers       the fake gateway answered by the issuer's rule
\*                        (checks the harness itself)
EXTENDS Integers, Sequences, FiniteSets, TraceObs

VARIABLES i, bad, gen, revoked, expired, loginRevoked, known, sends, rejectedOnce, killed

Accepts(t) == ~loginRevoked /\ t = gen /\ t \notin revoked

TraceInit ==
    /\ i = 0
    /\ bad = {}
    /\ gen = 0
    /\ revoked = {}
    /\ expired = {}
    /\ loginRevoked = FALSE
    /\ known = {0}
    /\ sends = [p \in ObsProcs |-> 0]
    /\ rejectedOnce = [p \in ObsProcs |-> FALSE]
    /\ killed = {}

Broken(r) ==
    LET d == r.data IN
    CASE r.event = "send" ->
            (IF d.tok \notin known THEN {"SendKnownToken"} ELSE {}) \cup
            (IF sends[d.p] >= 2 THEN {"OneReplay"} ELSE {}) \cup
            (IF sends[d.p] = 1 /\ ~rejectedOnce[d.p] THEN {"ReplayAfterReject"} ELSE {}) \cup
            (IF d.p \in killed THEN {"NoSendAfterKill"} ELSE {})
      [] r.event = "answer" ->
            IF d.ok # Accepts(d.tok) THEN {"GatewayAnswers"} ELSE {}
      [] r.event = "redeem" ->
            (IF d.saved # d.rt THEN {"RedeemSaved"} ELSE {}) \cup
            (IF d.saved >= 0 /\ Accepts(d.saved) /\ d.saved \notin expired
                THEN {"NoRedundantRotation"} ELSE {})
      [] OTHER -> {}

Step(r) ==
    LET d == r.data IN
    CASE r.event = "send" ->
            /\ sends' = [sends EXCEPT ![d.p] = @ + 1]
            /\ UNCHANGED <<gen, revoked, expired, loginRevoked, known, rejectedOnce, killed>>
      [] r.event = "answer" ->
            /\ rejectedOnce' = [rejectedOnce EXCEPT ![d.p] = @ \/ ~d.ok]
            /\ UNCHANGED <<gen, revoked, expired, loginRevoked, known, sends, killed>>
      [] r.event \in {"redeem", "fail", "remove"} ->
            UNCHANGED <<gen, revoked, expired, loginRevoked, known, sends, rejectedOnce, killed>>
      [] r.event = "issue" ->
            /\ gen' = d.tok
            /\ known' = known \cup {d.tok}
            /\ UNCHANGED <<revoked, expired, loginRevoked, sends, rejectedOnce, killed>>
      [] r.event = "refuse" ->
            /\ loginRevoked' = TRUE
            /\ UNCHANGED <<gen, revoked, expired, known, sends, rejectedOnce, killed>>
      [] r.event = "revoke" ->
            /\ revoked' = revoked \cup {d.tok}
            /\ UNCHANGED <<gen, expired, loginRevoked, known, sends, rejectedOnce, killed>>
      [] r.event = "replace" ->
            /\ gen' = d.tok
            /\ known' = known \cup {d.tok}
            /\ expired' = IF d.expired THEN expired \cup {d.tok} ELSE expired
            /\ UNCHANGED <<revoked, loginRevoked, sends, rejectedOnce, killed>>
      [] r.event = "kill" ->
            /\ killed' = killed \cup {d.p}
            /\ UNCHANGED <<gen, revoked, expired, loginRevoked, known, sends, rejectedOnce>>
      [] OTHER -> FALSE

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ Step(ObsTrace[i + 1])
    /\ bad' = bad \cup Broken(ObsTrace[i + 1])
    /\ i' = i + 1

\* Sentinels for drivers/auth/trace.ts: TLC reports NotDone violated exactly
\* when the whole trace matches, NotDoneClean when it matches keeping every
\* rule, and NotDoneDirty when it matches breaking one.
NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====

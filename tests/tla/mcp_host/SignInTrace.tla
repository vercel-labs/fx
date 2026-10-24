---- MODULE SignInTrace ----
\* Trace wrapper for SignIn.tla. trace.ts generates TraceObs from a real
\* sign-in against the harness's OAuth fake (tests/tla/drivers/mcp_host/). Logins
\* are numbered in the order started; a state is the number of the login
\* whose authorization URL carried it, or 0 for one fx never made.
\*   login {}                  `fx mcp login --no-browser NAME` or `/mcp login NAME`
\*   authorize {login}         the authorization URL was printed
\*   probe {login, result}     the harness asked the login's port for an icon:
\*                             "open" (a 404 came back), "closed" (refused)
\*   callback {login, state, kind}  the harness came back to that port:
\*                             "get" (GET /callback), "form_ours",
\*                             "form_foreign", or "other"
\*   redeem {login}            the fake's token endpoint got that login's code
\*   signed_in {login}         "Signed in to NAME."
\*   failed {login}            "Couldn't sign in to NAME: ..."
\*   reload {server}           a /mcp change reloaded in place: "kept" left
\*                             the server as it was, "dropped" removed or
\*                             changed it
\*   replace {}, lease {}, release {}  a reload that replaced the host
\*   status {signing}          the shell's status line says "Signing in to NAME"
EXTENDS SignIn, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF RedeemOnlyLiveState THEN {} ELSE {"RedeemOnlyLiveState"}) \cup
    (IF ListenerTakesOnlyItsOwn THEN {} ELSE {"ListenerTakesOnlyItsOwn"}) \cup
    (IF NoListenerWithoutHost THEN {} ELSE {"NoListenerWithoutHost"}) \cup
    (IF OneSignInPerHost THEN {} ELSE {"OneSignInPerHost"}) \cup
    (IF IndicatorImpliesListener THEN {} ELSE {"IndicatorImpliesListener"}) \cup
    (IF OneSignInPerServer THEN {} ELSE {"OneSignInPerServer"}) \cup
    (IF FlowHasListener THEN {} ELSE {"FlowHasListener"})

Probed(k, result) ==
    /\ IF result = "open" THEN phase[k] = "open" /\ alive[hostOf[k]] ELSE ~Open(k)
    /\ UNCHANGED vars

Step(rec) ==
    CASE rec.event = "login" -> StartLogin \/ AgainLogin
      [] rec.event = "authorize" -> Authorize(rec.data.login)
      [] rec.event = "probe" -> Probed(rec.data.login, rec.data.result)
      [] rec.event = "callback" -> Arrive(rec.data.login, rec.data.state, rec.data.kind)
      [] rec.event = "redeem" -> Handle(rec.data.login) /\ phase'[rec.data.login] = "redeeming"
      [] rec.event = "signed_in" -> Redeemed(rec.data.login, TRUE)
      [] rec.event = "failed" -> \/ Handle(rec.data.login) /\ phase'[rec.data.login] = "closed"
                                 \/ Redeemed(rec.data.login, FALSE)
                                 \/ Expire(rec.data.login)
      [] rec.event = "reload" -> IF rec.data.server = "kept" THEN ReloadKeeps ELSE ReloadDrops
      [] rec.event = "replace" -> Replace
      [] rec.event = "lease" -> Lease
      [] rec.event = "release" -> \E h \in Hosts : Release(h)
      [] rec.event = "status" -> indicator = rec.data.signing /\ UNCHANGED vars
      [] OTHER -> FALSE

TraceInit == Init /\ i = 0 /\ bad = Viol

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ Step(ObsTrace[i + 1])
    /\ i' = i + 1
    /\ bad' = bad \cup Viol'

NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====

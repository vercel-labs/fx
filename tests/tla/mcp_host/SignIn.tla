---- MODULE SignIn ----
\* fx's MCP sign-in for one HTTP server (vercel-labs/fx at 53a561bea).
\*
\* Code:
\*   - src/core/mcp_host/runtime.zig: startLogin (a login already under way
\*     for the server is the one asked for: its address is shown again;
\*     else a new Login: a loopback listener and the awaitBrowser task, then
\*     engine.signIn, which starts a flow only when none is running,
\*     client.zig Auth.signIn), awaitBrowser (the first
\*     `GET /callback`, or for a bridged server the first form posted from
\*     the bridge's origin, carrying the state `.authorize` gave the
\*     listener, is posted as finish_login; the task then ends),
\*     finishLogin (`fx mcp login NAME --no-browser`: a pasted address,
\*     past the listener), `.finish_login` (engine.finishSignIn: the engine's
\*     flow checks the state),
\*     onServer `.authorize` / `.signed_in` / `.sign_in_failed`, expireLogins
\*     (5 minutes), shutdown (endLogin for every login, each with a
\*     `.sign_in_failed`: the MCP config changed). While another
\*     host is retired but alive, a login waits.
\*   - src/core/mcp_host/login.zig: Listener.accept, takeReturn, takeForm
\*     (any other return gets a 404 and the wait goes on).
\*   - src/core/app/app_mcp_runtime.zig HostSink: `.authorize` sets the
\*     shell's "Signing in to NAME" (sign_in), `.signed_in` and
\*     `.sign_in_failed` clear it; it lives in the shell's State, not in the
\*     host, so it outlives a host a reload replaces. reloadHost reloads the
\*     host in place (Runtime.reload): a change that leaves the server alone
\*     leaves its login, and one that removes or changes it ends the login
\*     (dropServer: endLogin with a `.sign_in_failed`). It replaces the host
\*     only when the loader can't reload in place (the config went empty or
\*     came back, or the reload failed); the old one goes with its last lease.
\*   - src/mcp/auth/client.zig finishSignIn + core/auth.zig: a response whose
\*     state isn't the live flow's fails the sign-in; the code is redeemed
\*     only when it matches.
\*
\* Logins are numbered 1..MaxLogins in the order started; login k's flow has
\* its own state, also k. A callback carries a state: 0 is one fx never made.
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxLogins,  \* logins started
    MaxHosts,   \* hosts (one per reload)
    MaxLeases,  \* leases one host holds at once
    Bridge      \* the server signs in through a bridge page (Slack through fx.sh)

Logins == 1..MaxLogins
Hosts == 1..MaxHosts
States == 0..MaxLogins
\* What reaches a listener: the browser's GET /callback, a bridge page's
\* form from the bridge's origin, a form from any other origin, or an
\* unrelated request (an icon).
Kinds == {"get", "form_ours", "form_foreign", "other"}
Phases == {"unused", "open", "consumed", "redeeming", "closed"}

VARIABLES
    cur, alive, retired, leases,
    phase,      \* [Logins -> Phases]: open = the listener accepts; consumed = its
                \* task took a callback the owner hasn't handled
    hostOf,     \* [Logins -> 0..MaxHosts]
    got,        \* [Logins -> States]: the state its callback carried
    live,       \* [Hosts -> 0..MaxLogins]: the host's login (runtime.logins)
    flow,       \* [Hosts -> States]: the engine's live flow there (0: none)
    shownUrl,   \* [Logins -> BOOLEAN]: its `.authorize` notice came
    indicator,  \* the shell says "Signing in to NAME"
    saved,      \* a token was kept
    next,       \* the next login's number
    badRedeem,      \* ghost: a code was redeemed for a state not the live flow's
    foreignTaken    \* ghost: a listener took what its kind of sign-in must refuse

vars == <<cur, alive, retired, leases, phase, hostOf, got, live, flow, shownUrl, indicator, saved, next, badRedeem, foreignTaken>>

Open(k) == phase[k] \in {"open", "consumed", "redeeming"}

TypeOK ==
    /\ cur \in Hosts /\ alive \in [Hosts -> BOOLEAN] /\ retired \in [Hosts -> BOOLEAN]
    /\ leases \in [Hosts -> 0..MaxLeases]
    /\ phase \in [Logins -> Phases]
    /\ hostOf \in [Logins -> 0..MaxHosts]
    /\ got \in [Logins -> States]
    /\ live \in [Hosts -> 0..MaxLogins]
    /\ flow \in [Hosts -> States]
    /\ shownUrl \in [Logins -> BOOLEAN]
    /\ indicator \in BOOLEAN /\ saved \in BOOLEAN
    /\ next \in 1..(MaxLogins + 1)
    /\ badRedeem \in BOOLEAN /\ foreignTaken \in BOOLEAN

Init ==
    /\ cur = 1 /\ alive = [h \in Hosts |-> h = 1] /\ retired = [h \in Hosts |-> FALSE]
    /\ leases = [h \in Hosts |-> 0]
    /\ phase = [k \in Logins |-> "unused"]
    /\ hostOf = [k \in Logins |-> 0]
    /\ got = [k \in Logins |-> 0]
    /\ live = [h \in Hosts |-> 0]
    /\ flow = [h \in Hosts |-> 0]
    /\ shownUrl = [k \in Logins |-> FALSE]
    /\ indicator = FALSE /\ saved = FALSE
    /\ next = 1
    /\ badRedeem = FALSE /\ foreignTaken = FALSE

\* endLogin(k): cancel its task, close its listener, forget it. No notice.
Ended(k) == [phase EXCEPT ![k] = "closed"]

\* The host's login, while it's under way.
SigningIn(h) == live[h] # 0 /\ Open(live[h])

\* `/mcp login NAME` or `fx mcp login NAME` on the current host. It waits
\* while any other host is alive. The engine starts a flow only when none
\* is running.
StartLogin ==
    /\ alive[cur] /\ next <= MaxLogins
    /\ \A h \in Hosts : alive[h] => h = cur
    /\ ~SigningIn(cur)
    /\ LET k == next
       IN /\ phase' = [phase EXCEPT ![k] = "open"]
          /\ hostOf' = [hostOf EXCEPT ![k] = cur]
          /\ live' = [live EXCEPT ![cur] = k]
          /\ flow' = IF flow[cur] = 0 THEN [flow EXCEPT ![cur] = k] ELSE flow
          /\ next' = next + 1
    /\ UNCHANGED <<cur, alive, retired, leases, got, shownUrl, indicator, saved, badRedeem, foreignTaken>>

\* The same, asked for while the host's login is under way: that login is
\* the one asked for, and its listener and flow stay. Its address, if it
\* came, is shown again.
AgainLogin ==
    /\ alive[cur]
    /\ \A h \in Hosts : alive[h] => h = cur
    /\ SigningIn(cur)
    /\ UNCHANGED vars

\* The engine's `.authorize` event for login k: the notice sets the shell's
\* "Signing in" and carries the URL (with the state and redirect port).
Authorize(k) ==
    /\ phase[k] = "open" /\ alive[hostOf[k]] /\ live[hostOf[k]] = k /\ ~shownUrl[k]
    /\ shownUrl' = [shownUrl EXCEPT ![k] = TRUE]
    /\ indicator' = TRUE
    /\ UNCHANGED <<cur, alive, retired, leases, phase, hostOf, got, live, flow, saved, next, badRedeem, foreignTaken>>

\* login.zig takeReturn/takeForm: what the listener takes. A non-bridged
\* listener takes GET /callback; a bridged one takes a form only from the
\* bridge's origin. Either carries the login's own state. Anything else gets
\* a 404 and the wait goes on, so a stray return never ends a sign-in.
Takes(kind) == IF Bridge THEN kind = "form_ours" ELSE kind = "get"

Arrive(k, s, kind) ==
    /\ phase[k] = "open"
    /\ IF Takes(kind) /\ s = k
       THEN /\ phase' = [phase EXCEPT ![k] = "consumed"]
            /\ got' = [got EXCEPT ![k] = s]
            /\ foreignTaken' = (foreignTaken \/ kind \in {"form_foreign", "other"} \/ s # k)
       ELSE UNCHANGED <<phase, got, foreignTaken>>
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, live, flow, shownUrl, indicator, saved, next, badRedeem>>

\* finishLogin: the address the browser ended on, pasted. It goes to the engine
\* as it is, past the listener, so a wrong one fails the sign-in there.
Paste(k, s) ==
    /\ phase[k] = "open"
    /\ phase' = [phase EXCEPT ![k] = "consumed"]
    /\ got' = [got EXCEPT ![k] = s]
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, live, flow, shownUrl, indicator, saved, next, badRedeem, foreignTaken>>

\* `.finish_login`: the engine checks the state against the live flow.
Handle(k) ==
    /\ phase[k] = "consumed" /\ alive[hostOf[k]] /\ live[hostOf[k]] = k
    /\ LET h == hostOf[k]
           ok == flow[h] # 0 /\ got[k] = flow[h]
       IN IF ok
          THEN /\ phase' = [phase EXCEPT ![k] = "redeeming"]
               /\ badRedeem' = (badRedeem \/ got[k] # flow[h])
               /\ UNCHANGED <<live, flow, indicator>>
          ELSE \* `.sign_in_failed`: endLogin, then the notice clears the line.
               /\ phase' = Ended(k)
               /\ live' = [live EXCEPT ![h] = 0]
               /\ flow' = [flow EXCEPT ![h] = 0]
               /\ indicator' = FALSE
               /\ UNCHANGED badRedeem
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, shownUrl, saved, next, foreignTaken>>

\* The token endpoint answers the redemption: `.signed_in` (and a
\* `credential` event: the token is kept), or `.sign_in_failed`.
Redeemed(k, ok) ==
    /\ phase[k] = "redeeming" /\ alive[hostOf[k]]
    /\ LET h == hostOf[k]
       IN /\ phase' = Ended(k)
          /\ live' = [live EXCEPT ![h] = 0]
          /\ flow' = [flow EXCEPT ![h] = 0]
          /\ indicator' = FALSE
          /\ saved' = (saved \/ ok)
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, shownUrl, next, badRedeem, foreignTaken>>

\* expireLogins: the browser didn't come back in 5 minutes.
Expire(k) ==
    /\ Open(k) /\ alive[hostOf[k]] /\ live[hostOf[k]] = k
    /\ LET h == hostOf[k]
       IN /\ phase' = Ended(k)
          /\ live' = [live EXCEPT ![h] = 0]
          /\ flow' = [flow EXCEPT ![h] = 0]
          /\ indicator' = FALSE
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, shownUrl, saved, next, badRedeem, foreignTaken>>

\* A host's end: Runtime.shutdown ends its logins, each with a
\* `.sign_in_failed` that clears the shell's "Signing in".
Gone(h, ph) == [k \in Logins |-> IF hostOf[k] = h /\ Open(k) THEN "closed" ELSE ph[k]]
SignsIn(h) == \E k \in Logins : hostOf[k] = h /\ Open(k)
GoneIndicator(h) == IF SignsIn(h) THEN FALSE ELSE indicator

Lease ==
    /\ alive[cur] /\ leases[cur] < MaxLeases
    /\ leases' = [leases EXCEPT ![cur] = @ + 1]
    /\ UNCHANGED <<cur, alive, retired, phase, hostOf, got, live, flow, shownUrl, indicator, saved, next, badRedeem, foreignTaken>>

Release(h) ==
    /\ leases[h] > 0
    /\ leases' = [leases EXCEPT ![h] = @ - 1]
    /\ IF retired[h] /\ leases[h] = 1
       THEN /\ alive' = [alive EXCEPT ![h] = FALSE]
            /\ phase' = Gone(h, phase)
            /\ live' = [live EXCEPT ![h] = 0]
            /\ flow' = [flow EXCEPT ![h] = 0]
            /\ indicator' = GoneIndicator(h)
       ELSE UNCHANGED <<alive, phase, live, flow, indicator>>
    /\ UNCHANGED <<cur, retired, hostOf, got, shownUrl, saved, next, badRedeem, foreignTaken>>

\* `/mcp add`, `remove`, `approve`, `reject` in the shell, applied in place,
\* that remove or change this server: dropServer ends its login with a
\* `.sign_in_failed` that clears the shell's "Signing in", and the engine's
\* flow goes with the server's old slot.
ReloadDrops ==
    /\ alive[cur]
    /\ IF SigningIn(cur)
       THEN /\ phase' = Ended(live[cur])
            /\ live' = [live EXCEPT ![cur] = 0]
            /\ indicator' = FALSE
       ELSE UNCHANGED <<phase, live, indicator>>
    /\ flow' = [flow EXCEPT ![cur] = 0]
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, shownUrl, saved, next, badRedeem, foreignTaken>>

\* The same, leaving this server as it was.
ReloadKeeps == alive[cur] /\ UNCHANGED vars

\* A reload the loader can't apply in place: reloadHost replaces the host.
Replace ==
    /\ cur < MaxHosts
    /\ LET n == cur + 1
           free == leases[cur] = 0
       IN /\ cur' = n
          /\ retired' = [retired EXCEPT ![cur] = TRUE]
          /\ alive' = [alive EXCEPT ![n] = TRUE, ![cur] = ~free]
          /\ phase' = IF free THEN Gone(cur, phase) ELSE phase
          /\ live' = IF free THEN [live EXCEPT ![cur] = 0] ELSE live
          /\ flow' = IF free THEN [flow EXCEPT ![cur] = 0] ELSE flow
          /\ indicator' = IF free THEN GoneIndicator(cur) ELSE indicator
    /\ UNCHANGED <<leases, hostOf, got, shownUrl, saved, next, badRedeem, foreignTaken>>

Next ==
    \/ StartLogin
    \/ AgainLogin
    \/ \E k \in Logins : Authorize(k) \/ Handle(k) \/ Expire(k) \/ Redeemed(k, TRUE) \/ Redeemed(k, FALSE)
    \/ \E k \in Logins, s \in States, kind \in Kinds : Arrive(k, s, kind)
    \/ \E k \in Logins, s \in States : Paste(k, s)
    \/ Lease
    \/ \E h \in Hosts : Release(h)
    \/ ReloadKeeps
    \/ ReloadDrops
    \/ Replace
    \* Nothing more to do is not a deadlock: Next allows stuttering.
    \/ UNCHANGED vars

Fairness ==
    /\ \A k \in Logins : WF_vars(Authorize(k)) /\ WF_vars(Handle(k)) /\ WF_vars(Expire(k))
                         /\ WF_vars(Redeemed(k, TRUE) \/ Redeemed(k, FALSE))
    /\ \A h \in Hosts : WF_vars(Release(h))

Spec == Init /\ [][Next]_vars /\ Fairness

\* ---- Safety the code keeps ----

\* A token is redeemed only for a callback whose state matches the live sign-in.
RedeemOnlyLiveState == ~badRedeem

\* A listener takes only the browser's return of its own sign-in: of its
\* kind (a bridged one only a form from the bridge's origin), and carrying
\* its state.
ListenerTakesOnlyItsOwn == ~foreignTaken

\* A login's listener never outlives its host.
NoListenerWithoutHost == \A k \in Logins : Open(k) => alive[hostOf[k]]

\* One sign-in per server in each host.
OneSignInPerHost == \A h \in Hosts : Cardinality({k \in Logins : hostOf[k] = h /\ Open(k)}) <= 1

\* "Signing in" implies a live listener.
IndicatorImpliesListener == indicator => \E k \in Logins : Open(k) /\ alive[hostOf[k]]

\* One sign-in per server, whatever hosts are alive.
OneSignInPerServer == Cardinality({k \in Logins : Open(k)}) <= 1

\* The engine's live flow is the host's login, with its listener open: the
\* browser can come back to the sign-in the engine waits on.
FlowHasListener == \A h \in Hosts : flow[h] # 0 => live[h] = flow[h] /\ Open(flow[h])

\* A reload that leaves the server as it was leaves its sign-in going.
KeptSignInGoesOn == [][ReloadKeeps => \A k \in Logins : Open(k) => Open(k)']_vars

\* ---- Liveness ----

\* Every login started ends: signed in, failed, expired, or gone with its host.
EveryLoginEnds == \A k \in Logins : Open(k) ~> ~Open(k)

\* The shell's "Signing in" doesn't stay once nothing signs in.
IndicatorClears == indicator ~> ~indicator
====

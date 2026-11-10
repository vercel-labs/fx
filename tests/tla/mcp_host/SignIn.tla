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
\*   - src/core/mcp_host/runtime.zig, the check request (CheckFirst): `.signed_in`
\*     (the engine holds the new tokens, unsaved) marks the login confirming
\*     and sends engine.reconnect; Confirm is concludeSignIn, called by the
\*     server's answer: `.tools` ok (accept), `.auth_required` that isn't a
\*     step-up (refuse: discardLogin, nothing saved, `.sign_in_failed`),
\*     `.tools` not ok, `.failed`, or `.phase` backoff or failed (fail: saved,
\*     `.signed_in_unchecked`), or expireLogins after 45 s (fail). A `.credential`
\*     meanwhile is held. PickUp is pickUpLogin in another fx process.
\*   - src/core/mcp_host/runtime.zig, the read again for an unreadable store (PR #1793):
\*     `store_unread` (restoreCredentials, adoptSaved) is StoreUnreadable; pickUpLogin
\*     (takeSaved clears it on a read that works) is Reread, and skips a server with a
\*     login under way; the `.auth_required` handler answers a sign-in's check request
\*     (concludeSignIn) before its `store_unread` branch (UnreadFirst FALSE).
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
\* A new login is confirmed before it is kept and reported (CheckFirst, the fix):
\* the token exchange only gives the engine a token, which stays in memory. The
\* host sends one request with it (the connect and tools/list `fx mcp show`
\* uses) and the server's answer ends the sign-in:
\*   - accepted: the login is saved, then "Signed in to NAME." (`.signed_in`);
\*   - refused (a 401, or a 403 that isn't a step-up): `.sign_in_failed` with
\*     the server's error, and the token is never saved;
\*   - no answer in time, a 5xx, or a dropped connection: the login is saved,
\*     and "Signed in to NAME" says it couldn't be checked.
\* Before the fix (CheckFirst FALSE) the exchange saved and reported at once.
\* The server's answer to a request with login k's token is `srv`, fixed when
\* the run starts. Another fx process takes any login that is saved
\* (pickUpLogin in runtime.zig; SharedLogins.tla), so a refused token that was
\* ever saved can be taken.
\*
\* Logins are numbered 1..MaxLogins in the order started; login k's flow has
\* its own state, also k. A callback carries a state: 0 is one fx never made.
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxLogins,  \* logins started
    MaxHosts,   \* hosts (one per reload)
    MaxLeases,  \* leases one host holds at once
    Bridge,     \* the server signs in through a bridge page (Slack through fx.sh)
    CheckFirst  \* a new login is confirmed by the server before it is kept and reported

Logins == 1..MaxLogins
\* The order of two branches of the host's `.auth_required` handler. fx has the
\* sign-in's own answer first: a 401 to the request that checks a new login ends
\* that sign-in (concludeSignIn). With UnreadFirst, the branch added for an
\* unreadable store (PR #1793: read the store again, else say it can't be read)
\* would take that 401 and swallow it. A findings config sets it to TRUE.
UnreadFirst == FALSE
UnreadFirstYes == TRUE
Hosts == 1..MaxHosts
States == 0..MaxLogins
\* What reaches a listener: the browser's GET /callback, a bridge page's
\* form from the bridge's origin, a form from any other origin, or an
\* unrelated request (an icon).
Kinds == {"get", "form_ours", "form_foreign", "other"}
Phases == {"unused", "open", "consumed", "redeeming", "confirming", "closed"}
\* What the server answers a request with a login's token: accepts it, refuses
\* it (401), or fails (a 5xx, a dropped connection, no answer in time).
Answers == {"accept", "refuse", "fail"}

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
    saved,      \* the logins kept in the store
    ck,         \* [Logins -> [srv, notified, asked, taken]]: srv is the server's answer to a
                \* request with that login's token; notified: `.signed_in` was sent;
                \* asked: that request got its answer; taken: another fx took the saved login
    next,       \* the next login's number
    unread,     \* the host's `store_unread`: the store of saved logins couldn't be read, at the start or
                \* for a server a reload added; a read that works clears it
    swapped,    \* ghost: the host took a saved login in place of the one a sign-in holds
    gone,       \* the logins a logout cut off while they waited for their check request
    badRedeem,      \* ghost: a code was redeemed for a state not the live flow's
    foreignTaken    \* ghost: a listener took what its kind of sign-in must refuse

vars == <<cur, alive, retired, leases, phase, hostOf, got, live, flow, shownUrl, indicator, saved, ck, next, badRedeem, foreignTaken, unread, swapped, gone>>

Open(k) == phase[k] \in {"open", "consumed", "redeeming"}
\* A login under way, its check request included: the host keeps it, and the
\* shell its "Signing in", until the server answers.
Pending(k) == Open(k) \/ phase[k] = "confirming"

TypeOK ==
    /\ cur \in Hosts /\ alive \in [Hosts -> BOOLEAN] /\ retired \in [Hosts -> BOOLEAN]
    /\ leases \in [Hosts -> 0..MaxLeases]
    /\ phase \in [Logins -> Phases]
    /\ hostOf \in [Logins -> 0..MaxHosts]
    /\ got \in [Logins -> States]
    /\ live \in [Hosts -> 0..MaxLogins]
    /\ flow \in [Hosts -> States]
    /\ shownUrl \in [Logins -> BOOLEAN]
    /\ indicator \in BOOLEAN /\ saved \subseteq Logins
    /\ ck \in [Logins -> [srv : Answers, notified : BOOLEAN, asked : BOOLEAN, taken : BOOLEAN]]
    /\ next \in 1..(MaxLogins + 1)
    /\ badRedeem \in BOOLEAN /\ foreignTaken \in BOOLEAN
    /\ unread \in BOOLEAN /\ swapped \in BOOLEAN /\ gone \subseteq Logins

Init ==
    /\ cur = 1 /\ alive = [h \in Hosts |-> h = 1] /\ retired = [h \in Hosts |-> FALSE]
    /\ leases = [h \in Hosts |-> 0]
    /\ phase = [k \in Logins |-> "unused"]
    /\ hostOf = [k \in Logins |-> 0]
    /\ got = [k \in Logins |-> 0]
    /\ live = [h \in Hosts |-> 0]
    /\ flow = [h \in Hosts |-> 0]
    /\ shownUrl = [k \in Logins |-> FALSE]
    /\ indicator = FALSE /\ saved = {}
    /\ ck \in [Logins -> [srv : Answers, notified : {FALSE}, asked : {FALSE}, taken : {FALSE}]]
    /\ next = 1
    /\ badRedeem = FALSE /\ foreignTaken = FALSE
    /\ unread = FALSE /\ swapped = FALSE /\ gone = {}

\* endLogin(k): cancel its task, close its listener, forget it. No notice.
Ended(k) == [phase EXCEPT ![k] = "closed"]

\* The host's login, while it's under way.
SigningIn(h) == live[h] # 0 /\ Pending(live[h])

\* `/mcp login NAME` or `fx mcp login NAME` on the current host, or the same
\* login `add` starts for a new server that asks for one (verbs.zig
\* signInAfterAdd, app_mcp_runtime.zig signInAfterAdd). It waits while any
\* other host is alive. The engine starts a flow only when none is running.
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
    /\ UNCHANGED <<cur, alive, retired, leases, got, shownUrl, indicator, saved, ck, badRedeem, foreignTaken, unread, swapped, gone>>

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
    /\ UNCHANGED <<cur, alive, retired, leases, phase, hostOf, got, live, flow, saved, ck, next, badRedeem, foreignTaken, unread, swapped, gone>>

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
       ELSE UNCHANGED <<phase, got, foreignTaken, unread, swapped, gone>>
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, live, flow, shownUrl, indicator, saved, ck, next, badRedeem, unread, swapped, gone>>

\* finishLogin: the address the browser ended on, pasted. It goes to the engine
\* as it is, past the listener, so a wrong one fails the sign-in there.
Paste(k, s) ==
    /\ phase[k] = "open"
    /\ phase' = [phase EXCEPT ![k] = "consumed"]
    /\ got' = [got EXCEPT ![k] = s]
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, live, flow, shownUrl, indicator, saved, ck, next, badRedeem, foreignTaken, unread, swapped, gone>>

\* `.finish_login`: the engine checks the state against the live flow.
Handle(k) ==
    /\ phase[k] = "consumed" /\ alive[hostOf[k]] /\ live[hostOf[k]] = k
    /\ LET h == hostOf[k]
           ok == flow[h] # 0 /\ got[k] = flow[h]
       IN IF ok
          THEN /\ phase' = [phase EXCEPT ![k] = "redeeming"]
               /\ badRedeem' = (badRedeem \/ got[k] # flow[h])
               /\ UNCHANGED <<live, flow, indicator, unread, swapped, gone>>
          ELSE \* `.sign_in_failed`: endLogin, then the notice clears the line.
               /\ phase' = Ended(k)
               /\ live' = [live EXCEPT ![h] = 0]
               /\ flow' = [flow EXCEPT ![h] = 0]
               /\ indicator' = FALSE
               /\ UNCHANGED badRedeem
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, shownUrl, saved, ck, next, foreignTaken, unread, swapped, gone>>

\* The token endpoint answers the redemption. Failing: `.sign_in_failed`. A
\* token, with CheckFirst: the engine holds it and the host sends its check
\* request (Confirm); the login stays, with the shell's "Signing in". Without
\* CheckFirst (fx before the fix): the token is saved (a `credential` event)
\* and `.signed_in` is sent at once.
Redeemed(k, ok) ==
    /\ phase[k] = "redeeming" /\ alive[hostOf[k]]
    /\ LET h == hostOf[k]
       IN /\ flow' = [flow EXCEPT ![h] = 0]
          /\ IF ok /\ CheckFirst
             THEN /\ phase' = [phase EXCEPT ![k] = "confirming"]
                  /\ UNCHANGED <<live, indicator, saved, ck, unread, swapped, gone>>
             ELSE /\ phase' = Ended(k)
                  /\ live' = [live EXCEPT ![h] = 0]
                  /\ indicator' = FALSE
                  /\ saved' = IF ok THEN saved \cup {k} ELSE saved
                  /\ ck' = IF ok THEN [ck EXCEPT ![k].notified = TRUE] ELSE ck
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, shownUrl, next, badRedeem, foreignTaken, unread, swapped, gone>>

\* The server answers the check request with the new login's token (runtime.zig
\* `.signed_in`, once the engine's request with it ended). An accepted or an
\* unanswered one keeps the login, then reports it; a refused one reports the
\* refusal (`.sign_in_failed`) and the token goes with the login: it is never
\* saved.
Confirm(k) ==
    /\ phase[k] = "confirming" /\ alive[hostOf[k]]
    /\ LET h == hostOf[k]
           \* What the host acts on: a refusal the unreadable-store branch swallowed is
           \* no answer, and the sign-in ends by its timeout (a login kept, with a note).
           a == IF UnreadFirst /\ unread /\ ck[k].srv = "refuse" THEN "fail" ELSE ck[k].srv
       IN /\ phase' = Ended(k)
          /\ live' = [live EXCEPT ![h] = 0]
          /\ indicator' = FALSE
          /\ saved' = IF a # "refuse" THEN saved \cup {k} ELSE saved
          /\ ck' = [ck EXCEPT ![k].asked = TRUE, ![k].notified = (a # "refuse")]
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, flow, shownUrl, next, badRedeem, foreignTaken, unread, swapped, gone>>

\* Another fx process takes a login that is saved (pickUpLogin).
PickUp(k) ==
    /\ k \in saved /\ ~ck[k].taken
    /\ ck' = [ck EXCEPT ![k].taken = TRUE]
    /\ UNCHANGED <<cur, alive, retired, leases, phase, hostOf, got, live, flow, shownUrl, indicator, saved, next, badRedeem, foreignTaken, unread, swapped, gone>>

\* The host's read of the store of saved logins failed (restoreCredentials at the
\* start, adoptSaved for a server a reload added): `store_unread`.
StoreUnreadable ==
    /\ alive[cur] /\ ~unread
    /\ unread' = TRUE
    /\ UNCHANGED <<cur, alive, retired, leases, phase, hostOf, got, live, flow, shownUrl, indicator, saved, ck, next, badRedeem, foreignTaken, swapped, gone>>

\* The host reads the store again and takes a saved login (pickUpLogin, from the
\* `.auth_required` branch for an unreadable store, a tool request, a call, or a
\* status). A server with a login under way is skipped (`loginFor(i) != null`): what
\* the engine holds for a sign-in is never replaced by a saved login.
Reread ==
    /\ alive[cur] /\ ~SigningIn(cur)
    /\ unread' \in {unread, FALSE}
    /\ swapped' = (swapped \/ SigningIn(cur))
    /\ UNCHANGED <<cur, alive, retired, leases, phase, hostOf, got, live, flow, shownUrl, indicator, saved, ck, next, badRedeem, foreignTaken, gone>>

\* `/mcp logout NAME` (PR #1794 says how the revocation went; this is about the login): the
\* engine's tokens are signed out and revoked, and a login that waits for its check request goes
\* with them: runtime.zig `.logout` ends it (endLogin) with a `.sign_in_failed` notice, so the
\* check's answer has nothing to save and no \"Signed in\" follows. A login still waiting for its
\* browser is left as it is.
Logout ==
    /\ alive[cur]
    /\ IF SigningIn(cur) /\ phase[live[cur]] = "confirming"
       THEN /\ gone' = gone \cup {live[cur]}
            /\ phase' = Ended(live[cur])
            /\ live' = [live EXCEPT ![cur] = 0]
            /\ indicator' = FALSE
       ELSE UNCHANGED <<gone, phase, live, indicator>>
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, flow, shownUrl, saved, ck, next, badRedeem, foreignTaken, unread, swapped>>

\* expireLogins: the browser didn't come back in 5 minutes.
Expire(k) ==
    /\ Open(k) /\ alive[hostOf[k]] /\ live[hostOf[k]] = k
    /\ LET h == hostOf[k]
       IN /\ phase' = Ended(k)
          /\ live' = [live EXCEPT ![h] = 0]
          /\ flow' = [flow EXCEPT ![h] = 0]
          /\ indicator' = FALSE
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, shownUrl, saved, ck, next, badRedeem, foreignTaken, unread, swapped, gone>>

\* A host's end: Runtime.shutdown ends its logins, each with a
\* `.sign_in_failed` that clears the shell's "Signing in".
Gone(h, ph) == [k \in Logins |-> IF hostOf[k] = h /\ Pending(k) THEN "closed" ELSE ph[k]]
SignsIn(h) == \E k \in Logins : hostOf[k] = h /\ Pending(k)
GoneIndicator(h) == IF SignsIn(h) THEN FALSE ELSE indicator

Lease ==
    /\ alive[cur] /\ leases[cur] < MaxLeases
    /\ leases' = [leases EXCEPT ![cur] = @ + 1]
    /\ UNCHANGED <<cur, alive, retired, phase, hostOf, got, live, flow, shownUrl, indicator, saved, ck, next, badRedeem, foreignTaken, unread, swapped, gone>>

Release(h) ==
    /\ leases[h] > 0
    /\ leases' = [leases EXCEPT ![h] = @ - 1]
    /\ IF retired[h] /\ leases[h] = 1
       THEN /\ alive' = [alive EXCEPT ![h] = FALSE]
            /\ phase' = Gone(h, phase)
            /\ live' = [live EXCEPT ![h] = 0]
            /\ flow' = [flow EXCEPT ![h] = 0]
            /\ indicator' = GoneIndicator(h)
       ELSE UNCHANGED <<alive, phase, live, flow, indicator, unread, swapped, gone>>
    /\ UNCHANGED <<cur, retired, hostOf, got, shownUrl, saved, ck, next, badRedeem, foreignTaken, unread, swapped, gone>>

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
       ELSE UNCHANGED <<phase, live, indicator, unread, swapped, gone>>
    /\ flow' = [flow EXCEPT ![cur] = 0]
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, shownUrl, saved, ck, next, badRedeem, foreignTaken, unread, swapped, gone>>

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
    /\ UNCHANGED <<leases, hostOf, got, shownUrl, saved, ck, next, badRedeem, foreignTaken, unread, swapped, gone>>

Next ==
    \/ StartLogin
    \/ AgainLogin
    \/ \E k \in Logins : Authorize(k) \/ Handle(k) \/ Expire(k) \/ Redeemed(k, TRUE) \/ Redeemed(k, FALSE) \/ Confirm(k) \/ PickUp(k)
    \/ StoreUnreadable
    \/ Reread
    \/ Logout
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
                         /\ WF_vars(Redeemed(k, TRUE) \/ Redeemed(k, FALSE)) /\ WF_vars(Confirm(k))
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

\* Nor does a login that waits for its check request: its host's end ends it
\* too (Runtime.shutdown), with a `.sign_in_failed`.
NoPendingWithoutHost == \A k \in Logins : Pending(k) => alive[hostOf[k]]

\* One sign-in per server in each host.
OneSignInPerHost == \A h \in Hosts : Cardinality({k \in Logins : hostOf[k] = h /\ Pending(k)}) <= 1

\* "Signing in" implies a live listener, or a check request under way.
IndicatorImpliesListener == indicator => \E k \in Logins : Pending(k) /\ alive[hostOf[k]]

\* One sign-in per server, whatever hosts are alive.
OneSignInPerServer == Cardinality({k \in Logins : Pending(k)}) <= 1

\* The engine's live flow is the host's login, with its listener open: the
\* browser can come back to the sign-in the engine waits on.
FlowHasListener == \A h \in Hosts : flow[h] # 0 => live[h] = flow[h] /\ Open(flow[h])

\* A reload that leaves the server as it was leaves its sign-in going.
KeptSignInGoesOn == [][ReloadKeeps => \A k \in Logins : Open(k) => Open(k)']_vars

\* ---- What the server's answer decides (the fix) ----

\* "Signed in to NAME" comes only after the check request got its answer: a login
\* the server refused is never reported as signed in, and none is reported
\* before the server was asked.
SignedInOnlyAfterCheck == \A k \in Logins : ck[k].notified => ck[k].asked

\* The server never hears "Signed in" for a login it refuses.
NoticeMatchesAnswer == \A k \in Logins : ck[k].notified => ck[k].srv # "refuse"

\* A token the server refuses is never kept in the store.
RefusedNeverSaved == \A k \in Logins : ck[k].srv = "refuse" => k \notin saved

\* So no other fx process can take a login the server refuses
\* (SharedLogins.tla's pickUpLogin).
NeverTakeRefused == \A k \in Logins : ck[k].taken => ck[k].srv # "refuse"

\* A login the server accepted, or didn't answer (the note case), is kept and
\* reported once its request ended: the held save can't lose it.
AnsweredKeptAndReported == \A k \in Logins : (ck[k].asked /\ ck[k].srv # "refuse") => k \in saved /\ ck[k].notified

\* The login a sign-in holds is never replaced by one read from the store, so the
\* check request is answered for the token the person just got (PR #1793's re-read
\* skips a server with a login under way).
HeldNeverReplaced == ~swapped

\* A login a logout cut off is never saved or reported afterwards: the answer to its check
\* request finds no login waiting for it.
LoggedOutNeverSaved == \A k \in gone : k \notin saved /\ ~ck[k].notified

\* ---- Liveness ----

\* Every login started ends: signed in, failed, expired, or gone with its host.
EveryLoginEnds == \A k \in Logins : Open(k) ~> ~Open(k)

\* The shell's "Signing in" doesn't stay once nothing signs in.
IndicatorClears == indicator ~> ~indicator

\* The check request ends the sign-in, whatever the server does (its timeout).
ConfirmingEnds == \A k \in Logins : phase[k] = "confirming" ~> phase[k] # "confirming"
====

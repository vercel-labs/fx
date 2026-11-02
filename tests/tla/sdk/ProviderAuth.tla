---------------------------- MODULE ProviderAuth ----------------------------
(* The fetch edge that adds a provider's credentials to libfx requests:
   createChatgptAuthorizer and createSubscriptionAuthorizer with the Codex,
   Grok and custom-provider specs (sdk/chatgpt.js, sdk/subscription.js).

   One authorizer belongs to one engine, and libfx opens one engine per
   session. Each memory remembers, per access token the host supplied, the
   newest credentials refreshed from it (`desc`), and runs at most one refresh
   per refresh token at a time (`tasks`). Engines have their own memory, or,
   with SharedMemory, one agent's engines share one.

   The issuer rotates refresh tokens and treats a redeemed one as spent, as
   OpenAI and xAI do. The provider rejects the host's first access token when
   `Rejecting`, to drive the refresh-after-401 path.

   Every step sets `ev`, the event a run of the real code records at the same
   point, so AuthTrace.tla can replay observed runs through this Next. *)
EXTENDS Naturals, FiniteSets

CONSTANTS
  Provider,       \* "codex", "grok" or "custom"
  Engines,        \* one authorizer each
  Requests,       \* request ids
  EngineOf,       \* [Requests -> Engines]
  UrlOf,          \* [Requests -> {"provider", "other"}]
  Expiring,       \* the host's credentials are within the refresh window
  Rejecting,      \* the provider answers 401 to the host's first access token
  ForeignRefresh, \* the issuer may hand back another account's token (Grok)
  CheckAccount,   \* design: a refresh is refused when the account changed
  ScopeAll,       \* planted bug: the spec authorizes every URL
  NoSingleFlight, \* planted bug: concurrent refreshes do not share a task
  SharedMemory,   \* design: the engines share one memory (one agent)
  Recheck,        \* design: a 401 retries on newer credentials before refreshing
  Lock            \* design: the host's refreshLock serializes refreshes across memories

\* No token, and no account. Tokens are numbers, so the sentinel is one too.
NoTok == 999
NoAcct == "none"
Refreshable == Provider # "custom"
Accounts == {"A", "B"}

\* A credential: access token, refresh token, account, whether it is fresh.
Cred(at, rt, acct, fresh) == [at |-> at, rt |-> rt, acct |-> acct, fresh |-> fresh]
NoCred == Cred(NoTok, NoTok, NoAcct, TRUE)
Supplied0 == Cred(0, IF Refreshable THEN 0 ELSE NoTok, "A", ~Expiring)
NeedsRefresh(c) == c.rt # NoTok /\ ~c.fresh
Authorized(r) == ScopeAll \/ UrlOf[r] = "provider"
Mem(e) == IF SharedMemory THEN "agent" ELSE e
Memories == {Mem(e) : e \in Engines}

VARIABLES
  host,    \* what credentials() returns now
  spent,   \* refresh tokens the issuer has redeemed
  reused,  \* the issuer was sent a spent refresh token
  issued,  \* tokens issued so far; token n is "at-n"/"rt-n"
  acctOf,  \* account of each issued access token
  desc,    \* [Memories -> [Nat -> credential]] by supplied access token
  tasks,   \* in-flight refreshes
  req,     \* [Requests -> request record]
  ev       \* the event the last step produced

vars == <<host, spent, reused, issued, acctOf, desc, tasks, req, ev>>

Req(phase, supplied, used, sends, wait, status) ==
  [phase |-> phase, supplied |-> supplied, used |-> used, sends |-> sends, wait |-> wait, status |-> status]

\* A refresh task: engine, the credential being refreshed, the one supplied for
\* it, the result once the issuer answers, and its phase.
Task(e, cur, sup, next, phase) == [e |-> e, cur |-> cur, sup |-> sup, next |-> next, phase |-> phase]

Init ==
  /\ host = Supplied0
  /\ spent = {}
  /\ reused = FALSE
  /\ issued = 0
  /\ acctOf = [n \in {0} |-> "A"]
  /\ desc = [m \in Memories |-> [n \in {} |-> NoCred]]
  /\ tasks = {}
  /\ req = [r \in Requests |-> Req("new", NoCred, NoCred, 0, NoTok, 0)]
  /\ ev = [k |-> "init"]

\* The credential an engine uses for what the host supplied.
Best(e, s) == IF s.at \in DOMAIN desc[Mem(e)] THEN desc[Mem(e)][s.at] ELSE s

Running(e, rt) == {t \in tasks : Mem(t.e) = Mem(e) /\ t.cur.rt = rt /\ t.phase \in {"lock", "redeem", "verify", "save"}}

\* A task holds the host's lock from acquiring it until it saves or fails.
Holding == {t \in tasks : t.phase \in {"redeem", "verify", "save", "failed"}}

\* Joins the engine's refresh of `cur.rt`, or starts one.
StartOrJoin(e, cur, sup) ==
  IF Running(e, cur.rt) # {} /\ ~NoSingleFlight
  THEN tasks' = tasks
  ELSE tasks' = tasks \cup {Task(e, cur, sup, NoCred, IF Lock THEN "lock" ELSE "redeem")}

(* A request asks the host for credentials: credentials() resolves and the
   authorizer computes what it will use, starting a refresh when needed. A
   request to a URL the spec does not authorize is sent without asking. *)
Ask(r) ==
  LET e == EngineOf[r]
      best == Best(e, host)
  IN /\ req[r].phase = "new"
     /\ Authorized(r)
     /\ IF NeedsRefresh(best)
        THEN /\ StartOrJoin(e, best, host)
             /\ req' = [req EXCEPT ![r] = Req("wait", host, NoCred, 0, best.rt, 0)]
        ELSE /\ tasks' = tasks
             /\ req' = [req EXCEPT ![r] = Req("ready", host, best, 0, NoTok, 0)]
     /\ ev' = [k |-> "ask", r |-> r]
     /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc>>

Bypass(r) ==
  /\ req[r].phase = "new"
  /\ ~Authorized(r)
  /\ req' = [req EXCEPT ![r] = Req("ready", NoCred, NoCred, 0, NoTok, 0)]
  /\ ev' = [k |-> "bypass", r |-> r]
  /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc, tasks>>

(* With Lock, a refresh first takes the host's lock, then asks the host again:
   credentials another server saved meanwhile are used without a redemption. *)
Acquire(t) ==
  /\ t \in tasks
  /\ t.phase = "lock"
  /\ Holding = {}
  /\ LET newer == host.at # t.cur.at /\ host.at # t.sup.at /\ ~NeedsRefresh(host)
     IN tasks' = (tasks \ {t}) \cup {IF newer THEN [t EXCEPT !.next = host, !.phase = "save"] ELSE [t EXCEPT !.phase = "redeem"]}
  /\ ev' = [k |-> "acquire", e |-> t.e]
  /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc, req>>

(* The issuer redeems a refresh token: a fresh one rotates into new tokens,
   possibly for another account when ForeignRefresh; a spent one is refused. *)
Redeem(t) ==
  /\ t \in tasks
  /\ t.phase = "redeem"
  /\ IF t.cur.rt \in spent
     THEN /\ reused' = TRUE
          /\ tasks' = (tasks \ {t}) \cup {[t EXCEPT !.phase = "failed"]}
          /\ ev' = [k |-> "redeem", e |-> t.e, rt |-> t.cur.rt, ok |-> FALSE, acct |-> NoAcct]
          /\ UNCHANGED <<spent, issued, acctOf>>
     ELSE \E acct \in (IF ForeignRefresh THEN Accounts ELSE {"A"}):
          LET n == issued + 1
              next == Cred(n, n, acct, TRUE)
          IN /\ spent' = spent \cup {t.cur.rt}
             /\ issued' = n
             /\ acctOf' = [x \in DOMAIN acctOf \cup {n} |-> IF x = n THEN acct ELSE acctOf[x]]
             /\ tasks' = (tasks \ {t}) \cup {[t EXCEPT !.next = next, !.phase = IF Provider = "grok" THEN "verify" ELSE "save"]}
             /\ ev' = [k |-> "redeem", e |-> t.e, rt |-> t.cur.rt, ok |-> TRUE, acct |-> acct]
             /\ UNCHANGED reused
  /\ UNCHANGED <<host, desc, req>>

\* Grok: the refreshed token's account, from userinfo, must be the one refreshed.
Verify(t) ==
  /\ t \in tasks
  /\ t.phase = "verify"
  /\ LET refused == CheckAccount /\ t.next.acct # t.cur.acct
     IN tasks' = (tasks \ {t}) \cup {[t EXCEPT !.phase = IF refused THEN "failed" ELSE "save"]}
  /\ ev' = [k |-> "verify", e |-> t.e, at |-> t.next.at, acct |-> t.next.acct]
  /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc, req>>

(* The authorizer remembers the refreshed credentials for the supplied ones and
   hands them to onCredentials, which saves them to the host. Waiting requests
   then use them. *)
Save(t) ==
  /\ t \in tasks
  /\ t.phase = "save"
  /\ host' = t.next
  /\ desc' = [desc EXCEPT ![Mem(t.e)] = [x \in DOMAIN desc[Mem(t.e)] \cup {t.sup.at} |-> IF x = t.sup.at THEN t.next ELSE desc[Mem(t.e)][x]]]
  /\ tasks' = tasks \ {t}
  /\ req' = [r \in Requests |->
              IF Mem(EngineOf[r]) = Mem(t.e) /\ req[r].wait = t.cur.rt /\ req[r].phase \in {"wait", "rewait"}
              THEN [req[r] EXCEPT !.phase = "ready", !.used = t.next, !.wait = NoTok]
              ELSE req[r]]
  /\ ev' = [k |-> "save", e |-> t.e, at |-> t.next.at]
  /\ UNCHANGED <<spent, reused, issued, acctOf>>

\* A refresh that failed fails every request waiting on it.
Fail(t) ==
  /\ t \in tasks
  /\ t.phase = "failed"
  /\ tasks' = tasks \ {t}
  /\ req' = [r \in Requests |->
              IF Mem(EngineOf[r]) = Mem(t.e) /\ req[r].wait = t.cur.rt /\ req[r].phase \in {"wait", "rewait"}
              THEN [req[r] EXCEPT !.phase = "error", !.wait = NoTok]
              ELSE req[r]]
  /\ ev' = [k |-> "fail", e |-> t.e, rt |-> t.cur.rt]
  /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc>>

(* The provider answers. The host's first access token is rejected when
   Rejecting; a 401 is refreshed and resent once, if the credentials carry a
   refresh token. *)
Send(r) ==
  LET q == req[r]
      status == IF q.used.at = 0 /\ Rejecting THEN 401 ELSE 200
      retry == status = 401 /\ q.used.rt # NoTok /\ q.sends = 0
      e == EngineOf[r]
  IN /\ q.phase = "ready"
     /\ IF retry /\ Recheck
        THEN /\ tasks' = tasks
             /\ req' = [req EXCEPT ![r] = [q EXCEPT !.phase = "recheck", !.sends = 1, !.status = status]]
        ELSE IF retry
        THEN /\ StartOrJoin(e, q.used, q.supplied)
             /\ req' = [req EXCEPT ![r] = [q EXCEPT !.phase = "rewait", !.sends = 1, !.wait = q.used.rt, !.status = status]]
        ELSE /\ tasks' = tasks
             /\ req' = [req EXCEPT ![r] = [q EXCEPT !.phase = "done", !.sends = q.sends + 1, !.status = status]]
     /\ ev' = [k |-> "send", r |-> r, at |-> q.used.at, status |-> status]
     /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc>>

(* With Recheck, a rejected request asks the host again and looks for newer
   credentials, as a new request would. It resends on them when they differ
   from the rejected ones, and refreshes only when they do not. *)
RecheckAfter401(r) ==
  LET q == req[r]
      e == EngineOf[r]
      latest == Best(e, host)
  IN /\ q.phase = "recheck"
     /\ IF latest.at # q.used.at /\ NeedsRefresh(latest)
        THEN /\ StartOrJoin(e, latest, host)
             /\ req' = [req EXCEPT ![r] = [q EXCEPT !.phase = "rewait", !.supplied = host, !.wait = latest.rt]]
        ELSE IF latest.at # q.used.at
        THEN /\ tasks' = tasks
             /\ req' = [req EXCEPT ![r] = [q EXCEPT !.phase = "ready", !.supplied = host, !.used = latest]]
        ELSE /\ StartOrJoin(e, q.used, host)
             /\ req' = [req EXCEPT ![r] = [q EXCEPT !.phase = "rewait", !.supplied = host, !.wait = q.used.rt]]
     /\ ev' = [k |-> "ask", r |-> r]
     /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc>>

Next ==
  \/ \E r \in Requests : Ask(r) \/ Bypass(r) \/ Send(r) \/ RecheckAfter401(r)
  \/ \E t \in tasks : Acquire(t) \/ Redeem(t) \/ Verify(t) \/ Save(t) \/ Fail(t)

Spec == Init /\ [][Next]_vars

Done == \A r \in Requests : req[r].phase \in {"done", "error"}

---------------------------------------------------------------------------
(* Properties. *)

\* No refresh token reaches the issuer after it was redeemed.
NoRefreshReuse == ~reused

\* A request is sent at most twice: once, and once more after a 401.
AtMostOneResend == \A r \in Requests : req[r].sends <= 2

\* No request carries, and the host never saves, another account's token.
NoForeignToken ==
  /\ host.acct \in {"A", NoAcct}
  /\ \A r \in Requests : req[r].used.at = NoTok \/ acctOf[req[r].used.at] = "A"

\* A URL the spec does not authorize never carries credentials.
ScopedAuth == \A r \in Requests : UrlOf[r] = "other" => req[r].used.at = NoTok

\* A custom provider's key is never refreshed.
KeyNeverRefreshed == Provider = "custom" => issued = 0 /\ spent = {}

TypeOK ==
  /\ issued \in 0..4
  /\ \A r \in Requests : req[r].phase \in {"new", "wait", "ready", "rewait", "recheck", "done", "error"}
=============================================================================

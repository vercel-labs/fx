---- MODULE SharedLoginRefresh ----
\* fx processes that share one saved fx login, after the gateway answers a
\* request with 401 (src/core/auth/credentials.zig
\* refreshFxLoginCredentialLocked, reached from the 401 replay in
\* src/core/agent/runtime/orchestrator.zig).
\*
\* Each process holds the access token it last loaded. The saved login sits
\* behind one lock (src/core/auth/oauth_session.zig beginExistingMutation).
\* The issuer rotates the refresh token on every refresh and the gateway then
\* takes only the newest access token, so one process's refresh leaves every
\* other process holding a token the gateway rejects. Tokens are numbered by
\* the issuer's generation, and a redeemed refresh token is spent.
\*
\* After a 401 a process takes the lock and reads the saved login. It rotates
\* the login only when the saved token is the one the gateway rejected or is
\* past its refresh deadline; otherwise it adopts the saved login. Either way
\* it sends the request once more. The environment revokes or expires the
\* newest token, signs the login out, and kills a process at any step; the
\* kernel drops a killed holder's lock.
\*
\* Rules:
\*   NoRedundantRotation  fx never rotates a saved login the gateway still takes
\*   AdoptOnlyLive        fx never adopts a saved login past its refresh deadline
\*   NoSpentRefresh       the issuer sees a spent refresh token only after a
\*                        process died between redeeming one and saving what
\*                        it got back
\*   SignInOnlyWithCause  the saved login is gone only after a sign-out or
\*                        such a death
\*   Settles              every process that is not killed ends done or failed
\*
\* Planted mutants (check.sh): AlwaysRotate is fx before this change, which
\* rotated on every 401; DecideOutsideLock compares the rejected token with a
\* saved login read before taking the lock; AdoptExpired leaves out the
\* refresh deadline.
EXTENDS Naturals, FiniteSets

CONSTANTS
    Procs,              \* the fx processes
    MaxEnv,             \* how many environment events may happen
    AlwaysRotate,       \* mutant: rotate on every 401
    DecideOutsideLock,  \* mutant: decide on a saved login read before the lock
    AdoptExpired        \* mutant: adopt a saved login past its refresh deadline

None == "none"
NoLogin == 99
\* Every rotation the design makes replaces a token that died, and at most
\* MaxEnv die, so this bound never stops it; a mutant that rotates more is
\* caught before it reaches the bound.
MaxGen == MaxEnv + 1
Gens == 0..MaxGen
Terminal == {"done", "failed", "dead"}

VARIABLES
    gen,            \* the issuer's newest generation
    spent,          \* generations whose refresh token the issuer redeemed
    loginRevoked,   \* the issuer saw a spent refresh token and revoked the login
    revoked,        \* generations the gateway stopped taking
    expired,        \* generations past their refresh deadline
    saved,          \* the saved login's generation, or NoLogin
    lock,           \* the process holding the login's lock, or None
    pc,             \* each process's step
    held,           \* the generation each process sends
    rejected,       \* the generation each process's 401 rejected
    peek,           \* the saved generation a process read at its 401 (mutant only)
    got,            \* the generation the issuer handed a process
    envUsed,        \* environment events so far
    redundant,      \* a rotation replaced a token the gateway still took
    staleAdopt,     \* an adoption took a token past its refresh deadline
    reuse,          \* the issuer saw a spent refresh token
    diedMidRotation,\* a process died after redeeming and before saving
    signedOut       \* the environment signed the login out

vars == <<gen, spent, loginRevoked, revoked, expired, saved, lock, pc, held,
          rejected, peek, got, envUsed, redundant, staleAdopt, reuse,
          diedMidRotation, signedOut>>

Accepts(t) == ~loginRevoked /\ t = gen /\ t \notin revoked /\ t \notin expired

TypeOK ==
    /\ gen \in Gens
    /\ spent \subseteq Gens
    /\ revoked \subseteq Gens
    /\ expired \subseteq Gens
    /\ saved \in Gens \cup {NoLogin}
    /\ lock \in Procs \cup {None}
    /\ pc \in [Procs -> {"new", "idle", "waitlock", "locked", "redeeming",
                         "saving", "replay", "done", "failed", "dead"}]
    /\ held \in [Procs -> Gens \cup {NoLogin}]
    /\ rejected \in [Procs -> Gens \cup {NoLogin}]
    /\ peek \in [Procs -> Gens \cup {NoLogin}]
    /\ got \in [Procs -> Gens \cup {NoLogin}]

Init ==
    /\ gen = 0
    /\ spent = {}
    /\ loginRevoked = FALSE
    /\ revoked = {}
    /\ expired = {}
    /\ saved = 0
    /\ lock = None
    /\ pc = [p \in Procs |-> "new"]
    /\ held = [p \in Procs |-> NoLogin]
    /\ rejected = [p \in Procs |-> NoLogin]
    /\ peek = [p \in Procs |-> NoLogin]
    /\ got = [p \in Procs |-> NoLogin]
    /\ envUsed = 0
    /\ redundant = FALSE
    /\ staleAdopt = FALSE
    /\ reuse = FALSE
    /\ diedMidRotation = FALSE
    /\ signedOut = FALSE

\* fx starts and loads the saved login.
Start(p) ==
    /\ pc[p] = "new"
    /\ IF saved = NoLogin
         THEN pc' = [pc EXCEPT ![p] = "failed"] /\ UNCHANGED held
         ELSE pc' = [pc EXCEPT ![p] = "idle"] /\ held' = [held EXCEPT ![p] = saved]
    /\ UNCHANGED <<gen, spent, loginRevoked, revoked, expired, saved, lock, rejected,
                   peek, got, envUsed, redundant, staleAdopt, reuse, diedMidRotation, signedOut>>

\* The request goes out; a 401 sends the process for the lock.
Send(p) ==
    /\ pc[p] = "idle"
    /\ IF Accepts(held[p])
         THEN pc' = [pc EXCEPT ![p] = "done"] /\ UNCHANGED <<rejected, peek>>
         ELSE /\ pc' = [pc EXCEPT ![p] = "waitlock"]
              /\ rejected' = [rejected EXCEPT ![p] = held[p]]
              /\ peek' = [peek EXCEPT ![p] = saved]
    /\ UNCHANGED <<gen, spent, loginRevoked, revoked, expired, saved, lock, held,
                   got, envUsed, redundant, staleAdopt, reuse, diedMidRotation, signedOut>>

TakeLock(p) ==
    /\ pc[p] = "waitlock"
    /\ lock = None
    /\ lock' = p
    /\ pc' = [pc EXCEPT ![p] = "locked"]
    /\ UNCHANGED <<gen, spent, loginRevoked, revoked, expired, saved, held, rejected,
                   peek, got, envUsed, redundant, staleAdopt, reuse, diedMidRotation, signedOut>>

\* Under the lock: no saved login means sign in; otherwise rotate or adopt.
Decide(p) ==
    /\ pc[p] = "locked"
    /\ IF saved = NoLogin
         THEN /\ pc' = [pc EXCEPT ![p] = "failed"]
              /\ lock' = None
              /\ UNCHANGED <<held, staleAdopt>>
         ELSE LET seen == IF DecideOutsideLock THEN peek[p] ELSE saved
                  rotate == \/ AlwaysRotate
                            \/ seen = rejected[p]
                            \/ (~AdoptExpired /\ saved \in expired)
              IN IF rotate
                   THEN /\ pc' = [pc EXCEPT ![p] = "redeeming"]
                        /\ UNCHANGED <<lock, held, staleAdopt>>
                   ELSE /\ held' = [held EXCEPT ![p] = saved]
                        /\ staleAdopt' = (staleAdopt \/ saved \in expired)
                        /\ pc' = [pc EXCEPT ![p] = "replay"]
                        /\ lock' = None
    /\ UNCHANGED <<gen, spent, loginRevoked, revoked, expired, saved, rejected, peek,
                   got, envUsed, redundant, reuse, diedMidRotation, signedOut>>

\* The issuer redeems the saved refresh token. A spent one revokes the login
\* and fx retires it.
Redeem(p) ==
    /\ pc[p] = "redeeming"
    /\ gen < MaxGen
    /\ redundant' = (redundant \/ Accepts(saved))
    /\ IF loginRevoked \/ saved \in spent
         THEN /\ reuse' = (reuse \/ saved \in spent)
              /\ loginRevoked' = TRUE
              /\ saved' = NoLogin
              /\ pc' = [pc EXCEPT ![p] = "failed"]
              /\ lock' = None
              /\ UNCHANGED <<gen, spent, got>>
         ELSE /\ gen' = gen + 1
              /\ spent' = spent \cup {saved}
              /\ got' = [got EXCEPT ![p] = gen + 1]
              /\ pc' = [pc EXCEPT ![p] = "saving"]
              /\ UNCHANGED <<reuse, loginRevoked, saved, lock>>
    /\ UNCHANGED <<revoked, expired, held, rejected, peek, envUsed, staleAdopt,
                   diedMidRotation, signedOut>>

\* fx saves what the issuer handed it and lets the lock go.
Save(p) ==
    /\ pc[p] = "saving"
    /\ saved' = got[p]
    /\ held' = [held EXCEPT ![p] = got[p]]
    /\ pc' = [pc EXCEPT ![p] = "replay"]
    /\ lock' = None
    /\ UNCHANGED <<gen, spent, loginRevoked, revoked, expired, rejected, peek, got,
                   envUsed, redundant, staleAdopt, reuse, diedMidRotation, signedOut>>

\* The one resend after a 401; a second 401 ends the request.
Replay(p) ==
    /\ pc[p] = "replay"
    /\ pc' = [pc EXCEPT ![p] = IF Accepts(held[p]) THEN "done" ELSE "failed"]
    /\ UNCHANGED <<gen, spent, loginRevoked, revoked, expired, saved, lock, held,
                   rejected, peek, got, envUsed, redundant, staleAdopt, reuse,
                   diedMidRotation, signedOut>>

ProcStep(p) == Start(p) \/ Send(p) \/ TakeLock(p) \/ Decide(p) \/ Redeem(p) \/ Save(p) \/ Replay(p)

EnvOk == envUsed < MaxEnv

\* The gateway stops taking the newest token.
RevokeNewest ==
    /\ EnvOk
    /\ gen \notin revoked
    /\ revoked' = revoked \cup {gen}
    /\ envUsed' = envUsed + 1
    /\ UNCHANGED <<gen, spent, loginRevoked, expired, saved, lock, pc, held, rejected,
                   peek, got, redundant, staleAdopt, reuse, diedMidRotation, signedOut>>

\* The newest token passes its refresh deadline.
ExpireNewest ==
    /\ EnvOk
    /\ gen \notin expired
    /\ expired' = expired \cup {gen}
    /\ envUsed' = envUsed + 1
    /\ UNCHANGED <<gen, spent, loginRevoked, revoked, saved, lock, pc, held, rejected,
                   peek, got, redundant, staleAdopt, reuse, diedMidRotation, signedOut>>

\* The user signs out somewhere else, which takes the lock to delete the login.
SignOut ==
    /\ EnvOk
    /\ lock = None
    /\ saved # NoLogin
    /\ saved' = NoLogin
    /\ signedOut' = TRUE
    /\ revoked' = revoked \cup {gen}
    /\ envUsed' = envUsed + 1
    /\ UNCHANGED <<gen, spent, loginRevoked, expired, lock, pc, held, rejected, peek,
                   got, redundant, staleAdopt, reuse, diedMidRotation>>

\* A process dies at any step; the kernel drops its lock.
Kill(p) ==
    /\ EnvOk
    /\ pc[p] \notin Terminal
    /\ pc' = [pc EXCEPT ![p] = "dead"]
    /\ lock' = IF lock = p THEN None ELSE lock
    /\ diedMidRotation' = (diedMidRotation \/ pc[p] = "saving")
    /\ envUsed' = envUsed + 1
    /\ UNCHANGED <<gen, spent, loginRevoked, revoked, expired, saved, held, rejected,
                   peek, got, redundant, staleAdopt, reuse, signedOut>>

Settled == \A p \in Procs : pc[p] \in Terminal

Next ==
    \/ \E p \in Procs : ProcStep(p) \/ Kill(p)
    \/ RevokeNewest \/ ExpireNewest \/ SignOut
    \/ (Settled /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars /\ \A p \in Procs : WF_vars(ProcStep(p))

NoRedundantRotation == ~redundant
AdoptOnlyLive == ~staleAdopt
NoSpentRefresh == reuse => diedMidRotation
SignInOnlyWithCause == saved = NoLogin => (signedOut \/ diedMidRotation)
Settles == <>Settled

\* Witnesses that the model reaches what the E2E tests drive: two processes
\* share one rotation, and one adopts a login another saved.
NoSharedRotation == ~(gen = 1 /\ \A p \in Procs : pc[p] = "done" /\ held[p] = 1)
NoAdoption == \A p \in Procs : ~(pc[p] = "done" /\ held[p] # rejected[p] /\ rejected[p] # NoLogin /\ got[p] = NoLogin)
====

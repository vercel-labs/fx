---- MODULE GeminiDpopRefresh ----
\* Two designs for fx processes sharing one Google Gemini DPoP-bound login:
\*   Design "A": cross-process lock (mirrors src/core/auth/subscription_session.zig
\*               beginExistingMutation), reading and writing tokens + DPoP nonce
\*               atomically under the lock.
\*   Design "B": no lock; each process keeps the DPoP nonce in memory, reads the
\*               saved record without a lock, refreshes, and writes back.
\*
\* Rules:
\*   NonceRetryAtMostOnce  one refresh attempt sends at most 2 token requests
\*   NoSpentRefresh        the issuer never sees a spent refresh token, unless a
\*                         process died between redeeming and saving
\*   NoLostUpdate          the saved record's refresh generation never goes backwards
\*   NoStaleOverwrite      a save never replaces a saved access generation or
\*                         saved nonce with an older one
\*   SignOutSticks         after SignOut deletes the login, no refresh write
\*                         restores it
\*   ClearOnlyWithCause    the saved login is deleted only after invalid_grant or
\*                         sign-out (never after offline/429/5xx)
\*   NoUseAfterExpiry      after the grant expires, no process ends "done" with a
\*                         token it got after expiry
\*   Settles               every process not killed ends done, failed, or needs_sign_in

EXTENDS Naturals, FiniteSets

CONSTANTS
    Procs,                  \* the fx processes
    MaxEnv,                 \* bound on environment events
    Design,                 \* "A" (shared lock) or "B" (no lock)
    RotatesRefresh,         \* BOOLEAN: whether /token rotates the refresh token
    MutantUnboundedRetry,   \* mutant: omit the 1-retry cap on use_dpop_nonce
    MutantClearOnOffline,   \* mutant: clear saved login on offline/429/5xx
    MutantDecideOutsideLock,\* mutant: read saved record before taking the lock
    MutantSignOutUnlocked   \* mutant: SignOut deletes login without taking the lock

ASSUME Design \in {"A", "B"}
ASSUME RotatesRefresh \in BOOLEAN
ASSUME MutantUnboundedRetry \in BOOLEAN
ASSUME MutantClearOnOffline \in BOOLEAN
ASSUME MutantDecideOutsideLock \in BOOLEAN
ASSUME MutantSignOutUnlocked \in BOOLEAN

None == "none"
NoLogin == 99
MaxGen == MaxEnv + Cardinality(Procs) + 1
Gens == 0..MaxGen
MaxNonce == MaxEnv + Cardinality(Procs) + 2
Nonces == 0..MaxNonce
Terminal == {"done", "failed", "needs_sign_in", "dead"}

VARIABLES
    \* Issuer / server state
    issuerAccessGen,    \* newest access token generation
    issuerRefreshGen,   \* newest refresh token generation
    spentRefresh,       \* set of spent refresh generations (when RotatesRefresh)
    loginRevoked,       \* issuer revoked the login due to spent refresh token
    serverNonce,        \* current DPoP-Nonce expected by /token
    grantExpired,       \* 7-day grant expired
    accessExpired,      \* set of access generations past their refresh deadline
    signedOut,          \* user signed out

    \* Shared disk state (saved login record)
    \* saved = NoLogin when cleared, otherwise [access: Nat, refresh: Nat, nonce: Nat]
    savedAccess,
    savedRefresh,
    savedNonce,
    lock,               \* process holding the cross-process lock, or None

    \* Per-process state
    pc,                 \* step of each process
    heldAccess,         \* access generation held by process
    rejectedAccess,     \* access generation rejected with 401
    memNonce,           \* in-memory DPoP nonce (Design B, or Design A during retry)
    peekAccess,         \* saved access read before lock (MutantDecideOutsideLock)
    peekRefresh,        \* saved refresh read before lock (MutantDecideOutsideLock / Design B)
    gotAccess,          \* access generation returned by /token
    gotRefresh,         \* refresh generation returned by /token
    gotNonce,           \* DPoP-Nonce returned by /token
    reqCount,           \* number of /token requests sent in current refresh attempt
    gotAfterExpiry,     \* TRUE if process obtained a token from /token after grantExpired

    \* Environment & ghost/audit state
    envUsed,
    diedMidRotation,    \* a process died after redeeming and before saving
    clearedWithoutCause,\* saved login was cleared without invalid_grant or signOut
    lostUpdate,         \* savedRefresh went backwards
    staleOverwrite,     \* a save replaced savedAccess or savedNonce with an older one
    reuse               \* issuer saw a spent refresh token

vars == <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked, serverNonce,
          grantExpired, accessExpired, signedOut, savedAccess, savedRefresh, savedNonce,
          lock, pc, heldAccess, rejectedAccess, memNonce, peekAccess, peekRefresh,
          gotAccess, gotRefresh, gotNonce, reqCount, gotAfterExpiry, envUsed,
          diedMidRotation, clearedWithoutCause, lostUpdate, staleOverwrite, reuse>>

HasSaved == savedAccess # NoLogin

AcceptsAccess(t) ==
    /\ ~loginRevoked
    /\ ~signedOut
    /\ t # NoLogin
    /\ t = issuerAccessGen
    /\ t \notin accessExpired

TypeOK ==
    /\ issuerAccessGen \in Gens
    /\ issuerRefreshGen \in Gens
    /\ spentRefresh \subseteq Gens
    /\ loginRevoked \in BOOLEAN
    /\ serverNonce \in Nonces
    /\ grantExpired \in BOOLEAN
    /\ accessExpired \subseteq Gens
    /\ signedOut \in BOOLEAN
    /\ savedAccess \in Gens \cup {NoLogin}
    /\ savedRefresh \in Gens \cup {NoLogin}
    /\ savedNonce \in Nonces \cup {NoLogin}
    /\ lock \in Procs \cup {None}
    /\ pc \in [Procs -> {"new", "idle", "waitlock", "locked", "redeeming",
                         "saving", "replay", "done", "failed", "needs_sign_in", "dead"}]
    /\ heldAccess \in [Procs -> Gens \cup {NoLogin}]
    /\ rejectedAccess \in [Procs -> Gens \cup {NoLogin}]
    /\ memNonce \in [Procs -> Nonces]
    /\ peekAccess \in [Procs -> Gens \cup {NoLogin}]
    /\ peekRefresh \in [Procs -> Gens \cup {NoLogin}]
    /\ gotAccess \in [Procs -> Gens \cup {NoLogin}]
    /\ gotRefresh \in [Procs -> Gens \cup {NoLogin}]
    /\ gotNonce \in [Procs -> Nonces]
    /\ reqCount \in [Procs -> 0..(MaxEnv + 3)]
    /\ gotAfterExpiry \in [Procs -> BOOLEAN]
    /\ staleOverwrite \in BOOLEAN

Init ==
    /\ issuerAccessGen = 0
    /\ issuerRefreshGen = 0
    /\ spentRefresh = {}
    /\ loginRevoked = FALSE
    /\ serverNonce \in {0, 1}
    /\ grantExpired = FALSE
    /\ accessExpired \in {{}, {0}}
    /\ signedOut = FALSE
    /\ savedAccess = 0
    /\ savedRefresh = 0
    /\ savedNonce = 0
    /\ lock = None
    /\ pc = [p \in Procs |-> "new"]
    /\ heldAccess = [p \in Procs |-> NoLogin]
    /\ rejectedAccess = [p \in Procs |-> NoLogin]
    /\ memNonce = [p \in Procs |-> 0]
    /\ peekAccess = [p \in Procs |-> NoLogin]
    /\ peekRefresh = [p \in Procs |-> NoLogin]
    /\ gotAccess = [p \in Procs |-> NoLogin]
    /\ gotRefresh = [p \in Procs |-> NoLogin]
    /\ gotNonce = [p \in Procs |-> 0]
    /\ reqCount = [p \in Procs |-> 0]
    /\ gotAfterExpiry = [p \in Procs |-> FALSE]
    /\ envUsed = 0
    /\ diedMidRotation = FALSE
    /\ clearedWithoutCause = FALSE
    /\ lostUpdate = FALSE
    /\ staleOverwrite = FALSE
    /\ reuse = FALSE

\* Process starts and loads the saved login.
Start(p) ==
    /\ pc[p] = "new"
    /\ IF ~HasSaved
         THEN /\ pc' = [pc EXCEPT ![p] = "needs_sign_in"]
              /\ UNCHANGED <<heldAccess, memNonce>>
         ELSE /\ pc' = [pc EXCEPT ![p] = "idle"]
              /\ heldAccess' = [heldAccess EXCEPT ![p] = savedAccess]
              /\ memNonce' = [memNonce EXCEPT ![p] = savedNonce]
    /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked, serverNonce,
                   grantExpired, accessExpired, signedOut, savedAccess, savedRefresh, savedNonce,
                   lock, rejectedAccess, peekAccess, peekRefresh, gotAccess, gotRefresh, gotNonce,
                   reqCount, gotAfterExpiry, envUsed, diedMidRotation, clearedWithoutCause,
                   lostUpdate, staleOverwrite, reuse>>

\* Process sends an API request; 401 or <300s remaining triggers refresh.
Send(p) ==
    /\ pc[p] = "idle"
    /\ IF AcceptsAccess(heldAccess[p])
         THEN /\ pc' = [pc EXCEPT ![p] = "done"]
              /\ UNCHANGED <<rejectedAccess, peekAccess, peekRefresh, reqCount>>
         ELSE /\ rejectedAccess' = [rejectedAccess EXCEPT ![p] = heldAccess[p]]
              /\ peekAccess' = [peekAccess EXCEPT ![p] = savedAccess]
              /\ peekRefresh' = [peekRefresh EXCEPT ![p] = savedRefresh]
              /\ reqCount' = [reqCount EXCEPT ![p] = 0]
              /\ pc' = [pc EXCEPT ![p] = IF Design = "A" THEN "waitlock" ELSE "locked"]
    /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked, serverNonce,
                   grantExpired, accessExpired, signedOut, savedAccess, savedRefresh, savedNonce,
                   lock, heldAccess, memNonce, gotAccess, gotRefresh, gotNonce, gotAfterExpiry,
                   envUsed, diedMidRotation, clearedWithoutCause, lostUpdate, staleOverwrite, reuse>>

TakeLock(p) ==
    /\ Design = "A"
    /\ pc[p] = "waitlock"
    /\ lock = None
    /\ lock' = p
    /\ pc' = [pc EXCEPT ![p] = "locked"]
    /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked, serverNonce,
                   grantExpired, accessExpired, signedOut, savedAccess, savedRefresh, savedNonce,
                   heldAccess, rejectedAccess, memNonce, peekAccess, peekRefresh, gotAccess,
                   gotRefresh, gotNonce, reqCount, gotAfterExpiry, envUsed, diedMidRotation,
                   clearedWithoutCause, lostUpdate, staleOverwrite, reuse>>

\* Decide whether to adopt the saved access token or refresh.
Decide(p) ==
    /\ pc[p] = "locked"
    /\ LET seenAccess == IF (Design = "B" \/ MutantDecideOutsideLock)
                           THEN peekAccess[p]
                           ELSE savedAccess
           seenRefresh == IF (Design = "B" \/ MutantDecideOutsideLock)
                            THEN peekRefresh[p]
                            ELSE savedRefresh
       IN IF ~HasSaved \/ seenAccess = NoLogin \/ seenRefresh = NoLogin
            THEN /\ pc' = [pc EXCEPT ![p] = "needs_sign_in"]
                 /\ lock' = IF Design = "A" THEN None ELSE lock
                 /\ UNCHANGED <<heldAccess, memNonce, peekRefresh>>
            ELSE LET canAdopt == /\ seenAccess # rejectedAccess[p]
                                 /\ seenAccess \notin accessExpired
                 IN IF Design = "A" /\ canAdopt
                      THEN /\ heldAccess' = [heldAccess EXCEPT ![p] = savedAccess]
                           /\ pc' = [pc EXCEPT ![p] = "replay"]
                           /\ lock' = None
                           /\ UNCHANGED <<memNonce, peekRefresh>>
                      ELSE /\ memNonce' = [memNonce EXCEPT ![p] = IF Design = "A" THEN savedNonce ELSE memNonce[p]]
                           /\ peekRefresh' = [peekRefresh EXCEPT ![p] = seenRefresh]
                           /\ pc' = [pc EXCEPT ![p] = "redeeming"]
                           /\ UNCHANGED <<lock, heldAccess>>
    /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked, serverNonce,
                   grantExpired, accessExpired, signedOut, savedAccess, savedRefresh, savedNonce,
                   rejectedAccess, peekAccess, gotAccess, gotRefresh, gotNonce, reqCount,
                   gotAfterExpiry, envUsed, diedMidRotation, clearedWithoutCause, lostUpdate, staleOverwrite, reuse>>

\* POST /token with DPoP proof carrying memNonce[p] and refresh token peekRefresh[p].
Redeem(p) ==
    /\ pc[p] = "redeeming"
    /\ issuerAccessGen < MaxGen
    /\ issuerRefreshGen < MaxGen
    /\ reqCount[p] < MaxEnv + 3
    /\ LET rTok == peekRefresh[p]
           nextReq == reqCount[p] + 1
       IN
       \* Case 1: 7-day grant expired -> 400 invalid_grant, clear saved login.
       \/ /\ grantExpired
          /\ reqCount' = [reqCount EXCEPT ![p] = nextReq]
          /\ savedAccess' = NoLogin
          /\ savedRefresh' = NoLogin
          /\ savedNonce' = NoLogin
          /\ pc' = [pc EXCEPT ![p] = "needs_sign_in"]
          /\ lock' = IF Design = "A" THEN None ELSE lock
          /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked,
                         serverNonce, memNonce, gotAccess, gotRefresh, gotNonce,
                         gotAfterExpiry, envUsed, clearedWithoutCause, reuse>>
       \* Case 2: offline / 429 / 5xx transient failure (bounded by EnvOk).
       \/ /\ ~grantExpired
          /\ envUsed < MaxEnv
          /\ envUsed' = envUsed + 1
          /\ reqCount' = [reqCount EXCEPT ![p] = nextReq]
          /\ IF MutantClearOnOffline
               THEN /\ savedAccess' = NoLogin
                    /\ savedRefresh' = NoLogin
                    /\ savedNonce' = NoLogin
                    /\ clearedWithoutCause' = TRUE
                    /\ pc' = [pc EXCEPT ![p] = "needs_sign_in"]
               ELSE /\ pc' = [pc EXCEPT ![p] = "failed"]
                    /\ UNCHANGED <<savedAccess, savedRefresh, savedNonce, clearedWithoutCause>>
          /\ lock' = IF Design = "A" THEN None ELSE lock
          /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked,
                         serverNonce, memNonce, gotAccess, gotRefresh, gotNonce,
                         gotAfterExpiry, reuse>>
       \* Case 3: stale DPoP nonce -> 400 use_dpop_nonce + new DPoP-Nonce header.
       \/ /\ ~grantExpired
          /\ memNonce[p] # serverNonce
          /\ reqCount' = [reqCount EXCEPT ![p] = nextReq]
          /\ IF MutantUnboundedRetry \/ reqCount[p] = 0
               THEN /\ memNonce' = [memNonce EXCEPT ![p] = serverNonce]
                    /\ pc' = [pc EXCEPT ![p] = "redeeming"]
                    /\ lock' = lock
               ELSE /\ pc' = [pc EXCEPT ![p] = "failed"]
                    /\ lock' = IF Design = "A" THEN None ELSE lock
                    /\ UNCHANGED memNonce
          /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked,
                         serverNonce, savedAccess, savedRefresh, savedNonce,
                         gotAccess, gotRefresh, gotNonce, gotAfterExpiry, envUsed,
                         clearedWithoutCause, reuse>>
       \* Case 4: valid nonce, not expired -> check refresh token.
       \/ /\ ~grantExpired
          /\ memNonce[p] = serverNonce
          /\ reqCount' = [reqCount EXCEPT ![p] = nextReq]
          /\ IF loginRevoked \/ (RotatesRefresh /\ rTok \in spentRefresh)
               THEN /\ reuse' = (reuse \/ (RotatesRefresh /\ rTok \in spentRefresh))
                    /\ loginRevoked' = TRUE
                    /\ savedAccess' = NoLogin
                    /\ savedRefresh' = NoLogin
                    /\ savedNonce' = NoLogin
                    /\ pc' = [pc EXCEPT ![p] = "needs_sign_in"]
                    /\ lock' = IF Design = "A" THEN None ELSE lock
                    /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh,
                                   serverNonce, memNonce, gotAccess, gotRefresh, gotNonce,
                                   gotAfterExpiry>>
               ELSE /\ issuerAccessGen' = issuerAccessGen + 1
                    /\ issuerRefreshGen' = IF RotatesRefresh THEN issuerRefreshGen + 1 ELSE issuerRefreshGen
                    /\ spentRefresh' = IF RotatesRefresh THEN spentRefresh \cup {rTok} ELSE spentRefresh
                    /\ serverNonce' = IF serverNonce < MaxNonce THEN serverNonce + 1 ELSE serverNonce
                    /\ gotAccess' = [gotAccess EXCEPT ![p] = issuerAccessGen + 1]
                    /\ gotRefresh' = [gotRefresh EXCEPT ![p] = IF RotatesRefresh THEN issuerRefreshGen + 1 ELSE rTok]
                    /\ gotNonce' = [gotNonce EXCEPT ![p] = IF serverNonce < MaxNonce THEN serverNonce + 1 ELSE serverNonce]
                    /\ gotAfterExpiry' = [gotAfterExpiry EXCEPT ![p] = grantExpired]
                    /\ pc' = [pc EXCEPT ![p] = "saving"]
                    /\ UNCHANGED <<loginRevoked, savedAccess, savedRefresh, savedNonce,
                                   lock, memNonce, reuse>>
          /\ UNCHANGED <<envUsed, clearedWithoutCause>>
    /\ UNCHANGED <<grantExpired, accessExpired, signedOut, heldAccess, rejectedAccess,
                   peekAccess, peekRefresh, diedMidRotation, lostUpdate, staleOverwrite>>

\* Atomically write new tokens + rotated DPoP-Nonce, then release lock (if Design A).
Save(p) ==
    /\ pc[p] = "saving"
    /\ lostUpdate' = (lostUpdate \/ (savedRefresh # NoLogin /\ gotRefresh[p] < savedRefresh))
    /\ staleOverwrite' = (staleOverwrite \/ (HasSaved /\ (gotAccess[p] < savedAccess \/ gotNonce[p] < savedNonce)))
    /\ savedAccess' = gotAccess[p]
    /\ savedRefresh' = gotRefresh[p]
    /\ savedNonce' = gotNonce[p]
    /\ heldAccess' = [heldAccess EXCEPT ![p] = gotAccess[p]]
    /\ memNonce' = [memNonce EXCEPT ![p] = gotNonce[p]]
    /\ pc' = [pc EXCEPT ![p] = "replay"]
    /\ lock' = IF Design = "A" THEN None ELSE lock
    /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked, serverNonce,
                   grantExpired, accessExpired, signedOut, rejectedAccess, peekAccess,
                   peekRefresh, gotAccess, gotRefresh, gotNonce, reqCount, gotAfterExpiry,
                   envUsed, diedMidRotation, clearedWithoutCause, reuse>>

Replay(p) ==
    /\ pc[p] = "replay"
    /\ pc' = [pc EXCEPT ![p] = IF AcceptsAccess(heldAccess[p]) THEN "done" ELSE "failed"]
    /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked, serverNonce,
                   grantExpired, accessExpired, signedOut, savedAccess, savedRefresh, savedNonce,
                   lock, heldAccess, rejectedAccess, memNonce, peekAccess, peekRefresh,
                   gotAccess, gotRefresh, gotNonce, reqCount, gotAfterExpiry, envUsed,
                   diedMidRotation, clearedWithoutCause, lostUpdate, staleOverwrite, reuse>>

ProcStep(p) ==
    Start(p) \/ Send(p) \/ TakeLock(p) \/ Decide(p) \/ Redeem(p) \/ Save(p) \/ Replay(p)

EnvOk == envUsed < MaxEnv

RotateServerNonce ==
    /\ EnvOk
    /\ serverNonce < MaxNonce
    /\ serverNonce' = serverNonce + 1
    /\ envUsed' = envUsed + 1
    /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked, grantExpired,
                   accessExpired, signedOut, savedAccess, savedRefresh, savedNonce, lock, pc,
                   heldAccess, rejectedAccess, memNonce, peekAccess, peekRefresh, gotAccess,
                   gotRefresh, gotNonce, reqCount, gotAfterExpiry, diedMidRotation,
                   clearedWithoutCause, lostUpdate, staleOverwrite, reuse>>

ExpireAccess ==
    /\ EnvOk
    /\ issuerAccessGen \notin accessExpired
    /\ accessExpired' = accessExpired \cup {issuerAccessGen}
    /\ envUsed' = envUsed + 1
    /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked, serverNonce,
                   grantExpired, signedOut, savedAccess, savedRefresh, savedNonce, lock, pc,
                   heldAccess, rejectedAccess, memNonce, peekAccess, peekRefresh, gotAccess,
                   gotRefresh, gotNonce, reqCount, gotAfterExpiry, diedMidRotation,
                   clearedWithoutCause, lostUpdate, staleOverwrite, reuse>>

ExpireGrant ==
    /\ EnvOk
    /\ ~grantExpired
    /\ grantExpired' = TRUE
    /\ envUsed' = envUsed + 1
    /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked, serverNonce,
                   accessExpired, signedOut, savedAccess, savedRefresh, savedNonce, lock, pc,
                   heldAccess, rejectedAccess, memNonce, peekAccess, peekRefresh, gotAccess,
                   gotRefresh, gotNonce, reqCount, gotAfterExpiry, diedMidRotation,
                   clearedWithoutCause, lostUpdate, staleOverwrite, reuse>>

SignOut ==
    /\ EnvOk
    /\ (Design = "B" \/ MutantSignOutUnlocked \/ lock = None)
    /\ HasSaved
    /\ savedAccess' = NoLogin
    /\ savedRefresh' = NoLogin
    /\ savedNonce' = NoLogin
    /\ signedOut' = TRUE
    /\ envUsed' = envUsed + 1
    /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked, serverNonce,
                   grantExpired, accessExpired, lock, pc, heldAccess, rejectedAccess, memNonce,
                   peekAccess, peekRefresh, gotAccess, gotRefresh, gotNonce, reqCount,
                   gotAfterExpiry, diedMidRotation, clearedWithoutCause, lostUpdate, staleOverwrite, reuse>>

Kill(p) ==
    /\ EnvOk
    /\ pc[p] \notin Terminal
    /\ pc' = [pc EXCEPT ![p] = "dead"]
    /\ lock' = IF lock = p THEN None ELSE lock
    /\ diedMidRotation' = (diedMidRotation \/ pc[p] = "saving")
    /\ envUsed' = envUsed + 1
    /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked, serverNonce,
                   grantExpired, accessExpired, signedOut, savedAccess, savedRefresh, savedNonce,
                   heldAccess, rejectedAccess, memNonce, peekAccess, peekRefresh, gotAccess,
                   gotRefresh, gotNonce, reqCount, gotAfterExpiry, clearedWithoutCause,
                   lostUpdate, staleOverwrite, reuse>>

Settled == \A p \in Procs : pc[p] \in Terminal

Next ==
    \/ \E p \in Procs : ProcStep(p) \/ Kill(p)
    \/ RotateServerNonce \/ ExpireAccess \/ ExpireGrant \/ SignOut
    \/ (Settled /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars /\ \A p \in Procs : WF_vars(ProcStep(p))

\* Invariants
NonceRetryAtMostOnce == \A p \in Procs : reqCount[p] <= 2
NoSpentRefresh == reuse => diedMidRotation
NoLostUpdate == ~lostUpdate
NoStaleOverwrite == ~staleOverwrite
SignOutSticks == signedOut => ~HasSaved
ClearOnlyWithCause == ~clearedWithoutCause
NoUseAfterExpiry == \A p \in Procs : (pc[p] = "done") => ~gotAfterExpiry[p]

\* Liveness
Settles == <>Settled
====

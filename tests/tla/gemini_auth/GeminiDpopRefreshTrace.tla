---- MODULE GeminiDpopRefreshTrace ----
\* Real runs of fx processes that share one Google Gemini DPoP-bound plan login
\* (`google-auth.json` under `google-auth.lock`), checked against Design A of
\* GeminiDpopRefresh.tla. tests/tla/drivers/gemini_auth/trace.ts writes
\* TraceObs.tla from the ordered log of what the fake Google server, the disk
\* observer, and the harness saw:
\*   api_send {p, access}               p sent /v1beta/interactions:createPerUserQuota
\*                                      with access token generation `access`
\*   api_answer {p, access, ok}         fake Gemini accepted it (`ok`) or answered 401
\*   token_req {p, rt, nonce}           p sent POST /token with refresh gen `rt` and
\*                                      DPoP proof nonce `nonce` (-1 if absent)
\*   token_nonce {p, nonce}             /token answered 400 use_dpop_nonce with `nonce`
\*   token_ok {p, access, rt, nonce}    /token answered 200 with new tokens and nonce
\*   token_invalid_grant {p}            /token answered 400 invalid_grant
\*   token_fail {p, status}             /token answered transient failure (503) or
\*                                      stalled/timed out (0)
\*   save {access, rt, nonce}           saved record written atomically to disk
\*   clear {none}                       saved record deleted without sign-out
\*   sign_out {none}                    sign-out (`fx logout google`) removed record
\*   kill {p}                           harness killed process `p` by PID
\*
\* Rules (matching GeminiDpopRefresh.tla Design A):
\*   NonceRetryAtMostOnce  at most 2 /token requests per refresh attempt
\*   NoSpentRefresh        no spent refresh token redeemed unless a process died
\*                         between /token 200 and saving
\*   NoLostUpdate          saved refresh generation never goes backwards
\*   NoStaleOverwrite      saved access generation or nonce never goes backwards
\*   ClearOnlyWithCause    saved login cleared only after invalid_grant or sign_out
\*   SignOutSticks         no save restores the login after sign_out
EXTENDS Integers, Sequences, FiniteSets, TraceObs

VARIABLES
    i,
    bad,
    issuerAccessGen,
    issuerRefreshGen,
    spentRefresh,
    loginRevoked,
    serverNonce,
    signedOut,
    knownAccess,
    hasSaved,
    savedAccess,
    savedRefresh,
    savedNonce,
    diedMidRotation,
    invalidGrantSeen,
    pc,
    apiSends,
    rejectedOnce,
    inTokenReq,
    reqCount,
    lastRt,
    pendingSave,
    expectedAccess,
    expectedRt,
    expectedNonce

TraceInit ==
    /\ i = 0
    /\ bad = {}
    /\ issuerAccessGen = ObsInitAccess
    /\ issuerRefreshGen = ObsInitRefresh
    /\ spentRefresh = {}
    /\ loginRevoked = FALSE
    /\ serverNonce = ObsServerNonce
    /\ signedOut = FALSE
    /\ knownAccess = {ObsInitAccess}
    /\ hasSaved = TRUE
    /\ savedAccess = ObsInitAccess
    /\ savedRefresh = ObsInitRefresh
    /\ savedNonce = ObsInitNonce
    /\ diedMidRotation = FALSE
    /\ invalidGrantSeen = FALSE
    /\ pc = [p \in ObsProcs |-> "idle"]
    /\ apiSends = [p \in ObsProcs |-> 0]
    /\ rejectedOnce = [p \in ObsProcs |-> FALSE]
    /\ inTokenReq = [p \in ObsProcs |-> FALSE]
    /\ reqCount = [p \in ObsProcs |-> 0]
    /\ lastRt = [p \in ObsProcs |-> -1]
    /\ pendingSave = [p \in ObsProcs |-> FALSE]
    /\ expectedAccess = [p \in ObsProcs |-> -1]
    /\ expectedRt = [p \in ObsProcs |-> -1]
    /\ expectedNonce = [p \in ObsProcs |-> -1]

Broken(r) ==
    LET d == r.data IN
    CASE r.event = "token_req" ->
            (IF reqCount[d.p] >= 2 THEN {"NonceRetryAtMostOnce"} ELSE {}) \cup
            (IF ObsRotatesRefresh /\ d.rt \in spentRefresh /\ ~diedMidRotation
                THEN {"NoSpentRefresh"} ELSE {})
      [] r.event = "token_invalid_grant" ->
            IF ObsRotatesRefresh /\ lastRt[d.p] \in spentRefresh /\ ~diedMidRotation
                THEN {"NoSpentRefresh"} ELSE {}
      [] r.event = "save" ->
            (IF hasSaved /\ d.rt < savedRefresh THEN {"NoLostUpdate"} ELSE {}) \cup
            (IF hasSaved /\ (d.access < savedAccess \/ d.nonce < savedNonce)
                THEN {"NoStaleOverwrite"} ELSE {}) \cup
            (IF signedOut THEN {"SignOutSticks"} ELSE {})
      [] r.event = "clear" ->
            IF ~invalidGrantSeen /\ ~signedOut THEN {"ClearOnlyWithCause"} ELSE {}
      [] OTHER -> {}

Step(r) ==
    LET d == r.data IN
    CASE r.event = "api_send" ->
            /\ d.p \in ObsProcs
            /\ pc[d.p] \in {"idle", "replay"}
            /\ ~pendingSave[d.p]
            /\ apiSends[d.p] < 2
            /\ (apiSends[d.p] = 1 => rejectedOnce[d.p])
            /\ d.access \in knownAccess
            /\ pc' = [pc EXCEPT ![d.p] = "api_wait"]
            /\ apiSends' = [apiSends EXCEPT ![d.p] = @ + 1]
            /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked,
                           serverNonce, signedOut, knownAccess, hasSaved, savedAccess,
                           savedRefresh, savedNonce, diedMidRotation, invalidGrantSeen,
                           rejectedOnce, inTokenReq, reqCount, lastRt, pendingSave,
                           expectedAccess, expectedRt, expectedNonce>>
      [] r.event = "api_answer" ->
            /\ d.p \in ObsProcs
            /\ pc[d.p] = "api_wait"
            /\ pc' = [pc EXCEPT ![d.p] = IF d.ok THEN "done" ELSE "idle"]
            /\ rejectedOnce' = [rejectedOnce EXCEPT ![d.p] = @ \/ ~d.ok]
            /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked,
                           serverNonce, signedOut, knownAccess, hasSaved, savedAccess,
                           savedRefresh, savedNonce, diedMidRotation, invalidGrantSeen,
                           apiSends, inTokenReq, reqCount, lastRt, pendingSave,
                           expectedAccess, expectedRt, expectedNonce>>
      [] r.event = "token_req" ->
            /\ d.p \in ObsProcs
            /\ pc[d.p] \in {"idle", "redeeming"}
            /\ ~inTokenReq[d.p]
            /\ ~pendingSave[d.p]
            /\ d.rt >= 0
            /\ pc' = [pc EXCEPT ![d.p] = "redeeming"]
            /\ inTokenReq' = [inTokenReq EXCEPT ![d.p] = TRUE]
            /\ reqCount' = [reqCount EXCEPT ![d.p] = @ + 1]
            /\ lastRt' = [lastRt EXCEPT ![d.p] = d.rt]
            /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked,
                           serverNonce, signedOut, knownAccess, hasSaved, savedAccess,
                           savedRefresh, savedNonce, diedMidRotation, invalidGrantSeen,
                           apiSends, rejectedOnce, pendingSave, expectedAccess,
                           expectedRt, expectedNonce>>
      [] r.event = "token_nonce" ->
            /\ d.p \in ObsProcs
            /\ pc[d.p] = "redeeming"
            /\ inTokenReq[d.p]
            /\ inTokenReq' = [inTokenReq EXCEPT ![d.p] = FALSE]
            /\ serverNonce' = d.nonce
            /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked,
                           signedOut, knownAccess, hasSaved, savedAccess, savedRefresh,
                           savedNonce, diedMidRotation, invalidGrantSeen, pc, apiSends,
                           rejectedOnce, reqCount, lastRt, pendingSave, expectedAccess,
                           expectedRt, expectedNonce>>
      [] r.event = "token_ok" ->
            /\ d.p \in ObsProcs
            /\ pc[d.p] = "redeeming"
            /\ inTokenReq[d.p]
            /\ inTokenReq' = [inTokenReq EXCEPT ![d.p] = FALSE]
            /\ pc' = [pc EXCEPT ![d.p] = "saving"]
            /\ pendingSave' = [pendingSave EXCEPT ![d.p] = TRUE]
            /\ expectedAccess' = [expectedAccess EXCEPT ![d.p] = d.access]
            /\ expectedRt' = [expectedRt EXCEPT ![d.p] = d.rt]
            /\ expectedNonce' = [expectedNonce EXCEPT ![d.p] = d.nonce]
            /\ issuerAccessGen' = d.access
            /\ issuerRefreshGen' = d.rt
            /\ spentRefresh' = IF ObsRotatesRefresh THEN spentRefresh \cup {lastRt[d.p]} ELSE spentRefresh
            /\ serverNonce' = d.nonce
            /\ knownAccess' = knownAccess \cup {d.access}
            /\ UNCHANGED <<loginRevoked, signedOut, hasSaved, savedAccess, savedRefresh,
                           savedNonce, diedMidRotation, invalidGrantSeen, apiSends,
                           rejectedOnce, reqCount, lastRt>>
      [] r.event = "token_invalid_grant" ->
            /\ d.p \in ObsProcs
            /\ pc[d.p] = "redeeming"
            /\ inTokenReq[d.p]
            /\ inTokenReq' = [inTokenReq EXCEPT ![d.p] = FALSE]
            /\ pc' = [pc EXCEPT ![d.p] = "needs_sign_in"]
            /\ reqCount' = [reqCount EXCEPT ![d.p] = 0]
            /\ invalidGrantSeen' = TRUE
            /\ loginRevoked' = TRUE
            /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, serverNonce,
                           signedOut, knownAccess, hasSaved, savedAccess, savedRefresh,
                           savedNonce, diedMidRotation, apiSends, rejectedOnce, lastRt,
                           pendingSave, expectedAccess, expectedRt, expectedNonce>>
      [] r.event = "token_fail" ->
            /\ d.p \in ObsProcs
            /\ pc[d.p] = "redeeming"
            /\ inTokenReq[d.p]
            /\ inTokenReq' = [inTokenReq EXCEPT ![d.p] = FALSE]
            /\ pc' = [pc EXCEPT ![d.p] = "failed"]
            /\ reqCount' = [reqCount EXCEPT ![d.p] = 0]
            /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked,
                           serverNonce, signedOut, knownAccess, hasSaved, savedAccess,
                           savedRefresh, savedNonce, diedMidRotation, invalidGrantSeen,
                           apiSends, rejectedOnce, lastRt, pendingSave, expectedAccess,
                           expectedRt, expectedNonce>>
      [] r.event = "save" ->
            /\ \E p \in ObsProcs :
                /\ pendingSave[p]
                /\ expectedAccess[p] = d.access
                /\ expectedRt[p] = d.rt
                /\ expectedNonce[p] = d.nonce
            /\ LET p == CHOOSE q \in ObsProcs :
                        /\ pendingSave[q]
                        /\ expectedAccess[q] = d.access
                        /\ expectedRt[q] = d.rt
                        /\ expectedNonce[q] = d.nonce
               IN /\ pendingSave' = [pendingSave EXCEPT ![p] = FALSE]
                  /\ pc' = [pc EXCEPT ![p] = "replay"]
                  /\ reqCount' = [reqCount EXCEPT ![p] = 0]
            /\ hasSaved' = TRUE
            /\ savedAccess' = d.access
            /\ savedRefresh' = d.rt
            /\ savedNonce' = d.nonce
            /\ invalidGrantSeen' = FALSE
            /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked,
                           serverNonce, signedOut, knownAccess, diedMidRotation, apiSends,
                           rejectedOnce, inTokenReq, lastRt, expectedAccess, expectedRt,
                           expectedNonce>>
      [] r.event = "clear" ->
            /\ hasSaved
            /\ hasSaved' = FALSE
            /\ savedAccess' = -1
            /\ savedRefresh' = -1
            /\ savedNonce' = -1
            /\ invalidGrantSeen' = FALSE
            /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked,
                           serverNonce, signedOut, knownAccess, diedMidRotation, pc,
                           apiSends, rejectedOnce, inTokenReq, reqCount, lastRt,
                           pendingSave, expectedAccess, expectedRt, expectedNonce>>
      [] r.event = "sign_out" ->
            /\ signedOut' = TRUE
            /\ hasSaved' = FALSE
            /\ savedAccess' = -1
            /\ savedRefresh' = -1
            /\ savedNonce' = -1
            /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked,
                           serverNonce, knownAccess, diedMidRotation, invalidGrantSeen, pc,
                           apiSends, rejectedOnce, inTokenReq, reqCount, lastRt,
                           pendingSave, expectedAccess, expectedRt, expectedNonce>>
      [] r.event = "kill" ->
            /\ d.p \in ObsProcs
            /\ pc[d.p] # "dead"
            /\ diedMidRotation' = (diedMidRotation \/ pendingSave[d.p])
            /\ pc' = [pc EXCEPT ![d.p] = "dead"]
            /\ inTokenReq' = [inTokenReq EXCEPT ![d.p] = FALSE]
            /\ pendingSave' = [pendingSave EXCEPT ![d.p] = FALSE]
            /\ UNCHANGED <<issuerAccessGen, issuerRefreshGen, spentRefresh, loginRevoked,
                           serverNonce, signedOut, knownAccess, hasSaved, savedAccess,
                           savedRefresh, savedNonce, invalidGrantSeen, apiSends,
                           rejectedOnce, reqCount, lastRt, expectedAccess, expectedRt,
                           expectedNonce>>
      [] OTHER -> FALSE

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ Step(ObsTrace[i + 1])
    /\ bad' = bad \cup Broken(ObsTrace[i + 1])
    /\ i' = i + 1

\* Sentinels for drivers/gemini_auth/trace.ts: TLC reports NotDone violated
\* when the whole trace matches, NotDoneClean when it matches keeping every
\* rule, and NotDoneDirty when it matches breaking one.
NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====

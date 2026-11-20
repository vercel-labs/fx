------------------------ MODULE AcpSessionReaders -----------------------------
(***************************************************************************)
(* Two readers of one session in fx acp: its owner's connection and a      *)
(* follower's connection. Each reader can begin a request: a prompt (a      *)
(* turn, or a delivery into the running one), a withdrawal, a cancel, or a  *)
(* reap of a finished turn. The owner can also close the session. A turn's *)
(* worker thread runs, then ends. The model counts the threads that are    *)
(* spawned and joined, the turns that are freed, and the uses that readers *)
(* hold of the session.                                                    *)
(*                                                                         *)
(* Rules = FALSE is fx today with a second reader added. Each reader reads *)
(* the prompt slot without a lock and acts on that read. A reap joins and  *)
(* frees the turn before it clears the slot. The follower keeps no use     *)
(* count, and a close frees the session without waiting for anyone.        *)
(*                                                                         *)
(* Rules = TRUE is the design (narrow design A). It is NOT LANDED: no code  *)
(* in fx has these claim, wait and retain steps yet. A close sets closing  *)
(* in the same step that begins it. A start claims the slot under the line  *)
(* lock, waits while a taken turn is joining, and spawns the thread outside *)
(* the lock. A reap takes the finished turn out of the slot under that     *)
(* lock, marks it joining, and joins and frees it outside the lock. A      *)
(* follower's request retains the session under the shared table's lock    *)
(* and releases it after the request. A close (1) sets closing and         *)
(* unregisters, (2) waits until no follower uses the session, (3) cancels, *)
(* takes the turn and joins it, and (4) frees the session.                 *)
(*                                                                         *)
(* Code the steps follow today (server.zig, by function name):             *)
(* - dispatch: session/prompt reads session.prompt without a lock before   *)
(*   it calls handleDeliveryPrompt or startPrompt.                         *)
(* - dispatch and dispatchNotification: reapPrompts runs before a request. *)
(*   It reaps the connection's own sessions only.                          *)
(* - handleDeliveryPrompt: the line lock and worker_running. Its .start    *)
(*   arm reaps, then starts.                                               *)
(* - startPrompt: worker_running and the steering open under the line lock;*)
(*   the thread spawn; the failed-spawn cleanup; session.prompt is set     *)
(*   after the spawn.                                                      *)
(* - reapSessionPrompt: session.prompt is read, the thread is joined,      *)
(*   freeActivePrompt frees the turn, and session.prompt is cleared.       *)
(* - withdrawSessionRequest: session.prompt is read before the line lock,  *)
(*   and the turn's fields are read under it.                              *)
(* - handleCancel: cancelForUser under the line lock; then the worker nudge.*)
(* - promptWorkerMain: worker_running is cleared and reapable is set under *)
(*   the line lock; the last answers are sent after that.                  *)
(* - cancelAndReapPrompt, closeSession and destroySession: the cancel, the *)
(*   reap, then the unregister from the shared table (shared.unregister),  *)
(*   dropFollowersAtClose, and the frees.                                  *)
(* - followedElsewhere and followSharedSession: the lookup under           *)
(*   shared.mutex.                                                         *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxTurns,   \* the turns the model runs, one after another
    MaxReq,     \* the requests each reader begins
    Rules       \* TRUE: the design; FALSE: fx today

Owner == "owner"
Follower == "follower"
Readers == {Owner, Follower}
Turns == 1..MaxTurns
Requests == {"prompt", "withdraw", "cancel", "reap"}
Kinds == {"none", "prompt", "withdraw", "cancel", "reap", "close"}
TStates == {"unborn", "claimed", "unclaimed", "spawned", "done", "joined"}
PCs == {"idle", "check", "reapFirst", "retry", "joinOwn", "freeOwn", "spawn",
        "deliver", "startToday", "setSlot", "wTouch", "release",
        "cDetach", "cWait", "cCancel", "cTake", "cJoin", "cFreeT",
        "cDetachT", "cFree"}

VARIABLES
    slot,       \* the turn in session.prompt, or 0 (none)
    tcount,     \* the turns created so far
    tstate,     \* per turn: its thread's state (see TStates)
    joins,      \* per turn: how many joins it received
    tfreed,     \* per turn: its ActivePrompt has been freed
    pc,         \* per reader: the step it is at
    kind,       \* per reader: the request it runs
    ptr,        \* per reader: the turn it holds, or 0
    reqs,       \* per reader: the requests it has begun
    users,      \* the uses the followers hold of the session (design only)
    closing,    \* the session refuses new turns (design: set with the close's begin)
    registered, \* the session is in the shared table
    closeBegun, \* ghost: a close has started
    freed,      \* the session's storage has been freed
    joining,    \* design: a taken turn is being joined; claims and reaps wait
    claimAfterClose \* ghost: a claim ran while closing was TRUE

vars == <<slot, tcount, tstate, joins, tfreed, pc, kind, ptr, reqs, users,
          closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* The slot's status: none, claimed (spawn pending), spawned (running), or
\* done (reapable). The design's claim, reap and deliver read it under the
\* line lock; today's read it unlocked.
SlotStatus == IF slot = 0 THEN "none" ELSE tstate[slot]

\* A follower's request retains the session (design only).
Retains(r) == Rules /\ r = Follower

Init ==
    /\ slot = 0
    /\ tcount = 0
    /\ tstate = [t \in Turns |-> "unborn"]
    /\ joins = [t \in Turns |-> 0]
    /\ tfreed = [t \in Turns |-> FALSE]
    /\ pc = [r \in Readers |-> "idle"]
    /\ kind = [r \in Readers |-> "none"]
    /\ ptr = [r \in Readers |-> 0]
    /\ reqs = [r \in Readers |-> 0]
    /\ users = 0
    /\ closing = FALSE
    /\ registered = TRUE
    /\ closeBegun = FALSE
    /\ freed = FALSE
    /\ joining = FALSE
    /\ claimAfterClose = FALSE

-----------------------------------------------------------------------------
\* A reader begins a request. The owner's requests stop once its close begins,
\* because its own connection runs the close. A follower's request needs the
\* session in the shared table (followedElsewhere and followSharedSession), and
\* the design retains it there. A reap is the owner's own dispatch step
\* (reapPrompts), so only the owner begins one.
BeginRequest(r, k) ==
    /\ pc[r] = "idle"
    /\ reqs[r] < MaxReq
    /\ (k = "reap") => (r = Owner)
    /\ IF r = Owner THEN ~closeBegun ELSE registered
    /\ pc' = [pc EXCEPT ![r] = IF k = "reap" THEN "reapFirst" ELSE "check"]
    /\ kind' = [kind EXCEPT ![r] = k]
    /\ reqs' = [reqs EXCEPT ![r] = reqs[r] + 1]
    /\ users' = IF Retains(r) THEN users + 1 ELSE users
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, closing,
                   registered, closeBegun, freed, joining, claimAfterClose>>

\* The owner's close begins (handleCloseSession, closeSession). The design sets
\* closing in this same step, as closeSession's first act under the line lock,
\* so no claim can run between the close's begin and the refusal of claims.
\* Today has no closing flag, so closing stays FALSE there.
BeginClose ==
    /\ pc[Owner] = "idle"
    /\ ~closeBegun
    /\ closeBegun' = TRUE
    /\ closing' = Rules
    /\ kind' = [kind EXCEPT ![Owner] = "close"]
    /\ pc' = [pc EXCEPT ![Owner] = IF Rules THEN "cDetach" ELSE "cCancel"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, reqs, users,
                   registered, freed, joining, claimAfterClose>>

-----------------------------------------------------------------------------
\* Design: a closing session refuses a start at once (startPrompt, under the
\* line lock, with the closing test).
ClaimRefuse(r) ==
    /\ kind[r] = "prompt"
    /\ pc[r] \in {"check", "retry"}
    /\ closing
    /\ pc' = [pc EXCEPT ![r] = "release"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, kind, ptr, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* Design: a start claims the slot under the line lock, and spawns the thread
\* after the lock (startPrompt). The guard ~joining is the wait: in code the
\* reader waits on the line mutex's condition until the join's free clears
\* joining, so a second turn starts only after the first is joined.
\* claimAfterClose records a claim that runs while closing is TRUE (the
\* mutant that drops the closing test sets it).
ClaimNew(r) ==
    /\ kind[r] = "prompt"
    /\ pc[r] \in {"check", "retry"}
    /\ ~closing
    /\ ~joining
    /\ slot = 0
    /\ tcount < MaxTurns
    /\ tcount' = tcount + 1
    /\ slot' = tcount + 1
    /\ tstate' = [tstate EXCEPT ![tcount + 1] = "claimed"]
    /\ ptr' = [ptr EXCEPT ![r] = tcount + 1]
    /\ pc' = [pc EXCEPT ![r] = "spawn"]
    /\ claimAfterClose' = (claimAfterClose \/ closing)
    /\ UNCHANGED <<joins, tfreed, kind, reqs, users, closing, registered,
                   closeBegun, freed, joining>>

\* Design: the model's turn bound refuses a start beyond MaxTurns. It waits
\* while a taken turn is joining, as ClaimNew does.
ClaimFull(r) ==
    /\ kind[r] = "prompt"
    /\ pc[r] \in {"check", "retry"}
    /\ ~closing
    /\ ~joining
    /\ slot = 0
    /\ tcount = MaxTurns
    /\ pc' = [pc EXCEPT ![r] = "release"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* Design: a finished turn in the slot is reaped first (the .start arm of
\* handleDeliveryPrompt). It waits while another turn is joining.
ClaimReap(r) ==
    /\ kind[r] = "prompt"
    /\ pc[r] \in {"check", "retry"}
    /\ ~closing
    /\ ~joining
    /\ SlotStatus = "done"
    /\ pc' = [pc EXCEPT ![r] = "reapFirst"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* Design: a running or claimed turn takes the delivery path (handleDeliveryPrompt).
\* It waits while a taken turn is joining.
ClaimDeliver(r) ==
    /\ kind[r] = "prompt"
    /\ pc[r] \in {"check", "retry"}
    /\ ~closing
    /\ ~joining
    /\ SlotStatus \in {"claimed", "spawned"}
    /\ pc' = [pc EXCEPT ![r] = "deliver"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* Design: the reap takes the finished turn out of the slot under the line lock,
\* and marks it joining until its free. The join and the free happen outside the
\* lock. A reap waits while another turn is joining (the guard ~joining).
ReapTake(r) ==
    /\ pc[r] = "reapFirst"
    /\ ~joining
    /\ SlotStatus = "done"
    /\ ptr' = [ptr EXCEPT ![r] = slot]
    /\ slot' = 0
    /\ pc' = [pc EXCEPT ![r] = "joinOwn"]
    /\ joining' = TRUE
    /\ UNCHANGED <<tcount, tstate, joins, tfreed, kind, reqs, users, closing,
                   registered, closeBegun, freed, claimAfterClose>>

\* Design: nothing to reap now. A prompt tries its claim again, and a reap ends.
ReapRetry(r) ==
    /\ pc[r] = "reapFirst"
    /\ SlotStatus # "done"
    /\ pc' = [pc EXCEPT ![r] = IF kind[r] = "reap" THEN "release" ELSE "retry"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* The join of the taken turn (reapSessionPrompt). The turn's thread must have
\* ended: a join of a thread still running is not enabled here. A second join
\* of a turn is recorded, because the join is undefined behavior there.
JoinOwn(r) ==
    /\ pc[r] = "joinOwn"
    /\ tstate[ptr[r]] \in {"done", "joined"}
    /\ joins' = [joins EXCEPT ![ptr[r]] = joins[ptr[r]] + 1]
    /\ tstate' = [tstate EXCEPT ![ptr[r]] = "joined"]
    /\ pc' = [pc EXCEPT ![r] = "freeOwn"]
    /\ UNCHANGED <<slot, tcount, tfreed, kind, ptr, reqs, users, closing,
                   registered, closeBegun, freed, joining, claimAfterClose>>

\* Design: the free (freeActivePrompt). The slot was already taken, so it is
\* cleared only if it still names this turn. The free ends the joining mark.
FreeOwn(r) ==
    /\ pc[r] = "freeOwn"
    /\ tfreed' = [tfreed EXCEPT ![ptr[r]] = TRUE]
    /\ slot' = IF slot = ptr[r] THEN 0 ELSE slot
    /\ ptr' = [ptr EXCEPT ![r] = 0]
    /\ pc' = [pc EXCEPT ![r] = IF kind[r] = "reap" THEN "release" ELSE "retry"]
    /\ joining' = FALSE
    /\ UNCHANGED <<tcount, tstate, joins, kind, reqs, users, closing, registered,
                   closeBegun, freed, claimAfterClose>>

\* The thread is spawned (startPrompt). It ends later (WorkerEnd).
Spawn(r) ==
    /\ pc[r] = "spawn"
    /\ tstate' = [tstate EXCEPT ![ptr[r]] = "spawned"]
    /\ ptr' = [ptr EXCEPT ![r] = 0]
    /\ pc' = [pc EXCEPT ![r] = "release"]
    /\ UNCHANGED <<slot, tcount, joins, tfreed, kind, reqs, users, closing,
                   registered, closeBegun, freed, joining, claimAfterClose>>

\* A failed spawn releases the claim under the line lock (the failed-spawn cleanup
\* in startPrompt).
SpawnFail(r) ==
    /\ pc[r] = "spawn"
    /\ tstate' = [tstate EXCEPT ![ptr[r]] = "unclaimed"]
    /\ slot' = IF slot = ptr[r] THEN 0 ELSE slot
    /\ ptr' = [ptr EXCEPT ![r] = 0]
    /\ pc' = [pc EXCEPT ![r] = "release"]
    /\ UNCHANGED <<tcount, joins, tfreed, kind, reqs, users, closing, registered,
                   closeBegun, freed, joining, claimAfterClose>>

\* A delivery into the running turn: a steer, or a queued prompt
\* (handleDeliveryPrompt). It touches the session, not a turn it holds.
Deliver(r) ==
    /\ pc[r] = "deliver"
    /\ pc' = [pc EXCEPT ![r] = "release"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* Design: a withdrawal reads the slot and the turn under the line lock
\* (withdrawSessionRequest).
WithdrawLocked(r) ==
    /\ kind[r] = "withdraw"
    /\ pc[r] = "check"
    /\ pc' = [pc EXCEPT ![r] = "release"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* A cancel stops the running turn under the line lock (handleCancel's
\* cancelForUser).
CancelTouch(r) ==
    /\ kind[r] = "cancel"
    /\ pc[r] = "check"
    /\ pc' = [pc EXCEPT ![r] = "release"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* A reader ends its request. A follower releases the use it retained.
Release(r) ==
    /\ pc[r] = "release"
    /\ pc' = [pc EXCEPT ![r] = "idle"]
    /\ kind' = [kind EXCEPT ![r] = "none"]
    /\ users' = IF Retains(r) THEN users - 1 ELSE users
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, reqs, closing,
                   registered, closeBegun, freed, joining, claimAfterClose>>

\* The design's steps of one reader.
DesignStep(r) ==
    \/ ClaimRefuse(r)
    \/ ClaimNew(r)
    \/ ClaimFull(r)
    \/ ClaimReap(r)
    \/ ClaimDeliver(r)
    \/ ReapTake(r)
    \/ ReapRetry(r)
    \/ JoinOwn(r)
    \/ FreeOwn(r)
    \/ Spawn(r)
    \/ SpawnFail(r)
    \/ Deliver(r)
    \/ WithdrawLocked(r)
    \/ CancelTouch(r)
    \/ Release(r)

-----------------------------------------------------------------------------
\* Today: the start reads the slot without a lock (dispatch, session/prompt). A
\* check that finds a running turn takes the delivery path. Otherwise the start
\* spawns (startPrompt) and sets the slot after the spawn. Nothing re-checks it.
CheckToday(r) ==
    /\ kind[r] = "prompt"
    /\ pc[r] = "check"
    /\ pc' = [pc EXCEPT ![r] =
            IF SlotStatus = "none" THEN "startToday"
            ELSE IF SlotStatus = "done" THEN "reapFirst"
            ELSE "deliver"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* Today: the spawn of the new turn (startPrompt). The debug assert that the
\* slot is empty at its start is not modeled.
StartToday(r) ==
    /\ pc[r] = "startToday"
    /\ tcount < MaxTurns
    /\ tcount' = tcount + 1
    /\ tstate' = [tstate EXCEPT ![tcount + 1] = "spawned"]
    /\ ptr' = [ptr EXCEPT ![r] = tcount + 1]
    /\ pc' = [pc EXCEPT ![r] = "setSlot"]
    /\ UNCHANGED <<slot, joins, tfreed, kind, reqs, users, closing, registered,
                   closeBegun, freed, joining, claimAfterClose>>

\* Today: the turn bound refuses a start beyond MaxTurns.
StartFull(r) ==
    /\ pc[r] = "startToday"
    /\ tcount = MaxTurns
    /\ pc' = [pc EXCEPT ![r] = "release"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* Today: session.prompt is set after the spawn (startPrompt).
SetSlotToday(r) ==
    /\ pc[r] = "setSlot"
    /\ slot' = ptr[r]
    /\ ptr' = [ptr EXCEPT ![r] = 0]
    /\ pc' = [pc EXCEPT ![r] = "release"]
    /\ UNCHANGED <<tcount, tstate, joins, tfreed, kind, reqs, users, closing,
                   registered, closeBegun, freed, joining, claimAfterClose>>

\* Today: the reap reads the slot without a lock (reapSessionPrompt) and keeps it
\* set until after the free.
ReapTakeToday(r) ==
    /\ pc[r] = "reapFirst"
    /\ SlotStatus = "done"
    /\ ptr' = [ptr EXCEPT ![r] = slot]
    /\ pc' = [pc EXCEPT ![r] = "joinOwn"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, kind, reqs, users, closing,
                   registered, closeBegun, freed, joining, claimAfterClose>>

\* Today: nothing to reap now. A start goes on to spawn, as the .start arm does.
ReapRetryToday(r) ==
    /\ pc[r] = "reapFirst"
    /\ SlotStatus # "done"
    /\ pc' = [pc EXCEPT ![r] = IF kind[r] = "reap" THEN "release" ELSE "startToday"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* Today: the free (freeActivePrompt), then session.prompt is cleared
\* (reapSessionPrompt), with no test that the slot still names this turn.
FreeOwnToday(r) ==
    /\ pc[r] = "freeOwn"
    /\ tfreed' = [tfreed EXCEPT ![ptr[r]] = TRUE]
    /\ slot' = 0
    /\ ptr' = [ptr EXCEPT ![r] = 0]
    /\ pc' = [pc EXCEPT ![r] = IF kind[r] = "reap" THEN "release" ELSE "startToday"]
    /\ UNCHANGED <<tcount, tstate, joins, kind, reqs, users, closing, registered,
                   closeBegun, freed, joining, claimAfterClose>>

\* Today: a withdrawal finds no turn, and returns (withdrawSessionRequest).
WithdrawNoneToday(r) ==
    /\ kind[r] = "withdraw"
    /\ pc[r] = "check"
    /\ SlotStatus = "none"
    /\ pc' = [pc EXCEPT ![r] = "release"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* Today: the withdrawal reads the turn before the line lock, then uses it after
\* the lock. The use happens in WithdrawTouchToday.
WithdrawReadToday(r) ==
    /\ kind[r] = "withdraw"
    /\ pc[r] = "check"
    /\ SlotStatus # "none"
    /\ ptr' = [ptr EXCEPT ![r] = slot]
    /\ pc' = [pc EXCEPT ![r] = "wTouch"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, kind, reqs, users, closing,
                   registered, closeBegun, freed, joining, claimAfterClose>>

WithdrawTouchToday(r) ==
    /\ pc[r] = "wTouch"
    /\ ptr' = [ptr EXCEPT ![r] = 0]
    /\ pc' = [pc EXCEPT ![r] = "release"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, kind, reqs, users, closing,
                   registered, closeBegun, freed, joining, claimAfterClose>>

\* fx today's steps of one reader.
TodayStep(r) ==
    \/ CheckToday(r)
    \/ StartToday(r)
    \/ StartFull(r)
    \/ SetSlotToday(r)
    \/ ReapTakeToday(r)
    \/ ReapRetryToday(r)
    \/ JoinOwn(r)
    \/ FreeOwnToday(r)
    \/ Spawn(r)
    \/ Deliver(r)
    \/ WithdrawNoneToday(r)
    \/ WithdrawReadToday(r)
    \/ WithdrawTouchToday(r)
    \/ CancelTouch(r)
    \/ Release(r)

ReaderStep(r) == IF Rules THEN DesignStep(r) ELSE TodayStep(r)

-----------------------------------------------------------------------------
\* The close's steps after BeginClose. Today's close cancels, reaps, unregisters,
\* and frees (closeSession, cancelAndReapPrompt, destroySession). The design
\* unregisters (1), waits for the users (2), cancels, takes and joins the turn
\* (3), and frees (4). Its closing flag was set by BeginClose.
\* Design: unregister from the shared table (shared.unregister).
CloseDetach ==
    /\ pc[Owner] = "cDetach"
    /\ registered' = FALSE
    /\ pc' = [pc EXCEPT ![Owner] = "cWait"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, closeBegun, freed, joining, claimAfterClose>>

\* Design: wait until no follower uses the session.
CloseWait ==
    /\ pc[Owner] = "cWait"
    /\ users = 0
    /\ pc' = [pc EXCEPT ![Owner] = "cCancel"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* The cancel of the running turn (cancelAndReapPrompt, handleCancel).
CloseCancel ==
    /\ pc[Owner] = "cCancel"
    /\ pc' = [pc EXCEPT ![Owner] = "cTake"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* The slot's turn is taken for the join. Design: the slot is cleared under the
\* line lock. Today: it stays set until the free.
CloseTakeSlot ==
    /\ pc[Owner] = "cTake"
    /\ SlotStatus # "none"
    /\ ptr' = [ptr EXCEPT ![Owner] = slot]
    /\ slot' = IF Rules THEN 0 ELSE slot
    /\ pc' = [pc EXCEPT ![Owner] = "cJoin"]
    /\ UNCHANGED <<tcount, tstate, joins, tfreed, kind, reqs, users, closing,
                   registered, closeBegun, freed, joining, claimAfterClose>>

CloseTakeNone ==
    /\ pc[Owner] = "cTake"
    /\ SlotStatus = "none"
    /\ pc' = [pc EXCEPT ![Owner] = IF Rules THEN "cFree" ELSE "cDetachT"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

\* The close's join of the turn (reapSessionPrompt, from cancelAndReapPrompt).
CloseJoin ==
    /\ pc[Owner] = "cJoin"
    /\ tstate[ptr[Owner]] \in {"done", "joined"}
    /\ joins' = [joins EXCEPT ![ptr[Owner]] = joins[ptr[Owner]] + 1]
    /\ tstate' = [tstate EXCEPT ![ptr[Owner]] = "joined"]
    /\ pc' = [pc EXCEPT ![Owner] = "cFreeT"]
    /\ UNCHANGED <<slot, tcount, tfreed, ptr, kind, reqs, users, closing,
                   registered, closeBegun, freed, joining, claimAfterClose>>

\* The turn is freed (freeActivePrompt). Design: the slot is cleared only if it
\* still names this turn. Today: cleared unconditionally.
CloseFreeT ==
    /\ pc[Owner] = "cFreeT"
    /\ tfreed' = [tfreed EXCEPT ![ptr[Owner]] = TRUE]
    /\ slot' = IF Rules THEN (IF slot = ptr[Owner] THEN 0 ELSE slot) ELSE 0
    /\ ptr' = [ptr EXCEPT ![Owner] = 0]
    /\ pc' = [pc EXCEPT ![Owner] = IF Rules THEN "cFree" ELSE "cDetachT"]
    /\ UNCHANGED <<tcount, tstate, joins, kind, reqs, users, closing, registered,
                   closeBegun, freed, joining, claimAfterClose>>

\* Today: unregister after the reap (destroySession).
CloseDetachT ==
    /\ pc[Owner] = "cDetachT"
    /\ registered' = FALSE
    /\ pc' = [pc EXCEPT ![Owner] = "cFree"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users,
                   closing, closeBegun, freed, joining, claimAfterClose>>

\* The session's storage is freed (destroySession). The owner's reader returns
\* to idle, and the close is over.
CloseFree ==
    /\ pc[Owner] = "cFree"
    /\ freed' = TRUE
    /\ pc' = [pc EXCEPT ![Owner] = "idle"]
    /\ kind' = [kind EXCEPT ![Owner] = "none"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, reqs, users, closing,
                   registered, closeBegun, joining, claimAfterClose>>

CloseSteps ==
    \/ CloseDetach
    \/ CloseWait
    \/ CloseCancel
    \/ CloseTakeSlot
    \/ CloseTakeNone
    \/ CloseJoin
    \/ CloseFreeT
    \/ CloseDetachT
    \/ CloseFree

\* A worker thread ends. The worker sets reapable under the line lock (server.zig
\* 3761) and sends its last answers after that (3765-3770). The order is
\* deliberate (3681-3682). So the thread still runs after it is reapable; the
\* second turn waits for the join (AtMostOneWorker, and the guard ~joining).
WorkerEnd(t) ==
    /\ tstate[t] = "spawned"
    /\ tstate' = [tstate EXCEPT ![t] = "done"]
    /\ UNCHANGED <<slot, tcount, joins, tfreed, pc, kind, ptr, reqs, users,
                   closing, registered, closeBegun, freed, joining, claimAfterClose>>

-----------------------------------------------------------------------------
Next ==
    \/ \E r \in Readers, k \in Requests : BeginRequest(r, k)
    \/ BeginClose
    \/ \E r \in Readers : ReaderStep(r)
    \/ CloseSteps
    \/ \E t \in Turns : WorkerEnd(t)

\* Weak fairness: a started close moves on, every thread ends, and every step
\* of a reader that is under way is taken.
Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(CloseSteps)
    /\ \A t \in Turns : WF_vars(WorkerEnd(t))
    /\ \A r \in Readers : WF_vars(ReaderStep(r))

-----------------------------------------------------------------------------
\* Forbids a variable outside its type.
TypeOK ==
    /\ slot \in 0..MaxTurns
    /\ tcount \in 0..MaxTurns
    /\ tstate \in [Turns -> TStates]
    /\ joins \in [Turns -> 0..4]
    /\ tfreed \in [Turns -> BOOLEAN]
    /\ pc \in [Readers -> PCs]
    /\ kind \in [Readers -> Kinds]
    /\ ptr \in [Readers -> 0..MaxTurns]
    /\ reqs \in [Readers -> 0..MaxReq]
    /\ users \in 0..MaxReq
    /\ closing \in BOOLEAN
    /\ registered \in BOOLEAN
    /\ closeBegun \in BOOLEAN
    /\ freed \in BOOLEAN
    /\ joining \in BOOLEAN
    /\ claimAfterClose \in BOOLEAN

\* Forbids two turns alive at once. A turn is alive from its spawn until its join.
\* The worker sends its last answers after it sets reapable (server.zig 3761,
\* 3765-3770; the order is deliberate, 3681-3682), so a second turn may not start
\* until the first is joined: ClaimNew waits while joining is TRUE.
AtMostOneWorker ==
    \A t1 \in Turns : \A t2 \in Turns :
        ((tstate[t1] \in {"spawned", "done"}) /\ (tstate[t2] \in {"spawned", "done"}))
            => (t1 = t2)

\* Forbids a second join of a turn.
NoDoubleJoin == \A t \in Turns : joins[t] <= 1

\* Forbids a reader step on the session once it is freed, a thread still
\* running after it, and a reader that holds a turn freed under it.
NoUseAfterFree ==
    /\ freed => (\A r \in Readers : pc[r] = "idle")
    /\ freed => (\A t \in Turns : tstate[t] # "spawned")
    /\ \A r \in Readers : IF ptr[r] = 0 THEN TRUE ELSE ~tfreed[ptr[r]]

\* Forbids a thread that is not joined when the session is freed.
NoLeakedWorker ==
    freed => (\A t \in Turns : tstate[t] \in {"unborn", "unclaimed", "joined"})

\* Once a close has begun, a new prompt is refused, not started. A claim made
\* before the close is still reaped by the close (CloseTakeSlot).
NoClaimAfterClose == ~claimAfterClose

\* A started close reaches the freed session.
CloseFinishes == closeBegun ~> freed

=============================================================================

---- MODULE KeychainLock ----
\* Refreshes of the fx login by several fx processes, each in an fx profile
\* (src/core/auth/oauth_session.zig lockMutation and lockMutationWithBackend,
\* src/core/auth/credentials.zig refreshFxSession).
\*
\* Profile 0 is the default ~/.fx; the others are folders FX_HOME names. On
\* macOS the login is one Keychain item for the user, whatever the profile;
\* with the profile-file backend (FX_DISABLE_KEYCHAIN=1, or off macOS) each
\* profile saves its own login in auth.json. A process takes the login's lock,
\* auth.lock, in a folder, loads the saved login, and may refresh it. The
\* issuer takes each refresh token once (rotation): a refresh returns the next
\* version and retires the one sent, and a retired one sent again is refused
\* with invalid_grant, after which fx deletes the saved login
\* (retire_fx_session). Versions stand for logins: each sign-in or refresh is
\* a new, higher one.
\*
\* Where the lock is (Rule):
\*   "profile"  fx before this change: the process's profile folder.
\*   "home"     this change: with the Keychain, ~/.fx, the default profile's
\*              folder, for every profile. When HOME is not absolute or ~/.fx
\*              can't hold the lock (HomeUsable = FALSE), the profile.
\*   "runtime"  the alternative left out: a per-user folder outside ~/.fx.
\* A process running an older build locks its profile whatever the rule, and
\* the profile-file backend keeps its lock in the profile.
\*
\* Environment: any process may die at any step (Crashes), which drops its
\* lock and loses a rotated login it had not saved yet, and the issuer may
\* stop taking every token (the login was revoked or ran out there).
EXTENDS Naturals, FiniteSets

CONSTANTS
    NP,            \* profiles; profile 0 is ~/.fx
    PerProfile,    \* processes of this build in each profile
    OldInDefault,  \* an older-build process in the default profile
    OldInMoved,    \* an older-build process in profile 1, which FX_HOME moved
    Backend,       \* "keychain" or "file"
    Rule,          \* "profile", "home", or "runtime"
    HomeUsable,    \* HOME is absolute and ~/.fx can hold the lock
    LoadAfterLock, \* a process loads the saved login after it takes the lock
    FileShares,    \* planted: the profile-file backend takes the ~/.fx lock too
    Crashes,       \* a process may die at any step
    MaxVer         \* the highest version a run issues

Profiles == 0..(NP - 1)
New == {<<pr, i>> : pr \in Profiles, i \in 1..PerProfile}
Old == (IF OldInDefault THEN {<<0, 0>>} ELSE {})
       \cup (IF OldInMoved /\ NP > 1 THEN {<<1, 0>>} ELSE {})
Procs == New \cup Old
Runtime == NP     \* the per-user runtime folder, as a lock place
KStore == NP      \* the Keychain item, as a store
Places == Profiles \cup {Runtime}
Stores == Profiles \cup {KStore}
None == <<NP + 1, 0>>   \* no process: profiles end at NP - 1

ProfileOf(p) == p[1]

\* The folder whose auth.lock process p takes.
LockPlace(p) ==
    IF p \in Old THEN ProfileOf(p)
    ELSE IF Backend = "file" /\ ~FileShares THEN ProfileOf(p)
    ELSE CASE Rule = "profile" -> ProfileOf(p)
           [] Rule = "home" -> (IF HomeUsable THEN 0 ELSE ProfileOf(p))
           [] Rule = "runtime" -> Runtime

\* Where process p's login is saved.
StoreOf(p) == IF Backend = "keychain" THEN KStore ELSE ProfileOf(p)
UsedStores == {StoreOf(p) : p \in Procs}

\* A process holding the lock: loading, refreshing, saving, or deleting.
Holding == {"locked", "loaded", "sent", "refused", "done"}

VARIABLES
    pc,     \* [Procs -> "idle", "early", or a Holding phase, or "dead"]
    held,   \* [Procs -> the version it loaded, 0 for none]
    reply,  \* [Procs -> the version the issuer returned it, not saved yet, 0 for none]
    owner,  \* [Places -> the process holding that folder's lock, or None]
    store,  \* [Stores -> the saved version, 0 for none]
    live,   \* the versions whose refresh token the issuer still takes
    next,   \* the next version the issuer issues
    \* Ghosts.
    reused,       \* a process sent a retired token while a usable login was saved
    validDeleted  \* a refusal deleted a saved login the issuer still took

vars == <<pc, held, reply, owner, store, live, next, reused, validDeleted>>

TypeOK ==
    /\ pc \in [Procs -> {"idle", "early", "dead"} \cup Holding]
    /\ held \in [Procs -> 0..MaxVer]
    /\ reply \in [Procs -> 0..MaxVer]
    /\ owner \in [Places -> Procs \cup {None}]
    /\ store \in [Stores -> 0..MaxVer]
    /\ live \subseteq 1..MaxVer
    /\ next \in 1..(MaxVer + 1)
    /\ reused \in BOOLEAN
    /\ validDeleted \in BOOLEAN

\* Each store starts with its own signed-in login, which has run out.
Init ==
    /\ pc = [p \in Procs |-> "idle"]
    /\ held = [p \in Procs |-> 0]
    /\ reply = [p \in Procs |-> 0]
    /\ owner = [l \in Places |-> None]
    /\ store = [s \in Stores |-> IF s \in UsedStores THEN s + 1 ELSE 0]
    /\ live = {s + 1 : s \in UsedStores}
    /\ next = NP + 2
    /\ reused = FALSE
    /\ validDeleted = FALSE

\* p takes the lock in its folder, once nobody holds it there.
Take(p) ==
    /\ \/ pc[p] = "idle" /\ LoadAfterLock
       \/ pc[p] = "early"
    /\ owner[LockPlace(p)] = None
    /\ owner' = [owner EXCEPT ![LockPlace(p)] = p]
    /\ pc' = [pc EXCEPT ![p] = IF pc[p] = "early" THEN "loaded" ELSE "locked"]
    /\ UNCHANGED <<held, reply, store, live, next, reused, validDeleted>>

\* Planted (LoadAfterLock = FALSE): p loads the saved login before the lock.
EarlyLoad(p) ==
    /\ ~LoadAfterLock
    /\ pc[p] = "idle"
    /\ held' = [held EXCEPT ![p] = store[StoreOf(p)]]
    /\ pc' = [pc EXCEPT ![p] = "early"]
    /\ UNCHANGED <<reply, owner, store, live, next, reused, validDeleted>>

\* p loads the saved login under the lock (Mutation.load).
Load(p) ==
    /\ pc[p] = "locked"
    /\ held' = [held EXCEPT ![p] = store[StoreOf(p)]]
    /\ pc' = [pc EXCEPT ![p] = "loaded"]
    /\ UNCHANGED <<reply, owner, store, live, next, reused, validDeleted>>

\* p sends the refresh token of the login it loaded: whether it ran out or a
\* request was refused with 401 (the forced refresh), so any loaded login may
\* be sent. The issuer rotates a live one and refuses a retired one.
Send(p) ==
    LET v == held[p] IN
    /\ pc[p] = "loaded"
    /\ v # 0
    /\ IF v \in live
       THEN /\ next <= MaxVer
            /\ live' = (live \ {v}) \cup {next}
            /\ reply' = [reply EXCEPT ![p] = next]
            /\ next' = next + 1
            /\ pc' = [pc EXCEPT ![p] = "sent"]
            /\ UNCHANGED <<held, owner, store, reused, validDeleted>>
       ELSE /\ reused' = (reused \/ store[StoreOf(p)] \in live)
            /\ pc' = [pc EXCEPT ![p] = "refused"]
            /\ UNCHANGED <<held, reply, owner, store, live, next, validDeleted>>

\* p saves the rotated login it got.
Save(p) ==
    /\ pc[p] = "sent"
    /\ store' = [store EXCEPT ![StoreOf(p)] = reply[p]]
    /\ held' = [held EXCEPT ![p] = reply[p]]
    /\ reply' = [reply EXCEPT ![p] = 0]
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<owner, live, next, reused, validDeleted>>

\* p, refused, deletes the saved login, whoever saved it.
Retire(p) ==
    /\ pc[p] = "refused"
    /\ validDeleted' = (validDeleted \/ store[StoreOf(p)] \in live)
    /\ store' = [store EXCEPT ![StoreOf(p)] = 0]
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<held, reply, owner, live, next, reused>>

\* p lets the lock go: after a refresh, or with a login that needs none.
Release(p) ==
    /\ pc[p] \in {"loaded", "done"}
    /\ owner' = [owner EXCEPT ![LockPlace(p)] = None]
    /\ pc' = [pc EXCEPT ![p] = "idle"]
    /\ held' = [held EXCEPT ![p] = 0]
    /\ UNCHANGED <<reply, store, live, next, reused, validDeleted>>

\* p dies. The kernel drops the lock it held; a rotated login it had not
\* saved is lost, and the issuer has retired the one saved.
Crash(p) ==
    /\ Crashes
    /\ pc[p] \notin {"dead", "idle"}
    /\ owner' = IF pc[p] \in Holding THEN [owner EXCEPT ![LockPlace(p)] = None] ELSE owner
    /\ pc' = [pc EXCEPT ![p] = "dead"]
    /\ held' = [held EXCEPT ![p] = 0]
    /\ reply' = [reply EXCEPT ![p] = 0]
    /\ UNCHANGED <<store, live, next, reused, validDeleted>>

\* The issuer stops taking every token: the login was revoked there.
Revoke ==
    /\ live # {}
    /\ live' = {}
    /\ UNCHANGED <<pc, held, reply, owner, store, next, reused, validDeleted>>

\* Nothing happens: a run may end anywhere, so no state is a deadlock.
Idle == UNCHANGED vars

Next ==
    \/ \E p \in Procs :
        Take(p) \/ EarlyLoad(p) \/ Load(p) \/ Send(p) \/ Save(p) \/ Retire(p) \/ Release(p) \/ Crash(p)
    \/ Revoke
    \/ Idle

Spec == Init /\ [][Next]_vars

\* A process never sends a refresh token the issuer retired while a login the
\* issuer still takes is saved: it loads the saved one under the lock.
NoReuse == ~reused

\* A refused refresh never deletes a saved login the issuer still takes, so
\* one profile's refresh never signs the user out of every profile.
NoValidLoginDeleted == ~validDeleted

\* At most one process holds the lock of one saved login at a time.
OneRefresher ==
    \A p, q \in Procs :
        p # q /\ pc[p] \in Holding /\ pc[q] \in Holding => StoreOf(p) # StoreOf(q)

\* With the profile-file backend, a process holding the lock holds it in its
\* own profile's folder.
FileLockStaysInProfile ==
    Backend = "file" => \A p \in Procs : pc[p] \in Holding => owner[ProfileOf(p)] = p
====

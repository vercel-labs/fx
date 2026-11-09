---- MODULE KeychainLock ----
\* Refreshes of a Keychain item that is one for the user, whatever the profile,
\* by several fx processes, each in an fx profile. Two items are modeled:
\*   "login"  the fx login (src/core/auth/oauth_session.zig lockMutation and
\*            lockMutationWithBackend, src/core/auth/credentials.zig
\*            refreshFxSession)
\*   "mcp"    an MCP credential (src/core/mcp_host/credentials.zig: the
\*            refresh lock of one login, Store.tryRefreshLock; the store lock,
\*            Store.lock, follows the same rule)
\* Both take their lock through src/core/shared/keychain_lock.zig.
\*
\* Profile 0 is the default ~/.fx; the others are folders FX_HOME names. On
\* macOS each item is one Keychain item for the user, whatever the profile;
\* with the profile-file backend (FX_DISABLE_KEYCHAIN=1, or off macOS) each
\* profile saves its own login. A process takes the item's lock in a folder,
\* loads the saved login, and may refresh it. The issuer takes each refresh
\* token once (rotation): a refresh returns the next version and retires the
\* one sent, and a retired one sent again is refused with invalid_grant, after
\* which fx deletes the saved login (retire_fx_session). Versions stand for
\* logins: each sign-in or refresh is a new, higher one.
\*
\* Where the lock is (Rule for the login, McpRule for the MCP credential):
\*   "profile"  fx before the change: the process's profile folder.
\*   "home"     with the Keychain, ~/.fx (for the MCP credential,
\*              ~/.fx/mcp-credentials), the default profile's folder, for every
\*              profile. When HOME is not absolute or ~/.fx can't be opened
\*              (HomeUsable = FALSE), the profile, with a trace line. When ~/.fx
\*              opens but its lock can't be taken, a symlink, a mode 644 file, a
\*              folder, or a fifo (LockUsable = FALSE): the profile with a trace
\*              line (OnUnusable = "profile"), or, as the PR's first head did,
\*              the operation fails (OnUnusable = "fail").
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
    PerProfile,    \* processes of this build in each profile, for each item
    OldInDefault,  \* an older-build process in the default profile, for each item
    OldInMoved,    \* an older-build process in profile 1, which FX_HOME moved
    Backend,       \* "keychain" or "file"
    Items,         \* the items refreshed: "login", "mcp", or both
    Rule,          \* the login's lock: "profile", "home", or "runtime"
    McpRule,       \* the MCP credential's lock, the same choices
    HomeUsable,    \* HOME is absolute and ~/.fx can be opened and made private
    LockUsable,    \* the lock file in ~/.fx can be taken
    OnUnusable,    \* "profile": take the profile's lock; "fail": the operation fails
    TraceFallback, \* a fallback writes a debug trace line
    FallOnBusy,    \* planted: a shared lock another process holds falls back too
    LoadAfterLock, \* a process loads the saved login after it takes the lock
    FileShares,    \* planted: the profile-file backend takes the ~/.fx lock too
    Crashes,       \* a process may die at any step
    MaxVer         \* the highest version a run issues

Profiles == 0..(NP - 1)
New == {<<pr, i, it>> : pr \in Profiles, i \in 1..PerProfile, it \in Items}
Old == {<<0, 0, it>> : it \in (IF OldInDefault THEN Items ELSE {})}
       \cup {<<1, 0, it>> : it \in (IF OldInMoved /\ NP > 1 THEN Items ELSE {})}
Procs == New \cup Old
Runtime == NP     \* the per-user runtime folder, as a lock place
KStore == NP      \* the Keychain item, as a store
NoPlace == NP + 1
Places == (Profiles \cup {Runtime}) \X Items
Stores == (Profiles \cup {KStore}) \X Items
None == <<NP + 1, 0, "none">>   \* no process: profiles end at NP - 1

ProfileOf(p) == p[1]
ItemOf(p) == p[3]
RuleOf(p) == IF ItemOf(p) = "login" THEN Rule ELSE McpRule

\* The shared lock is meant for p: a process of this build, with the Keychain,
\* under a rule that moves the lock out of the profile.
Applies(p) ==
    /\ p \notin Old
    /\ ~(Backend = "file" /\ ~FileShares)
    /\ RuleOf(p) # "profile"

\* The place of the shared lock for p.
SharedPlace(p) == IF RuleOf(p) = "runtime" THEN Runtime ELSE 0

\* ~/.fx opens but its lock can't be taken, and the operation fails.
Fails(p) ==
    /\ Applies(p)
    /\ RuleOf(p) = "home"
    /\ HomeUsable /\ ~LockUsable
    /\ OnUnusable = "fail"

\* The shared lock can't be used, so p takes the profile's.
Falls(p) ==
    /\ Applies(p)
    /\ RuleOf(p) = "home"
    /\ ~(HomeUsable /\ LockUsable)
    /\ ~Fails(p)

\* The folders whose lock p may take: its profile's, or the shared one.
\* Planted (FallOnBusy): a shared lock another process holds sends p to its
\* profile's, where nobody else is.
LockPlaces(p, own) ==
    IF ~Applies(p) \/ Falls(p) THEN {ProfileOf(p)}
    ELSE IF FallOnBusy /\ own[<<SharedPlace(p), ItemOf(p)>>] # None THEN {ProfileOf(p)}
    ELSE {SharedPlace(p)}

\* Where process p's login is saved.
StoreOf(p) == IF Backend = "keychain" THEN <<KStore, ItemOf(p)>> ELSE <<ProfileOf(p), ItemOf(p)>>
UsedStores == {StoreOf(p) : p \in Procs}

\* The login each store starts with, and the version after them all.
Ver0(s) == s[1] + 1 + (IF s[2] = "mcp" THEN NP + 1 ELSE 0)
FirstNext == IF "mcp" \in Items THEN 2 * NP + 3 ELSE NP + 2

\* A process holding the lock: loading, refreshing, saving, or deleting.
Holding == {"locked", "loaded", "sent", "refused", "done"}

VARIABLES
    pc,     \* [Procs -> "idle", "early", or a Holding phase, or "dead"]
    held,   \* [Procs -> the version it loaded, 0 for none]
    reply,  \* [Procs -> the version the issuer returned it, not saved yet, 0 for none]
    at,     \* [Procs -> the folder whose lock it holds, NoPlace for none]
    owner,  \* [Places -> the process holding that folder's lock, or None]
    store,  \* [Stores -> the saved version, 0 for none]
    live,   \* the versions whose refresh token the issuer still takes
    next,   \* the next version the issuer issues
    \* Ghosts.
    reused,       \* a process sent a retired token while a usable login was saved
    validDeleted, \* a refusal deleted a saved login the issuer still took
    signInFailed, \* a process could not take the lock, so its operation failed
    untraced      \* a process fell back to its profile's lock and wrote no trace line

vars == <<pc, held, reply, at, owner, store, live, next, reused, validDeleted, signInFailed, untraced>>

TypeOK ==
    /\ pc \in [Procs -> {"idle", "early", "dead"} \cup Holding]
    /\ held \in [Procs -> 0..MaxVer]
    /\ reply \in [Procs -> 0..MaxVer]
    /\ at \in [Procs -> 0..NoPlace]
    /\ owner \in [Places -> Procs \cup {None}]
    /\ store \in [Stores -> 0..MaxVer]
    /\ live \subseteq 1..MaxVer
    /\ next \in 1..(MaxVer + 1)
    /\ reused \in BOOLEAN
    /\ validDeleted \in BOOLEAN
    /\ signInFailed \in BOOLEAN
    /\ untraced \in BOOLEAN

\* Each store starts with its own signed-in login, which has run out.
Init ==
    /\ pc = [p \in Procs |-> "idle"]
    /\ held = [p \in Procs |-> 0]
    /\ reply = [p \in Procs |-> 0]
    /\ at = [p \in Procs |-> NoPlace]
    /\ owner = [l \in Places |-> None]
    /\ store = [s \in Stores |-> IF s \in UsedStores THEN Ver0(s) ELSE 0]
    /\ live = {Ver0(s) : s \in UsedStores}
    /\ next = FirstNext
    /\ reused = FALSE
    /\ validDeleted = FALSE
    /\ signInFailed = FALSE
    /\ untraced = FALSE

\* p takes the lock in a folder, once nobody holds it there.
Take(p) ==
    /\ \/ pc[p] = "idle" /\ LoadAfterLock
       \/ pc[p] = "early"
    /\ \E place \in LockPlaces(p, owner) :
        /\ owner[<<place, ItemOf(p)>>] = None
        /\ owner' = [owner EXCEPT ![<<place, ItemOf(p)>>] = p]
        /\ at' = [at EXCEPT ![p] = place]
    /\ untraced' = (untraced \/ (Falls(p) /\ ~TraceFallback))
    /\ pc' = [pc EXCEPT ![p] = IF pc[p] = "early" THEN "loaded" ELSE "locked"]
    /\ UNCHANGED <<held, reply, store, live, next, reused, validDeleted, signInFailed>>

\* p can't take the lock: ~/.fx opens but its lock can't be taken, so the
\* operation fails with CredentialStorageUnavailable (OnUnusable = "fail").
FailTake(p) ==
    /\ Fails(p)
    /\ pc[p] \in {"idle", "early"}
    /\ signInFailed' = TRUE
    /\ pc' = [pc EXCEPT ![p] = "idle"]
    /\ held' = [held EXCEPT ![p] = 0]
    /\ UNCHANGED <<reply, at, owner, store, live, next, reused, validDeleted, untraced>>

\* Planted (LoadAfterLock = FALSE): p loads the saved login before the lock.
EarlyLoad(p) ==
    /\ ~LoadAfterLock
    /\ pc[p] = "idle"
    /\ held' = [held EXCEPT ![p] = store[StoreOf(p)]]
    /\ pc' = [pc EXCEPT ![p] = "early"]
    /\ UNCHANGED <<reply, at, owner, store, live, next, reused, validDeleted, signInFailed, untraced>>

\* p loads the saved login under the lock (Mutation.load).
Load(p) ==
    /\ pc[p] = "locked"
    /\ held' = [held EXCEPT ![p] = store[StoreOf(p)]]
    /\ pc' = [pc EXCEPT ![p] = "loaded"]
    /\ UNCHANGED <<reply, at, owner, store, live, next, reused, validDeleted, signInFailed, untraced>>

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
            /\ UNCHANGED <<held, at, owner, store, reused, validDeleted, signInFailed, untraced>>
       ELSE /\ reused' = (reused \/ store[StoreOf(p)] \in live)
            /\ pc' = [pc EXCEPT ![p] = "refused"]
            /\ UNCHANGED <<held, reply, at, owner, store, live, next, validDeleted, signInFailed, untraced>>

\* p saves the rotated login it got.
Save(p) ==
    /\ pc[p] = "sent"
    /\ store' = [store EXCEPT ![StoreOf(p)] = reply[p]]
    /\ held' = [held EXCEPT ![p] = reply[p]]
    /\ reply' = [reply EXCEPT ![p] = 0]
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<at, owner, live, next, reused, validDeleted, signInFailed, untraced>>

\* p, refused, deletes the saved fx login, whoever saved it
\* (retire_fx_session). An MCP credential goes only if it is the one p loaded:
\* a credential another fx saved since stays (Store.removeIfSame).
Retire(p) ==
    LET deletes == ItemOf(p) = "login" \/ store[StoreOf(p)] = held[p] IN
    /\ pc[p] = "refused"
    /\ validDeleted' = (validDeleted \/ (deletes /\ store[StoreOf(p)] \in live))
    /\ store' = IF deletes THEN [store EXCEPT ![StoreOf(p)] = 0] ELSE store
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<held, reply, at, owner, live, next, reused, signInFailed, untraced>>

\* p lets the lock go: after a refresh, or with a login that needs none.
Release(p) ==
    /\ pc[p] \in {"loaded", "done"}
    /\ owner' = [owner EXCEPT ![<<at[p], ItemOf(p)>>] = None]
    /\ at' = [at EXCEPT ![p] = NoPlace]
    /\ pc' = [pc EXCEPT ![p] = "idle"]
    /\ held' = [held EXCEPT ![p] = 0]
    /\ UNCHANGED <<reply, store, live, next, reused, validDeleted, signInFailed, untraced>>

\* p dies. The kernel drops the lock it held; a rotated login it had not
\* saved is lost, and the issuer has retired the one saved.
Crash(p) ==
    /\ Crashes
    /\ pc[p] \notin {"dead", "idle"}
    /\ owner' = IF pc[p] \in Holding THEN [owner EXCEPT ![<<at[p], ItemOf(p)>>] = None] ELSE owner
    /\ at' = [at EXCEPT ![p] = NoPlace]
    /\ pc' = [pc EXCEPT ![p] = "dead"]
    /\ held' = [held EXCEPT ![p] = 0]
    /\ reply' = [reply EXCEPT ![p] = 0]
    /\ UNCHANGED <<store, live, next, reused, validDeleted, signInFailed, untraced>>

\* The issuer stops taking every token: the login was revoked there.
Revoke ==
    /\ live # {}
    /\ live' = {}
    /\ UNCHANGED <<pc, held, reply, at, owner, store, next, reused, validDeleted, signInFailed, untraced>>

\* Nothing happens: a run may end anywhere, so no state is a deadlock.
Idle == UNCHANGED vars

Next ==
    \/ \E p \in Procs :
        Take(p) \/ FailTake(p) \/ EarlyLoad(p) \/ Load(p) \/ Send(p) \/ Save(p) \/ Retire(p) \/ Release(p) \/ Crash(p)
    \/ Revoke
    \/ Idle

Spec == Init /\ [][Next]_vars

\* A process never sends a refresh token the issuer retired while a login the
\* issuer still takes is saved: it loads the saved one under the lock.
NoReuse == ~reused

\* A refused refresh never deletes a saved login the issuer still takes, so
\* one profile's refresh never signs the user out of every profile. It holds
\* when every process runs this build and the shared lock is usable. An MCP
\* credential is guarded by removeIfSame, so for it NoReuse is the law the
\* missing shared lock breaks: a retired token sent again, which an issuer may
\* answer by revoking the whole login.
NoValidLoginDeleted == ~validDeleted

\* At most one process holds the lock of one saved login at a time.
OneRefresher ==
    \A p, q \in Procs :
        p # q /\ pc[p] \in Holding /\ pc[q] \in Holding => StoreOf(p) # StoreOf(q)

\* With the profile-file backend, a process holding the lock holds it in its
\* own profile's folder.
FileLockStaysInProfile ==
    Backend = "file" => \A p \in Procs : pc[p] \in Holding => owner[<<ProfileOf(p), ItemOf(p)>>] = p

\* An unusable shared lock never fails the operation: the process takes its
\* profile's lock instead.
NoSignInFailure == ~signInFailed

\* A process that fell back to its profile's lock left a trace line.
FallbackTraced == ~untraced
====

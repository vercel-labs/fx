---- MODULE SharedLogins ----
\* Several fx processes sharing one saved login for one MCP server
\* (src/core/mcp_host/runtime.zig pickUpLogin, refreshDue and saveCredential,
\* credentials.zig removeIfSame and tryRefreshLock).
\*
\* The store holds the version of the login last saved, 0 for none; each
\* sign-in or refresh anywhere is a new, higher version. Each process holds a
\* version in memory, 0 when signed out, and remembers the last saved version
\* it had or tried (`tried`, a digest in the code).
\*   - SignIn: a process signs in and saves its version.
\*   - Refused: the server stops taking the version a process holds (a newer
\*     sign-in elsewhere replaced it, or it expired). Its tokens drop, it
\*     needs a login, and it removes the saved login only if that is its own.
\*   - NeedsScope: the server wants more than the version a process holds
\*     (a step-up); it needs a login but keeps its tokens, so nothing is
\*     removed and the saved login is still its own.
\*   - PickUp: a process that needs a login takes the saved one, unless it
\*     already had or tried it.
\*   - Logout: a sign-out on purpose removes the saved login, whoever saved it,
\*     and ends it everywhere.
\*   - Refresh: the access token a process holds runs out. Each refresh token
\*     works once (WorkOS; RFC 9700 4.14.2): a refresh returns the next version
\*     and retires the one sent, and the server refuses a retired one sent
\*     again; with RevokeOnReplay that also stops every version of its chain.
\*     Under the login's refresh lock, so one process refreshes at a time, a
\*     process takes a newer saved login if there is one, and refreshes only
\*     if not. With SaveFaults the save of what it got may fail: it keeps
\*     using it, and the saved login it had stays its own.
EXTENDS Naturals

CONSTANTS
    Procs,          \* fx processes sharing the store
    MaxVer,         \* sign-ins and refreshes per run
    RevokeOnReplay, \* a retired version sent again stops its whole chain
    SaveFaults      \* a refresh's save may fail

Vers == 1..MaxVer

VARIABLES
    store,    \* the saved version, 0 for none
    held,     \* [Procs -> the version held, 0 for none]
    tried,    \* [Procs -> the last saved version had or tried, 0 for none]
    needs,    \* [Procs -> needs a login]
    unsaved,  \* [Procs -> holds a version its save failed to keep]
    next,     \* the next version, by sign-in or refresh
    dead,     \* the versions the server no longer takes
    chain,    \* [Vers -> the sign-in each version descends from, 0 if unused]
    \* Ghosts.
    erased,   \* a refusal removed a newer login another process saved
    retook,   \* a process took a version it had or tried before
    replayed, \* a process sent a retired version while a later one was saved
    stale     \* a refusal left saved an older version the process had refreshed away

vars == <<store, held, tried, needs, unsaved, next, dead, chain, erased, retook, replayed, stale>>

TypeOK ==
    /\ store \in 0..MaxVer
    /\ held \in [Procs -> 0..MaxVer]
    /\ tried \in [Procs -> 0..MaxVer]
    /\ needs \in [Procs -> BOOLEAN]
    /\ unsaved \in [Procs -> BOOLEAN]
    /\ next \in 1..(MaxVer + 1)
    /\ dead \subseteq Vers
    /\ chain \in [Vers -> 0..MaxVer]
    /\ erased \in BOOLEAN /\ retook \in BOOLEAN /\ replayed \in BOOLEAN /\ stale \in BOOLEAN

Init ==
    /\ store = 0
    /\ held = [p \in Procs |-> 0]
    /\ tried = [p \in Procs |-> 0]
    /\ needs = [p \in Procs |-> FALSE]
    /\ unsaved = [p \in Procs |-> FALSE]
    /\ next = 1
    /\ dead = {}
    /\ chain = [v \in Vers |-> 0]
    /\ erased = FALSE /\ retook = FALSE /\ replayed = FALSE /\ stale = FALSE

SignIn(p) ==
    /\ next <= MaxVer
    /\ store' = next
    /\ held' = [held EXCEPT ![p] = next]
    /\ tried' = [tried EXCEPT ![p] = next]
    /\ needs' = [needs EXCEPT ![p] = FALSE]
    /\ unsaved' = [unsaved EXCEPT ![p] = FALSE]
    /\ next' = next + 1
    /\ chain' = [chain EXCEPT ![next] = next]
    /\ UNCHANGED <<dead, erased, retook, replayed, stale>>

\* p's tokens drop and it needs a login; it removes the saved login only if
\* that is its own.
Drop(p) ==
    /\ held' = [held EXCEPT ![p] = 0]
    /\ needs' = [needs EXCEPT ![p] = TRUE]
    /\ unsaved' = [unsaved EXCEPT ![p] = FALSE]
    /\ store' = IF store = tried[p] THEN 0 ELSE store
    /\ erased' = (erased \/ (store > tried[p] /\ store' = 0))
    /\ stale' = (stale \/ (store' # 0 /\ store' < held[p] /\ store' \in dead /\ chain[store'] = chain[held[p]]))

Refused(p) ==
    /\ held[p] # 0
    /\ dead' = dead \cup {held[p]}
    /\ Drop(p)
    /\ UNCHANGED <<tried, next, chain, retook, replayed>>

NeedsScope(p) ==
    /\ held[p] # 0
    /\ ~needs[p]
    /\ needs' = [needs EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<store, held, tried, unsaved, next, dead, chain, erased, retook, replayed, stale>>

PickUp(p) ==
    /\ needs[p]
    /\ store # 0
    /\ store # tried[p]
    /\ held' = [held EXCEPT ![p] = store]
    /\ tried' = [tried EXCEPT ![p] = store]
    /\ needs' = [needs EXCEPT ![p] = FALSE]
    /\ unsaved' = [unsaved EXCEPT ![p] = FALSE]
    /\ retook' = (retook \/ store = tried[p])
    /\ UNCHANGED <<store, next, dead, chain, erased, replayed, stale>>

Logout(p) ==
    /\ held[p] # 0
    /\ held' = [held EXCEPT ![p] = 0]
    /\ unsaved' = [unsaved EXCEPT ![p] = FALSE]
    /\ store' = 0
    /\ dead' = {w \in Vers : chain[w] # 0}
    /\ UNCHANGED <<tried, needs, next, chain, erased, retook, replayed, stale>>

\* Another process saved a login this one hasn't had or tried.
Newer(p) == store # 0 /\ store # tried[p]

\* p takes the newer saved login in place of refreshing its own.
Take(p) ==
    /\ held' = [held EXCEPT ![p] = store]
    /\ tried' = [tried EXCEPT ![p] = store]
    /\ unsaved' = [unsaved EXCEPT ![p] = FALSE]
    /\ retook' = (retook \/ store = tried[p])
    /\ UNCHANGED <<store, needs, next, dead, chain, erased, replayed, stale>>

\* The saved login is a later version of v's chain, so sending v was avoidable.
SavedLater(v) == store # 0 /\ chain[store] = chain[v] /\ store > v

\* p sends the version it holds. A working one is retired for the next
\* version, which is saved, or with SaveFaults may fail to be: then the store
\* keeps what it had and p's `tried` stays. A retired one is refused.
Send(p) ==
    LET v == held[p] IN
    IF v \notin dead
    THEN /\ next <= MaxVer
         /\ held' = [held EXCEPT ![p] = next]
         /\ dead' = dead \cup {v}
         /\ chain' = [chain EXCEPT ![next] = chain[v]]
         /\ next' = next + 1
         /\ \/ /\ store' = next
               /\ tried' = [tried EXCEPT ![p] = next]
               /\ unsaved' = [unsaved EXCEPT ![p] = FALSE]
            \/ /\ SaveFaults
               /\ unsaved' = [unsaved EXCEPT ![p] = TRUE]
               /\ UNCHANGED <<store, tried>>
         /\ UNCHANGED <<needs, erased, retook, replayed, stale>>
    ELSE /\ replayed' = (replayed \/ SavedLater(v))
         /\ dead' = IF RevokeOnReplay THEN dead \cup {w \in Vers : chain[w] = chain[v]} ELSE dead
         /\ Drop(p)
         /\ UNCHANGED <<tried, next, chain, retook>>

\* Under the login's refresh lock: a newer saved login if there is one, else
\* a refresh.
Refresh(p) ==
    /\ held[p] # 0 /\ ~needs[p]
    /\ IF Newer(p) THEN Take(p) ELSE Send(p)

\* Nothing happens: a run may end anywhere, so no state is a deadlock.
Idle == UNCHANGED vars

Next ==
    \/ \E p \in Procs :
        SignIn(p) \/ Refused(p) \/ NeedsScope(p) \/ PickUp(p) \/ Logout(p) \/ Refresh(p)
    \/ Idle

Spec == Init /\ [][Next]_vars

\* A refusal never removes a newer login another process saved.
NoNewerLoginErased == ~erased

\* A process never takes a version it had or tried before.
NoLoginRetaken == ~retook

\* What a process holds is the version it last had or tried, unless it
\* couldn't save it; so a refused process removes its own saved login, and
\* only that.
HeldIsTried == \A p \in Procs : held[p] # 0 /\ ~unsaved[p] => held[p] = tried[p]

\* A process never sends a refresh token that a refresh saved in the store
\* has retired.
NoRetiredRefresh == ~replayed

\* A refused process never leaves saved a version it had refreshed away, so
\* nothing takes that one later.
NoStaleLoginLeft == ~stale
====

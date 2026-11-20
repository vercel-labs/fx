---- MODULE RefreshLease ----
\* A login's refresh lock (src/core/mcp_host/credentials.zig
\* Store.tryRefreshLock, src/core/mcp_host/runtime.zig tryRefresh), on a
\* whole-second awake clock.
\*
\* The refresher, one fx, holds the refresh lock across three steps: it looks
\* the saved login up in the store (one Keychain call under the store's
\* lock), sends the refresh and waits up to RefreshMax for the answer
\* (src/mcp/core/request.zig refresh_ms), and saves the answer in the store
\* (a read and a write under the store's lock). Other fx processes use the
\* store meanwhile; the store's lock is leased as in StoreLockBudget.tla: a
\* stamp before each Keychain call, each call within CallMax <= Budget of it,
\* and its waiters give up Budget + Slack after the later of the stamp and
\* their own start. A refresher that gives up on the store, or whose call is
\* cut, goes on without that step's result, as the code does.
\*
\* Another fx waits for the refresh lock, so as to take the login the
\* refresher saves rather than refresh it again with a token already sent.
\* The design: the refresher stamps the refresh lock when it takes it, before
\* it sends the refresh, and before it saves; the waiter goes ahead without
\* the lock only Slack after both that stamp's step (RefreshMax) and the
\* store's lease (Budget + Slack) ran out, each counted from its own start
\* if that is later. The store's lease runs out for the refresher too, when
\* it waits behind a frozen holder: the extra Slack lets it give up on the
\* store and stamp the refresh lock first. Any fx may freeze (ctrl+z) and
\* never act again.
\*
\* NoGoAheadPastLiveRefresher: the waiter goes ahead only behind a frozen
\* refresher.
EXTENDS Naturals

CONSTANTS
    Others,     \* the other fx processes that use the store, once each
    CallMax,    \* one Keychain call's own timeout (s)
    MaxCalls,   \* Keychain calls another fx's hold makes, at most
    Budget,     \* how old a live store holder's stamp gets (s)
    Slack,      \* what a waiter allows past a stamp (s)
    RefreshMax  \* how long a sent refresh waits for its answer (s)

R == "refresher"

VARIABLES
    now,
    sOwner,      \* who holds the store's lock: an Other, R, or "none"
    storeStamp,  \* the store lock file's stamp
    oState,      \* Other -> "ready" | "holding" | "done"
    oNeeds, oCalls, oIn, oCallAt, oStamped,
    phase,       \* R: "lookup" | "network" | "save" | "done"
    rHold,       \* R holds the store's lock for this step
    rCalls, rIn, rCallAt, rStamped,
    rWaitAt,     \* when R began waiting for the store in this step
    netAt,       \* when R sent the refresh
    rStamp,      \* the refresh lock file's stamp
    frozen,      \* the processes that froze: Others and R
    w            \* the waiter: "waiting" | "got" | "went"

vars == <<now, sOwner, storeStamp, oState, oNeeds, oCalls, oIn, oCallAt, oStamped,
          phase, rHold, rCalls, rIn, rCallAt, rStamped, rWaitAt, netAt, rStamp, frozen, w>>

\* The waiter started at 0.
WStart == 0

Max(a, b) == IF a > b THEN a ELSE b

\* What R's step makes under the store's lock: a lookup reads, a save reads and writes.
RNeeds == IF phase = "lookup" THEN 1 ELSE 2

RWantsStore == phase \in {"lookup", "save"} /\ ~rHold
RLive == phase # "done" /\ ~(R \in frozen)
OLive(o) == sOwner = o /\ ~(o \in frozen)
OOver(o) == oIn[o] /\ now - oCallAt[o] >= CallMax
ROver == rIn /\ now - rCallAt >= CallMax

\* R gives up on the store as any waiter does.
RStoreExpired == now >= Max(storeStamp, rWaitAt) + Budget + Slack

\* The waiter's rule for going ahead without the lock.
GoAhead ==
    now >= Max(Max(rStamp, WStart) + RefreshMax, Max(storeStamp, WStart) + Budget + Slack) + Slack

TypeOK ==
    /\ sOwner \in Others \cup {R, "none"}
    /\ phase \in {"lookup", "network", "save", "done"}
    /\ w \in {"waiting", "got", "went"}

Init ==
    /\ now = 0
    /\ sOwner = "none" /\ storeStamp = 0
    /\ oState = [o \in Others |-> "ready"]
    /\ oNeeds \in [Others -> 1..MaxCalls]
    /\ oCalls = [o \in Others |-> 0]
    /\ oIn = [o \in Others |-> FALSE]
    /\ oCallAt = [o \in Others |-> 0]
    /\ oStamped = [o \in Others |-> FALSE]
    \* R has just taken the refresh lock and stamped it.
    /\ phase = "lookup" /\ rHold = FALSE /\ rCalls = 0 /\ rIn = FALSE /\ rCallAt = 0
    /\ rStamped = FALSE /\ rWaitAt = 0 /\ netAt = 0 /\ rStamp = 0
    /\ frozen = {}
    /\ w = "waiting"

OVars == <<oState, oNeeds, oCalls, oIn, oCallAt, oStamped>>
RVars == <<phase, rHold, rCalls, rIn, rCallAt, rStamped, rWaitAt, netAt, rStamp>>

\* Another fx takes the free store lock whenever it likes.
OAcquire(o) ==
    /\ sOwner = "none" /\ oState[o] = "ready" /\ ~(o \in frozen)
    /\ sOwner' = o
    /\ oState' = [oState EXCEPT ![o] = "holding"]
    /\ UNCHANGED <<now, storeStamp, oNeeds, oCalls, oIn, oCallAt, oStamped, frozen, w>> /\ UNCHANGED RVars

OStamp(o) ==
    /\ OLive(o) /\ ~oStamped[o] /\ ~oIn[o] /\ oCalls[o] < oNeeds[o]
    /\ oStamped' = [oStamped EXCEPT ![o] = TRUE]
    /\ storeStamp' = now
    /\ UNCHANGED <<now, sOwner, oState, oNeeds, oCalls, oIn, oCallAt, frozen, w>> /\ UNCHANGED RVars

OStartCall(o) ==
    /\ OLive(o) /\ oStamped[o] /\ ~oIn[o]
    /\ oIn' = [oIn EXCEPT ![o] = TRUE]
    /\ oCallAt' = [oCallAt EXCEPT ![o] = now]
    /\ oStamped' = [oStamped EXCEPT ![o] = FALSE]
    /\ UNCHANGED <<now, sOwner, storeStamp, oState, oNeeds, oCalls, frozen, w>> /\ UNCHANGED RVars

OEndCall(o) ==
    /\ OLive(o) /\ oIn[o] /\ ~OOver(o)
    /\ oIn' = [oIn EXCEPT ![o] = FALSE]
    /\ oCalls' = [oCalls EXCEPT ![o] = @ + 1]
    /\ UNCHANGED <<now, sOwner, storeStamp, oState, oNeeds, oCallAt, oStamped, frozen, w>> /\ UNCHANGED RVars

\* Done, or its call cut: either way it lets the lock go.
ORelease(o) ==
    /\ OLive(o)
    /\ (~oIn[o] /\ oCalls[o] = oNeeds[o]) \/ OOver(o)
    /\ sOwner' = "none"
    /\ oState' = [oState EXCEPT ![o] = "done"]
    /\ oIn' = [oIn EXCEPT ![o] = FALSE]
    /\ UNCHANGED <<now, storeStamp, oNeeds, oCalls, oCallAt, oStamped, frozen, w>> /\ UNCHANGED RVars

\* R moves to its next step; sending the refresh or saving stamps the refresh lock first.
RNext(p) ==
    /\ phase' = p
    /\ rHold' = FALSE /\ rCalls' = 0 /\ rIn' = FALSE /\ rStamped' = FALSE
    /\ rWaitAt' = now
    /\ netAt' = IF p = "network" THEN now ELSE netAt
    /\ rStamp' = IF p \in {"network", "save"} THEN now ELSE rStamp

RAcquire ==
    /\ RLive /\ RWantsStore /\ sOwner = "none"
    /\ sOwner' = R /\ rHold' = TRUE
    /\ UNCHANGED <<now, storeStamp, phase, rCalls, rIn, rCallAt, rStamped, rWaitAt, netAt, rStamp, frozen, w>> /\ UNCHANGED OVars

RStampStore ==
    /\ RLive /\ rHold /\ ~rStamped /\ ~rIn /\ rCalls < RNeeds
    /\ rStamped' = TRUE /\ storeStamp' = now
    /\ UNCHANGED <<now, sOwner, phase, rHold, rCalls, rIn, rCallAt, rWaitAt, netAt, rStamp, frozen, w>> /\ UNCHANGED OVars

RStartCall ==
    /\ RLive /\ rHold /\ rStamped /\ ~rIn
    /\ rIn' = TRUE /\ rCallAt' = now /\ rStamped' = FALSE
    /\ UNCHANGED <<now, sOwner, storeStamp, phase, rHold, rCalls, rWaitAt, netAt, rStamp, frozen, w>> /\ UNCHANGED OVars

REndCall ==
    /\ RLive /\ rIn /\ ~ROver
    /\ rIn' = FALSE /\ rCalls' = rCalls + 1
    /\ UNCHANGED <<now, sOwner, storeStamp, phase, rHold, rCallAt, rStamped, rWaitAt, netAt, rStamp, frozen, w>> /\ UNCHANGED OVars

\* The step's hold ends, done or cut; a lookup goes on to the refresh either way, a save ends it.
RRelease ==
    /\ RLive /\ rHold
    /\ (~rIn /\ rCalls = RNeeds) \/ ROver
    /\ sOwner' = "none"
    /\ RNext(IF phase = "lookup" THEN "network" ELSE "done")
    /\ UNCHANGED <<now, storeStamp, rCallAt, frozen, w>> /\ UNCHANGED OVars

RGiveUpStore ==
    /\ RLive /\ RWantsStore /\ sOwner # "none" /\ RStoreExpired
    /\ RNext(IF phase = "lookup" THEN "network" ELSE "done")
    /\ UNCHANGED <<now, sOwner, storeStamp, rCallAt, frozen, w>> /\ UNCHANGED OVars

\* The answer comes before the refresh's timeout; at it, the refresh fails.
RAnswer ==
    /\ RLive /\ phase = "network" /\ now - netAt < RefreshMax
    /\ RNext("save")
    /\ UNCHANGED <<now, sOwner, storeStamp, rCallAt, frozen, w>> /\ UNCHANGED OVars

RTimeout ==
    /\ RLive /\ phase = "network" /\ now - netAt >= RefreshMax
    /\ RNext("done")
    /\ UNCHANGED <<now, sOwner, storeStamp, rCallAt, frozen, w>> /\ UNCHANGED OVars

Freeze(p) ==
    /\ p \notin frozen
    /\ IF p = R THEN RLive ELSE OLive(p)
    /\ frozen' = frozen \cup {p}
    /\ UNCHANGED <<now, sOwner, storeStamp, w>> /\ UNCHANGED OVars /\ UNCHANGED RVars

WGet ==
    /\ w = "waiting" /\ phase = "done"
    /\ w' = "got"
    /\ UNCHANGED <<now, sOwner, storeStamp, frozen>> /\ UNCHANGED OVars /\ UNCHANGED RVars

WGoAhead ==
    /\ w = "waiting" /\ phase # "done" /\ GoAhead
    /\ w' = "went"
    /\ UNCHANGED <<now, sOwner, storeStamp, frozen>> /\ UNCHANGED OVars /\ UNCHANGED RVars

\* What happens before time moves on: a live process's next step and its
\* timeouts, and the waiter's poll.
Due ==
    \/ \E o \in Others : OLive(o) /\ (~oIn[o] \/ OOver(o))
    \/ RLive /\ rHold /\ (~rIn \/ ROver)
    \/ RLive /\ RWantsStore /\ (sOwner = "none" \/ RStoreExpired)
    \/ RLive /\ phase = "network" /\ now - netAt >= RefreshMax
    \/ phase = "done"
    \/ GoAhead

Tick ==
    /\ w = "waiting" /\ ~Due
    /\ now' = now + 1
    /\ UNCHANGED <<sOwner, storeStamp, frozen, w>> /\ UNCHANGED OVars /\ UNCHANGED RVars

Next ==
    \/ \E o \in Others : OAcquire(o) \/ OStamp(o) \/ OStartCall(o) \/ OEndCall(o) \/ ORelease(o)
    \/ RAcquire \/ RStampStore \/ RStartCall \/ REndCall \/ RRelease \/ RGiveUpStore \/ RAnswer \/ RTimeout
    \/ \E p \in Others \cup {R} : Freeze(p)
    \/ WGet \/ WGoAhead \/ Tick

Spec == Init /\ [][Next]_vars

NoGoAheadPastLiveRefresher == w = "went" => R \in frozen
====

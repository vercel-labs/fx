---------------------------- MODULE CacheWarming ----------------------------
(***************************************************************************)
(* Claude cache warming (src/core/agent/runtime/cache_warming.zig and the  *)
(* warmer in cache_warmer.zig). Anthropic keeps a prompt cache entry for   *)
(* TTL after the start of the newest request that read or wrote it. While *)
(* fx waits for the user, or for a long tool run, the warmer resends the   *)
(* last real request with a one-token reply just before the entry expires, *)
(* so the next real request reads the conversation instead of writing it   *)
(* again. Pings stop Cap after the real request that armed them.           *)
(*                                                                         *)
(* Time is a discrete clock. Every age counts ticks since an event and     *)
(* saturates, so the state space is finite. The planner is armed by a      *)
(* completed real request and disarmed by the next send, a session change, *)
(* or shutdown. It wakes at the planned time; a wake can come late after   *)
(* the machine sleeps. The provider side is the entry's age: it is alive   *)
(* while cacheAge < TTL, a request that starts on a live entry refreshes   *)
(* it, and the provider may evict it early.                                *)
(*                                                                         *)
(* Bug plants one defect for the mutation configs:                         *)
(*   ping_at_ttl        pings when the entry expires, not before           *)
(*   no_cap             keeps pinging past Cap                             *)
(*   no_late_check      pings after a sleep that outlived the entry        *)
(*   stale_finish       applies a ping's answer after the session moved on *)
(*   ping_while_sending wakes and pings while a real request is out        *)
(*   no_shutdown_cancel leaves a ping running after shutdown               *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    TTL,       \* the entry's lifetime, in ticks
    Cap,       \* pings stop this long after the real request that armed them
    MaxSend,   \* ticks a real request may stay on the wire
    MaxSleep,  \* the longest the machine sleeps at once
    Bug

ASSUME /\ TTL \in 10..40 /\ Cap \in TTL..(4 * TTL)
       /\ MaxSend \in 1..TTL /\ MaxSleep \in 2..(2 * TTL)

\* cache_warming.zig Timing: ping a tenth of the lifetime before expiry, and
\* give up on a wake later than half the remaining margin.
Interval == IF Bug = "ping_at_ttl" THEN TTL ELSE TTL - TTL \div 10
Late == (TTL - (TTL - TTL \div 10)) \div 2
MaxPings == Cap \div (TTL - TTL \div 10)

Stops == {"none", "disarmed", "cap", "late", "failed", "missed"}

VARIABLES
    awake,      \* the session is open
    sending,    \* a real request is on the wire
    sendAge,    \* ticks since it started
    armed,      \* the planner holds a request to keep warm
    touchAge,   \* ticks since the start of the newest request the planner
                \* knows touched the entry (the armed request or an answered ping)
    reqAge,     \* ticks since the armed real request started
    pings,      \* pings since the planner was armed
    inflight,   \* a ping is on the wire
    pingAge,    \* ticks since it started
    pingStale,  \* the planner was disarmed or re-armed since it started
    pingHit,    \* it started on a live entry
    cacheAge,   \* ticks since the provider last refreshed the entry
    slept,      \* the machine slept since the planner's last touch
    evicted,    \* the provider evicted the entry since the planner's last touch
    stopped,    \* why the planner last stopped
    staleStop,  \* the planner stopped on the answer of a stale ping
    writes      \* pings that started on an expired entry without an eviction

vars == <<awake, sending, sendAge, armed, touchAge, reqAge, pings, inflight,
          pingAge, pingStale, pingHit, cacheAge, slept, evicted, stopped,
          staleStop, writes>>

Sat(n, max) == IF n > max THEN max ELSE n
Alive == cacheAge < TTL

TypeOK ==
    /\ awake \in BOOLEAN /\ sending \in BOOLEAN /\ sendAge \in 0..(TTL + 1)
    /\ armed \in BOOLEAN /\ touchAge \in 0..(TTL + 1) /\ reqAge \in 0..(Cap + TTL + 1)
    /\ pings \in 0..(MaxPings + 2) /\ inflight \in BOOLEAN /\ pingAge \in 0..1
    /\ pingStale \in BOOLEAN /\ pingHit \in BOOLEAN /\ cacheAge \in 0..TTL
    /\ slept \in BOOLEAN /\ evicted \in BOOLEAN /\ stopped \in Stops
    /\ staleStop \in BOOLEAN /\ writes \in 0..1

Init ==
    /\ awake = TRUE /\ sending = FALSE /\ sendAge = 0
    /\ armed = FALSE /\ touchAge = 0 /\ reqAge = 0 /\ pings = 0
    /\ inflight = FALSE /\ pingAge = 0 /\ pingStale = FALSE /\ pingHit = FALSE
    /\ cacheAge = TTL /\ slept = FALSE /\ evicted = FALSE
    /\ stopped = "none" /\ staleStop = FALSE /\ writes = 0

\* After an arm or an answered ping, the planner plans its next ping. A ping
\* that would start past Cap is never planned (cache_warming.zig next).
PastCap(touch, req) == Bug # "no_cap" /\ (req - touch) + Interval > Cap

\* --- the user and the agent loop ---------------------------------------

\* A real request goes out: the planner is disarmed first, and the request
\* refreshes or rewrites the entry at its start.
Send ==
    /\ awake /\ ~sending
    /\ sending' = TRUE /\ sendAge' = 0
    /\ armed' = FALSE
    /\ stopped' = IF armed THEN "disarmed" ELSE stopped
    /\ pingStale' = (inflight \/ pingStale)
    /\ cacheAge' = 0 /\ evicted' = FALSE
    /\ UNCHANGED <<awake, touchAge, reqAge, pings, inflight, pingAge, pingHit,
                   slept, staleStop, writes>>

\* It completes: the planner is armed with the request's start time.
Complete ==
    /\ sending
    /\ sending' = FALSE
    /\ IF PastCap(sendAge, sendAge) \/ sendAge > Interval + Late
       THEN /\ armed' = FALSE
            /\ stopped' = IF sendAge > Interval + Late THEN "late" ELSE "cap"
       ELSE /\ armed' = TRUE /\ stopped' = "none"
    /\ touchAge' = sendAge /\ reqAge' = sendAge /\ pings' = 0
    /\ pingStale' = (inflight \/ pingStale)
    \* the touch is the request's start, so an eviction while it streamed stays
    /\ slept' = FALSE /\ staleStop' = FALSE
    /\ UNCHANGED <<awake, sendAge, inflight, pingAge, pingHit, cacheAge, evicted, writes>>

\* It fails: nothing is armed.
Fail ==
    /\ sending
    /\ sending' = FALSE
    /\ UNCHANGED <<awake, sendAge, armed, touchAge, reqAge, pings, inflight,
                   pingAge, pingStale, pingHit, cacheAge, slept, evicted,
                   stopped, staleStop, writes>>

\* The session is reset, cleared, restored, switches model, or warming is
\* turned off: the armed request no longer matches the next one.
Reset ==
    /\ awake /\ armed
    /\ armed' = FALSE /\ stopped' = "disarmed"
    /\ pingStale' = (inflight \/ pingStale)
    /\ UNCHANGED <<awake, sending, sendAge, touchAge, reqAge, pings, inflight,
                   pingAge, pingHit, cacheAge, slept, evicted, staleStop, writes>>

\* fx closes the session: the warmer cancels its ping and stops.
Shutdown ==
    /\ awake
    /\ awake' = FALSE /\ armed' = FALSE /\ sending' = FALSE
    /\ inflight' = (Bug = "no_shutdown_cancel" /\ inflight)
    /\ stopped' = IF armed THEN "disarmed" ELSE stopped
    /\ UNCHANGED <<sendAge, touchAge, reqAge, pings, pingAge, pingStale,
                   pingHit, cacheAge, slept, evicted, staleStop, writes>>

\* --- the planner ------------------------------------------------------

\* The timer fires at the planned time, or later after a sleep.
CanWake ==
    /\ awake /\ ~inflight /\ touchAge >= Interval
    /\ (armed \/ (Bug = "ping_while_sending" /\ sending))

Wake ==
    /\ CanWake
    /\ IF touchAge > Interval + Late /\ Bug # "no_late_check"
       THEN /\ armed' = FALSE /\ stopped' = "late"
            /\ UNCHANGED <<inflight, pingAge, pingStale, pingHit, pings, cacheAge,
                           writes, slept, evicted>>
       ELSE /\ inflight' = TRUE /\ pingAge' = 0 /\ pingStale' = FALSE
            /\ pingHit' = Alive
            /\ pings' = Sat(pings + 1, MaxPings + 2)
            \* the provider refreshes a live entry, or rewrites an expired one
            /\ cacheAge' = 0
            /\ writes' = IF ~Alive /\ ~evicted THEN 1 ELSE writes
            \* the ping touches the entry at its start
            /\ slept' = FALSE /\ evicted' = FALSE
            /\ UNCHANGED <<armed, stopped>>
    /\ UNCHANGED <<awake, sending, sendAge, touchAge, reqAge, staleStop>>

\* The ping's answer. A stale answer changes nothing the planner holds.
Answer(outcome) ==
    /\ inflight
    /\ outcome \in (IF pingHit THEN {"read", "failed"} ELSE {"missed", "failed"})
    /\ inflight' = FALSE
    /\ IF pingStale /\ Bug # "stale_finish"
       THEN UNCHANGED <<armed, touchAge, stopped, staleStop>>
       ELSE IF outcome = "read"
            THEN /\ touchAge' = pingAge
                 /\ IF armed /\ PastCap(pingAge, reqAge)
                    THEN armed' = FALSE /\ stopped' = "cap"
                    ELSE UNCHANGED <<armed, stopped>>
                 /\ UNCHANGED staleStop
            ELSE /\ armed' = FALSE
                 /\ stopped' = IF armed \/ pingStale THEN outcome ELSE stopped
                 /\ staleStop' = (pingStale /\ armed)
                 /\ UNCHANGED touchAge
    /\ UNCHANGED <<awake, sending, sendAge, reqAge, pings, pingAge, pingStale,
                   pingHit, cacheAge, slept, evicted, writes>>

\* --- the world --------------------------------------------------------

\* The planner's timer, the ping's answer, and a real request's answer are
\* due: time does not pass them (the deadlines in cache_warmer.zig).
Urgent ==
    \/ CanWake
    \/ (inflight /\ pingAge = 1)
    \/ (sending /\ sendAge = MaxSend)

Age(d) ==
    /\ touchAge' = Sat(touchAge + d, TTL + 1)
    /\ reqAge' = Sat(reqAge + d, Cap + TTL + 1)
    /\ sendAge' = IF sending THEN Sat(sendAge + d, TTL + 1) ELSE sendAge
    /\ pingAge' = IF inflight THEN Sat(pingAge + d, 1) ELSE pingAge
    /\ cacheAge' = Sat(cacheAge + d, TTL)

Tick ==
    /\ awake /\ ~Urgent
    /\ Age(1)
    /\ UNCHANGED <<awake, sending, armed, pings, inflight, pingStale, pingHit,
                   slept, evicted, stopped, staleStop, writes>>

\* The machine sleeps: no timer fires and nothing answers meanwhile.
Sleep ==
    /\ awake /\ ~inflight /\ ~sending
    /\ \E d \in 2..MaxSleep : Age(d)
    /\ slept' = TRUE
    /\ UNCHANGED <<awake, sending, armed, pings, inflight, pingStale, pingHit,
                   evicted, stopped, staleStop, writes>>

\* The provider drops the entry early.
Evict ==
    /\ awake /\ Alive
    /\ cacheAge' = TTL /\ evicted' = TRUE
    /\ UNCHANGED <<awake, sending, sendAge, armed, touchAge, reqAge, pings,
                   inflight, pingAge, pingStale, pingHit, slept, stopped,
                   staleStop, writes>>

\* A closed session stays closed.
Closed == ~awake /\ UNCHANGED vars

Next ==
    \/ Send \/ Complete \/ Fail \/ Reset \/ Shutdown
    \/ Wake \/ \E o \in {"read", "missed", "failed"} : Answer(o)
    \/ Tick \/ Sleep \/ Evict \/ Closed

Spec == Init /\ [][Next]_vars

\* --- what must hold ---------------------------------------------------

\* A ping never starts on an entry the provider did not evict early: every
\* ping is a cheap read, never a full write.
NoWritingPing == writes = 0

\* While armed, and unless the machine slept or the provider evicted it,
\* the entry is alive: the pings come in time.
KeepsAlive == (armed /\ ~slept /\ ~evicted) => Alive

\* Pings start only within Cap of the real request that armed them.
PingWithinCap == [][Wake /\ inflight' => reqAge <= Cap]_vars

\* No more pings per arm than Cap allows.
PingsBounded == pings <= MaxPings

\* A ping never overlaps a real request the planner was disarmed for.
NoPingWhileSending == (inflight /\ ~pingStale) => ~sending

\* After shutdown nothing is armed and no ping is on the wire.
NoPingAfterShutdown == ~awake => (~armed /\ ~inflight)

\* A stale ping's failure never stops the warming of a newer request.
NoStaleStop == ~staleStop

=============================================================================

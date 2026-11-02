---------------------------- MODULE LeanUsage ----------------------------
(***************************************************************************)
(* The lean /usage refresh model (src/usage/policy.zig, view.zig).        *)
(*                                                                         *)
(* Several fx processes share one cache file. Each process may have the   *)
(* dashboard open, holds one active credential identity, and runs at most *)
(* one fetch at a time. A fetch always reads "today" and, at most once per *)
(* UTC day per identity, the finished days of the 7d and 30d windows.      *)
(* Time is abstract ticks; DAY ticks make one UTC day.                     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Procs, Idents, None, FLOOR, TIMER, DAY, MAXT

ASSUME FLOOR \in Nat \ {0} /\ TIMER \in Nat /\ TIMER > FLOOR /\ DAY \in Nat \ {0}

VARIABLES
    now,        \* abstract clock
    ident,      \* active credential identity per process
    open,       \* whether the dashboard is on screen per process
    inflight,   \* the fetch a process is running, or None
    lastStart,  \* when a process last started a fetch, or None
    failedAt,   \* when a process's last fetch failed, or None
    cache,      \* the shared cache file: one record per identity
    shown,      \* what each process has rendered
    finCount    \* ghost: finished-days fetches per process, identity and day

vars == <<now, ident, open, inflight, lastStart, failedAt, cache, shown, finCount>>

Day(t) == t \div DAY
Days == 0..Day(MAXT)
Times == 0..MAXT
Opt(S) == S \cup {None}

EmptyRec == [todayDay |-> None, todayAt |-> None, finDay |-> None]

\* What the dashboard renders for identity i from cache c at time t. Today's
\* numbers show only when they belong to the current UTC day; finished days
\* show as current only when fetched today.
ViewOf(c, i, t) ==
    [ident |-> i,
     today |-> IF c[i].todayDay = Day(t) THEN c[i].todayAt ELSE None,
     finCurrent |-> c[i].finDay = Day(t)]

Hidden == [ident |-> None, today |-> None, finCurrent |-> FALSE]

TypeOK ==
    /\ now \in Times
    /\ ident \in [Procs -> Idents]
    /\ open \in [Procs -> BOOLEAN]
    /\ inflight \in [Procs -> Opt([ident : Idents, at : Times, fin : BOOLEAN])]
    /\ lastStart \in [Procs -> Opt(Times)]
    /\ failedAt \in [Procs -> Opt(Times)]
    /\ cache \in [Idents -> [todayDay : Opt(Days), todayAt : Opt(Times), finDay : Opt(Days)]]
    /\ finCount \in [Procs -> [Idents -> [Days -> Nat]]]

Init ==
    /\ now = 0
    /\ ident \in [Procs -> Idents]
    /\ open = [p \in Procs |-> FALSE]
    /\ inflight = [p \in Procs |-> None]
    /\ lastStart = [p \in Procs |-> None]
    /\ failedAt = [p \in Procs |-> None]
    /\ cache = [i \in Idents |-> EmptyRec]
    /\ shown = [p \in Procs |-> Hidden]
    /\ finCount = [p \in Procs |-> [i \in Idents |-> [d \in Days |-> 0]]]

\* At least FLOOR ticks since this process's last fetch started and since its
\* last failure, and nothing in flight.
\* At least n ticks have passed since t (TLC splits \/ inside actions, so the
\* None case is an IF).
Since(t, n) == IF t = None THEN TRUE ELSE now - t >= n

FloorClear(p) ==
    /\ inflight[p] = None
    /\ Since(lastStart[p], FLOOR)
    /\ Since(failedAt[p], FLOOR)

\* Start a fetch for p's identity. The finished days ride along only when
\* the cache does not already hold today's finished days for that identity.
StartFetch(p) ==
    LET i == ident[p]
        fin == cache[i].finDay # Day(now)
    IN /\ inflight' = [inflight EXCEPT ![p] = [ident |-> i, at |-> now, fin |-> fin]]
       /\ lastStart' = [lastStart EXCEPT ![p] = now]

Tick ==
    /\ now < MAXT
    /\ now' = now + 1
    \* Views are recomputed at render time, so a day change hides yesterday's
    \* "today" numbers immediately.
    /\ shown' = [p \in Procs |-> IF open[p] THEN ViewOf(cache, ident[p], now + 1) ELSE shown[p]]
    /\ UNCHANGED <<ident, open, inflight, lastStart, failedAt, cache, finCount>>

\* Enter on /usage: render from cache at once, and fetch when the floor allows.
Open(p) ==
    /\ ~open[p]
    /\ open' = [open EXCEPT ![p] = TRUE]
    /\ shown' = [shown EXCEPT ![p] = ViewOf(cache, ident[p], now)]
    /\ IF FloorClear(p)
       THEN StartFetch(p)
       ELSE UNCHANGED <<inflight, lastStart>>
    /\ UNCHANGED <<now, ident, failedAt, cache, finCount>>

Close(p) ==
    /\ open[p]
    /\ open' = [open EXCEPT ![p] = FALSE]
    /\ shown' = [shown EXCEPT ![p] = Hidden]
    /\ UNCHANGED <<now, ident, inflight, lastStart, failedAt, cache, finCount>>

\* Every redraw renders from the shared cache, so an open dashboard picks up
\* what another process stored as soon as it redraws for any reason.
Redraw(p) == [shown EXCEPT ![p] = IF open[p] THEN ViewOf(cache, ident[p], now) ELSE shown[p]]

\* r while the dashboard is open. Starting a fetch redraws.
Manual(p) ==
    /\ open[p]
    /\ FloorClear(p)
    /\ StartFetch(p)
    /\ shown' = Redraw(p)
    /\ UNCHANGED <<now, ident, open, failedAt, cache, finCount>>

\* The 15-minute refresh while the dashboard stays open.
Timer(p) ==
    /\ open[p]
    /\ FloorClear(p)
    /\ lastStart[p] # None
    /\ Since(lastStart[p], TIMER)
    /\ StartFetch(p)
    /\ shown' = Redraw(p)
    /\ UNCHANGED <<now, ident, open, failedAt, cache, finCount>>

\* A fetch returns. It writes the shared cache only when it is newer than
\* what another process already stored, and p's dashboard re-renders only
\* for p's current identity.
Complete(p) ==
    LET f == inflight[p]
        i == f.ident
        newer == IF cache[i].todayAt = None THEN TRUE ELSE f.at >= cache[i].todayAt
        rec == [todayDay |-> Day(f.at),
                todayAt |-> f.at,
                finDay |-> IF f.fin THEN Day(f.at) ELSE cache[i].finDay]
        c2 == IF newer THEN [cache EXCEPT ![i] = rec] ELSE cache
    IN /\ f # None
       /\ cache' = c2
       /\ inflight' = [inflight EXCEPT ![p] = None]
       /\ failedAt' = [failedAt EXCEPT ![p] = None]
       /\ shown' = [q \in Procs |->
                       IF q = p /\ open[q] THEN ViewOf(c2, ident[q], now) ELSE shown[q]]
       /\ finCount' = IF newer /\ f.fin
                      THEN [finCount EXCEPT ![p][i][Day(f.at)] = @ + 1]
                      ELSE finCount
       /\ UNCHANGED <<now, ident, open, lastStart>>

\* A failed fetch stores nothing; the dashboard redraws to say so.
Fail(p) ==
    /\ inflight[p] # None
    /\ inflight' = [inflight EXCEPT ![p] = None]
    /\ failedAt' = [failedAt EXCEPT ![p] = now]
    /\ shown' = Redraw(p)
    /\ UNCHANGED <<now, ident, open, lastStart, cache, finCount>>

\* The user switches credential or team. The dashboard re-renders from the
\* new identity's cache at once; a fetch still in flight finishes against the
\* old identity's record.
Switch(p, j) ==
    /\ j # ident[p]
    /\ ident' = [ident EXCEPT ![p] = j]
    /\ shown' = [shown EXCEPT ![p] = IF open[p] THEN ViewOf(cache, j, now) ELSE Hidden]
    /\ UNCHANGED <<now, open, inflight, lastStart, failedAt, cache, finCount>>

Next ==
    \/ Tick
    \/ \E p \in Procs :
          \/ Open(p) \/ Close(p) \/ Manual(p) \/ Timer(p) \/ Complete(p) \/ Fail(p)
          \/ \E j \in Idents : Switch(p, j)

Spec == Init /\ [][Next]_vars

---------------------------------------------------------------------------
(* Safety properties.                                                      *)

\* An open dashboard only ever shows its own identity's numbers.
ShowsOwnIdentity == \A p \in Procs : open[p] => shown[p].ident = ident[p]

\* "Today" on screen always belongs to the current UTC day.
TodayIsToday ==
    \A p \in Procs : open[p] /\ shown[p].today # None => Day(shown[p].today) = Day(now)

\* Each process stores an identity's finished days at most once per UTC day;
\* a failed fetch stores nothing, so its retry is not a second fetch.
FinishedOncePerDay ==
    \A p \in Procs, i \in Idents, d \in Days : finCount[p][i][d] <= 1

\* Across processes, at most one stored finished-days fetch per process.
FinishedBounded ==
    \A i \in Idents, d \in Days :
        LET total[S \in SUBSET Procs] ==
                IF S = {} THEN 0
                ELSE LET q == CHOOSE x \in S : TRUE IN finCount[q][i][d] + total[S \ {q}]
        IN total[Procs] <= Cardinality(Procs)

\* Fetches start only with the dashboard open, never closer than FLOOR.
FetchRules ==
    [][\A p \in Procs :
         (inflight[p] = None /\ inflight'[p] # None) =>
             /\ open[p] \/ open'[p]
             /\ Since(lastStart[p], FLOOR)]_vars

\* The cache never moves back to an older "today".
CacheNeverRegresses ==
    [][\A i \in Idents :
         IF cache[i].todayAt = None THEN TRUE
         ELSE cache'[i].todayAt # None /\ cache'[i].todayAt >= cache[i].todayAt]_vars
=============================================================================

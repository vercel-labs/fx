------------------------------ MODULE UsageModel ------------------------------
(***************************************************************************)
(* fx `/usage` refresh and shared cache (src/usage/policy.zig, cache.zig,  *)
(* view.zig, usage.zig `Dashboard`), in ideal and non-ideal conditions.    *)
(*                                                                         *)
(* Several fx processes share one cache file per identity. A process may   *)
(* have the dashboard open, holds one identity and the entry it last read  *)
(* or stored (`mem`), and runs at most one fetch at a time. A fetch always *)
(* reads today, and reads the finished days of the 7d and month views only *)
(* when its entry lacks that day's copy.                                   *)
(*                                                                         *)
(* Reads follow `reloadEntryLocked`: a readable file replaces the entry in *)
(* memory, a missing or unreadable one keeps it. Stores follow             *)
(* `cache.store`: read the file under the lock (an unreadable file reads   *)
(* as empty), merge (today by fetch start, finished days by day), write by *)
(* rename, and keep the result as the entry.                               *)
(*                                                                         *)
(* `now` is real time in ticks. fx reads the wall clock `Wall`, which is   *)
(* `now + skew`; every timestamp fx stores or compares is wall time.       *)
(*                                                                         *)
(* A store also merges the storing process's own entry                    *)
(* (`Dashboard.ownedEntryFor`), if it is for the same identity, so no      *)
(* process stores less than it holds.                                      *)
(*                                                                         *)
(* HOSTILE adds failed fetches and processes killed at any point and       *)
(* started again; CORRUPT adds a cache file something else made            *)
(* unreadable (garbage, or another fx version's schema); SKEW > 0 adds one *)
(* backward wall-clock correction. MAXFAULTS bounds crashes, corruptions   *)
(* and the clock jump together.                                            *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS Procs, Idents, None, FLOOR, TIMER, DAY, MAXT, SKEW, HOSTILE, CORRUPT, MAXFAULTS

ASSUME FLOOR \in Nat \ {0} /\ TIMER > FLOOR /\ DAY \in Nat \ {0}
ASSUME SKEW \in Nat /\ HOSTILE \in BOOLEAN /\ CORRUPT \in BOOLEAN /\ MAXFAULTS \in Nat

VARIABLES
    now,         \* real time
    skew,        \* wall clock minus real time (0, or -SKEW after the jump)
    ident,       \* identity per process
    open,        \* dashboard on screen per process
    inflight,    \* the fetch a process is running, or None
    lastStart,   \* wall time a process last started a fetch, or None
    failedAt,    \* wall time a process's last fetch failed, or None
    owed,        \* a new sign-in's first fetch is still to start (Dashboard.fetch_owed)
    cache,       \* the shared cache file's content per identity
    corrupt,     \* whether that file is unreadable
    mem,         \* the entry each process holds for its identity
    shown,       \* what each process renders
    finCount,    \* ghost: successful finished-days reads per process, identity, day
    corruptions, \* ghost: times each identity's file was made unreadable
    faults       \* crashes, corruptions and clock jumps so far

vars == <<now, skew, ident, open, inflight, lastStart, failedAt, owed, cache, corrupt, mem, shown, finCount, corruptions, faults>>

Wall == now + skew
Day(t) == t \div DAY
Days == 0..Day(MAXT)
Times == 0..MAXT
Opt(S) == S \cup {None}

EmptyRec == [todayDay |-> None, todayAt |-> None, finDay |-> None]
Recs == [todayDay : Opt(Days), todayAt : Opt(Times), finDay : Opt(Days)]

\* view.build: today counts only on its own UTC day; finished rows count
\* whatever their day (the 7d row is finished + today).
ViewOf(r, i, w) ==
    [ident |-> i,
     today |-> IF r.todayDay = Day(w) THEN r.todayAt ELSE None,
     fin |-> r.finDay]

Hidden == [ident |-> None, today |-> None, fin |-> None]

\* cache.merge of record x (kept) with record y (incoming) at wall time w:
\* the newer of each part; a kept today stamped after w, and finished days
\* for a later day than w's on either side, do not count.
Newer(x, y, w) ==
    LET xToday == x.todayAt # None /\ x.todayAt <= w
        takeY == y.todayAt # None /\ (~xToday \/ y.todayAt >= x.todayAt)
        xFin == IF x.finDay # None /\ x.finDay <= Day(w) THEN x.finDay ELSE None
        yFin == IF y.finDay # None /\ y.finDay <= Day(w) THEN y.finDay ELSE None
    IN [todayDay |-> IF takeY THEN y.todayDay ELSE IF xToday THEN x.todayDay ELSE None,
        todayAt |-> IF takeY THEN y.todayAt ELSE IF xToday THEN x.todayAt ELSE None,
        finDay |-> IF yFin # None /\ (xFin = None \/ yFin >= xFin) THEN yFin ELSE xFin]

\* What reloadEntryLocked leaves in memory for identity i: the newer of
\* memory and a readable file; a missing or unreadable file keeps memory.
Reload(m, i) == IF corrupt[i] \/ cache[i] = EmptyRec THEN m ELSE Newer(m, cache[i], Wall)

TypeOK ==
    /\ now \in Times
    /\ skew \in {0, -SKEW}
    /\ ident \in [Procs -> Idents]
    /\ open \in [Procs -> BOOLEAN]
    /\ inflight \in [Procs -> Opt([ident : Idents, at : Times, fin : BOOLEAN])]
    /\ lastStart \in [Procs -> Opt(Times)]
    /\ failedAt \in [Procs -> Opt(Times)]
    /\ owed \in [Procs -> BOOLEAN]
    /\ cache \in [Idents -> Recs]
    /\ corrupt \in [Idents -> BOOLEAN]
    /\ mem \in [Procs -> Recs]
    /\ finCount \in [Procs -> [Idents -> [Days -> Nat]]]
    /\ corruptions \in [Idents -> Nat]
    /\ faults \in 0..MAXFAULTS

Init ==
    /\ now = 0
    /\ skew = 0
    /\ ident \in [Procs -> Idents]
    /\ open = [p \in Procs |-> FALSE]
    /\ inflight = [p \in Procs |-> None]
    /\ lastStart = [p \in Procs |-> None]
    /\ failedAt = [p \in Procs |-> None]
    /\ owed = [p \in Procs |-> FALSE]
    /\ cache = [i \in Idents |-> EmptyRec]
    /\ corrupt = [i \in Idents |-> FALSE]
    /\ mem = [p \in Procs |-> EmptyRec]
    /\ shown = [p \in Procs |-> Hidden]
    /\ finCount = [p \in Procs |-> [i \in Idents |-> [d \in Days |-> 0]]]
    /\ corruptions = [i \in Idents |-> 0]
    /\ faults = 0

\* policy.since: true when t is unset, when n has passed, or when the wall
\* clock reads earlier than t (it was corrected backward).
Since(t, n) == IF t = None THEN TRUE ELSE Wall < t \/ Wall - t >= n

FloorClear(p) ==
    /\ inflight[p] = None
    /\ Since(lastStart[p], FLOOR)
    /\ Since(failedAt[p], FLOOR)

\* maybeStartLocked: reload, then policy.plan from the entry in memory.
StartFetch(p, m) ==
    LET i == ident[p]
        fin == m.finDay # Day(Wall)
    IN /\ inflight' = [inflight EXCEPT ![p] = [ident |-> i, at |-> Wall, fin |-> fin]]
       /\ lastStart' = [lastStart EXCEPT ![p] = Wall]
       /\ owed' = [owed EXCEPT ![p] = FALSE]

\* A redraw of every open dashboard at wall time w (minute turned, clock
\* moved): each reloads, then renders.
RedrawOpen(w) ==
    /\ mem' = [p \in Procs |-> IF open[p] THEN Reload(mem[p], ident[p]) ELSE mem[p]]
    /\ shown' = [p \in Procs |-> IF open[p] THEN ViewOf(Reload(mem[p], ident[p]), ident[p], w) ELSE shown[p]]

\* One process reloads and redraws.
RedrawOne(p) ==
    LET m == Reload(mem[p], ident[p]) IN
    /\ mem' = [mem EXCEPT ![p] = m]
    /\ shown' = [shown EXCEPT ![p] = ViewOf(m, ident[p], Wall)]

Tick ==
    /\ now < MAXT
    /\ Wall + 1 \in Times
    /\ now' = now + 1
    /\ RedrawOpen(Wall + 1)
    /\ UNCHANGED <<skew, ident, open, inflight, lastStart, owed, failedAt, cache, corrupt, finCount, corruptions, faults>>

Open(p) ==
    LET m == Reload(mem[p], ident[p]) IN
    /\ ~open[p]
    /\ open' = [open EXCEPT ![p] = TRUE]
    /\ mem' = [mem EXCEPT ![p] = m]
    /\ shown' = [shown EXCEPT ![p] = ViewOf(m, ident[p], Wall)]
    /\ IF FloorClear(p)
       THEN StartFetch(p, m)
       ELSE UNCHANGED <<inflight, lastStart, owed>>
    /\ UNCHANGED <<now, skew, ident, failedAt, cache, corrupt, finCount, corruptions, faults>>

Close(p) ==
    /\ open[p]
    /\ open' = [open EXCEPT ![p] = FALSE]
    /\ shown' = [shown EXCEPT ![p] = Hidden]
    /\ UNCHANGED <<now, skew, ident, inflight, lastStart, owed, failedAt, cache, corrupt, mem, finCount, corruptions, faults>>

\* `r`: fetches whenever nothing is in flight; the floor never holds it.
Manual(p) ==
    LET m == Reload(mem[p], ident[p]) IN
    /\ open[p]
    /\ inflight[p] = None
    /\ StartFetch(p, m)
    /\ RedrawOne(p)
    /\ UNCHANGED <<now, skew, ident, open, failedAt, cache, corrupt, finCount, corruptions, faults>>

TimerDue(p) ==
    /\ open[p]
    /\ FloorClear(p)
    /\ lastStart[p] # None
    /\ Since(lastStart[p], TIMER)

Timer(p) ==
    LET m == Reload(mem[p], ident[p]) IN
    /\ TimerDue(p)
    /\ StartFetch(p, m)
    /\ RedrawOne(p)
    /\ UNCHANGED <<now, skew, ident, open, failedAt, cache, corrupt, finCount, corruptions, faults>>

\* What a fetch returned, as a cache record.
Fetched(f) == [todayDay |-> Day(f.at), todayAt |-> f.at, finDay |-> IF f.fin THEN Day(f.at) ELSE None]

Complete(p) ==
    LET f == inflight[p]
        i == f.ident
        \* The process's own entry counts with the file (a missing or
        \* unreadable file is just that entry), if it is for i.
        own == IF ident[p] = i THEN mem[p] ELSE EmptyRec
        stored == IF corrupt[i] \/ cache[i] = EmptyRec THEN own ELSE Newer(own, cache[i], Wall)
        rec == Newer(stored, Fetched(f), Wall)
        mine == ident[p] = i
    IN /\ f # None
       /\ cache' = [cache EXCEPT ![i] = rec]
       /\ corrupt' = [corrupt EXCEPT ![i] = FALSE]
       /\ inflight' = [inflight EXCEPT ![p] = None]
       /\ failedAt' = [failedAt EXCEPT ![p] = None]
       /\ mem' = IF mine THEN [mem EXCEPT ![p] = rec] ELSE mem
       /\ owed' = IF mine THEN [owed EXCEPT ![p] = FALSE] ELSE owed
       /\ shown' = IF mine /\ open[p] THEN [shown EXCEPT ![p] = ViewOf(rec, i, Wall)] ELSE shown
       \* Every successful fetch that read finished days counts, kept or not.
       /\ finCount' = IF f.fin THEN [finCount EXCEPT ![p][i][Day(f.at)] = @ + 1] ELSE finCount
       /\ UNCHANGED <<now, skew, ident, open, lastStart, corruptions, faults>>

Fail(p) ==
    /\ HOSTILE
    /\ inflight[p] # None
    /\ inflight' = [inflight EXCEPT ![p] = None]
    /\ failedAt' = [failedAt EXCEPT ![p] = IF inflight[p].ident = ident[p] THEN Wall ELSE @]
    /\ owed' = [owed EXCEPT ![p] = IF inflight[p].ident = ident[p] THEN FALSE ELSE @]
    /\ IF open[p] THEN RedrawOne(p) ELSE UNCHANGED <<mem, shown>>
    /\ UNCHANGED <<now, skew, ident, open, lastStart, cache, corrupt, finCount, corruptions, faults>>

\* SIGKILL, and a new fx starts in its place: closed, no fetch history, no
\* entry in memory. A fetch in flight stores nothing (writes land by rename).
Crash(p) ==
    /\ HOSTILE
    /\ faults < MAXFAULTS
    /\ faults' = faults + 1
    /\ open' = [open EXCEPT ![p] = FALSE]
    /\ inflight' = [inflight EXCEPT ![p] = None]
    /\ lastStart' = [lastStart EXCEPT ![p] = None]
    /\ failedAt' = [failedAt EXCEPT ![p] = None]
    /\ owed' = [owed EXCEPT ![p] = FALSE]
    /\ mem' = [mem EXCEPT ![p] = EmptyRec]
    /\ shown' = [shown EXCEPT ![p] = Hidden]
    /\ UNCHANGED <<now, skew, ident, cache, corrupt, finCount, corruptions>>

\* Something else makes identity i's file unreadable. Nothing redraws.
Corrupt(i) ==
    /\ CORRUPT
    /\ faults < MAXFAULTS
    /\ faults' = faults + 1
    /\ cache[i] # EmptyRec
    /\ ~corrupt[i]
    /\ corrupt' = [corrupt EXCEPT ![i] = TRUE]
    /\ cache' = [cache EXCEPT ![i] = EmptyRec]
    /\ corruptions' = [corruptions EXCEPT ![i] = @ + 1]
    /\ UNCHANGED <<now, skew, ident, open, inflight, lastStart, owed, failedAt, mem, shown, finCount>>

\* The machine's clock is corrected backward once by SKEW ticks.
ClockBack ==
    /\ SKEW > 0
    /\ faults < MAXFAULTS
    /\ faults' = faults + 1
    /\ skew = 0
    /\ now >= SKEW
    /\ skew' = -SKEW
    /\ RedrawOpen(now - SKEW)
    /\ UNCHANGED <<now, ident, open, inflight, lastStart, owed, failedAt, cache, corrupt, finCount, corruptions>>

\* A new sign-in: installCredentialLocked reads the new identity's file,
\* clears the floor (it is per sign-in), and owes the first fetch.
Switch(p, j) ==
    LET m == IF corrupt[j] THEN EmptyRec ELSE cache[j] IN
    /\ j # ident[p]
    /\ ident' = [ident EXCEPT ![p] = j]
    /\ mem' = [mem EXCEPT ![p] = m]
    /\ shown' = [shown EXCEPT ![p] = IF open[p] THEN ViewOf(m, j, Wall) ELSE Hidden]
    /\ lastStart' = [lastStart EXCEPT ![p] = None] /\ failedAt' = [failedAt EXCEPT ![p] = None]
    /\ owed' = [owed EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<now, skew, open, inflight, cache, corrupt, finCount, corruptions, faults>>

\* Dashboard.tick: an owed first fetch starts once nothing is in flight.
OwedStart(p) ==
    LET m == Reload(mem[p], ident[p]) IN
    /\ open[p]
    /\ owed[p]
    /\ FloorClear(p)
    /\ StartFetch(p, m)
    /\ RedrawOne(p)
    /\ UNCHANGED <<now, skew, ident, open, failedAt, cache, corrupt, finCount, corruptions, faults>>

Next ==
    \/ Tick \/ ClockBack
    \/ \E i \in Idents : Corrupt(i)
    \/ \E p \in Procs :
          \/ Open(p) \/ Close(p) \/ Manual(p) \/ Timer(p) \/ Complete(p) \/ Fail(p) \/ Crash(p)
          \/ OwedStart(p) \/ \E j \in Idents : Switch(p, j)

Spec == Init /\ [][Next]_vars

\* What the Bun driver replays against real fx: fx fires a due timer on its
\* next loop pass, and a running TUI's sign-in cannot be switched.
DriveNext ==
    IF \E p \in Procs : TimerDue(p)
    THEN \E p \in Procs : Timer(p)
    ELSE \/ Tick \/ ClockBack
         \/ \E i \in Idents : Corrupt(i)
         \/ \E p \in Procs :
               Open(p) \/ Close(p) \/ Manual(p) \/ Complete(p) \/ Fail(p) \/ Crash(p)

DriveSpec == Init /\ [][DriveNext]_vars

-----------------------------------------------------------------------------
(* Kept in every condition.                                                *)

ShowsOwnIdentity == \A p \in Procs : open[p] => shown[p].ident = ident[p]

\* A new sign-in's first fetch never waits on another sign-in's floor: once
\* nothing is in flight, it may start.
OwedNeverWaitsOnFloor == \A p \in Procs : open[p] /\ owed[p] /\ inflight[p] = None => FloorClear(p)

\* `r` always works while /usage is open and nothing is in flight.
RAlwaysWorks == \A p \in Procs : open[p] /\ inflight[p] = None => ENABLED Manual(p)

\* Today on screen belongs to the wall clock's current UTC day.
TodayIsToday ==
    \A p \in Procs : open[p] /\ shown[p].today # None => Day(shown[p].today) = Day(Wall)

\* A process reads an identity's finished days at most once per UTC day,
\* plus once per time the file was made unreadable, plus once after the
\* clock was corrected (what it read for a day that had not begun is read
\* again when that day comes).
FinishedOncePerDay ==
    \A p \in Procs, i \in Idents, d \in Days :
        finCount[p][i][d] <= 1 + corruptions[i] + (IF skew # 0 THEN 1 ELSE 0)

\* Fetches start only around an open dashboard, never closer than FLOOR on
\* the wall clock.
\* Fetches start only for a dashboard on screen.
FetchRules ==
    [][\A p \in Procs :
         (inflight[p] = None /\ inflight'[p] # None) => open[p] \/ open'[p]]_vars

\* Opening /usage fetches only past the floor of the process's last start.
OpenRespectsFloor ==
    [][\A p \in Procs :
         (~open[p] /\ open'[p] /\ inflight[p] = None /\ inflight'[p] # None) =>
             Since(lastStart[p], FLOOR)]_vars

\* The file's today never moves to an older fetch, except when something
\* else made the file unreadable or it was stamped after the wall clock.
CacheNeverRegresses ==
    [][\A i \in Idents :
         (corruptions'[i] = corruptions[i] /\ cache[i].todayAt # None /\ cache[i].todayAt <= Wall) =>
             (cache'[i].todayAt # None /\ cache'[i].todayAt >= cache[i].todayAt)]_vars

-----------------------------------------------------------------------------
(* Stated for users; kept in every condition.                              *)

\* A fetch that started today for the dashboard's own identity and succeeded
\* shows today's numbers on that dashboard.
SuccessShowsToday ==
    [][\A p \in Procs :
         (/\ inflight[p] # None /\ inflight'[p] = None /\ failedAt'[p] = None
          /\ open[p] /\ open'[p]
          /\ inflight[p].ident = ident[p]
          /\ Day(inflight[p].at) = Day(Wall))
         => shown'[p].today # None]_vars

\* Once today's finished days are on screen, they stay for the rest of the
\* UTC day while the dashboard stays open on the same identity.
FinishedStaysShown ==
    [][\A p \in Procs :
         (/\ open[p] /\ open'[p] /\ ident'[p] = ident[p]
          /\ shown[p].fin = Day(Wall) /\ Day(now' + skew') = Day(Wall))
         => shown'[p].fin = Day(Wall)]_vars
=============================================================================

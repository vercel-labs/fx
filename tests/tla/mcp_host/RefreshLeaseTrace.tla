---- MODULE RefreshLeaseTrace ----
\* Real runs of a login's refresh lock checked against RefreshLease.tla's
\* rules, on the real clock. trace.ts generates TraceObs.tla from what
\* tests/tla/drivers/mcp_host/refresh-lease.test.ts saw of real fx processes
\* on the file store, whose lock writes no stamps: their "MCP refresh lock"
\* and "MCP refresh went ahead" trace lines (src/core/mcp_host/credentials.zig,
\* src/core/mcp_host/runtime.zig) and the harness's own steps. Times are
\* awake-clock milliseconds from the run's start.
\*   take {p, at}               p took the refresh lock and stamped it
\*   stamp {p, at}              p, holding it, stamped it before a step
\*   release {p, at}            p let it go
\*   goahead {p, at, started}   p, waiting since started, refreshed without it
\*   freeze {p, at}, thaw {p, at}  the harness stopped or resumed p (ctrl+z)
\*   kill {p, at}               the harness killed p; the kernel drops its lock
\*   foreign {p, at}, foreign_release {p, at}  the harness held the lock
\*                              itself and stamped nothing, as an older fx does
\* The rules, the model's on real time with Tolerance for scheduling:
\*   NoGoAheadPastLiveRefresher  a waiter goes ahead only behind a frozen
\*                               holder or one that stamps nothing
\*   GoAheadOnTime  a waiter goes ahead Slack after both the holder's step
\*                  (RefreshMax from the last stamp, or its own start if
\*                  later) and the store's lease (Budget + Slack from its own
\*                  start: the file store has no stamp) ran out, not before
\*                  and not long after
\*   OneOwner       no one takes or stamps the lock while another holds it
EXTENDS Integers, Sequences, FiniteSets, TraceObs

CONSTANTS RefreshMax, Budget, Slack, Tolerance

VARIABLES
    i, bad,
    owner,      \* who holds the lock, or None
    frozen,     \* processes the harness has stopped
    foreign,    \* the harness holds the lock and stamped nothing
    lastStamp   \* the stamp in the lock file, -1 for none

None == "none"
Max(a, b) == IF a > b THEN a ELSE b

TraceInit == i = 0 /\ bad = {} /\ owner = None /\ frozen = {} /\ foreign = FALSE /\ lastStamp = -1

\* When a waiter that started at `started` may go ahead.
From(started) == IF lastStamp > started THEN lastStamp ELSE started
GoAheadAt(started) == Max(From(started) + RefreshMax, started + Budget + Slack) + Slack

Broken(r) ==
    LET d == r.data IN
    (IF r.event \in {"take", "foreign"} /\ owner # None THEN {"OneOwner"} ELSE {}) \cup
    (IF r.event = "stamp" /\ owner # d.p THEN {"OneOwner"} ELSE {}) \cup
    (IF r.event = "goahead" /\ owner # None /\ ~(owner \in frozen \/ foreign)
        THEN {"NoGoAheadPastLiveRefresher"} ELSE {}) \cup
    (IF r.event = "goahead" /\
        (d.at + Tolerance < GoAheadAt(d.started) \/ d.at > GoAheadAt(d.started) + Tolerance)
        THEN {"GoAheadOnTime"} ELSE {})

Step(r) ==
    LET d == r.data IN
    CASE r.event \in {"take", "stamp"} ->
            owner' = d.p /\ lastStamp' = d.at /\ UNCHANGED <<frozen, foreign>>
      [] r.event = "foreign" ->
            owner' = d.p /\ foreign' = TRUE /\ UNCHANGED <<frozen, lastStamp>>
      [] r.event \in {"release", "kill", "foreign_release"} ->
            (owner' = (IF owner = d.p THEN None ELSE owner))
            /\ (foreign' = (IF owner = d.p THEN FALSE ELSE foreign))
            /\ frozen' = frozen \ {d.p}
            /\ UNCHANGED lastStamp
      [] r.event = "freeze" -> frozen' = frozen \cup {d.p} /\ UNCHANGED <<owner, foreign, lastStamp>>
      [] r.event = "thaw" -> frozen' = frozen \ {d.p} /\ UNCHANGED <<owner, foreign, lastStamp>>
      [] r.event = "goahead" -> UNCHANGED <<owner, frozen, foreign, lastStamp>>
      [] OTHER -> FALSE

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ Step(ObsTrace[i + 1])
    /\ bad' = bad \cup Broken(ObsTrace[i + 1])
    /\ i' = i + 1

NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====

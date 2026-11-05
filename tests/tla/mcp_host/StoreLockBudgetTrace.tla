---- MODULE StoreLockBudgetTrace ----
\* Real runs of the MCP store lock checked against StoreLockBudget.tla's
\* rules, on the real clock. trace.ts generates TraceObs.tla from what
\* tests/tla/drivers/mcp_host/store-lock-budget.test.ts saw of real fx
\* processes on the Keychain backend: their "MCP store lock" trace lines
\* (src/core/mcp_host/credentials.zig) and the harness's own steps. Times are
\* awake-clock milliseconds from the run's start.
\*   take {p, at, started}      p took the lock and wrote its stamp, at
\*   stamp {p, at}              p, holding it, wrote a new stamp before a
\*                              Keychain call
\*   release {p, at}            p let it go
\*   giveup {p, at, started}    p gave up waiting for it
\*   freeze {p, at}, thaw {p, at}  the harness stopped or resumed p (ctrl+z)
\*   kill {p, at}               the harness killed p; the kernel drops its lock
\*   foreign {p, at}, foreign_release {p, at}  the harness held the lock
\*                              itself and wrote no stamp, as an older fx does
\*   scribble {p, at}           the harness wrote garbage over the stamp, which
\*                              the rules read as no stamp
\* Every record is one step: the trace is complete when each one is taken.
\* The rules, the model's on real time with Tolerance for scheduling:
\*   NoGiveUpOnLiveHolder  a waiter gives up only behind a frozen holder or
\*                         one that wrote no stamp (StoreLockBudget.tla)
\*   HoldWithinBudget      a live holder writes its next stamp, or lets the
\*                         lock go, within Budget of its last stamp: each
\*                         Keychain call ends by then
\*   GiveUpOnTime          a waiter gives up Budget + Slack after the later
\*                         of the last stamp and its own start, not before
\*                         and not long after
\*   OneOwner              no one takes the lock while another holds it
EXTENDS Integers, Sequences, FiniteSets, TraceObs

CONSTANTS Budget, Slack, Tolerance

VARIABLES
    i, bad,
    owner,      \* who holds the lock, or None
    stampAt,    \* the current holder's last stamp
    frozen,     \* processes the harness has stopped
    excused,    \* processes stopped at some point in their current hold
    foreign,    \* the harness holds the lock and wrote no stamp
    lastStamp   \* the stamp in the lock file, -1 for none

None == "none"
Max(a, b) == IF a > b THEN a ELSE b

TraceInit ==
    /\ i = 0 /\ bad = {} /\ owner = None /\ stampAt = 0
    /\ frozen = {} /\ excused = {} /\ foreign = FALSE /\ lastStamp = -1

\* Why record `r` breaks a rule, in the state before it.
Broken(r) ==
    LET d == r.data IN
    (IF r.event \in {"take", "foreign"} /\ owner # None THEN {"OneOwner"} ELSE {}) \cup
    (IF r.event \in {"stamp", "release"} /\ owner = d.p /\ ~(d.p \in excused) /\ d.at > stampAt + Budget + Tolerance
        THEN {"HoldWithinBudget"} ELSE {}) \cup
    (IF r.event = "stamp" /\ owner # d.p THEN {"OneOwner"} ELSE {}) \cup
    (IF r.event = "giveup" /\ ~(owner # None /\ (owner \in frozen \/ foreign))
        THEN {"NoGiveUpOnLiveHolder"} ELSE {}) \cup
    (IF r.event = "giveup" /\
        (d.at + Tolerance < Max(lastStamp, d.started) + Budget + Slack \/
         d.at > Max(lastStamp, d.started) + Budget + Slack + Tolerance)
        THEN {"GiveUpOnTime"} ELSE {})

Step(r) ==
    LET d == r.data IN
    CASE r.event = "take" ->
            owner' = d.p /\ stampAt' = d.at /\ lastStamp' = d.at /\ foreign' = FALSE /\ UNCHANGED <<frozen, excused>>
      [] r.event = "stamp" ->
            stampAt' = d.at /\ lastStamp' = d.at /\ UNCHANGED <<owner, frozen, excused, foreign>>
      [] r.event = "foreign" ->
            owner' = d.p /\ foreign' = TRUE /\ UNCHANGED <<stampAt, lastStamp, frozen, excused>>
      [] r.event \in {"release", "kill", "foreign_release"} ->
            (owner' = (IF owner = d.p THEN None ELSE owner))
            /\ (foreign' = (IF owner = d.p THEN FALSE ELSE foreign))
            /\ frozen' = frozen \ {d.p}
            /\ excused' = excused \ {d.p}
            /\ UNCHANGED <<stampAt, lastStamp>>
      [] r.event = "freeze" ->
            frozen' = frozen \cup {d.p} /\ excused' = excused \cup {d.p} /\ UNCHANGED <<owner, stampAt, foreign, lastStamp>>
      [] r.event = "thaw" -> frozen' = frozen \ {d.p} /\ UNCHANGED <<owner, stampAt, foreign, lastStamp, excused>>
      [] r.event = "giveup" -> UNCHANGED <<owner, stampAt, frozen, excused, foreign, lastStamp>>
      [] r.event = "scribble" -> lastStamp' = -1 /\ UNCHANGED <<owner, stampAt, frozen, excused, foreign>>
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

------------------------------ MODULE QuietWait ------------------------------
(***************************************************************************)
(* A wait on a running shell command and the quiet notice                  *)
(* (src/core/execution/quiet_notice.zig, driven by Runtime.wait in         *)
(* src/core/execution/managed_execution.zig and written by                 *)
(* formatSnapshotRaw in src/tools/shell/shell.zig).                        *)
(*                                                                         *)
(* A command may print nothing for a long time: it may have hung, or it    *)
(* may be a server or watcher at rest. fx never stops it. A result for a   *)
(* running command that has been quiet for Limit carries a notice that     *)
(* asks the model to check it, and a wait (an interact call) that has seen *)
(* the command under the limit ends the moment the quiet time reaches it,  *)
(* so a model waiting with a long yield learns of it at the limit. A wait  *)
(* that begins past the limit runs to its ceiling unless new output brings *)
(* the command back under it, so a model that waits again is not woken at  *)
(* once.                                                                   *)
(*                                                                         *)
(* While the shell call that waits serves one of the command's fx mcp call *)
(* requests (yield_hold above zero; src/core/mcp_host/mcp_call_bridge.zig), *)
(* the wait ends neither for quiet nor at its ceiling, since the request   *)
(* must not end before its answer: it runs past its ceiling while held,    *)
(* and ends at the first look after the hold drops. A finished command     *)
(* still ends it first. Each request ends, and a run of them leaves the    *)
(* waiter a look without a hold now and then (fairness on Release and on  *)
(* an unheld Poll).                                                        *)
(*                                                                         *)
(* Time is a discrete clock. quiet counts ticks since the last output, or  *)
(* since the start, and saturates past Limit. The worker thread's output   *)
(* and the command's exit come at any moment; the waiter polls every       *)
(* 10 ms, so it looks at least once between ticks and after each output,  *)
(* and output never holds the clock back (strong fairness on Tick).       *)
(*                                                                         *)
(* Bug plants one defect for the mutation configs:                         *)
(*   notice_any_quiet  the notice shows for any quiet time                 *)
(*   notice_when_done  the notice shows on a finished command              *)
(*   end_unarmed       a wait that began past the limit ends for quiet     *)
(*   no_crossing_end   a wait never ends at the crossing                   *)
(*   no_rearm          output during a wait does not arm it                *)
(*   ceiling_late      a wait runs one tick past its ceiling               *)
(*   hold_ignored      a held wait ends for quiet or at its ceiling        *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Limit,    \* the quiet limit, in ticks
    MaxCeil,  \* the longest ceiling (yield_time_ms) a wait may take, in ticks
    Bug

Bugs == {"none", "notice_any_quiet", "notice_when_done", "end_unarmed",
         "no_crossing_end", "no_rearm", "ceiling_late", "hold_ignored"}

ASSUME /\ Limit \in 1..6 /\ MaxCeil \in 0..12 /\ Bug \in Bugs

QSat == Limit + 1
Ends == {"none", "quiet", "ceiling", "done"}

VARIABLES
    cmd,        \* "running" or "done"
    quiet,      \* ticks since the last output or the start, saturating at QSat
    waiting,    \* a wait is open
    ceil,       \* its ceiling
    waitAge,    \* ticks since it began
    armed,      \* quiet_notice.Wait.armed
    polled,     \* the waiter has looked since the last tick, output, or exit
    under,      \* the wait has seen the command under the limit: at its start,
                \* or by output during it (a ghost the code does not keep)
    outDuring,  \* output came during the wait (a ghost)
    result,     \* the last result a wait returned
    held,       \* one of the command's fx mcp call requests is in progress
    heldLate    \* a look found the wait held at or past its ceiling (a ghost)

vars == <<cmd, quiet, waiting, ceil, waitAge, armed, polled, under, outDuring, result,
          held, heldLate>>

NoResult == [end |-> "none", running |-> FALSE, quietDue |-> FALSE,
             notice |-> FALSE, armed |-> FALSE, under |-> FALSE,
             output |-> FALSE, waitAge |-> 0, ceil |-> 0,
             held |-> FALSE, heldLate |-> FALSE]

Due == quiet >= Limit

\* formatSnapshotRaw writes the notice for a running captured command whose
\* quiet time is at the limit or past it.
Notice(running) ==
    CASE Bug = "notice_any_quiet" -> running /\ quiet > 0
      [] Bug = "notice_when_done" -> Due
      [] OTHER -> running /\ Due

TypeOK ==
    /\ cmd \in {"running", "done"}
    /\ quiet \in 0..QSat
    /\ waiting \in BOOLEAN
    /\ ceil \in 0..MaxCeil
    /\ waitAge \in 0..(MaxCeil + 1)
    /\ armed \in BOOLEAN /\ polled \in BOOLEAN
    /\ under \in BOOLEAN /\ outDuring \in BOOLEAN
    /\ result.end \in Ends
    /\ held \in BOOLEAN /\ heldLate \in BOOLEAN

Init ==
    /\ cmd = "running"
    /\ quiet = 0
    /\ waiting = FALSE
    /\ ceil = 0
    /\ waitAge = 0
    /\ armed = FALSE
    /\ polled = TRUE
    /\ under = FALSE
    /\ outDuring = FALSE
    /\ result = NoResult
    /\ held = FALSE
    /\ heldLate = FALSE

\* The command prints: Entry.appendOutput on the worker thread.
Output ==
    /\ cmd = "running"
    /\ quiet' = 0
    /\ polled' = FALSE
    /\ under' = (under \/ waiting)
    /\ outDuring' = (outDuring \/ waiting)
    /\ UNCHANGED <<cmd, waiting, ceil, waitAge, armed, result, held, heldLate>>

\* The command exits: Entry.workerMain reaches a terminal state.
Finish ==
    /\ cmd = "running"
    /\ cmd' = "done"
    /\ polled' = FALSE
    /\ UNCHANGED <<quiet, waiting, ceil, waitAge, armed, under, outDuring, result, held, heldLate>>

\* One tick of the clock. An open wait has looked since the last change. Its
\* age stops one tick past the ceiling: the code tells no later age apart.
Tick ==
    /\ waiting => polled
    /\ quiet' = IF quiet + 1 > QSat THEN QSat ELSE quiet + 1
    /\ waitAge' = IF waiting /\ waitAge <= ceil THEN waitAge + 1 ELSE waitAge
    /\ polled' = FALSE
    /\ UNCHANGED <<cmd, waiting, ceil, armed, under, outDuring, result, held, heldLate>>

\* The bridge admits one of the command's fx mcp call requests: the
\* registration's hold rises (mcp_call_bridge.zig serve).
Hold ==
    /\ cmd = "running" /\ ~held
    /\ held' = TRUE
    /\ UNCHANGED <<cmd, quiet, waiting, ceil, waitAge, armed, polled, under, outDuring, result, heldLate>>

\* The request ends and the hold drops. The waiter looks again.
Release ==
    /\ held
    /\ held' = FALSE
    /\ polled' = FALSE
    /\ UNCHANGED <<cmd, quiet, waiting, ceil, waitAge, armed, under, outDuring, result, heldLate>>

\* A wait begins: shell interact on a captured session, quiet_notice.beginWait.
Begin(c) ==
    /\ ~waiting
    /\ waiting' = TRUE
    /\ ceil' = c
    /\ waitAge' = 0
    /\ armed' = ~Due
    /\ under' = ~Due
    /\ outDuring' = FALSE
    /\ polled' = FALSE
    /\ heldLate' = FALSE
    /\ UNCHANGED <<cmd, quiet, result, held>>

\* The waiter looks: one pass of Runtime.wait's loop, quiet_notice.poll. A
\* finished command ends the wait first, before the module is asked. While
\* held, the module still arms the wait, but its end does not count.
Poll ==
    /\ waiting /\ ~polled
    /\ LET a == IF cmd = "done" \/ Bug = "no_rearm" THEN armed ELSE armed \/ ~Due
           pastCeil == IF Bug = "ceiling_late" THEN waitAge > ceil ELSE waitAge >= ceil
           free == ~held \/ Bug = "hold_ignored"
           late == heldLate \/ (held /\ pastCeil)
           e == IF cmd = "done" THEN "done"
                ELSE IF ~free THEN "none"
                ELSE IF Bug = "end_unarmed" /\ Due THEN "quiet"
                ELSE IF Bug # "no_crossing_end" /\ a /\ Due THEN "quiet"
                ELSE IF pastCeil THEN "ceiling"
                ELSE "none"
       IN /\ armed' = a
          /\ polled' = TRUE
          /\ heldLate' = late
          /\ IF e = "none"
             THEN UNCHANGED <<waiting, result>>
             ELSE /\ waiting' = FALSE
                  /\ result' = [end |-> e, running |-> cmd = "running",
                                quietDue |-> Due, notice |-> Notice(cmd = "running"),
                                armed |-> a, under |-> under, output |-> outDuring,
                                waitAge |-> waitAge, ceil |-> ceil,
                                held |-> held, heldLate |-> late]
    /\ UNCHANGED <<cmd, quiet, ceil, waitAge, under, outDuring, held>>

Next ==
    \/ Output
    \/ Finish
    \/ Tick
    \/ Hold
    \/ Release
    \/ \E c \in 0..MaxCeil : Begin(c)
    \/ Poll

Spec == Init /\ [][Next]_vars /\ WF_vars(Poll) /\ SF_vars(Tick)
        /\ WF_vars(Release) /\ SF_vars(~held /\ Poll)

----------------------------------------------------------------------------
(* Rules *)

\* A result asks the model to check the command exactly when the command is
\* running and has been quiet for the limit.
NoticeRule ==
    result.end # "none" => (result.notice <=> (result.running /\ result.quietDue))

\* A wait ends for quiet only at a crossing it saw: the command is running,
\* at the limit, and the wait saw it under the limit.
QuietEndNeedsCrossing ==
    result.end = "quiet" => (result.running /\ result.quietDue /\ result.under)

\* A wait that ends at its ceiling ran exactly that long, unless a look found
\* it held there.
CeilingEndOnTime ==
    result.end = "ceiling" => (result.waitAge = result.ceil \/ result.heldLate)

\* An open wait runs past its ceiling only after a look found it held there.
WaitBounded ==
    (waiting /\ waitAge > ceil) => heldLate

\* A wait ends neither for quiet nor at its ceiling while one of the
\* command's requests is in progress.
HeldWaitStaysOpen ==
    result.end \in {"quiet", "ceiling"} => ~result.held

\* Once the waiter has looked without a hold, a wait is not left open at its
\* ceiling: it ended there, or at the first look after the hold dropped.
CeilingEnds ==
    (waiting /\ polled /\ ~held /\ cmd = "running") => waitAge < ceil

\* Once the waiter has looked without a hold, a wait that saw the command
\* under the limit is not left open at the limit: it ended at the crossing.
CrossingEnds ==
    (waiting /\ polled /\ ~held /\ under /\ cmd = "running") => ~Due

\* Once the waiter has looked, a finished command has ended the wait.
DoneEnds ==
    (waiting /\ polled) => cmd = "running"

\* Every wait ends.
WaitEnds == waiting ~> ~waiting
=============================================================================

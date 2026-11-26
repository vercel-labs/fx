------------------------------ MODULE QuietWait ------------------------------
(***************************************************************************)
(* A wait on a running shell command and the quiet notice                  *)
(* (src/core/execution/quiet_notice.zig, driven by Runtime.wait and        *)
(* Runtime.waitOrYield in src/core/execution/managed_execution.zig, and    *)
(* written by formatSnapshotRaw in src/tools/shell/shell.zig).             *)
(*                                                                         *)
(* A command may print nothing for a long time: it may have hung, or it    *)
(* may be a server or watcher at rest. fx never stops it and never cuts a  *)
(* requested wait short for quiet. A wait ends only at its ceiling or when *)
(* the command finishes. A result for a running command that has been      *)
(* quiet for Limit carries a notice that asks the model to check it, and a *)
(* wait that ends past the limit after seeing the command under it reports *)
(* one crossing per quiet spell.                                           *)
(*                                                                         *)
(* Time is a discrete clock. quiet counts ticks since the last output, or  *)
(* since the start, and saturates past Limit. The worker thread's output   *)
(* and the command's exit come at any moment; the waiter polls every       *)
(* 10 ms, so it looks at least once between ticks and after each output,  *)
(* and output never holds the clock back (strong fairness on Tick).        *)
(*                                                                         *)
(* Bug plants one defect for the mutation configs:                         *)
(*   notice_any_quiet  the notice shows for any quiet time                 *)
(*   notice_when_done  the notice shows on a finished command              *)
(*   end_at_crossing   a wait ends early at the quiet crossing             *)
(*   cross_unarmed     an unarmed wait reports a crossing                  *)
(*   never_cross       a wait never reports a crossing                     *)
(*   no_rearm          output during a wait does not arm it                *)
(*   ceiling_late      a wait runs one tick past its ceiling               *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Limit,    \* the quiet limit, in ticks
    MaxCeil,  \* the longest ceiling (yield_time_ms) a wait may take, in ticks
    Bug

Bugs == {"none", "notice_any_quiet", "notice_when_done", "end_at_crossing",
         "cross_unarmed", "never_cross", "no_rearm", "ceiling_late"}

ASSUME /\ Limit \in 1..6 /\ MaxCeil \in 0..12 /\ Bug \in Bugs

QSat == Limit + 1
Ends == {"none", "ceiling", "done"}

VARIABLES
    cmd,          \* "running" or "done"
    quiet,        \* ticks since the last output or the start, saturating at QSat
    waiting,      \* a wait is open
    ceil,         \* its ceiling
    waitAge,      \* ticks since it began
    armed,        \* quiet_notice.Wait.armed
    polled,       \* the waiter has looked since the last tick, output, or exit
    under,        \* the wait has seen the command under the limit: at its start,
                  \* or by output during it (a ghost the code does not keep)
    outDuring,    \* output came during the wait (a ghost)
    spellCrosses, \* crossings reported in the current quiet spell (a ghost, 0..2)
    result        \* the last result a wait returned

vars == <<cmd, quiet, waiting, ceil, waitAge, armed, polled, under, outDuring, spellCrosses, result>>

NoResult == [end |-> "none", running |-> FALSE, quietDue |-> FALSE,
             notice |-> FALSE, crossed |-> FALSE, armed |-> FALSE,
             under |-> FALSE, output |-> FALSE, waitAge |-> 0, ceil |-> 0]

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
    /\ spellCrosses \in 0..2
    /\ result.end \in Ends
    /\ result.crossed \in BOOLEAN

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
    /\ spellCrosses = 0
    /\ result = NoResult

\* The command prints: Entry.appendOutput on the worker thread.
Output ==
    /\ cmd = "running"
    /\ quiet' = 0
    /\ polled' = FALSE
    /\ under' = (under \/ waiting)
    /\ outDuring' = (outDuring \/ waiting)
    /\ spellCrosses' = 0
    /\ UNCHANGED <<cmd, waiting, ceil, waitAge, armed, result>>

\* The command exits: Entry.workerMain reaches a terminal state.
Finish ==
    /\ cmd = "running"
    /\ cmd' = "done"
    /\ polled' = FALSE
    /\ UNCHANGED <<quiet, waiting, ceil, waitAge, armed, under, outDuring, spellCrosses, result>>

\* One tick of the clock. An open wait has looked since the last change.
Tick ==
    /\ waiting => polled
    /\ quiet' = IF quiet + 1 > QSat THEN QSat ELSE quiet + 1
    /\ waitAge' = IF waiting THEN waitAge + 1 ELSE waitAge
    /\ polled' = FALSE
    /\ UNCHANGED <<cmd, waiting, ceil, armed, under, outDuring, spellCrosses, result>>

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
    /\ UNCHANGED <<cmd, quiet, spellCrosses, result>>

\* The waiter looks: one pass of Runtime.wait's loop, quiet_notice.poll. A
\* finished command ends the wait first, before the module is asked.
Poll ==
    /\ waiting /\ ~polled
    /\ LET a == IF cmd = "done" \/ Bug = "no_rearm" THEN armed ELSE armed \/ ~Due
           pastCeil == IF Bug = "ceiling_late" THEN waitAge > ceil ELSE waitAge >= ceil
           e == IF cmd = "done" THEN "done"
                ELSE IF Bug = "end_at_crossing" /\ a /\ Due THEN "ceiling"
                ELSE IF pastCeil THEN "ceiling"
                ELSE "none"
           c == IF e # "ceiling" THEN FALSE
                ELSE CASE Bug = "cross_unarmed" -> Due
                       [] Bug = "never_cross" -> FALSE
                       [] OTHER -> a /\ Due
       IN /\ armed' = a
          /\ polled' = TRUE
          /\ IF e = "none"
             THEN UNCHANGED <<waiting, spellCrosses, result>>
             ELSE /\ waiting' = FALSE
                  /\ spellCrosses' =
                        IF c THEN (IF spellCrosses < 2 THEN spellCrosses + 1 ELSE 2)
                        ELSE spellCrosses
                  /\ result' = [end |-> e, running |-> cmd = "running",
                                quietDue |-> Due, notice |-> Notice(cmd = "running"),
                                crossed |-> c, armed |-> a, under |-> under,
                                output |-> outDuring, waitAge |-> waitAge, ceil |-> ceil]
    /\ UNCHANGED <<cmd, quiet, ceil, waitAge, under, outDuring>>

Next ==
    \/ Output
    \/ Finish
    \/ Tick
    \/ \E c \in 0..MaxCeil : Begin(c)
    \/ Poll

Spec == Init /\ [][Next]_vars /\ WF_vars(Poll) /\ SF_vars(Tick)

----------------------------------------------------------------------------
(* Rules *)

\* A result asks the model to check the command exactly when the command is
\* running and has been quiet for the limit.
NoticeRule ==
    result.end # "none" => (result.notice <=> (result.running /\ result.quietDue))

\* (a) A running command's wait ends only at its ceiling.
NoEarlyEnd ==
    (result.end # "none" /\ result.running) => (result.end = "ceiling" /\ result.waitAge = result.ceil)

\* (b) A crossing is reported only when the wait saw the command under the
\* limit and the command is running past the limit at the end.
CrossingNeedsUnder ==
    result.crossed => (result.running /\ result.quietDue /\ result.under)

\* (c) A running wait that saw the command under the limit and ends past it
\* always reports a crossing.
CrossingReported ==
    (result.running /\ result.under /\ result.quietDue) => result.crossed

\* (d) One quiet spell reports at most one crossing across waits.
OncePerSpell ==
    spellCrosses <= 1

\* A wait that ends at its ceiling ran exactly that long.
CeilingEndOnTime ==
    result.end = "ceiling" => result.waitAge = result.ceil

\* An open wait never runs past its ceiling.
WaitBounded ==
    waiting => waitAge <= ceil

\* Once the waiter has looked, a finished command has ended the wait.
DoneEnds ==
    (waiting /\ polled) => cmd = "running"

\* Every wait ends.
WaitEnds == waiting ~> ~waiting
=============================================================================

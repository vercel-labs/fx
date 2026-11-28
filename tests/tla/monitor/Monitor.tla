------------------------------ MODULE Monitor ------------------------------
(***************************************************************************)
(* How a monitor's output reaches the agent (src/core/monitor/,            *)
(* src/core/app/app_monitor_runtime.zig).                                  *)
(*                                                                         *)
(* A monitor is a shell command that prints lines. The main loop looks at  *)
(* it about once a second. When it printed something, or ended, and at     *)
(* least Gap ticks passed since its last event, the loop reads the output  *)
(* under a delivery reservation (managed_execution prepare), posts one     *)
(* event to the agent, and then commits the reservation. A post that       *)
(* fails cancels it, so the lines come back and go in a later event. An    *)
(* event that repeats the last event's text while the command runs is      *)
(* committed without waking the agent. The event for the end of the        *)
(* command is never held back and is the last one.                         *)
(*                                                                         *)
(* The command prints and exits at any moment, the clock ticks, and a      *)
(* post may fail, so the loop's read and its resolution interleave with    *)
(* all of them. Whether a read saw the command ended is fixed when the     *)
(* read is made, as the snapshot's state is.                               *)
(*                                                                         *)
(* A text is 1 or 2 when every line of a batch is the same, and 3 when a   *)
(* batch mixes them; 3 never counts as a repeat.                           *)
(*                                                                         *)
(* Bug plants one defect for the mutation configs:                         *)
(*   lose_on_fail     a failed post commits the lines instead of cancelling *)
(*   ignore_gap       an event goes at any time                            *)
(*   wake_quiet       the loop reads and posts when nothing was printed    *)
(*   no_dedupe        an event that repeats the last one wakes the agent   *)
(*   event_after_end  the loop posts again after the end event             *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxLines, \* lines the command may print
    Gap,      \* the least ticks between two events
    MaxTicks, \* the clock's last tick
    Bug

Bugs == {"none", "lose_on_fail", "ignore_gap", "wake_quiet", "no_dedupe", "event_after_end"}

ASSUME /\ MaxLines \in 1..4 /\ Gap \in 1..4 /\ MaxTicks \in 1..10 /\ Bug \in Bugs

VARIABLES
    cmd,         \* "running" or "exited"
    now,         \* the clock
    printed,     \* lines the command printed
    pending,     \* lines in the entry that no read took
    pendingVal,  \* the text of the pending lines: 0 none, 1, 2, or 3
    reading,     \* a read holds a reservation
    reserved,    \* lines that read holds
    reservedVal, \* their text
    readEnded,   \* that read saw the command ended
    carried,     \* lines in posted events
    dropped,     \* lines committed without an event, as repeats
    events,      \* events posted
    hasLast,     \* an event was posted or a repeat restarted the gap
    lastAt,      \* the tick of the last event
    lastText,    \* the text of the last event
    ended        \* the end event was posted

vars == <<cmd, now, printed, pending, pendingVal, reading, reserved, reservedVal,
          readEnded, carried, dropped, events, hasLast, lastAt, lastText, ended>>

Init ==
    /\ cmd = "running" /\ now = 0 /\ printed = 0
    /\ pending = 0 /\ pendingVal = 0
    /\ reading = FALSE /\ reserved = 0 /\ reservedVal = 0 /\ readEnded = FALSE
    /\ carried = 0 /\ dropped = 0 /\ events = 0
    /\ hasLast = FALSE /\ lastAt = 0 /\ lastText = 0 /\ ended = FALSE

Print ==
    /\ cmd = "running" /\ printed < MaxLines
    /\ \E v \in 1..2 :
        pendingVal' = IF pending = 0 THEN v ELSE IF pendingVal = v THEN v ELSE 3
    /\ printed' = printed + 1 /\ pending' = pending + 1
    /\ UNCHANGED <<cmd, now, reading, reserved, reservedVal, readEnded, carried,
                   dropped, events, hasLast, lastAt, lastText, ended>>

Exit ==
    /\ cmd = "running" /\ cmd' = "exited"
    /\ UNCHANGED <<now, printed, pending, pendingVal, reading, reserved,
                   reservedVal, readEnded, carried, dropped, events, hasLast,
                   lastAt, lastText, ended>>

Tick ==
    /\ now < MaxTicks /\ now' = now + 1
    /\ UNCHANGED <<cmd, printed, pending, pendingVal, reading, reserved,
                   reservedVal, readEnded, carried, dropped, events, hasLast,
                   lastAt, lastText, ended>>

Due == \/ Bug = "ignore_gap"
       \/ cmd = "exited"
       \/ ~hasLast
       \/ now - lastAt >= Gap

Wants ==
    \/ pending > 0
    \/ (cmd = "exited" /\ (~ended \/ Bug = "event_after_end"))
    \/ (Bug = "wake_quiet" /\ cmd = "running")

\* The loop reads: the pending lines move under a reservation.
Read ==
    /\ ~reading /\ Wants /\ Due
    /\ (~ended \/ Bug = "event_after_end")
    /\ reading' = TRUE
    /\ reserved' = pending /\ reservedVal' = pendingVal
    /\ readEnded' = (cmd = "exited")
    /\ pending' = 0 /\ pendingVal' = 0
    /\ UNCHANGED <<cmd, now, printed, carried, dropped, events, hasLast,
                   lastAt, lastText, ended>>

IsRepeat == /\ ~readEnded /\ Bug # "no_dedupe"
            /\ reservedVal \in 1..2 /\ reservedVal = lastText

\* The post succeeded: one event goes, and the reservation commits.
Post ==
    /\ reading /\ ~IsRepeat
    /\ events' = events + 1 /\ carried' = carried + reserved
    /\ hasLast' = TRUE /\ lastAt' = now /\ lastText' = reservedVal
    /\ ended' = readEnded
    /\ reading' = FALSE /\ reserved' = 0 /\ reservedVal' = 0
    /\ UNCHANGED <<cmd, now, printed, pending, pendingVal, readEnded, dropped>>

\* The same words again: committed, no event, the gap restarts.
Repeat ==
    /\ reading /\ IsRepeat
    /\ dropped' = dropped + reserved /\ hasLast' = TRUE /\ lastAt' = now
    /\ reading' = FALSE /\ reserved' = 0 /\ reservedVal' = 0
    /\ UNCHANGED <<cmd, now, printed, pending, pendingVal, readEnded, carried,
                   events, lastText, ended>>

\* The post failed: the reservation is cancelled and the lines wait again.
PostFails ==
    /\ reading /\ ~IsRepeat
    /\ IF Bug = "lose_on_fail"
          THEN /\ pending' = pending /\ pendingVal' = pendingVal
          ELSE /\ pending' = pending + reserved
               /\ pendingVal' = IF reserved = 0 THEN pendingVal
                                ELSE IF pending = 0 THEN reservedVal
                                ELSE IF pendingVal = reservedVal THEN pendingVal ELSE 3
    /\ reading' = FALSE /\ reserved' = 0 /\ reservedVal' = 0
    /\ UNCHANGED <<cmd, now, printed, readEnded, carried, dropped, events,
                   hasLast, lastAt, lastText, ended>>

Next == Print \/ Exit \/ Tick \/ Read \/ Post \/ Repeat \/ PostFails

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ cmd \in {"running", "exited"} /\ now \in 0..MaxTicks
    /\ printed \in 0..MaxLines /\ pending \in 0..MaxLines /\ reserved \in 0..MaxLines
    /\ events \in 0..40 /\ ended \in BOOLEAN /\ reading \in BOOLEAN

\* Every printed line is waiting, held by a read, in an event, or dropped as
\* a repeat: a failed post loses none.
NoLoss == printed = pending + reserved + carried + dropped

\* A running command's events are Gap ticks apart.
GapKept == [][ (events' > events /\ ~readEnded) => (~hasLast \/ now - lastAt >= Gap) ]_vars

\* An event carries a line, or is the end of the command: a quiet command
\* wakes no one.
NoQuietWake == [][ events' > events => (carried' > carried \/ readEnded) ]_vars

\* An event never repeats the last event's words while the command runs.
NoRepeatWake == [][ (events' > events /\ ~readEnded /\ hasLast /\ lastText' \in 1..2)
                     => lastText' # lastText ]_vars

\* The end event is the last.
EndIsLast == [][ ended => events' = events ]_vars
=============================================================================

------------------------------ MODULE Monitor ------------------------------
(***************************************************************************)
(* How a monitor's output reaches the agent (src/core/monitor/,            *)
(* src/core/app/app_monitor_runtime.zig).                                  *)
(*                                                                         *)
(* A monitor is a shell command that prints lines. The main loop looks at  *)
(* it about once a second. When it printed something, or ended, and at     *)
(* least Gap ticks passed since its last event, the loop reads the output  *)
(* under a delivery reservation (managed_execution prepare), appends it to *)
(* the monitor's file, makes one event from it, holds the event, and       *)
(* commits the reservation. An event that repeats the last event's text    *)
(* while the command runs is committed without an event. The end of the    *)
(* command makes one last event, never held back by the gap.               *)
(*                                                                         *)
(* A separate step posts what is held, as one message, when the agent's    *)
(* queue holds fewer than MaxQueued of them. An agent blocked on a prompt  *)
(* takes nothing, so events pile up in the monitor's own list, which keeps *)
(* the newest MaxHeld and counts each older one it drops. The next message *)
(* announces that count. The agent takes a message from its queue at any   *)
(* moment its turn allows.                                                 *)
(*                                                                         *)
(* The command prints and exits, the clock ticks, and the agent takes mail *)
(* at any moment, so the loop's read and its posts interleave with all of  *)
(* them. Whether a read saw the command ended is fixed when the read is    *)
(* made, as the snapshot's state is.                                       *)
(*                                                                         *)
(* A text is 1 or 2 when every line of a batch is the same, and 3 when a   *)
(* batch mixes them; 3 never counts as a repeat.                           *)
(*                                                                         *)
(* Bug plants one defect for the mutation configs:                         *)
(*   ignore_gap       an event is made at any time                         *)
(*   wake_quiet       the loop reads and makes an event when nothing was   *)
(*                    printed                                              *)
(*   no_dedupe        an event that repeats the last one is made           *)
(*   event_after_end  the loop makes another event after the end event     *)
(*   unbounded_held   the list keeps every event                           *)
(*   post_when_full   a message is posted into a full queue                *)
(*   lose_count       a dropped event is not counted                       *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    MaxLines,  \* lines the command may print
    Gap,       \* the least ticks between two events
    MaxTicks,  \* the clock's last tick
    MaxHeld,   \* events the list keeps (20 in the code)
    MaxQueued, \* messages of this monitor the agent's queue holds (1 in the code)
    Bug

Bugs == {"none", "ignore_gap", "wake_quiet", "no_dedupe", "event_after_end",
         "unbounded_held", "post_when_full", "lose_count"}

ASSUME /\ MaxLines \in 1..5 /\ Gap \in 1..4 /\ MaxTicks \in 1..10
       /\ MaxHeld \in 1..4 /\ MaxQueued \in 1..2 /\ Bug \in Bugs

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
    held,        \* the events the list keeps, oldest first: each its line count
    heldDropped, \* events dropped from the list since the last post
    droppedAll,  \* events dropped from the list, ever
    announced,   \* events dropped that a posted message counted
    carried,     \* lines in posted messages
    repeated,    \* lines committed as repeats, with no event
    cut,         \* lines of events dropped from the list
    mailbox,     \* messages posted that the agent has not taken
    events,      \* events made
    hasLast,     \* an event was made or a repeat restarted the gap
    lastAt,      \* the tick of the last event
    lastText,    \* the text of the last event
    ended        \* the end event was made

vars == <<cmd, now, printed, pending, pendingVal, reading, reserved, reservedVal,
          readEnded, held, heldDropped, droppedAll, announced, carried, repeated,
          cut, mailbox, events, hasLast, lastAt, lastText, ended>>

RECURSIVE Sum(_)
Sum(s) == IF s = <<>> THEN 0 ELSE Head(s) + Sum(Tail(s))

Init ==
    /\ cmd = "running" /\ now = 0 /\ printed = 0
    /\ pending = 0 /\ pendingVal = 0
    /\ reading = FALSE /\ reserved = 0 /\ reservedVal = 0 /\ readEnded = FALSE
    /\ held = <<>> /\ heldDropped = 0 /\ droppedAll = 0 /\ announced = 0
    /\ carried = 0 /\ repeated = 0 /\ cut = 0 /\ mailbox = 0 /\ events = 0
    /\ hasLast = FALSE /\ lastAt = 0 /\ lastText = 0 /\ ended = FALSE

Print ==
    /\ cmd = "running" /\ printed < MaxLines
    /\ \E v \in 1..2 :
        pendingVal' = IF pending = 0 THEN v ELSE IF pendingVal = v THEN v ELSE 3
    /\ printed' = printed + 1 /\ pending' = pending + 1
    /\ UNCHANGED <<cmd, now, reading, reserved, reservedVal, readEnded, held,
                   heldDropped, droppedAll, announced, carried, repeated, cut,
                   mailbox, events, hasLast, lastAt, lastText, ended>>

Exit ==
    /\ cmd = "running" /\ cmd' = "exited"
    /\ UNCHANGED <<now, printed, pending, pendingVal, reading, reserved,
                   reservedVal, readEnded, held, heldDropped, droppedAll,
                   announced, carried, repeated, cut, mailbox, events, hasLast,
                   lastAt, lastText, ended>>

Tick ==
    /\ now < MaxTicks /\ now' = now + 1
    /\ UNCHANGED <<cmd, printed, pending, pendingVal, reading, reserved,
                   reservedVal, readEnded, held, heldDropped, droppedAll,
                   announced, carried, repeated, cut, mailbox, events, hasLast,
                   lastAt, lastText, ended>>

\* The agent takes a message from its queue.
Take ==
    /\ mailbox > 0 /\ mailbox' = mailbox - 1
    /\ UNCHANGED <<cmd, now, printed, pending, pendingVal, reading, reserved,
                   reservedVal, readEnded, held, heldDropped, droppedAll,
                   announced, carried, repeated, cut, events, hasLast, lastAt,
                   lastText, ended>>

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
    /\ UNCHANGED <<cmd, now, printed, held, heldDropped, droppedAll, announced,
                   carried, repeated, cut, mailbox, events, hasLast, lastAt,
                   lastText, ended>>

IsRepeat == /\ ~readEnded /\ Bug # "no_dedupe"
            /\ reservedVal \in 1..2 /\ reservedVal = lastText

\* The read made an event: it joins the list, which keeps the newest MaxHeld
\* and counts each older one it drops. The reservation commits.
Hold ==
    /\ reading /\ ~IsRepeat
    /\ events' = events + 1
    /\ hasLast' = TRUE /\ lastAt' = now /\ lastText' = reservedVal
    /\ ended' = readEnded
    /\ IF Bug # "unbounded_held" /\ Len(held) = MaxHeld
          THEN /\ held' = Append(Tail(held), reserved)
               /\ cut' = cut + Head(held)
               /\ droppedAll' = droppedAll + 1
               /\ heldDropped' = IF Bug = "lose_count" THEN heldDropped ELSE heldDropped + 1
          ELSE /\ held' = Append(held, reserved)
               /\ UNCHANGED <<cut, droppedAll, heldDropped>>
    /\ reading' = FALSE /\ reserved' = 0 /\ reservedVal' = 0
    /\ UNCHANGED <<cmd, now, printed, pending, pendingVal, readEnded, announced,
                   carried, repeated, mailbox>>

\* The same words again: committed, no event, the gap restarts.
Repeat ==
    /\ reading /\ IsRepeat
    /\ repeated' = repeated + reserved /\ hasLast' = TRUE /\ lastAt' = now
    /\ reading' = FALSE /\ reserved' = 0 /\ reservedVal' = 0
    /\ UNCHANGED <<cmd, now, printed, pending, pendingVal, readEnded, held,
                   heldDropped, droppedAll, announced, carried, cut, mailbox,
                   events, lastText, ended>>

\* The loop posts what is held, as one message that counts the events dropped
\* before it, when the agent's queue has room.
Post ==
    /\ held # <<>>
    /\ (mailbox < MaxQueued \/ Bug = "post_when_full")
    /\ mailbox' = mailbox + 1
    /\ carried' = carried + Sum(held) /\ held' = <<>>
    /\ announced' = announced + heldDropped /\ heldDropped' = 0
    /\ UNCHANGED <<cmd, now, printed, pending, pendingVal, reading, reserved,
                   reservedVal, readEnded, droppedAll, repeated, cut, events,
                   hasLast, lastAt, lastText, ended>>

Next == Print \/ Exit \/ Tick \/ Take \/ Read \/ Hold \/ Repeat \/ Post

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ cmd \in {"running", "exited"} /\ now \in 0..MaxTicks
    /\ printed \in 0..MaxLines /\ pending \in 0..MaxLines /\ reserved \in 0..MaxLines
    /\ events \in 0..40 /\ ended \in BOOLEAN /\ reading \in BOOLEAN
    /\ mailbox \in 0..(MaxQueued + 1)

\* Every printed line is waiting, held by a read, in a held event, in a posted
\* message, a committed repeat, or in an event dropped from the list: the
\* monitor's file has all of them, and none is lost.
NoLoss == printed = pending + reserved + Sum(held) + carried + repeated + cut

\* The list never holds more than MaxHeld events.
HeldBounded == Len(held) <= MaxHeld

\* The agent's queue never holds more than MaxQueued of this monitor's messages.
OneQueued == mailbox <= MaxQueued

\* Every event dropped from the list is counted, and the count reaches the
\* agent in the next message.
DropCounted == droppedAll = announced + heldDropped

\* A running command's events are made Gap ticks apart.
GapKept == [][ (events' > events /\ ~readEnded) => (~hasLast \/ now - lastAt >= Gap) ]_vars

\* An event carries a line, or is the end of the command: a quiet command
\* makes none.
NoQuietWake == [][ events' > events => (Sum(held') + cut' > Sum(held) + cut \/ readEnded) ]_vars

\* An event never repeats the last event's words while the command runs.
NoRepeatWake == [][ (events' > events /\ ~readEnded /\ hasLast /\ lastText' \in 1..2)
                     => lastText' # lastText ]_vars

\* The end event is the last.
EndIsLast == [][ ended => events' = events ]_vars
=============================================================================

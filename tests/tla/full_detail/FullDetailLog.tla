---- MODULE FullDetailLog ----
\* How a turn saves its model call records and steering messages at one
\* tool step boundary, so every write of the streamed turn only adds to the
\* end of the one before (D96).
\*
\* At a boundary, steering messages arrive and model calls settle in any
\* order: a call can settle and be saved, then a message (a subagent's
\* report) arrive at the same boundary, then the next call settle. The first
\* write after a call settles gives its record a stamp, the number of the
\* turn's messages so far, which it keeps. A write lays the boundary out from
\* what it holds: each record goes before the first message its stamp does
\* not count.
\*
\* Planted bug:
\*   RecordsAfterSteering  TRUE: every record goes after all the boundary's
\*                         messages
EXTENDS Naturals, Sequences

CONSTANTS MaxCalls, MaxSteer, RecordsAfterSteering

ASSUME MaxCalls \in Nat /\ MaxSteer \in Nat /\ RecordsAfterSteering \in BOOLEAN

VARIABLES
    calls,    \* calls settled so far
    steer,    \* messages delivered so far
    stamps,   \* stamps[i]: the messages call i's record counts
    last,     \* what the last write saved
    grown     \* every write held the one before as its start

vars == <<calls, steer, stamps, last, grown>>

Init ==
    /\ calls = 0
    /\ steer = 0
    /\ stamps = <<>>
    /\ last = <<>>
    /\ grown = TRUE

Settle ==
    /\ calls < MaxCalls
    /\ calls' = calls + 1
    /\ UNCHANGED <<steer, stamps, last, grown>>

Steer ==
    /\ steer < MaxSteer
    /\ steer' = steer + 1
    /\ UNCHANGED <<calls, stamps, last, grown>>

Rec(i) == [t |-> "rec", n |-> i]
Msg(j) == [t |-> "msg", n |-> j]

\* The boundary as a write lays it out from records 1..c, stamped st, and
\* messages 1..s: record i before message j when its stamp does not count j.
RECURSIVE Lay(_, _, _, _, _)
Lay(st, c, s, i, j) ==
    IF i > c /\ j > s THEN <<>>
    ELSE IF i <= c /\ (j > s \/ (~RecordsAfterSteering /\ st[i] < j))
         THEN <<Rec(i)>> \o Lay(st, c, s, i + 1, j)
         ELSE <<Msg(j)>> \o Lay(st, c, s, i, j + 1)

\* A write of the turn so far: records settled since the last one take
\* their stamp now.
Save ==
    LET st == stamps \o [k \in 1..(calls - Len(stamps)) |-> steer]
        log == Lay(st, calls, steer, 1, 1)
    IN /\ stamps' = st
       /\ grown' = (grown /\ Len(log) >= Len(last) /\ SubSeq(log, 1, Len(last)) = last)
       /\ last' = log
       /\ UNCHANGED <<calls, steer>>

Next == Settle \/ Steer \/ Save

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ calls \in 0..MaxCalls
    /\ steer \in 0..MaxSteer
    /\ Len(stamps) <= calls

\* Every write of the turn starts with what the one before saved, so a
\* streamed turn is never written again whole.
AppendOnly == grown
====

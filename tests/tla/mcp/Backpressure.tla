---- MODULE Backpressure ----
\* The byte budget a connection's readers post under (src/mcp/io/budget.zig):
\* the stdio stdout reader (io/process.zig) and the HTTP request tasks
\* (io/http.zig) wait for room before copying a message they read, and
\* the host gives a message's bytes back when `poll` takes it off the queue.
\*
\* A reader reads a message of some size and joins the line. It posts when it
\* is first in line and the message fits: nothing posted is untaken, or what
\* is plus this one is at most Max, the largest message. A waiting reader may
\* be cancelled (its request ends, or the connection closes) and leaves the
\* line. The host takes the oldest posted message whenever there is one.
EXTENDS Naturals, Sequences

CONSTANTS
    Readers,  \* reader tasks: one for stdio, up to 32 for HTTP
    Sizes     \* message sizes in some unit; the largest is the limit

Max == CHOOSE m \in Sizes : \A s \in Sizes : s <= m

VARIABLES
    want,   \* [Readers -> the size of the message it waits to post, 0 for none]
    line,   \* the waiting readers, in the order they came
    queue,  \* sizes posted and not yet taken, oldest first
    used    \* the budget's count

vars == <<want, line, queue, used>>

RECURSIVE Total(_)
Total(s) == IF s = <<>> THEN 0 ELSE Head(s) + Total(Tail(s))

Without(s, r) == SelectSeq(s, LAMBDA x : x # r)

TypeOK ==
    /\ want \in [Readers -> {0} \cup Sizes]
    /\ line \in Seq(Readers)
    /\ queue \in Seq(Sizes)
    /\ used \in Nat

Init ==
    /\ want = [r \in Readers |-> 0]
    /\ line = <<>>
    /\ queue = <<>>
    /\ used = 0

Read(r) ==
    /\ want[r] = 0
    /\ \E s \in Sizes : want' = [want EXCEPT ![r] = s]
    /\ line' = Append(line, r)
    /\ UNCHANGED <<queue, used>>

\* First come, first served.
First(r) == line # <<>> /\ Head(line) = r

\* Nothing is held, so any one message goes; else it must fit.
Fits(n) == used = 0 \/ used + n <= Max

Post(r) ==
    /\ want[r] > 0
    /\ First(r)
    /\ Fits(want[r])
    /\ queue' = Append(queue, want[r])
    /\ used' = used + want[r]
    /\ want' = [want EXCEPT ![r] = 0]
    /\ line' = Without(line, r)

Cancel(r) ==
    /\ want[r] > 0
    /\ want' = [want EXCEPT ![r] = 0]
    /\ line' = Without(line, r)
    /\ UNCHANGED <<queue, used>>

Take ==
    /\ queue # <<>>
    /\ used' = used - Head(queue)
    /\ queue' = Tail(queue)
    /\ UNCHANGED <<want, line>>

Next == (\E r \in Readers : Read(r) \/ Post(r) \/ Cancel(r)) \/ Take

\* The host keeps reading; a reader that can post does. Cancelling and
\* reading are never forced.
Spec == Init /\ [][Next]_vars /\ WF_vars(Take) /\ \A r \in Readers : WF_vars(Post(r))

\* ---- Safety ----

\* The count is what is posted and not yet taken.
UsedIsQueued == used = Total(queue)

\* At most one largest message's worth waits for the host.
Bounded == used <= Max

\* The line is the waiting readers, each once.
LineIsWaiters ==
    /\ \A i \in 1..Len(line) : want[line[i]] > 0
    /\ \A i, j \in 1..Len(line) : i # j => line[i] # line[j]
    /\ \A r \in Readers : want[r] > 0 => \E i \in 1..Len(line) : line[i] = r

\* ---- Liveness ----

\* Every message read is posted or cancelled: small ones never starve a
\* large one.
EveryMessagePosted == \A r \in Readers : want[r] > 0 ~> want[r] = 0
====

---- MODULE Backpressure ----
\* The byte budget a connection's readers read and post under
\* (src/mcp/io/budget.zig): the stdio stdout reader (io/process.zig) and the
\* HTTP request tasks (io/http.zig) count what they read, and the host gives
\* a message's bytes back when `poll` takes it off the queue.
\*
\* A reader reads a message of some size one unit at a time. Its first
\* Allowance units are free, so a message no larger costs nothing until it
\* posts: it goes when its reader is first in line and it fits. A reader with
\* more to read needs the one large read: it waits in the same line for it,
\* then counts each further unit against the budget as it reads it, and posts
\* the message whole. A small message leaves room for the large read's next
\* step, so the large read never starves, and only it holds
\* bytes the budget counts but hasn't posted, so no two readers wait for each
\* other. What is held, posted or read, is then at most Max and each reader's
\* Allowance. A reader may be cancelled at any point (its request ends, or the
\* connection closes) and lets go of what it holds. The host takes the oldest
\* posted message whenever there is one.
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Readers,    \* reader tasks: one for stdio, up to 32 for HTTP
    Sizes,      \* message sizes in some unit; the largest is the limit
    Allowance   \* what a reader reads before it counts

None == "none"
Max == CHOOSE m \in Sizes : \A s \in Sizes : s <= m

ASSUME Allowance \in Nat /\ 0 < Allowance /\ Allowance < Max /\ None \notin Readers

VARIABLES
    want,     \* [Readers -> the size of the message it reads, 0 for none]
    got,      \* [Readers -> how much of it has been read]
    line,     \* readers waiting in the order they came: to post, or for the large read
    large,    \* the reader with the large read, or None
    counted,  \* what the large read has counted past its Allowance
    queue,    \* sizes posted and not yet taken, oldest first
    used      \* the budget's count

vars == <<want, got, line, large, counted, queue, used>>

RECURSIVE Total(_)
Total(s) == IF s = <<>> THEN 0 ELSE Head(s) + Total(Tail(s))

RECURSIVE Reading(_)
Reading(rs) == IF rs = {} THEN 0 ELSE LET r == CHOOSE x \in rs : TRUE IN got[r] + Reading(rs \ {r})

Without(s, r) == SelectSeq(s, LAMBDA x : x # r)
InLine(r) == \E i \in 1..Len(line) : line[i] = r

\* First come, first served.
First(r) == line # <<>> /\ Head(line) = r

Small(r) == want[r] > 0 /\ want[r] <= Allowance

\* Waiting to post a small message, or for the large read.
Waits(r) ==
    \/ Small(r) /\ got[r] = want[r]
    \/ want[r] > Allowance /\ got[r] = Allowance /\ large # r

\* The room a small message leaves the large read: its next unit and its
\* Allowance, which it counts when it posts. Its size isn't known until it
\* ends, so its next step is all that can be kept for it.
Reserve == IF large = None THEN 0 ELSE Allowance + 1

TypeOK ==
    /\ want \in [Readers -> {0} \cup Sizes]
    /\ got \in [Readers -> 0..Max]
    /\ line \in Seq(Readers)
    /\ large \in Readers \cup {None}
    /\ counted \in Nat
    /\ queue \in Seq(Sizes)
    /\ used \in Nat

Init ==
    /\ want = [r \in Readers |-> 0]
    /\ got = [r \in Readers |-> 0]
    /\ line = <<>>
    /\ large = None
    /\ counted = 0
    /\ queue = <<>>
    /\ used = 0

\* The server starts a message.
Start(r) ==
    /\ want[r] = 0
    /\ \E s \in Sizes : want' = [want EXCEPT ![r] = s]
    /\ UNCHANGED <<got, line, large, counted, queue, used>>

\* A unit within the allowance is read without counting.
ReadFree(r) ==
    /\ want[r] > 0 /\ got[r] < want[r] /\ got[r] < Allowance
    /\ got' = [got EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<want, line, large, counted, queue, used>>

\* It has to wait: to post, or for the large read.
Join(r) ==
    /\ Waits(r) /\ ~InLine(r)
    /\ line' = Append(line, r)
    /\ UNCHANGED <<want, got, large, counted, queue, used>>

\* The large read is free, and it is first in line.
Claim(r) ==
    /\ want[r] > Allowance /\ got[r] = Allowance
    /\ First(r) /\ large = None
    /\ large' = r
    /\ line' = Tail(line)
    /\ UNCHANGED <<want, got, counted, queue, used>>

\* Past its allowance the large read counts each unit as it reads it.
ReadCounted(r) ==
    /\ large = r /\ got[r] < want[r]
    /\ used + 1 <= Max
    /\ got' = [got EXCEPT ![r] = @ + 1]
    /\ counted' = counted + 1
    /\ used' = used + 1
    /\ UNCHANGED <<want, line, large, queue>>

\* A small message, read whole, goes in turn, leaving the large read its room.
PostSmall(r) ==
    /\ Small(r) /\ got[r] = want[r]
    /\ First(r) /\ used + want[r] + Reserve <= Max
    /\ queue' = Append(queue, want[r])
    /\ used' = used + want[r]
    /\ want' = [want EXCEPT ![r] = 0]
    /\ got' = [got EXCEPT ![r] = 0]
    /\ line' = Tail(line)
    /\ UNCHANGED <<large, counted>>

\* The large read, read whole, counts its allowance too and goes.
PostLarge(r) ==
    /\ large = r /\ got[r] = want[r]
    /\ used - counted + want[r] <= Max
    /\ queue' = Append(queue, want[r])
    /\ used' = used - counted + want[r]
    /\ counted' = 0
    /\ large' = None
    /\ want' = [want EXCEPT ![r] = 0]
    /\ got' = [got EXCEPT ![r] = 0]
    /\ UNCHANGED line

Cancel(r) ==
    /\ want[r] > 0
    /\ want' = [want EXCEPT ![r] = 0]
    /\ got' = [got EXCEPT ![r] = 0]
    /\ line' = Without(line, r)
    /\ IF large = r
       THEN /\ large' = None
            /\ counted' = 0
            /\ used' = used - counted
       ELSE UNCHANGED <<large, counted, used>>
    /\ UNCHANGED queue

Take ==
    /\ queue # <<>>
    /\ used' = used - Head(queue)
    /\ queue' = Tail(queue)
    /\ UNCHANGED <<want, got, line, large, counted>>

Next ==
    \/ \E r \in Readers :
        Start(r) \/ ReadFree(r) \/ Join(r) \/ Claim(r) \/ ReadCounted(r) \/ PostSmall(r) \/ PostLarge(r) \/ Cancel(r)
    \/ Take

\* The host keeps taking, the server keeps sending a message it started, and
\* a reader that can go on does. Starting and cancelling are never forced.
Fair(r) ==
    /\ WF_vars(ReadFree(r)) /\ WF_vars(Join(r)) /\ WF_vars(Claim(r))
    /\ WF_vars(ReadCounted(r)) /\ WF_vars(PostSmall(r)) /\ WF_vars(PostLarge(r))

Spec == Init /\ [][Next]_vars /\ WF_vars(Take) /\ \A r \in Readers : Fair(r)

\* ---- Safety ----

\* The count is what is posted and not yet taken, and what the large read
\* has counted.
UsedIsCounted == used = Total(queue) + counted

\* The large read's count is what it read past its allowance.
CountedIsLarge == IF large = None THEN counted = 0 ELSE counted = got[large] - Allowance

\* Only the large read reads past its allowance.
OneLargeRead == \A r \in Readers : got[r] > Allowance => large = r

\* At most one largest message's worth is counted.
Bounded == used <= Max

\* What is held, read or posted, is at most Max and each reader's Allowance.
HeldIsBounded == Total(queue) + Reading(Readers) <= Max + Cardinality(Readers) * Allowance

\* The line is waiting readers, each once.
LineIsWaiters ==
    /\ \A i \in 1..Len(line) : Waits(line[i])
    /\ \A i, j \in 1..Len(line) : i # j => line[i] # line[j]

\* ---- Liveness ----

\* Every message read is posted or cancelled: small ones never starve a large
\* one, and readers never wait for each other.
EveryMessagePosted == \A r \in Readers : want[r] > 0 ~> want[r] = 0
====

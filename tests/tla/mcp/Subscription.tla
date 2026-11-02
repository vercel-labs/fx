---- MODULE Subscription ----
\* U10 subscriptions, client side, for one 2026 server: the listen requests the
\* client sends for its subscriptions, what it hands the host, and when it
\* listens again. Rules: SUBS-01..SUBS-05.
\*
\* Each subscription in Subs is one thing the host listens for (fx has one:
\* tool list changes), asking for its own filter, Ask(s). Every listen is a
\* new request with a fresh id from
\* 1..MaxListens. The server may send anything for any id ever used: an
\* acknowledgment with any filter, notifications of any kind before or after
\* it, a result, an error, or a cancel. On HTTP each listen's stream may close;
\* on stdio (chosen at Init) the process may exit, ending every listen at
\* once, and come back. The client delivers a notification only to the
\* subscription whose current listen carries its id, after that listen's
\* acknowledgment, inside what it asked for and the server acknowledged, and
\* never after the listen ended. An abrupt end listens again, at most
\* MaxTries times in a row; a result, an error, or a server's cancel doesn't
\*. The ghost flags record a broken rule at the moment it breaks.
EXTENDS Naturals

CONSTANTS Subs, Kinds, Ask(_), MaxListens, MaxTries

ASSUME Subs \subseteq Nat \ {0} /\ \A s \in Subs: Ask(s) \subseteq Kinds /\ Ask(s) # {}

\* The configurations' subscriptions: 1 asks for tool list changes, 2 for
\* tool and prompt list changes.
TwoAsks(s) == IF s = 1 THEN {"tools"} ELSE {"tools", "prompts"}

None == 0   \* no subscription; subscriptions are numbered from 1
NoId == 0
Ids == 1..MaxListens
Phases == {"off", "pending", "active", "waiting", "ended"}

VARIABLES
    phase,     \* [Subs -> Phases]
    cur,       \* [Subs -> 0..MaxListens]: the current listen's id
    asked,     \* [Subs -> SUBSET Kinds]: what the current listen asked for
    acked,     \* [Subs -> SUBSET Kinds]: what the client takes as acknowledged
    tries,     \* [Subs -> 0..MaxTries]: listens in a row that ended abruptly
    next,      \* the next fresh id
    stdio,     \* BOOLEAN, fixed at Init: the transport
    up,        \* stdio: the process is running
    \* ghosts
    owner,     \* [Ids -> Subs \cup {None}]: the subscription that sent the id
    ackSeen,   \* [Ids -> BOOLEAN]: an acknowledgment of it was taken
    allowed,   \* [Ids -> SUBSET Kinds]: asked for and in that acknowledgment
    over,      \* [Ids -> BOOLEAN]: the listen ended, one way or another
    told,      \* [Ids -> 0..2]: ends of it reported to the host
    final,     \* [Ids -> BOOLEAN]: it ended with a result, an error, a server's
               \* cancel, or an acknowledgment of nothing asked
    misrouted, \* a notification went to a subscription that didn't send its id
    early,     \* a notification was delivered before its listen's acknowledgment
    unasked,   \* a notification outside what was asked and acknowledged
    late,      \* a notification was delivered after its listen ended
    sentDown,  \* a listen was sent while the stdio process was down
    relistened \* a listen went out again after a final end

vars == <<phase, cur, asked, acked, tries, next, stdio, up, owner, ackSeen, allowed, over, told, final,
          misrouted, early, unasked, late, sentDown, relistened>>
ghosts == <<misrouted, early, unasked, late, sentDown, relistened>>

Init ==
    /\ phase = [s \in Subs |-> "off"]
    /\ cur = [s \in Subs |-> NoId]
    /\ asked = [s \in Subs |-> {}]
    /\ acked = [s \in Subs |-> {}]
    /\ tries = [s \in Subs |-> 0]
    /\ next = 1
    /\ stdio \in BOOLEAN
    /\ up = TRUE
    /\ owner = [n \in Ids |-> None]
    /\ ackSeen = [n \in Ids |-> FALSE]
    /\ allowed = [n \in Ids |-> {}]
    /\ over = [n \in Ids |-> FALSE]
    /\ told = [n \in Ids |-> 0]
    /\ final = [n \in Ids |-> FALSE]
    /\ misrouted = FALSE /\ early = FALSE /\ unasked = FALSE /\ late = FALSE /\ sentDown = FALSE
    /\ relistened = FALSE

\* A listen for s goes out with the next id, asking for f.
Listen(s, f) ==
    /\ next <= MaxListens
    /\ phase' = [phase EXCEPT ![s] = "pending"]
    /\ cur' = [cur EXCEPT ![s] = next]
    /\ asked' = [asked EXCEPT ![s] = f]
    /\ acked' = [acked EXCEPT ![s] = {}]
    /\ next' = next + 1
    /\ owner' = [owner EXCEPT ![next] = s]
    /\ sentDown' = (sentDown \/ (stdio /\ ~up))

\* The host opens s. Never while the stdio process is down.
Open(s) ==
    /\ phase[s] \in {"off", "ended"}
    /\ ~stdio \/ up
    /\ Listen(s, Ask(s))
    /\ tries' = [tries EXCEPT ![s] = 0]
    /\ UNCHANGED <<stdio, up, ackSeen, allowed, over, told, final, misrouted, early, unasked, late, relistened>>

\* An abruptly ended s listens again with a new id (SUBS-05): after the
\* backoff on HTTP, once the process is back on stdio.
Resend(s) ==
    /\ phase[s] = "waiting"
    /\ ~stdio \/ up
    /\ Listen(s, asked[s])
    /\ relistened' = (relistened \/ final[cur[s]])
    /\ UNCHANGED <<tries, stdio, up, ackSeen, allowed, over, told, final, misrouted, early, unasked, late>>

\* The host cancels s: closing the stream, or notifications/cancelled (SUBS-04).
Cancel(s) ==
    /\ phase[s] \in {"pending", "active", "waiting"}
    /\ phase' = [phase EXCEPT ![s] = "off"]
    /\ over' = IF phase[s] \in {"pending", "active"} THEN [over EXCEPT ![cur[s]] = TRUE] ELSE over
    /\ UNCHANGED <<cur, asked, acked, tries, next, stdio, up, owner, ackSeen, allowed, told, final, ghosts>>

Current(n) == \E s \in Subs: phase[s] \in {"pending", "active"} /\ cur[s] = n
OwnerOf(n) == CHOOSE s \in Subs: cur[s] = n

\* The listen n ends for good, and the host hears it once.
Ends(s, n) ==
    /\ phase' = [phase EXCEPT ![s] = "ended"]
    /\ over' = [over EXCEPT ![n] = TRUE]
    /\ told' = [told EXCEPT ![n] = @ + 1]

\* An acknowledgment for n with filter f, which may name more than was asked.
\* The first one for a pending listen counts, as asked intersected with f
\* (SUBS-01). One naming nothing that was asked ends the listen.
Ack(n, f) ==
    IF Current(n) /\ phase[OwnerOf(n)] = "pending"
    THEN LET s == OwnerOf(n)
             a == f \cap asked[s]
         IN /\ ackSeen' = [ackSeen EXCEPT ![n] = TRUE]
            /\ allowed' = [allowed EXCEPT ![n] = Ask(owner[n]) \cap f]
            /\ IF a = {}
               THEN /\ Ends(s, n)
                    /\ final' = [final EXCEPT ![n] = TRUE]
                    /\ UNCHANGED <<acked, tries>>
               ELSE /\ phase' = [phase EXCEPT ![s] = "active"]
                    /\ acked' = [acked EXCEPT ![s] = a]
                    /\ tries' = [tries EXCEPT ![s] = 0]
                    /\ UNCHANGED <<over, told, final>>
            /\ UNCHANGED <<cur, asked, next, stdio, up, owner, ghosts>>
    ELSE UNCHANGED vars

\* A notification of kind k carrying id n (SUBS-02). The client hands it to
\* the subscriptions it routes it to, checking each delivery against the rules.
Targets(n, k) == {s \in Subs: phase[s] = "active" /\ cur[s] = n /\ k \in acked[s]}

Note(n, k) ==
    LET T == Targets(n, k)
    IN IF T = {}
       THEN UNCHANGED vars
       ELSE /\ misrouted' = (misrouted \/ \E s \in T: owner[n] # s)
            /\ early' = (early \/ ~ackSeen[n])
            /\ unasked' = (unasked \/ k \notin allowed[n])
            /\ late' = (late \/ over[n])
            /\ UNCHANGED <<phase, cur, asked, acked, tries, next, stdio, up, owner, ackSeen, allowed, over, told, final, sentDown, relistened>>

\* A result, an error, or the server's cancel for n ends it for good.
Final(n) ==
    IF Current(n)
    THEN /\ Ends(OwnerOf(n), n)
         /\ final' = [final EXCEPT ![n] = TRUE]
         /\ UNCHANGED <<cur, asked, acked, tries, next, stdio, up, owner, ackSeen, allowed, ghosts>>
    ELSE UNCHANGED vars

\* An abrupt end of s's listen: wait to listen again, or give up after
\* MaxTries in a row.
Abrupt(s) ==
    IF tries[s] < MaxTries
    THEN /\ phase' = [phase EXCEPT ![s] = "waiting"]
         /\ tries' = [tries EXCEPT ![s] = @ + 1]
         /\ over' = [over EXCEPT ![cur[s]] = TRUE]
         /\ UNCHANGED told
    ELSE /\ Ends(s, cur[s])
         /\ UNCHANGED tries

\* HTTP: listen n's stream closes without a result.
Lost(n) ==
    /\ ~stdio
    /\ IF Current(n)
       THEN /\ Abrupt(OwnerOf(n))
            /\ UNCHANGED <<cur, asked, acked, next, stdio, up, owner, ackSeen, allowed, final, ghosts>>
       ELSE UNCHANGED vars

\* stdio: the process exits, ending every listen at once (SUBS-05).
Live == {s \in Subs: phase[s] \in {"pending", "active"}}

Crash ==
    /\ stdio /\ up
    /\ up' = FALSE
    /\ phase' = [s \in Subs |-> IF s \in Live THEN (IF tries[s] < MaxTries THEN "waiting" ELSE "ended") ELSE phase[s]]
    /\ tries' = [s \in Subs |-> IF s \in Live /\ tries[s] < MaxTries THEN tries[s] + 1 ELSE tries[s]]
    /\ over' = [n \in Ids |-> over[n] \/ \E s \in Live: cur[s] = n]
    /\ told' = [n \in Ids |-> IF \E s \in Live: cur[s] = n /\ tries[s] = MaxTries THEN told[n] + 1 ELSE told[n]]
    /\ UNCHANGED <<cur, asked, acked, next, stdio, owner, ackSeen, allowed, final, ghosts>>

Restart ==
    /\ stdio /\ ~up
    /\ up' = TRUE
    /\ UNCHANGED <<phase, cur, asked, acked, tries, next, stdio, owner, ackSeen, allowed, over, told, final, ghosts>>

Next ==
    \/ \E s \in Subs: \/ Open(s)
                      \/ Resend(s)
                      \/ Cancel(s)
    \/ \E n \in 1..(next - 1):
           \/ \E f \in SUBSET Kinds: Ack(n, f)
           \/ \E k \in Kinds: Note(n, k)
           \/ Final(n)
           \/ Lost(n)
    \/ Crash
    \/ Restart

\* The client listens again as soon as it may: on stdio the process can exit
\* again before then, so a resend is only enabled now and then (strong fairness).
Spec == Init /\ [][Next]_vars /\ WF_vars(Restart) /\ \A s \in Subs: SF_vars(Resend(s))

TypeOK ==
    /\ phase \in [Subs -> Phases]
    /\ cur \in [Subs -> 0..MaxListens]
    /\ asked \in [Subs -> SUBSET Kinds]
    /\ acked \in [Subs -> SUBSET Kinds]
    /\ tries \in [Subs -> 0..MaxTries]
    /\ next \in 1..(MaxListens + 1)
    /\ stdio \in BOOLEAN /\ up \in BOOLEAN
    /\ owner \in [Ids -> Subs \cup {None}]
    /\ told \in [Ids -> 0..2]

\* SUBS-02: a notification reaches only the subscription whose listen it names.
SubDemux == ~misrouted

\* SUBS-01: nothing is delivered before the listen's acknowledgment.
AckFirst == ~early

\* SUBS-01: only what was asked for and acknowledged is delivered.
FilterRespected == ~unasked

\* Nothing is delivered after the listen ended.
NothingAfterEnd == ~late

\* Each listen's end reaches the host at most once, and a subscription
\* that ended was told.
OneEnd == \A n \in Ids: told[n] <= 1
EndTold == \A s \in Subs: phase[s] = "ended" => told[cur[s]] = 1

\* SUBS-05: no listen goes out while the stdio process is down.
NoSendWhileDown == ~sentDown

\* A listen that ended with a result, an error, or a server's cancel is
\* never sent again by the client on its own.
NoRelistenAfterFinal == ~relistened

\* An active subscription has something acknowledged.
ActiveListensForSomething == \A s \in Subs: phase[s] = "active" => acked[s] # {}

\* SUBS-05: a subscription waiting to listen again does, unless ids run
\* out in this bounded model.
ListensAgain == \A s \in Subs: phase[s] = "waiting" ~> (phase[s] # "waiting" \/ next > MaxListens)
====

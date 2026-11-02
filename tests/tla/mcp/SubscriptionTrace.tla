---- MODULE SubscriptionTrace ----
\* Trace wrapper for Subscription.tla (U10). tests/bun/bridge.ts generates
\* TraceObs from the records of one remote (instance "remote").
\*
\* Mapping from the Zig core (src/mcp/core/subscription.zig):
\*   - Records open, resend, cancel, ack, note, final, lost, crash, and restart
\*     are the model's actions of those names. A backoff timer writes none.
\*   - Subscriptions are numbered from 1. Each record carries the whole table
\*     packed 4 bits a subscription: phases (off, pending, active, waiting,
\*     ended as 0 to 4), tries, and acknowledged filters, whose bits are
\*     tools, prompts, and resources.
\*   - Listen ids are request ids, which only grow: the k-th distinct id a
\*     listen went out with is the model's id k. A record on an id no listen
\*     went out with must be ignored.
\*   - A record marked ignored is accepted only where nothing changes.
\*   - Ask(s) is what s's first open asked for; the transport is stdio when
\*     the trace has a crash or a restart; MaxTries comes from the scenario.
EXTENDS Subscription, TraceObs, Integers, Sequences, FiniteSets

VARIABLE i

Recs == {ObsTrace[n] : n \in 1..Len(ObsTrace)}
ObsSubSet == ({r.data.sub : r \in Recs} \ {0}) \cup {1}
ObsMaxSub == CHOOSE m \in ObsSubSet : \A x \in ObsSubSet : x <= m
ObsSubs == 1..ObsMaxSub
ObsKinds == {"tools", "prompts", "resources"}
KindBit(k) == CASE k = "tools" -> 1 [] k = "prompts" -> 2 [] OTHER -> 4
Bits(m) == {k \in ObsKinds : (m \div KindBit(k)) % 2 = 1}
Opens(s) == {r \in Recs : r.event = "open" /\ r.data.sub = s /\ ~r.data.ignored}
ObsAsk(s) == IF Opens(s) = {} THEN {"tools"} ELSE Bits((CHOOSE r \in Opens(s) : TRUE).data.filter)
Sent == {r.data.id : r \in {x \in Recs : x.event \in {"open", "resend"} /\ ~x.data.ignored}}
ObsMaxListens == IF Sent = {} THEN 1 ELSE Cardinality(Sent)
Idx(n) == Cardinality({m \in Sent : m <= n})
ObsStdio == \E r \in Recs : r.event \in {"crash", "restart"}

Field(packed, s) == (packed \div (2^(4 * (s - 1)))) % 16
PhaseName(n) == CASE n = 0 -> "off" [] n = 1 -> "pending" [] n = 2 -> "active" [] n = 3 -> "waiting" [] OTHER -> "ended"

OnListen(r) == r.data.id \in Sent

Step(r) ==
    LET s == r.data.sub
        n == Idx(r.data.id)
    IN CASE r.event = "open" -> Open(s)
         [] r.event = "resend" -> Resend(s)
         [] r.event = "cancel" -> Cancel(s)
         [] r.event = "ack" -> OnListen(r) /\ Ack(n, Bits(r.data.filter))
         [] r.event = "note" -> OnListen(r) /\ \E k \in Bits(r.data.filter) : Note(n, k)
         [] r.event = "final" -> OnListen(r) /\ Final(n)
         [] r.event = "lost" -> OnListen(r) /\ Lost(n)
         [] r.event = "crash" -> Crash
         [] r.event = "restart" -> Restart
         [] OTHER -> FALSE

Matches(r) ==
    /\ \A s \in Subs :
        /\ phase'[s] = PhaseName(Field(r.data.phases, s))
        /\ tries'[s] = Field(r.data.tries, s)
        /\ acked'[s] = Bits(Field(r.data.acked, s))
    /\ up' = r.data.up

TraceInit ==
    /\ Init
    /\ stdio = ObsStdio
    /\ i = 0

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ LET r == ObsTrace[i + 1]
       IN /\ IF r.data.ignored THEN UNCHANGED vars ELSE Step(r)
          /\ Matches(r)
    /\ i' = i + 1

\* Sentinel: violated exactly when every observed step has been matched.
NotDone == i < Len(ObsTrace)
====

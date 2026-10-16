---- MODULE EngineTrace ----
\* Trace wrapper for Engine.tla (U12). tests/bun/bridge.ts generates TraceObs
\* from the records of one server (one engine instance, named for the server).
\*
\* Mapping from the Zig core (src/mcp/core/engine.zig):
\*   - Records ask, need, cancel, drop, connect, up, down, backoff_over,
\*     stable, and answer are the model's actions for the one server. Calls are numbered
\*     from 1 in the order asked, and n is the model's c.
\*   - Each record carries the server's state after the step: phase (0 idle,
\*     1 connecting, 2 ready, 3 backoff, 4 failed), attempts, need, how many
\*     calls wait and how many are in flight, n's state (0 none,
\*     1 waiting, 2 sent, 3 done), and whether it starts again by itself.
\*   - A record marked ignored is accepted only where nothing changes.
\*   - MaxAttempts comes from the scenario (ObsMaxAttempts), the engine's
\*     limit, which every record also carries as `max`; a planted control
\*     gives a wrong one. MaxHost is the number of drop records.
EXTENDS Engine, TraceObs, Integers, Sequences, FiniteSets

VARIABLE i

Recs == {ObsTrace[k] : k \in 1..Len(ObsTrace)}
ObsNs == {r.data.n : r \in Recs} \ {0}
ObsMaxN == IF ObsNs = {} THEN 1 ELSE CHOOSE m \in ObsNs : \A x \in ObsNs : x <= m
ObsCalls == 1..ObsMaxN
ObsMaxHost == Cardinality({k \in 1..Len(ObsTrace) : ObsTrace[k].event = "drop"})
OneServer == {1}
OnlyOwner(c) == 1

PhaseName(k) == CASE k = 0 -> "idle" [] k = 1 -> "connecting" [] k = 2 -> "ready" [] k = 3 -> "backoff" [] OTHER -> "failed"
StateName(k) == CASE k = 0 -> "none" [] k = 1 -> "waiting" [] k = 2 -> "sent" [] OTHER -> "done"

Step(r) ==
    LET n == r.data.n
    IN CASE r.event = "ask" -> Ask(n, r.data.allowed)
         [] r.event = "need" -> Need(1)
         [] r.event = "cancel" -> Cancel(n)
         [] r.event = "drop" -> Drop(1, r.data.keep)
         [] r.event = "connect" -> Connect(1)
         [] r.event = "up" -> Up(1)
         [] r.event = "down" -> Down(1)
         [] r.event = "backoff_over" -> BackoffOver(1)
         [] r.event = "stable" -> Stable(1)
         [] r.event = "answer" -> Answer(n)
         [] OTHER -> FALSE

Matches(r) ==
    /\ phase'[1] = PhaseName(r.data.phase)
    /\ attempts'[1] = r.data.attempts
    /\ need'[1] = r.data.need
    /\ Cardinality({c \in Calls : call'[c] = "waiting"}) = r.data.waiting
    /\ Cardinality({c \in Calls : call'[c] = "sent"}) = r.data.sent
    /\ r.data.n # 0 => call'[r.data.n] = StateName(r.data.state)
    /\ retry'[1] = r.data.retry

TraceInit ==
    /\ Init
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

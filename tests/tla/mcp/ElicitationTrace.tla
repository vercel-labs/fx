---- MODULE ElicitationTrace ----
\* Trace wrapper for Elicitation.tla (U11). tests/bun/bridge.ts generates
\* TraceObs from the records of one remote (instance "remote").
\*
\* Mapping from the Zig core (src/mcp/core/elicitation.zig):
\*   - Records ask, answer, cancel, end, and complete are the model's Ask,
\*     Answer, ServerCancel, SessionEnd, and Complete. Elicitations are
\*     numbered from 1 in the order asked, and n is the model's r.
\*   - Each record carries n's phase after the step (0 idle, 1 shown,
\*     2 waiting, 3 done), what the step answered (0 nothing, 1 an error,
\*     2 content, 3 accept, 4 decline, 5 cancel), and the declared modes as
\*     bits (form 1, url 2), which fix `declared`.
\*   - A record marked ignored is accepted only where nothing changes.
\*   - MaxPending comes from the scenario (ObsMaxPending): the core's 16.
EXTENDS Elicitation, TraceObs, Integers, Sequences, FiniteSets

VARIABLE i

Recs == {ObsTrace[k] : k \in 1..Len(ObsTrace)}
ObsNs == {r.data.n : r \in Recs} \ {0}
ObsMaxN == IF ObsNs = {} THEN 1 ELSE CHOOSE m \in ObsNs : \A x \in ObsNs : x <= m
ObsReqs == 1..ObsMaxN
ObsBits == ObsTrace[1].data.declared
ObsDeclared == {m \in Modes : (m = "form" /\ ObsBits % 2 = 1) \/ (m = "url" /\ (ObsBits \div 2) % 2 = 1)}

ActName(k) == CASE k = 0 -> "accept" [] k = 1 -> "decline" [] OTHER -> "cancel"
PhaseName(k) == CASE k = 0 -> "idle" [] k = 1 -> "shown" [] k = 2 -> "waiting" [] OTHER -> "done"
SentName(k) == CASE k = 1 -> "error" [] k = 2 -> "content" [] k = 3 -> "accept" [] k = 4 -> "decline" [] OTHER -> "cancel"

Step(r) ==
    LET n == r.data.n
    IN CASE r.event = "ask" -> Ask(n, IF r.data.required THEN "required" ELSE "request", IF r.data.url THEN "url" ELSE "form", r.data.eid, r.data.readable)
         [] r.event = "answer" -> Answer(n, ActName(r.data.act), r.data.valid)
         [] r.event = "cancel" -> ServerCancel(n)
         [] r.event = "end" -> SessionEnd
         [] r.event = "complete" -> Complete(n)
         [] OTHER -> FALSE

Matches(r) ==
    LET n == r.data.n
    IN /\ n # 0 => phase'[n] = PhaseName(r.data.phase)
       /\ (n # 0 /\ r.data.sent # 0) => sent'[n] = SentName(r.data.sent)

TraceInit ==
    /\ Init
    /\ declared = ObsDeclared
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

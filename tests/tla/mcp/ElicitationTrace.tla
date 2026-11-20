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
\*   - The records do not show how a form's names and choices were written, or
\*     whether the answer fits the form. The scenario says so, as numbers:
\*       ObsEscaped    1: the server wrote a name or choice with an escape the
\*                     host's answer does not repeat; 0: it may have.
\*       ObsFits       1: the answer's strings match the form's by decoded
\*                     value; 2: it does not; 0: either.
\*       ObsRawCompare 0: the engine matches decoded strings (the code today);
\*                     1: byte for byte (the code before). A planted control:
\*                     the trace of the fixed engine is REJECTED by it.
\*     The engine's own verdict is the record's `valid`, and shows in the phase
\*     the step leaves: a refused answer leaves the request shown.
EXTENDS Elicitation, TraceObs, Integers, Sequences, FiniteSets

VARIABLE i

Recs == {ObsTrace[k] : k \in 1..Len(ObsTrace)}
ObsNs == {r.data.n : r \in Recs} \ {0}
ObsMaxN == IF ObsNs = {} THEN 1 ELSE CHOOSE m \in ObsNs : \A x \in ObsNs : x <= m
ObsReqs == 1..ObsMaxN
ObsBits == ObsTrace[1].data.declared
ObsDeclared == {m \in Modes : (m = "form" /\ ObsBits % 2 = 1) \/ (m = "url" /\ (ObsBits \div 2) % 2 = 1)}

ObsCompare == IF ObsRawCompare = 1 THEN "raw" ELSE "decoded"
ObsSpells == IF ObsEscaped = 1 THEN {"escaped"} ELSE Spells
ObsFitsSet == CASE ObsFits = 1 -> {TRUE} [] ObsFits = 2 -> {FALSE} [] OTHER -> BOOLEAN

ActName(k) == CASE k = 0 -> "accept" [] k = 1 -> "decline" [] OTHER -> "cancel"
PhaseName(k) == CASE k = 0 -> "idle" [] k = 1 -> "shown" [] k = 2 -> "waiting" [] OTHER -> "done"
SentName(k) == CASE k = 1 -> "error" [] k = 2 -> "content" [] k = 3 -> "accept" [] k = 4 -> "decline" [] OTHER -> "cancel"

Step(r) ==
    LET n == r.data.n
    IN CASE r.event = "ask" -> Ask(n, IF r.data.required THEN "required" ELSE "request", IF r.data.url THEN "url" ELSE "form", r.data.eid, r.data.readable)
         [] r.event = "answer" -> \E fits \in ObsFitsSet: Answer(n, ActName(r.data.act), fits)
         [] r.event = "cancel" -> ServerCancel(n)
         [] r.event = "end" -> SessionEnd
         [] r.event = "complete" -> Complete(n)
         [] OTHER -> FALSE

Matches(r) ==
    LET n == r.data.n
    IN /\ n # 0 => phase'[n] = PhaseName(r.data.phase)
       /\ (n # 0 /\ r.data.sent # 0) => sent'[n] = SentName(r.data.sent)
       /\ (n # 0 /\ r.event = "ask") => spell'[n] \in ObsSpells

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

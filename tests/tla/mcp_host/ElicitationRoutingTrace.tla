---- MODULE ElicitationRoutingTrace ----
\* Trace wrapper for ElicitationRouting.tla. trace.ts generates TraceObs from
\* a real `fx ask` in a terminal against the harness's 2025 stdio fixture
\* (tests/tla/drivers/mcp_host/). Questions are numbered in the order the fixture
\* sent them; each form asks for one string, and the harness answers with
\* "for-<n>" naming the question it saw, so the fixture's log says whose
\* answer reached which question.
\*   ask {q}                 the fixture sent elicitation/create q
\*   shown {q}               fx's terminal shows question q
\*   answer {q}              the harness typed the answer to what it saw
\*   delivered {target, from}  the fixture got, for q = target, the answer "for-<from>"
\*   withdraw {q}            the fixture sent notifications/cancelled for q
\*   call_end {}             the tool call's result went out
\* fx's own cancels are part of `ask`; `delivered` with from = target and
\* no answer typed for it is one.
EXTENDS ElicitationRouting, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF AnsweredOnce THEN {} ELSE {"AnsweredOnce"}) \cup
    (IF DismissedNeverShown THEN {} ELSE {"DismissedNeverShown"}) \cup
    (IF AnswerReachesSeenQuestion THEN {} ELSE {"AnswerReachesSeenQuestion"})

Step(rec) ==
    CASE rec.event = "ask" -> Ask /\ nextQ = rec.data.q
      [] rec.event = "shown" -> Take /\ offered = rec.data.q
      [] rec.event = "answer" -> UserAnswers /\ asking = rec.data.q
      [] rec.event = "delivered" -> Deliver /\ answeredBy'[rec.data.target] = rec.data.from /\ answeredBy[rec.data.target] = None
      [] rec.event = "fx_dismissed" -> answeredBy[rec.data.q] = rec.data.q /\ dismissed[rec.data.q] /\ UNCHANGED vars
      [] rec.event = "withdraw" -> Withdraw(rec.data.q)
      [] rec.event = "call_end" -> CallEnds
      [] OTHER -> FALSE

\* An answer the owner drops (its slot is free, or its call is over) shows
\* nothing on the wire.
Hidden == Deliver /\ answeredBy' = answeredBy

TraceInit == Init /\ i = 0 /\ bad = Viol

TraceNext ==
    \/ /\ i < Len(ObsTrace)
       /\ Step(ObsTrace[i + 1])
       /\ i' = i + 1
       /\ bad' = bad \cup Viol'
    \/ /\ Hidden
       /\ UNCHANGED i
       /\ bad' = bad \cup Viol'

NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====

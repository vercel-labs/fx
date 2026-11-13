---- MODULE WireDepthTrace ----
\* Trace wrapper for WireDepth.tla. trace.ts generates TraceObs from real `fx ask`
\* runs against tests/e2e/fixtures/mcp-legacy-stdio.mjs, a server that nests its
\* result, or one tool of its tool list, to a chosen depth
\* (tests/tla/drivers/mcp_host/wire-depth.test.ts). Each run is one record:
\*   observed {entry, depth, verdict}
\* The harness knows the entry point ("result" or "tool") and the depth of the value
\* fx checks there from what the fixture sent. The verdict it reads from what the
\* model got and from the process:
\*   accepted  the result reached the model, or the tool was listed
\*   refused   the call ended with the depth limit's words, or the tool was dropped
\*   crashed   fx aborted
\* A trace is the model's when each record's verdict is the one the model gives.
EXTENDS WireDepth, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF NoWriterOverflow THEN {} ELSE {"NoWriterOverflow"}) \cup
    (IF AcceptedUpToLimit THEN {} ELSE {"AcceptedUpToLimit"}) \cup
    (IF PastLimitRefused THEN {} ELSE {"PastLimitRefused"}) \cup
    (IF DroppedOnlyPastEngine THEN {} ELSE {"DroppedOnlyPastEngine"})

Step(rec) ==
    CASE rec.event = "observed" ->
            /\ Message(rec.data.entry, rec.data.depth)
            /\ verdict' = rec.data.verdict
      [] OTHER -> FALSE

TraceInit == Init /\ i = 0 /\ bad = Viol

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ Step(ObsTrace[i + 1])
    /\ i' = i + 1
    /\ bad' = bad \cup Viol'

NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====

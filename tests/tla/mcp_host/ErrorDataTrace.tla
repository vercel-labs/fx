---- MODULE ErrorDataTrace ----
\* Trace wrapper for ErrorData.tla. trace.ts generates TraceObs from real
\* `fx ask` runs in a terminal against tests/e2e/fixtures/mcp-legacy-stdio.mjs,
\* a server that answers a tools/call with an error that holds data
\* (tests/tla/drivers/mcp_host/error-data.test.ts). Each run is one record:
\*   observed {code, kind, size, form, prefix, extra, marked, split, logged}
\* The harness knows the first three from what the fixture sent (`size` is the
\* compact text's bytes). The rest it reads from the fake gateway's next
\* request, the model's text for the call, and from the trace log and standard
\* error:
\*   form    "none" without `; data=`; "cut" when the data is a string literal
\*           with the marker; otherwise "whole"
\*   prefix  the bytes of the data before the marker, as the data's own text;
\*           for a whole text, all of it
\*   extra   a cut's escapes: the literal's bytes before the marker, less its
\*           quotes and less `prefix`
\*   marked  the marker is in the text
\*   split   the cut text holds a character that is not whole
\*   logged  the data appears in the trace log or standard error
EXTENDS ErrorData, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF ErrorDataReachesModel THEN {} ELSE {"ErrorDataReachesModel"}) \cup
    (IF Unchanged THEN {} ELSE {"Unchanged"}) \cup
    (IF Bounded THEN {} ELSE {"Bounded"}) \cup
    (IF KeepsMost THEN {} ELSE {"KeepsMost"}) \cup
    (IF HeldBounded THEN {} ELSE {"HeldBounded"}) \cup
    (IF CutOnBoundary THEN {} ELSE {"CutOnBoundary"}) \cup
    (IF NoDataInLogs THEN {} ELSE {"NoDataInLogs"})

Step(rec) ==
    CASE rec.event = "observed" ->
            /\ Answer(rec.data.code, rec.data.kind, rec.data.size, rec.data.prefix, rec.data.extra)
            /\ form' = rec.data.form
            /\ prefix' = rec.data.prefix
            /\ extra' = rec.data.extra
            /\ marked' = rec.data.marked
            /\ split' = rec.data.split
            /\ logged' = rec.data.logged
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

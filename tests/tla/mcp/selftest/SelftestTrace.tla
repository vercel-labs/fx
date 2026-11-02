---- MODULE SelftestTrace ----
\* Trace wrapper for the bridge self-test. Not a product model.
\* tests/bun/bridge.ts generates TraceObs, whose ObsTrace holds the observed
\* steps for one machine instance. Each TLC step must match the next observed
\* step: its event, its "from" state, and its projected "to" state.
EXTENDS Selftest, TraceObs, Naturals, Sequences

VARIABLE i

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ LET rec == ObsTrace[i + 1] IN
         /\ status = rec.from
         /\ \/ rec.event = "response_received" /\ ResponseReceived
            \/ rec.event = "cancel_requested" /\ CancelRequested
         /\ status' = rec.to
         /\ "outcomes" \in DOMAIN rec.data
         /\ outcomes' = rec.data.outcomes
    /\ i' = i + 1

\* Sentinel: violated exactly when every observed step has been matched.
NotDone == i < Len(ObsTrace)
====

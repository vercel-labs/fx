---- MODULE MrtrTrace ----
\* Trace wrapper for Mrtr.tla (U08). tests/bun/bridge.ts generates TraceObs
\* from the records of one call's chain (its first round's instance, such as
\* "x3").
\*
\* Mapping from the Zig core (src/mcp/core/mrtr.zig):
\*   - Each record is one action, named as in the model in snake_case;
\*     `ended` is Ended with the record's outcome, and `input_required` is
\*     InputRequired with the record's requested and supported, and a
\*     requestState exactly when last_state isn't 0.
\*   - A record marked `ignored` is accepted only where the model's action is
\*     disabled, and nothing may change.
\*   - The ghosts follow the model.
\*   - MaxRequests comes from the scenario (ObsMaxRequests); MaxKeys only
\*     bounds the model's choices, not the trace's.
EXTENDS Mrtr, TraceObs, Integers, Sequences

VARIABLE i

Step(r) ==
    CASE r.event = "start" -> Start
      [] r.event = "ended" -> Ended(r.data.outcome)
      [] r.event = "malformed" -> Malformed
      [] r.event = "input_required" -> InputRequired(r.data.requested, r.data.last_state # 0, r.data.supported)
      [] r.event = "provide" -> Provide
      [] r.event = "backoff_done" -> BackoffDone
      [] r.event = "cancel" -> Cancel
      [] OTHER -> FALSE

Matches(r) ==
    /\ phase' = r.to
    /\ round' = r.data.round
    /\ lastState' = r.data.last_state
    /\ requested' = r.data.requested
    /\ supported' = r.data.supported
    /\ sentState' = r.data.sent_state
    /\ responded' = r.data.responded
    /\ outcome' = r.data.outcome

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ LET r == ObsTrace[i + 1]
       IN /\ phase = r.from
          /\ IF r.data.ignored THEN ~ENABLED Step(r) /\ UNCHANGED vars ELSE Step(r)
          /\ Matches(r)
    /\ i' = i + 1

\* Sentinel: violated exactly when every observed step has been matched.
NotDone == i < Len(ObsTrace)
====

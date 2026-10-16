---- MODULE HttpModernTrace ----
\* Trace wrapper for HttpModern.tla (U06). tests/bun/bridge.ts generates TraceObs
\* from the records of one logical request (one instance, such as "x3").
\*
\* Mapping from the Zig core (src/mcp/core/http_modern.zig):
\*   - Each record is one action, named as in the model in snake_case;
\*     `answer` and `ok` are the parameters of Answer and Relisted.
\*   - Ids aren't in the trace: each post is a new U02 request, and the U02
\*     model proves those ids are never reused. The id variables follow the
\*     model.
\*   - A record marked `ignored` is accepted only where the model's action is
\*     disabled, and nothing may change.
\*   - MaxAttempts comes from the scenario (ObsMaxAttempts).
\*   - The core's `close` effect is the client closing the attempt's stream:
\*     it comes exactly when the model's `closed` turns true.
EXTENDS HttpModern, TraceObs, Integers, Sequences

VARIABLE i

Step(r) ==
    CASE r.event = "send" -> Send
      [] r.event = "answer" -> Answer(r.data.answer)
      [] r.event = "http_failure" -> HttpFailure
      [] r.event = "stream_broken" -> StreamBroken
      [] r.event = "relisted" -> Relisted(r.data.ok)
      [] r.event = "cancel" -> Cancel
      [] OTHER -> FALSE

Emits(r, e) == \E k \in DOMAIN r.effects : r.effects[k] = e

Matches(r) ==
    /\ phase' = r.to
    /\ kind' = r.data.kind
    /\ attempts' = r.data.attempts
    /\ headerRetries' = r.data.header_retries
    /\ maybeRan' = r.data.maybe_ran
    /\ Emits(r, "close") = (closed' /\ ~closed)

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

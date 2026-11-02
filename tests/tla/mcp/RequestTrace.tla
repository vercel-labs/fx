---- MODULE RequestTrace ----
\* Trace wrapper for Request.tla (U02). tests/bun/bridge.ts generates TraceObs.
\*
\* Mapping from the Zig core (src/mcp/core/request.zig) to the model:
\*   - Ids are the request ids in the trace; InitIds the ones sent as
\*     initialize, and ListenIds the ones sent as a listen (U10).
\*   - progress[id] is the number of progress notifications the core accepted.
\*   - A step on an id that is not in flight is one of the model's ignore
\*     branches, which leave every variable unchanged. So are a stale idle
\*     timer and progress that doesn't increase.
\*   - Fields the core no longer knows (outcome and counters of a finished
\*     request) are absent from the record and not compared.
EXTENDS Request, TraceObs, Naturals, Sequences

VARIABLE i

Recs == {ObsTrace[k] : k \in 1..Len(ObsTrace)}
Has(r, f) == f \in DOMAIN r.data

ObsIds == {r.data.id : r \in Recs}
ObsInitIds == {r.data.id : r \in {x \in Recs : Has(x, "kind") /\ x.data.kind = "initialize"}}
ObsListenIds == {r.data.id : r \in {x \in Recs : Has(x, "kind") /\ x.data.kind = "listen"}}
ObsProgress == {r.data.progress : r \in {x \in Recs : Has(x, "progress")}}
ObsMaxProgress == IF ObsProgress = {} THEN 0 ELSE CHOOSE m \in ObsProgress : \A q \in ObsProgress : q <= m

Step(r, id) ==
    \/ r.event = "send" /\ Send(id)
    \/ r.event = "response_received" /\ ResponseReceived(id, r.data.response)
    \/ r.event = "cancel_requested" /\ (CancelRequested(id) \/ (req[id] # "inflight" /\ UNCHANGED vars))
    \/ r.event = "timer_fired" /\ (TimedOut(id) \/ UNCHANGED vars)
    \/ r.event = "transport_lost" /\ (TransportLost(id) \/ (req[id] # "inflight" /\ UNCHANGED vars))
    \* Ignored progress is the model's ELSE branch. The trace carries no raw
    \* values, so the "only when it increases" rule is checked by the Zig tests.
    \/ r.event = "progress_received" /\ ((\E p \in 1..MaxProgress : ProgressReceived(id, p)) \/ UNCHANGED vars)
    \/ r.event = "server_cancel_received" /\ ServerCancelReceived(id)

Matches(r, id) ==
    /\ req'[id] = r.to
    /\ Has(r, "outcome") => outcome'[id] = r.data.outcome
    /\ Has(r, "delivered") => delivered'[id] = r.data.delivered
    /\ Has(r, "cancel_sent") => cancelSent'[id] = r.data.cancel_sent
    /\ Has(r, "progress") => progress'[id] = r.data.progress

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ LET r == ObsTrace[i + 1]
           id == r.data.id
       IN /\ id \in Ids
          /\ req[id] = r.from
          /\ Step(r, id)
          /\ Matches(r, id)
    /\ i' = i + 1

\* Sentinel: violated exactly when every observed step has been matched.
NotDone == i < Len(ObsTrace)
====

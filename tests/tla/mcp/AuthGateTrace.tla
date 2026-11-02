---- MODULE AuthGateTrace ----
\* Trace wrapper for AuthGate.tla (U09). tests/bun/bridge.ts generates TraceObs
\* from the records of one remote (instance "remote").
\*
\* Mapping from the Zig core (src/mcp/core/auth.zig, Gate):
\*   - Each record is one action, named as in the model in snake_case, with
\*     its parameters in the data (`expiring`, `rotate`, `refreshable`).
\*   - `key` is the request's U02 id or the auxiliary key; Keys are those the
\*     trace names. The record carries the subject's entry after the step;
\*     other entries follow from the step.
\*   - The server's choices (Expire) aren't traced: they may happen between
\*     records.
\*   - A record marked `ignored` is accepted only where the model's action is
\*     disabled, and nothing may change.
EXTENDS AuthGate, TraceObs, Integers, Sequences, FiniteSets

VARIABLE i

Recs == {ObsTrace[n] : n \in 1..Len(ObsTrace)}
ObsKeys == {r.data.key : r \in {x \in Recs : x.data.key # 0}}
ObsGens == {r.data.gen : r \in Recs} \cup {1}
ObsMaxGen == CHOOSE m \in ObsGens : \A g \in ObsGens : g <= m

Step(r) ==
    CASE r.event = "send" -> Send(r.data.key, r.data.expiring)
      [] r.event = "accept" -> Accept(r.data.key)
      [] r.event = "reject" -> Reject(r.data.key)
      [] r.event = "forget" -> Forget(r.data.key)
      [] r.event = "refresh_ok" -> RefreshOk(r.data.rotate)
      [] r.event = "refresh_refused" -> RefreshRefused
      [] r.event = "refresh_failed" -> RefreshFailed
      [] r.event = "signed_in" -> SignedIn(r.data.refreshable)
      [] r.event = "sign_out" -> SignOut
      [] OTHER -> FALSE

Matches(r) ==
    /\ gen' = r.data.gen
    /\ held' = r.data.held
    /\ refreshable' = r.data.refreshable
    /\ rt' = r.data.rt
    /\ inflight' = IF r.data.refreshing THEN 1 ELSE 0
    /\ r.data.key # 0 =>
          /\ req'[r.data.key].phase = r.to
          /\ req'[r.data.key].g = r.data.g
          /\ req'[r.data.key].again = r.data.again

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    \/ /\ i < Len(ObsTrace)
       /\ LET r == ObsTrace[i + 1]
          IN /\ (r.data.key # 0 => req[r.data.key].phase = r.from)
             /\ IF r.data.ignored THEN ~ENABLED Step(r) /\ UNCHANGED vars ELSE Step(r)
             /\ Matches(r)
       /\ i' = i + 1
    \/ /\ \E g \in valid : Expire(g)
       /\ UNCHANGED i

\* Sentinel: violated exactly when every observed step has been matched.
NotDone == i < Len(ObsTrace)
====

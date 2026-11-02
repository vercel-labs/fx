---- MODULE CatalogTrace ----
\* Trace wrapper for Catalog.tla (U05). tests/bun/bridge.ts generates TraceObs.
\*
\* Mapping from the Zig core (src/mcp/core/catalog.zig):
\*   - Each record is one action, named as in the model in snake_case. The
\*     core has no single state name, so records carry "-" as from and to,
\*     and every step matches the whole projection instead.
\*   - `expired` is Expired; a timer that no longer applies is no step, and
\*     the core writes no record for it.
\*   - `page_received` carries `lapse`, which the core works out from the
\*     pages' arrival times; the model takes it as given.
\*   - MaxPages comes from the scenario (ObsMaxPages). MaxGen and
\*     MaxProcesses are the highest values in the trace.
EXTENDS Catalog, TraceObs, Integers, Sequences

VARIABLE i

Recs == {ObsTrace[k] : k \in 1..Len(ObsTrace)}
Highest(S) == CHOOSE m \in S : \A x \in S : x <= m
ObsMaxGen == Highest({r.data.gen : r \in Recs} \cup {0})
ObsMaxProcesses == Highest({r.data.process : r \in Recs} \cup {1})

Step(r) ==
    CASE r.event = "process_started" -> ProcessStarted(r.data.arg_era)
      [] r.event = "need" -> Need
      [] r.event = "page_received" -> PageReceived(r.data.more, r.data.ttl_zero, r.data.lapse)
      [] r.event = "invalid_cursor" -> InvalidCursor
      [] r.event = "page_failed" -> PageFailed
      [] r.event = "invalidated" -> Invalidate
      [] r.event = "expired" -> Expired
      [] OTHER -> FALSE

Matches(r) ==
    /\ era' = r.data.era
    /\ process' = r.data.process
    /\ gen' = r.data.gen
    /\ cache' = r.data.cache
    /\ cacheGen' = r.data.cache_gen
    /\ cachedZero' = r.data.cached_zero
    /\ cachedLapsed' = r.data.cached_lapsed
    /\ listing' = IF r.data.listing THEN "fetching" ELSE "idle"
    /\ startGen' = r.data.start_gen
    /\ page' = r.data.page
    /\ restarts' = r.data.restarts
    /\ zeroTtl' = r.data.zero_ttl
    /\ lapsed' = r.data.lapsed
    /\ pending' = r.data.pending
    /\ waiting' = r.data.waiting
    /\ answer' = r.data.answer

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ LET r == ObsTrace[i + 1]
       IN /\ Step(r)
          /\ Matches(r)
    /\ i' = i + 1

\* Sentinel: violated exactly when every observed step has been matched.
NotDone == i < Len(ObsTrace)
====

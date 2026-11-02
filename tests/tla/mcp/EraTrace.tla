---- MODULE EraTrace ----
\* Trace wrapper for Era.tla (U04). tests/bun/bridge.ts generates TraceObs.
\*
\* Mapping from the Zig core (src/mcp/core/era.zig):
\*   - Each record is one client action, named as in the model in snake_case.
\*     `probe_timer_fired` is ProbeTimedOut; a timer from an earlier probe is
\*     no step, and the core writes no record for it.
\*   - Versions are integer codes: k for the client's k-th preferred version,
\*     0 for the legacy one, -1 for none, -2 for a version only the server
\*     knows. They map to the names p1..p8, "L", and "O". `last_meta` uses -3
\*     for unset. A listed set is a bitmask over the preferred versions
\*     (`listed`) and a legacy flag (`listed_legacy`).
\*   - A record marked `ignored` is an event the model couldn't take in that
\*     state. It is accepted only where the model's action is disabled, and
\*     nothing may change.
\*   - The number of preferred versions comes from the scenario
\*     (ObsPreferredCount). MaxProcesses is the highest process in the trace.
EXTENDS Era, TraceObs, Integers, Sequences

VARIABLE i

Names == <<"p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8">>
ObsPreferred == SubSeq(Names, 1, ObsPreferredCount)
ObsLegacy == "L"
ObsOther == {"O"}

Recs == {ObsTrace[k] : k \in 1..Len(ObsTrace)}
ObsProcesses == {r.data.process : r \in Recs} \cup {1}
ObsMaxProcesses == CHOOSE m \in ObsProcesses : \A p \in ObsProcesses : p <= m

VersionOf(code) ==
    CASE code = -1 -> "none"
      [] code = 0 -> Legacy
      [] code = -2 -> "O"
      [] OTHER -> Preferred[code]

MetaOf(code) == IF code = -3 THEN "unset" ELSE VersionOf(code)

Listed(r) ==
    {Preferred[k] : k \in {j \in 1..Len(Preferred) : (r.data.listed \div 2^(j - 1)) % 2 = 1}}
        \cup (IF r.data.listed_legacy THEN {Legacy} ELSE {})

Step(r) ==
    CASE r.event = "process_started" -> ProcessStarted
      [] r.event = "detect_requested" -> DetectRequested
      [] r.event = "discover_result" -> DiscoverResult(Listed(r))
      [] r.event = "unsupported_version" -> UnsupportedVersion(Listed(r))
      [] r.event = "modern_rejection" -> ModernRejection
      [] r.event = "legacy_answer" -> LegacyAnswer
      [] r.event = "discover_not_implemented" -> DiscoverNotImplemented
      [] r.event = "probe_timer_fired" -> ProbeTimedOut
      [] r.event = "initialize_result" -> InitializeResult(VersionOf(r.data.result_version))
      [] r.event = "initialize_error" -> InitializeError(r.data.hint)
      [] r.event = "initialize_timed_out" -> InitializeTimedOut
      [] r.event = "operation_sent" -> OperationSent
      [] r.event = "operation_version_rejected" -> OperationVersionRejected(Listed(r))
      [] OTHER -> FALSE

Matches(r) ==
    /\ state' = r.to
    /\ version' = VersionOf(r.data.version)
    /\ pending' = r.data.pending
    /\ modernSeen' = r.data.modern_seen
    /\ process' = r.data.process
    /\ lastMeta' = MetaOf(r.data.last_meta)

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ LET r == ObsTrace[i + 1]
       IN /\ state = r.from
          /\ IF r.data.ignored THEN ~ENABLED Step(r) /\ UNCHANGED vars ELSE Step(r)
          /\ Matches(r)
    /\ i' = i + 1

\* Sentinel: violated exactly when every observed step has been matched.
NotDone == i < Len(ObsTrace)
====

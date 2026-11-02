---- MODULE StdioConnTrace ----
\* Trace wrapper for StdioConn.tla (U03). tests/bun/bridge.ts generates TraceObs.
\*
\* Mapping from the Zig core (src/mcp/core/stdio_conn.zig):
\*   - Each record is one client action, named as in the model in snake_case.
\*     `arg` is the action's generation parameter; `timer` picks which timer
\*     action a `timer_fired` record is.
\*   - A record marked `ignored` is an event the model couldn't take in that
\*     state. It is accepted only where the model's action is disabled, and
\*     nothing may change.
\*   - What the client can't see (the process writing a line, exiting, or dying
\*     after SIGKILL) are hidden environment steps that may come between records.
\*   - MaxAttempts comes from the scenario (ObsMaxAttempts). MaxStarts is the
\*     highest generation in the trace.
EXTENDS StdioConn, TraceObs, Naturals, Sequences

VARIABLE i

Recs == {ObsTrace[k] : k \in 1..Len(ObsTrace)}
ObsGens == {r.data.gen : r \in Recs} \cup {1}
ObsMaxStarts == CHOOSE m \in ObsGens : \A g \in ObsGens : g <= m

Step(r) ==
    CASE r.event = "start_requested" -> StartRequested
      [] r.event = "spawned" -> Spawned
      [] r.event = "spawn_failed" -> SpawnFailed
      [] r.event = "line_received" -> LineReceived(r.data.arg)
      [] r.event = "oversized_line" -> OversizedLine(r.data.arg)
      [] r.event = "write_failed" -> WriteFailed
      [] r.event = "process_exited" -> ProcessExited
      [] r.event = "stop_requested" -> StopRequested
      [] r.event = "timer_fired" /\ r.data.timer = "grace" -> GraceTimerFired(r.data.arg)
      [] r.event = "timer_fired" /\ r.data.timer = "term" -> TermTimerFired(r.data.arg)
      [] r.event = "timer_fired" /\ r.data.timer = "backoff" -> BackoffTimerFired(r.data.arg)
      [] r.event = "reconnect_requested" -> ReconnectRequested
      [] r.event = "era_detected" -> \E e \in {"modern", "legacy"} : EraDetected(e)
      [] r.event = "send" -> Send(r.data.kind)
      [] OTHER -> FALSE

Matches(r) ==
    /\ conn' = r.to
    /\ gen' = r.data.gen
    /\ attempts' = r.data.attempts
    /\ era' = r.data.era
    /\ stdinOpen' = r.data.stdin_open
    /\ stopping' = r.data.stopping
    /\ errored' = r.data.errored
    /\ ("term" \in sent') = r.data.term_sent
    /\ ("kill" \in sent') = r.data.kill_sent

Environment == EmitLine \/ Crash \/ Killed

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    \/ /\ i < Len(ObsTrace)
       /\ LET r == ObsTrace[i + 1]
          IN /\ conn = r.from
             /\ IF r.data.ignored THEN ~ENABLED Step(r) /\ UNCHANGED vars ELSE Step(r)
             /\ Matches(r)
       /\ i' = i + 1
    \/ /\ Environment
       /\ UNCHANGED i

\* Sentinel: violated exactly when every observed step has been matched.
NotDone == i < Len(ObsTrace)
====

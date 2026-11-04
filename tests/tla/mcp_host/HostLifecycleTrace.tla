---- MODULE HostLifecycleTrace ----
\* Trace wrapper for HostLifecycle.tla. trace.ts generates TraceObs from
\* what the harness saw of a real fx shell (tests/tla/drivers/mcp_host/):
\*   spawn {server}    the fixture server started (its pid log)
\*   ready {server}    it answered tools/list
\*   stop {server}     it exited at stdin's end
\*   term {server}     it exited after fx quit (SIGTERM; its log says which)
\*   reload {server, change}  `/mcp approve|reject|remove|add` typed
\*   edit {server, change}    `fx mcp add|remove` run outside the session
\*   lease {}, release {}     `/mcp show NAME` started, and printed its answer
\*   status {k, who, why, r, e}  the status line, read once it stopped changing
\*   quit {}           Ctrl+C twice
\* Both kinds of change are an Edit of the files. The first frame, a need, a
\* server the engine gives up on, and the host's reload at a check are
\* hidden steps: they may happen between records without advancing `i`.
\* `bad` collects the stated safety properties broken on the way; trace.ts
\* asks whether some complete match keeps them all.
EXTENDS HostLifecycle, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF HeldNeverSpawned THEN {} ELSE {"HeldNeverSpawned"}) \cup
    (IF StartedAfterFirstFrame THEN {} ELSE {"StartedAfterFirstFrame"}) \cup
    (IF QuitSignalsEveryServer THEN {} ELSE {"QuitSignalsEveryServer"}) \cup
    (IF RemovedNotRunning THEN {} ELSE {"RemovedNotRunning"}) \cup
    (IF AtMostOneOwner THEN {} ELSE {"AtMostOneOwner"}) \cup
    (IF OneProcessPerServer THEN {} ELSE {"OneProcessPerServer"})

AsLine(d) == [k |-> d.k, who |-> d.who, why |-> d.why, r |-> d.r, e |-> d.e]

Step(rec) ==
    CASE rec.event = "spawn" -> \E h \in Hosts : Spawn(h, rec.data.server)
      [] rec.event = "ready" -> \E h \in Hosts : Answer(h, rec.data.server)
      [] rec.event = "stop" -> \E h \in Hosts : Exit(h, rec.data.server)
      [] rec.event = "term" -> \E h \in Hosts : TermExit(h, rec.data.server)
      [] rec.event \in {"reload", "edit"} -> Edit(rec.data.server, rec.data.change)
      [] rec.event = "lease" -> Lease
      [] rec.event = "release" -> \E h \in Hosts : Release(h)
      [] rec.event = "status" -> RefreshStatus /\ shown' = AsLine(rec.data)
      [] rec.event = "quit" -> Quit
      [] OTHER -> FALSE

Hidden ==
    \/ FirstFrame
    \/ \E s \in Servers : Need(s)
    \/ \E h \in Hosts, s \in Servers : GiveUp(h, s)
    \/ Reload

TraceInit == Init /\ i = 0 /\ bad = Viol

TraceNext ==
    \/ /\ i < Len(ObsTrace)
       /\ Step(ObsTrace[i + 1])
       /\ i' = i + 1
       /\ bad' = bad \cup Viol'
    \/ /\ Hidden
       /\ UNCHANGED i
       /\ bad' = bad \cup Viol'

\* Sentinels (trace.ts): violated exactly when a complete match exists, one
\* that keeps every stated property, or one that breaks one.
NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====

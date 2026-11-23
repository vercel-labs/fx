---- MODULE SubagentAccessTrace ----
\* Trace wrapper for SubagentAccess.tla. trace.ts generates TraceObs from real
\* `fx ask` runs in which the main agent starts a subagent and the subagent's
\* shell command makes an `fx mcp call` against a fake MCP server
\* (tests/tla/drivers/mcp_host/subagent-access.test.ts). The server is "a", and
\* its tools are numbered from 1.
\*   init {usable}               the servers the parent may use
\*   create                      the parent starts a subagent
\*   load {server}               the server's tool list loaded: the subagent
\*                               opened one of its tools in toolbox
\*   shell                       the subagent's shell command begins
\*   bridge {server, n, ran}     its `fx mcp call` of the server's tool n:
\*                               ran (true) or refused (false)
\*   end                         the command ends
EXTENDS SubagentAccess, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF BridgeHoldsIntegration THEN {} ELSE {"BridgeHoldsIntegration"}) \cup
    (IF RefusalStartsNothing THEN {} ELSE {"RefusalStartsNothing"})

Step(rec) ==
    CASE rec.event = "init" ->
            /\ usable = rec.data.usable
            /\ UNCHANGED vars
      [] rec.event = "create" -> Create
      [] rec.event = "load" -> Load(rec.data.server)
      [] rec.event = "shell" -> \E v \in views : StartShell(v)
      [] rec.event = "end" -> EndShell
      [] rec.event = "bridge" ->
            LET t == <<rec.data.server, rec.data.n>>
            IN /\ BridgeCall(t)
               /\ ([tool |-> t, held |-> TRUE] \in ran') <=> rec.data.ran
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

---- MODULE SubagentAccessTrace ----
\* Trace wrapper for SubagentAccess.tla. trace.ts generates TraceObs from real
\* `fx ask` runs against fake MCP servers, one run for each scenario
\* (tests/tla/drivers/mcp_host/subagent-access.test.ts). The servers are a, the
\* small stdio server, and b, the large HTTP server. Tool 1 of a is
\* mcp_fixture_echo; tools 1 and 2 of b are mcp_big_tool_01 and _02.
\*   init {usable}               the servers the parent may use
\*   load {server}               the parent ran something that loads a server's
\*                               tool list
\*   create {scope, mode}        the parent starts a subagent whose profile
\*                               limits it to the servers in `scope` and sets
\*                               its permission mode
\*   bridge {scope, mode, server, n, answer}
\*                               a command of that subagent ran `fx mcp call` for
\*                               tool n of a server: "ran" (exit 0) or
\*                               "refused" (exit 5); any other answer is not
\*                               a step of the model
EXTENDS SubagentAccess, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF TypeOK THEN {} ELSE {"TypeOK"}) \cup
    (IF ChildWithinParent THEN {} ELSE {"ChildWithinParent"}) \cup
    (IF NotNarrower THEN {} ELSE {"NotNarrower"}) \cup
    (IF RunScoped THEN {} ELSE {"RunScoped"}) \cup
    (IF BridgeHoldsViewAndRules THEN {} ELSE {"BridgeHoldsViewAndRules"}) \cup
    (IF BridgeRunsWhatIsAllowed THEN {} ELSE {"BridgeRunsWhatIsAllowed"})

Step(rec) ==
    CASE rec.event = "init" ->
            /\ usable = rec.data.usable
            /\ UNCHANGED vars
      [] rec.event = "load" -> Load(rec.data.server)
      [] rec.event = "create" -> CreateWith(rec.data.scope, rec.data.mode)
      [] rec.event = "bridge" ->
            \E v \in views :
                /\ v.scope = rec.data.scope
                /\ v.mode = rec.data.mode
                /\ rec.data.answer \in {"ran", "refused"}
                /\ BridgeCall(v, <<rec.data.server, rec.data.n>>)
                /\ \A c \in calls' : c.ran <=> (rec.data.answer = "ran")
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

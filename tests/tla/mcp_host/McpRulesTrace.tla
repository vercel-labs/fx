---- MODULE McpRulesTrace ----
\* Trace wrapper for McpRules.tla. trace.ts generates TraceObs from real
\* `fx ask` runs against fake MCP servers, one run per mode and agent
\* (tests/tla/drivers/mcp_host/mcp-rules.test.ts). The tools are a, b, c: a is
\* the small server's tool, b and c are tools of the large server.
\*   init {mode, childMode, denied, view}
\*                               the host's mode, the mode a subagent runs
\*                               in, the tools the rules deny, and the tools
\*                               a subagent's access allows
\*   mode {mode}                 the next run is in another mode
\*   child {mode}                a new subagent runs in another mode
\*   ask {path, agent, tool, answer}
\*                               what the path answered for the tool:
\*                               "shown" (found, opened, run) or "hidden"
EXTENDS McpRules, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF AccessHolds THEN {} ELSE {"AccessHolds"}) \cup
    (IF DenyHoldsOutside THEN {} ELSE {"DenyHoldsOutside"}) \cup
    (IF FullAccessIgnoresRules THEN {} ELSE {"FullAccessIgnoresRules"}) \cup
    (IF PathsAgree THEN {} ELSE {"PathsAgree"}) \cup
    (IF UndeniedShown THEN {} ELSE {"UndeniedShown"})

Step(rec) ==
    CASE rec.event = "init" ->
            /\ mode = rec.data.mode
            /\ childMode = rec.data.childMode
            /\ denied = rec.data.denied
            /\ view = rec.data.view
            /\ UNCHANGED vars
      [] rec.event = "mode" -> SetMode(rec.data.mode)
      [] rec.event = "child" -> NewChild(rec.data.mode)
      [] rec.event = "ask" ->
            /\ Shown(rec.data.path, rec.data.agent, rec.data.tool) <=> (rec.data.answer = "shown")
            /\ UNCHANGED vars
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

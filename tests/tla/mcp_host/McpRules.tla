---- MODULE McpRules ----
\* Which MCP tools each path shows or admits, by permission mode
\* (src/core/tooling/tool_runtime.zig: typedDispatchContext, lookupBridge,
\* authorizeBridgeCall, resolveUnselectedMcpTool, lookupToolboxMcpTool,
\* refreshChangedMcpTool; src/tools/capabilities/toolbox.zig and
\* capability_search.zig; and the integrations list of a subagent, built by
\* the TUI (src/main.zig snapshotMcpToolNames), ACP (src/acp/server.zig) and
\* fx ask (src/core/cli/cli_ask.zig)).
\*
\* A deny rule names tools. Full access skips fx's permission policy, so in
\* full access no rule hides or blocks an MCP tool on any path. In ask and
\* auto a denied tool is hidden and refused on every path. What the agent's
\* access allows (a subagent's view of its parent's servers) holds in every
\* mode: only the rules go.
\*
\* Each path hands the catalog a rule set. `OwnRules` is the paths that read
\* the host's rules in every mode, as the code did before the fix: the
\* smoke and stress configs leave it empty, every path using the mode's rule
\* set. A subagent's run is also checked against its integrations list,
\* which the host builds from the rules once, so that list is a path too.
\*
\* A subagent runs in its own mode: its profile may set one, else it takes its
\* parent's. The host builds the integrations list once, so the list has to
\* follow the mode the child runs in, not the host's.
\*
\* A session changes its mode, a new subagent may run in another mode than the
\* last one, and a person remembers a deny rule for the session.
EXTENDS Naturals, FiniteSets

CONSTANTS Tools, OwnRules

Modes == {"ask", "auto", "full"}
Agents == {"main", "child"}
Paths == {"search", "open_small", "open_large", "open_tool", "run",
          "bridge_list", "bridge_search", "bridge_help", "bridge_call", "refresh"}
Lists == Paths \cup {"integrations"}

ASSUME OwnRules \subseteq Lists

VARIABLES mode, childMode, denied, view

vars == <<mode, childMode, denied, view>>

\* The rules a path uses in mode m.
EffRules(m) == IF m = "full" THEN {} ELSE denied
RulesFor(p, m) == IF p \in OwnRules THEN denied ELSE EffRules(m)

\* What the agent's access grants: the main agent everything, a child the
\* tools of its view. `Access` is what the paths check; the properties state
\* it separately, so a path that widens it is caught.
Granted(a, t) == a = "main" \/ t \in view

\* The mode an agent runs in.
ModeOf(a) == IF a = "main" THEN mode ELSE childMode
Access(a, t) == Granted(a, t)

\* The names a child's host lists, built from the rules.
Integrations(m) == {t \in Tools : t \notin RulesFor("integrations", m)}

\* A child's run must also be in its integrations list.
Gate(p, a, t) == IF a = "child" /\ p = "run" THEN t \in Integrations(childMode) ELSE TRUE

Shown(p, a, t) == Access(a, t) /\ t \notin RulesFor(p, ModeOf(a)) /\ Gate(p, a, t)

TypeOK == /\ mode \in Modes /\ childMode \in Modes /\ denied \subseteq Tools /\ view \subseteq Tools

\* Access holds in every mode.
AccessHolds == \A p \in Paths, a \in Agents, t \in Tools : ~Granted(a, t) => ~Shown(p, a, t)

\* Outside full access a denied tool is hidden and refused on every path.
DenyHoldsOutside == \A p \in Paths, a \in Agents, t \in denied : ModeOf(a) # "full" => ~Shown(p, a, t)

\* In full access every path shows what the access allows.
FullAccessIgnoresRules == \A p \in Paths, a \in Agents, t \in Tools :
    ModeOf(a) = "full" => Shown(p, a, t) = Granted(a, t)

\* For the same mode, rules, agent and tool, every path gives one answer.
PathsAgree == \A p \in Paths, q \in Paths, a \in Agents, t \in Tools : Shown(p, a, t) = Shown(q, a, t)

\* A tool no rule names and the access allows works in every mode.
UndeniedShown == \A p \in Paths, a \in Agents, t \in Tools : (Granted(a, t) /\ t \notin denied) => Shown(p, a, t)

Init == /\ mode \in Modes
        /\ childMode \in Modes
        /\ denied \in SUBSET Tools
        /\ view \in SUBSET Tools

SetMode(m) == /\ m # mode /\ mode' = m /\ UNCHANGED <<childMode, denied, view>>

NewChild(m) == /\ m # childMode /\ childMode' = m /\ UNCHANGED <<mode, denied, view>>

Remember(t) == /\ t \notin denied /\ denied' = denied \cup {t} /\ UNCHANGED <<mode, childMode, view>>

Next == (\E m \in Modes : SetMode(m)) \/ (\E m \in Modes : NewChild(m)) \/ (\E t \in Tools : Remember(t))

Spec == Init /\ [][Next]_vars

====

---- MODULE SubagentAccess ----
\* What a subagent may call from its parent's MCP servers
\* (src/core/mcp_host/model.zig Catalog.snapshotAccessView, and the check in
\* hasTool, validateTool, callTool, the searches, and the schema lookups).
\*
\* One run is one host: `/mcp reload`, approving, adding, or removing a server
\* builds a new host, whose catalog has a new generation. Within a run the
\* servers are fixed. Servers start lazily, so a server's tool list loads only
\* when something first needs it, and only servers the parent may use start.
\*   - Load: a usable server's tool list loads (a search, a call, or a start).
\*   - Create: the parent creates a subagent, which captures a view.
\*   - Reload: a new run with its own usable servers; no list is loaded yet.
\* A call loads the list first, so a child's call needs the list loaded.
\*
\* A child's shell command runs under the authority its tool call began with
\* (src/core/tooling/tool_runtime.zig `liveAuthorityHolds`), whose MCP integrations
\* are the tools of the lists loaded then. Its `fx mcp call` of a tool the integrations
\* do not hold is refused before any list is asked for, as the child's direct call of
\* that tool is refused. `shell` is that command; `snap` is the servers whose lists
\* were loaded when it began.
EXTENDS Naturals, FiniteSets

CONSTANTS Servers, MaxRuns, MaxViews,
    Bridge \* BOOLEAN: a child runs shell commands that make `fx mcp call`s. The smoke config checks them; the stress
           \* config leaves them out, as they add more than ten times its states and hold for one child at a time.

Tools == Servers \X {1, 2}

VARIABLES run, usable, loaded, views,
    shell,           \* NoShell, or the child's command running now: its view and the lists loaded when it began
    ran,             \* ghost: each `fx mcp call` that ran, and whether the integrations held its tool
    startedByRefusal \* ghost: a refused `fx mcp call` started a server to load its list

vars == <<run, usable, loaded, views, shell, ran, startedByRefusal>>

NoShell == [none |-> TRUE]

Views == [run : 1..MaxRuns, servers : SUBSET Servers, tools : SUBSET Tools]

\* The view a child captures: the servers its parent may use, and the tools
\* of the lists already loaded.
Captured == [run |-> run, servers |-> usable, tools |-> {t \in Tools : t[1] \in loaded}]

ParentAllowed(t) == t[1] \in loaded

AllowedWith(v, t, lists) ==
    /\ v.run = run
    /\ t[1] \in lists
    /\ (t \in v.tools \/ t[1] \in v.servers)

Allowed(v, t) == AllowedWith(v, t, loaded)

Init ==
    /\ run = 1
    /\ usable \in SUBSET Servers
    /\ loaded = {}
    /\ views = {}
    /\ shell = NoShell
    /\ ran = {}
    /\ startedByRefusal = FALSE

Load(s) ==
    /\ s \in usable \ loaded
    /\ loaded' = loaded \cup {s}
    /\ UNCHANGED <<run, usable, views, shell, ran, startedByRefusal>>

Create ==
    /\ Cardinality(views) < MaxViews
    /\ views' = views \cup {Captured}
    /\ UNCHANGED <<run, usable, loaded, shell, ran, startedByRefusal>>

Reload ==
    /\ run < MaxRuns
    /\ run' = run + 1
    /\ usable' \in SUBSET Servers
    /\ loaded' = {}
    /\ UNCHANGED <<views, shell, ran, startedByRefusal>>

\* A child's shell command begins: its integrations are the tools of the lists loaded now.
StartShell(v) ==
    /\ Bridge
    /\ shell = NoShell
    /\ shell' = [view |-> v, snap |-> loaded]
    /\ UNCHANGED <<run, usable, loaded, views, ran, startedByRefusal>>

EndShell ==
    /\ shell # NoShell
    /\ shell' = NoShell
    /\ UNCHANGED <<run, usable, loaded, views, ran, startedByRefusal>>

\* The command's `fx mcp call` of tool t. A tool whose list was not loaded when the command began is not
\* held: the call is refused, and no list is asked for. Otherwise it loads the list, and the child's view decides.
BridgeCall(t) ==
    /\ shell # NoShell
    /\ IF t[1] \in shell.snap
       THEN LET lists == IF t[1] \in usable THEN loaded \cup {t[1]} ELSE loaded
            IN /\ loaded' = lists
               /\ ran' = IF AllowedWith(shell.view, t, lists)
                          THEN ran \cup {[tool |-> t, held |-> t[1] \in shell.snap]}
                          ELSE ran
               /\ UNCHANGED startedByRefusal
       ELSE /\ UNCHANGED <<loaded, ran, startedByRefusal>>
    /\ UNCHANGED <<run, usable, views, shell>>

Next ==
    \/ \E s \in Servers : Load(s)
    \/ Create
    \/ Reload
    \/ \E v \in views : StartShell(v)
    \/ EndShell
    \/ \E t \in Tools : BridgeCall(t)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ run \in 1..MaxRuns
    /\ usable \subseteq Servers
    /\ loaded \subseteq usable
    /\ views \subseteq Views
    /\ shell \in {NoShell} \cup [view : Views, snap : SUBSET Servers]
    /\ ran \subseteq [tool : Tools, held : BOOLEAN]
    /\ startedByRefusal \in BOOLEAN

\* Anything a child may call, its parent may call.
ChildWithinParent == \A v \in views, t \in Tools : Allowed(v, t) => ParentAllowed(t)

\* A child of this run is not narrower than its parent: a list that loads
\* after the child was created still counts.
NotNarrower == \A v \in views : v.run = run => \A t \in Tools : ParentAllowed(t) => Allowed(v, t)

\* A view from an earlier run allows nothing.
RunScoped == \A v \in views : v.run # run => \A t \in Tools : ~Allowed(v, t)

\* Every `fx mcp call` that ran was for a tool the child's integrations held, as its direct call needs.
BridgeHoldsIntegration == \A r \in ran : r.held

\* A refused `fx mcp call` starts no server.
RefusalStartsNothing == ~startedByRefusal
====

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
EXTENDS Naturals, FiniteSets

CONSTANTS Servers, MaxRuns, MaxViews

Tools == Servers \X {1, 2}

VARIABLES run, usable, loaded, views

vars == <<run, usable, loaded, views>>

Views == [run : 1..MaxRuns, servers : SUBSET Servers, tools : SUBSET Tools]

\* The view a child captures: the servers its parent may use, and the tools
\* of the lists already loaded.
Captured == [run |-> run, servers |-> usable, tools |-> {t \in Tools : t[1] \in loaded}]

ParentAllowed(t) == t[1] \in loaded

Allowed(v, t) ==
    /\ v.run = run
    /\ t[1] \in loaded
    /\ (t \in v.tools \/ t[1] \in v.servers)

Init ==
    /\ run = 1
    /\ usable \in SUBSET Servers
    /\ loaded = {}
    /\ views = {}

Load(s) ==
    /\ s \in usable \ loaded
    /\ loaded' = loaded \cup {s}
    /\ UNCHANGED <<run, usable, views>>

Create ==
    /\ Cardinality(views) < MaxViews
    /\ views' = views \cup {Captured}
    /\ UNCHANGED <<run, usable, loaded>>

Reload ==
    /\ run < MaxRuns
    /\ run' = run + 1
    /\ usable' \in SUBSET Servers
    /\ loaded' = {}
    /\ UNCHANGED views

Next == (\E s \in Servers : Load(s)) \/ Create \/ Reload

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ run \in 1..MaxRuns
    /\ usable \subseteq Servers
    /\ loaded \subseteq usable
    /\ views \subseteq Views

\* Anything a child may call, its parent may call.
ChildWithinParent == \A v \in views, t \in Tools : Allowed(v, t) => ParentAllowed(t)

\* A child of this run is not narrower than its parent: a list that loads
\* after the child was created still counts.
NotNarrower == \A v \in views : v.run = run => \A t \in Tools : ParentAllowed(t) => Allowed(v, t)

\* A view from an earlier run allows nothing.
RunScoped == \A v \in views : v.run # run => \A t \in Tools : ~Allowed(v, t)
====

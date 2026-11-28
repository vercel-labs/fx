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
\*   - BridgeCall: a command of the child runs `fx mcp call` for a tool
\*     (src/core/tooling/tool_runtime.zig authorizeBridgeCall).
\* A call loads the list first, so a child's call needs the list loaded.
\*
\* A child's profile may limit it to some of its parent's servers (its scope),
\* and it runs in its own permission mode: in "full" no deny rule applies, in
\* "auto" the host's rules do (`DeniedFirst`). A bridge call runs exactly when the
\* child's view holds the tool and no rule of its mode denies it. Whether the
\* tool's list was loaded when the command began does not matter: the call
\* loads it.
\* The stress config leaves the bridge out (`Bridge` is FALSE): the smoke
\* config checks it, and stress keeps the size it had.
EXTENDS Naturals, FiniteSets

CONSTANTS Servers, MaxRuns, MaxViews, Bridge, DeniedFirst

Tools == Servers \X {1, 2}

VARIABLES run, usable, loaded, views, calls

vars == <<run, usable, loaded, views, calls>>

\* The tools the host's rules deny: the first tool of each server in
\* `DeniedFirst`.
Denied == {<<s, 1>> : s \in DeniedFirst}

Scopes == IF Bridge THEN SUBSET Servers ELSE {Servers}
Modes == IF Bridge THEN {"full", "auto"} ELSE {"full"}

Views == [run : 1..MaxRuns, servers : SUBSET Servers, tools : SUBSET Tools, scope : SUBSET Servers, mode : {"full", "auto"}]

\* The view a child captures: the servers its parent may use and its profile
\* allows, and the tools of the lists already loaded.
Captured(scope, mode) ==
    [run |-> run, servers |-> usable \cap scope, tools |-> {t \in Tools : t[1] \in loaded \cap scope},
     scope |-> scope, mode |-> mode]

ParentAllowed(t) == t[1] \in loaded

Allowed(v, t) ==
    /\ v.run = run
    /\ t[1] \in loaded
    /\ (t \in v.tools \/ t[1] \in v.servers)

\* The tools a rule denies a child: none in full access.
DeniedFor(v) == IF v.mode = "full" THEN {} ELSE Denied

InView(v, t) == v.run = run /\ (t \in v.tools \/ t[1] \in v.servers)

\* What a bridge call does: the view and the rules decide.
BridgeRuns(v, t) ==
    /\ InView(v, t)
    /\ t \notin DeniedFor(v)

Init ==
    /\ run = 1
    /\ usable \in SUBSET Servers
    /\ loaded = {}
    /\ views = {}
    /\ calls = {}

Load(s) ==
    /\ s \in usable \ loaded
    /\ loaded' = loaded \cup {s}
    /\ UNCHANGED <<run, usable, views>>
    /\ calls' = {}

CreateWith(scope, mode) ==
    /\ Cardinality(views) < MaxViews
    /\ views' = views \cup {Captured(scope, mode)}
    /\ UNCHANGED <<run, usable, loaded>>
    /\ calls' = {}

Create == \E scope \in Scopes, mode \in Modes : CreateWith(scope, mode)

Reload ==
    /\ run < MaxRuns
    /\ run' = run + 1
    /\ usable' \in SUBSET Servers
    /\ loaded' = {}
    /\ UNCHANGED views
    /\ calls' = {}

\* One command's call, as the last thing that happened: the facts about it are
\* worked out apart from the decision, so a check can compare the two.
BridgeCall(v, t) ==
    /\ Bridge
    /\ calls' = {[tool |-> t, view |-> v, loaded |-> t[1] \in loaded,
                  inView |-> InView(v, t), denied |-> t \in DeniedFor(v), ran |-> BridgeRuns(v, t)]}
    /\ loaded' = IF BridgeRuns(v, t) /\ t[1] \in usable THEN loaded \cup {t[1]} ELSE loaded
    /\ UNCHANGED <<run, usable, views>>

Next == (\E s \in Servers : Load(s)) \/ Create \/ Reload \/ (\E v \in views, t \in Tools : BridgeCall(v, t))

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ run \in 1..MaxRuns
    /\ usable \subseteq Servers
    /\ loaded \subseteq usable
    /\ views \subseteq Views
    /\ calls \subseteq [tool : Tools, view : Views, loaded : BOOLEAN, inView : BOOLEAN, denied : BOOLEAN, ran : BOOLEAN]
    /\ Cardinality(calls) <= 1

\* Anything a child may call, its parent may call.
ChildWithinParent == \A v \in views, t \in Tools : Allowed(v, t) => ParentAllowed(t)

\* A child of this run with its parent's servers is not narrower than its
\* parent: a list that loads after the child was created still counts.
NotNarrower == \A v \in views : v.run = run /\ v.scope = Servers => \A t \in Tools : ParentAllowed(t) => Allowed(v, t)

\* A view from an earlier run allows nothing.
RunScoped == \A v \in views : v.run # run => \A t \in Tools : ~Allowed(v, t)

\* A bridge call that ran was in its child's view, and no rule of the child's
\* mode denied it.
BridgeHoldsViewAndRules == \A c \in calls : c.ran => c.inView /\ ~c.denied

\* A bridge call that the view and the rules allow ran, whether or not its
\* list was loaded when the command began.
BridgeRunsWhatIsAllowed == \A c \in calls : c.inView /\ ~c.denied => c.ran
====

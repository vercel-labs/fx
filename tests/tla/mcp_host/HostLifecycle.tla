---- MODULE HostLifecycle ----
\* fx's MCP-v2 host lifecycle, as the shell runs it.
\*
\* Code (vercel-labs/fx at 53a561bea):
\*   - src/core/app/app_mcp_runtime.zig: loadHost, reloadHost (replaceHost
\*     then startHostServers), leaseHost/releaseHost (a replaced host lives
\*     until its last lease), destroyHost (process exit: signalServersForExit,
\*     nothing waits), refreshHostStatus/hostStatusLine.
\*   - src/core/app/app_render_runtime.zig:1031: the first frame calls
\*     startMcpHostServers, which prepares every server.
\*   - src/core/mcp_host/runtime.zig: one owner thread per Runtime (start,
\*     run, deinit); `.need` skips held servers (handle, `.need`); publish
\*     turns held reasons and engine phases into statuses.
\*   - src/core/mcp_host/menu.zig statusLine: the status line text.
\*   - src/mcp/io/process.zig signalAllForExit: SIGTERM to every process of
\*     every engine in the program.
\*
\* One host is one Runtime and its owner thread. A reload makes a new host
\* from the changed config and starts every server in it; the old host is
\* retired and goes, with its servers, when its last lease ends. A lease is a
\* `/mcp` verb, a status refresh, or a call still using that host.
\*
\* Server states per host (runtime.zig State, folded):
\*   absent       not in the config (removed)
\*   waiting      held: a project server waiting for approval
\*   rejected     held: a project server the user rejected
\*   idle         not needed yet
\*   starting     connecting, or backing off (`connecting`, `retrying`)
\*   ready, needs_login, failed
\* Processes: `procs` are live server processes the host runs, `stopping`
\* those whose host let go of them (stdin closed) that haven't exited yet,
\* and `termed` those sent SIGTERM at quit.
EXTENDS Naturals, FiniteSets

CONSTANTS
    Servers,    \* server names
    Project,    \* those from ./.mcp.json, which start waiting for approval
    Reachable,  \* those whose command starts and answers
    NeedsAuth,  \* reachable HTTP servers that answer 401 until a sign-in
    MaxHosts,   \* bound on reloads: hosts 1..MaxHosts
    MaxLeases   \* bound on leases one host holds at once

ASSUME Project \subseteq Servers /\ Reachable \subseteq Servers /\ NeedsAuth \subseteq Reachable
ASSUME MaxHosts \in Nat \ {0} /\ MaxLeases \in Nat

Hosts == 1..MaxHosts
States == {"absent", "waiting", "rejected", "idle", "starting", "ready", "needs_login", "failed"}
Decisions == {"ok", "pending", "approved", "rejected", "removed"}
Changes == {"approved", "rejected", "removed", "ok"}
Lines == [k : {"none", "attn", "many"}, who : Servers \cup {""}, why : {"", "waiting", "login", "failed"}, r : 0..10, e : 0..10]
NoLine == [k |-> "none", who |-> "", why |-> "", r |-> 0, e |-> 0]

VARIABLES
    decision,   \* [Servers -> Decisions]: the config files and project trust now
    cur,        \* the host the shell uses
    alive,      \* [Hosts -> BOOLEAN]: its owner thread runs
    retired,    \* [Hosts -> BOOLEAN]: replaced by a reload
    leases,     \* [Hosts -> 0..MaxLeases]
    st,         \* [Hosts -> [Servers -> States]]
    procs,      \* SUBSET (Hosts \X Servers)
    stopping,   \* SUBSET (Hosts \X Servers)
    termed,     \* SUBSET (Hosts \X Servers)
    framed,     \* the first frame was drawn
    quit,       \* fx exited
    shown,      \* the status line's MCP text, as last refreshed
    refreshed,  \* the step just taken was a status refresh
    heldAt      \* ghost: [Hosts -> SUBSET Servers] held when the host was made

vars == <<decision, cur, alive, retired, leases, st, procs, stopping, termed, framed, quit, shown, refreshed, heldAt>>

D0 == [s \in Servers |-> IF s \in Project THEN "pending" ELSE "ok"]

\* config.zig heldFor, and what publish shows for it.
Initial(d, s) == CASE d[s] = "removed" -> "absent"
                   [] d[s] = "pending" -> "waiting"
                   [] d[s] = "rejected" -> "rejected"
                   [] OTHER -> "idle"
Held(d) == {s \in Servers : Initial(d, s) \in {"absent", "waiting", "rejected"}}
\* runtime.zig `.need`: a held server is skipped.
Started(x) == IF x = "idle" THEN "starting" ELSE x

\* menu.zig statusLine, without news, a sign-in, or config notes: it names
\* the servers that need attention, and says nothing about MCP otherwise.
Needy(h) == {s \in Servers : st[h][s] \in {"waiting", "needs_login", "failed"}}
Why(x) == CASE x = "waiting" -> "waiting" [] x = "needs_login" -> "login" [] OTHER -> "failed"
Line(h) ==
    IF Cardinality(Needy(h)) = 1
    THEN LET s == CHOOSE x \in Needy(h) : TRUE
         IN [k |-> "attn", who |-> s, why |-> Why(st[h][s]), r |-> 0, e |-> 0]
    ELSE IF Cardinality(Needy(h)) > 1
    THEN [k |-> "many", who |-> "", why |-> "", r |-> Cardinality(Needy(h)), e |-> 0]
    ELSE NoLine

Of(h) == {p \in procs : p[1] = h}
Live == procs \cup stopping

TypeOK ==
    /\ decision \in [Servers -> Decisions]
    /\ cur \in Hosts
    /\ alive \in [Hosts -> BOOLEAN]
    /\ retired \in [Hosts -> BOOLEAN]
    /\ leases \in [Hosts -> 0..MaxLeases]
    /\ st \in [Hosts -> [Servers -> States]]
    /\ procs \subseteq Hosts \X Servers
    /\ stopping \subseteq Hosts \X Servers
    /\ termed \subseteq Hosts \X Servers
    /\ framed \in BOOLEAN /\ quit \in BOOLEAN /\ refreshed \in BOOLEAN
    /\ shown \in Lines
    /\ heldAt \in [Hosts -> SUBSET Servers]

Init ==
    /\ decision = D0
    /\ cur = 1
    /\ alive = [h \in Hosts |-> h = 1]
    /\ retired = [h \in Hosts |-> FALSE]
    /\ leases = [h \in Hosts |-> 0]
    /\ st = [h \in Hosts |-> [s \in Servers |-> IF h = 1 THEN Initial(D0, s) ELSE "absent"]]
    /\ procs = {} /\ stopping = {} /\ termed = {}
    /\ framed = FALSE /\ quit = FALSE
    /\ shown = NoLine /\ refreshed = FALSE
    /\ heldAt = [h \in Hosts |-> IF h = 1 THEN Held(D0) ELSE {}]

\* app_render_runtime.zig:1031 -> startHostServers: prepare(i) for every server.
FirstFrame ==
    /\ ~framed /\ ~quit
    /\ framed' = TRUE
    /\ st' = [st EXCEPT ![cur] = [s \in Servers |-> Started(st[cur][s])]]
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, procs, stopping, termed, quit, shown, heldAt>>

\* Something needs a server's tools: a tool search, `/mcp show`, a call.
Need(s) ==
    /\ ~quit /\ st[cur][s] = "idle"
    /\ st' = [st EXCEPT ![cur][s] = "starting"]
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, procs, stopping, termed, framed, quit, shown, heldAt>>

\* The owner thread starts the server's process. A retired host's servers
\* stop on a thread of their own, so the UI never waits for them.
\* While any other host still has a live process, in use under a lease or
\* stopping, a host starts none, so a server never runs twice.
Spawn(h, s) ==
    /\ ~quit /\ alive[h] /\ st[h][s] = "starting" /\ <<h, s>> \notin procs
    /\ \A p \in Live : p[1] = h
    /\ procs' = procs \cup {<<h, s>>}
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, st, stopping, termed, framed, quit, shown, heldAt>>

\* The server answered detection and its tool list.
Answer(h, s) ==
    /\ ~quit /\ alive[h] /\ st[h][s] = "starting" /\ <<h, s>> \in procs /\ s \in Reachable
    /\ st' = [st EXCEPT ![h][s] = IF s \in NeedsAuth THEN "needs_login" ELSE "ready"]
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, procs, stopping, termed, framed, quit, shown, heldAt>>

\* The engine gave up on a server that never answers (its attempt limit).
GiveUp(h, s) ==
    /\ ~quit /\ alive[h] /\ st[h][s] = "starting" /\ s \notin Reachable
    /\ st' = [st EXCEPT ![h][s] = "failed"]
    /\ procs' = procs \ {<<h, s>>}
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, stopping, termed, framed, quit, shown, heldAt>>

\* leaseHost: a `/mcp` verb, a status refresh, or a call takes the current host.
Lease ==
    /\ ~quit /\ leases[cur] < MaxLeases
    /\ leases' = [leases EXCEPT ![cur] = @ + 1]
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, st, procs, stopping, termed, framed, quit, shown, heldAt>>

\* releaseHost: the last lease of a retired host retires it (Host.retire:
\* Runtime.deinit on a thread of its own; the engine closes its servers'
\* stdin).
Release(h) ==
    /\ ~quit /\ leases[h] > 0
    /\ leases' = [leases EXCEPT ![h] = @ - 1]
    /\ IF retired[h] /\ leases[h] = 1
       THEN /\ alive' = [alive EXCEPT ![h] = FALSE]
            /\ procs' = procs \ Of(h)
            /\ stopping' = stopping \cup Of(h)
       ELSE UNCHANGED <<alive, procs, stopping>>
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, retired, st, termed, framed, quit, shown, heldAt>>

\* add, remove, approve, reject: hosts.changed -> applyMcpHostReload ->
\* reloadHost: a new host from the config, then startHostServers.
Change(s, d) ==
    \/ d = "approved" /\ decision[s] = "pending"
    \/ d = "rejected" /\ decision[s] = "pending"
    \/ d = "removed" /\ decision[s] # "removed"
    \/ d = "ok" /\ decision[s] = "removed"

Reload(s, d) ==
    /\ ~quit /\ cur < MaxHosts /\ Change(s, d)
    /\ LET n == cur + 1
           nd == [decision EXCEPT ![s] = d]
           free == leases[cur] = 0
       IN /\ decision' = nd
          /\ cur' = n
          /\ st' = [st EXCEPT ![n] = [x \in Servers |-> Started(Initial(nd, x))]]
          /\ heldAt' = [heldAt EXCEPT ![n] = Held(nd)]
          /\ retired' = [retired EXCEPT ![cur] = TRUE]
          /\ alive' = [alive EXCEPT ![n] = TRUE, ![cur] = ~free]
          /\ procs' = IF free THEN procs \ Of(cur) ELSE procs
          /\ stopping' = IF free THEN stopping \cup Of(cur) ELSE stopping
    /\ refreshed' = FALSE
    /\ UNCHANGED <<leases, termed, framed, quit, shown>>

\* A server whose stdin closed exits (also when fx quit meanwhile).
Exit(h, s) ==
    /\ <<h, s>> \in stopping
    /\ stopping' = stopping \ {<<h, s>>}
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, st, procs, termed, framed, quit, shown, heldAt>>

\* destroyHost at process exit: every server of every host gets SIGTERM and
\* nothing waits; fx is gone.
Quit ==
    /\ ~quit
    /\ quit' = TRUE
    /\ termed' = termed \cup procs \cup stopping
    /\ alive' = [h \in Hosts |-> FALSE]
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, retired, leases, st, procs, stopping, framed, shown, heldAt>>

\* A signalled server exits.
TermExit(h, s) ==
    /\ <<h, s>> \in termed /\ <<h, s>> \in Live
    /\ procs' = procs \ {<<h, s>>}
    /\ stopping' = stopping \ {<<h, s>>}
    /\ refreshed' = FALSE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, st, termed, framed, quit, shown, heldAt>>

\* refreshHostStatus: the line from the current host's statuses.
RefreshStatus ==
    /\ ~quit
    /\ shown' = Line(cur)
    /\ refreshed' = TRUE
    /\ UNCHANGED <<decision, cur, alive, retired, leases, st, procs, stopping, termed, framed, quit, heldAt>>

Next ==
    \/ FirstFrame
    \/ \E s \in Servers : Need(s)
    \/ \E h \in Hosts, s \in Servers : Spawn(h, s) \/ Answer(h, s) \/ GiveUp(h, s) \/ Exit(h, s) \/ TermExit(h, s)
    \/ Lease
    \/ \E h \in Hosts : Release(h)
    \/ \E s \in Servers, d \in Changes : Reload(s, d)
    \/ Quit
    \/ RefreshStatus
    \* fx has exited and every server with it: nothing more happens.
    \/ (quit /\ Live = {} /\ UNCHANGED vars)

Fairness ==
    /\ WF_vars(FirstFrame)
    /\ \A h \in Hosts, s \in Servers :
          WF_vars(Spawn(h, s)) /\ WF_vars(Answer(h, s)) /\ WF_vars(GiveUp(h, s)) /\ WF_vars(Exit(h, s)) /\ WF_vars(TermExit(h, s))
    /\ \A h \in Hosts : WF_vars(Release(h))

Spec == Init /\ [][Next]_vars /\ Fairness

\* ---- Safety the code keeps ----

\* A held server (waiting, rejected, or removed when its host was made) is
\* never spawned by that host.
HeldNeverSpawned == \A p \in procs \cup stopping \cup termed : p[2] \notin heldAt[p[1]]

\* After the first frame, and after every reload, no server the current host
\* may run is left idle: unchanged servers come back.
StartedAfterFirstFrame == (framed /\ ~quit) => \A s \in Servers : st[cur][s] # "idle"

\* A refreshed status line is the current host's statuses in words.
RefreshedLineAgrees == refreshed => shown = Line(cur)

\* Quitting signals every live server of every host, and waits for none.
QuitSignalsEveryServer == quit => Live \subseteq termed

\* A removed server is never running in the current host.
RemovedNotRunning == \A s \in Servers : decision[s] = "removed" => <<cur, s>> \notin Live

\* ---- Stated safety the code does not keep (HostLifecycle.findings.cfg) ----

\* At most one owner thread drives servers at a time.
AtMostOneOwner == Cardinality({h \in Hosts : alive[h]}) <= 1

\* At most one live process per configured server.
OneProcessPerServer == \A s \in Servers : Cardinality({h \in Hosts : <<h, s>> \in Live}) <= 1

\* ---- Liveness, under the fairness above ----

\* Every server the config approves settles: ready when it answers, needing a
\* login when it answers 401, failed when it never answers.
ApprovedServersSettle == \A s \in Servers :
    <>[](quit \/ decision[s] \in {"pending", "rejected", "removed"}
         \/ (s \in Reachable \ NeedsAuth /\ st[cur][s] = "ready")
         \/ (s \in NeedsAuth /\ st[cur][s] = "needs_login")
         \/ (s \notin Reachable /\ st[cur][s] = "failed"))

\* Every process a host let go of, or signalled, exits.
EveryStopEnds == []<>(stopping = {} /\ (quit => procs = {}))
====

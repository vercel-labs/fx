---- MODULE ProfileLoad ----
\* How fx reads the MCP servers in a profile mcp.json on each surface that
\* reads it, and which server URLs it takes.
\*
\* Code (vercel-labs/fx):
\*   - src/core/mcp/http_config.zig validateServerUrl: a server URL is HTTPS,
\*     or plain HTTP to 127.0.0.1, localhost, or [::1], with or without a
\*     port, and has no credentials or fragment. Plain HTTP without a port
\*     goes to port 80 (src/mcp/io/http.zig).
\*   - src/core/mcp/project_config.zig parseProfileServerMap: reads each
\*     entry in the file's order. With a skipped list, an entry it can't read
\*     is noted there and left out; without one, that entry fails the file.
\*   - src/builtins/mcp.zig loadNativeConfigs: the CLI and the TUI pass a
\*     list and print a note for each skipped entry.
\*   - src/acp/sessions.zig appendProfileMcpConfigsIfRequested: an ACP
\*     session that sets _meta.fx.profileMcpServers passes a list and logs one
\*     trace line per skipped entry.
\*
\* An entry is the part of its config the rules read: the URL's scheme, a
\* loopback host or another one, whether it names a port, and whether it
\* carries credentials or a fragment. "stdio" is a local server fx can read,
\* "broken" an entry it can't read for another reason, such as a missing
\* command.
\*
\* PortRule, AcpSkips, and Mutation select the code being modeled:
\*   PortRule "loopback"  the fix: loopback HTTP with or without a port
\*            "required"  fx before it: plain HTTP needs a port
\*            "any_host"  planted: plain HTTP with no port passes for any host
\*   AcpSkips TRUE        the fix: ACP passes a skipped list
\*            FALSE       fx before it: one bad entry fails ACP's whole file
\*   Mutation "stop"      planted: reading stops at the first bad entry
\*            "silent"    planted: ACP leaves an entry out without logging it
\*
\* tests/tla/drivers/mcp_config/driver.ts runs the built fx on profile files
\* and has TLC check each run against this model (ProfileLoadTrace.tla).
EXTENDS Naturals, FiniteSets

CONSTANTS
    N,          \* entries in the file
    PortRule,
    AcpSkips,
    Mutation    \* "none", "stop", or "silent"

ASSUME N \in Nat
ASSUME PortRule \in {"loopback", "required", "any_host"}
ASSUME AcpSkips \in BOOLEAN
ASSUME Mutation \in {"none", "stop", "silent"}

Entries == 1..N
\* The CLI and TUI read the file the same way (loadNativeConfigs).
Surfaces == {"cli", "acp"}

UrlKinds == [scheme : {"https", "http", "other"}, host : {"loopback", "remote"},
             port : BOOLEAN, extra : BOOLEAN]
Local(scheme) == [scheme |-> scheme, host |-> "none", port |-> FALSE, extra |-> FALSE]
Kinds == UrlKinds \cup {Local("stdio"), Local("broken")}

VARIABLES
    file,       \* [Entries -> Kinds]: the entries, in the file's order
    todo,       \* [Surfaces -> SUBSET Entries]: not read yet
    loaded,     \* [Surfaces -> SUBSET Entries]: servers the surface runs
    skipped,    \* [Surfaces -> SUBSET Entries]: left out, file still read
    noted,      \* [Surfaces -> SUBSET Entries]: named in a note or trace line
    phase       \* [Surfaces -> {"reading", "done", "failed"}]

vars == <<file, todo, loaded, skipped, noted, phase>>

\* http_config.zig validateServerUrl, as PortRule selects.
UrlAccepted(k) ==
    /\ ~k.extra
    /\ \/ k.scheme = "https"
       \/ /\ k.scheme = "http"
          /\ CASE PortRule = "loopback" -> k.host = "loopback"
               [] PortRule = "required" -> k.host = "loopback" /\ k.port
               [] PortRule = "any_host" -> k.host = "loopback" \/ ~k.port

\* parseServerEntry succeeds.
Readable(k) ==
    CASE k.scheme = "stdio" -> TRUE
      [] k.scheme = "broken" -> FALSE
      [] OTHER -> UrlAccepted(k)

Skips(s) == s = "cli" \/ AcpSkips
Ended(s) == phase[s] \in {"done", "failed"}

TypeOK ==
    /\ file \in [DOMAIN file -> Kinds]
    /\ \A s \in Surfaces :
        /\ todo[s] \subseteq DOMAIN file
        /\ loaded[s] \subseteq DOMAIN file
        /\ skipped[s] \subseteq DOMAIN file
        /\ noted[s] \subseteq DOMAIN file
        /\ phase[s] \in {"reading", "done", "failed"}

\* One file, before any surface reads it.
InitWith(f) ==
    /\ file = f
    /\ todo = [s \in Surfaces |-> DOMAIN f]
    /\ loaded = [s \in Surfaces |-> {}]
    /\ skipped = [s \in Surfaces |-> {}]
    /\ noted = [s \in Surfaces |-> {}]
    /\ phase = [s \in Surfaces |-> "reading"]

Init == \E f \in [Entries -> Kinds] : InitWith(f)

\* parseProfileServerMap reads entry e for surface s.
Read(s, e) ==
    /\ phase[s] = "reading"
    /\ e \in todo[s]
    /\ IF Readable(file[e])
       THEN /\ todo' = [todo EXCEPT ![s] = @ \ {e}]
            /\ loaded' = [loaded EXCEPT ![s] = @ \cup {e}]
            /\ UNCHANGED <<file, skipped, noted, phase>>
       ELSE IF ~Skips(s)
       \* No list: the error ends the read, and the surface gets no profile
       \* server ("ACP profile MCP servers unavailable").
       THEN /\ todo' = [todo EXCEPT ![s] = {}]
            /\ loaded' = [loaded EXCEPT ![s] = {}]
            /\ phase' = [phase EXCEPT ![s] = "failed"]
            /\ UNCHANGED <<file, skipped, noted>>
       ELSE /\ skipped' = [skipped EXCEPT ![s] = @ \cup {e}]
            /\ noted' = IF Mutation = "silent" /\ s = "acp"
                        THEN noted
                        ELSE [noted EXCEPT ![s] = @ \cup {e}]
            /\ IF Mutation = "stop"
               THEN /\ todo' = [todo EXCEPT ![s] = {}]
                    /\ phase' = [phase EXCEPT ![s] = "done"]
               ELSE /\ todo' = [todo EXCEPT ![s] = @ \ {e}]
                    /\ UNCHANGED phase
            /\ UNCHANGED <<file, loaded>>

Finish(s) ==
    /\ phase[s] = "reading"
    /\ todo[s] = {}
    /\ phase' = [phase EXCEPT ![s] = "done"]
    /\ UNCHANGED <<file, todo, loaded, skipped, noted>>

Next == \E s \in Surfaces : Finish(s) \/ \E e \in DOMAIN file : Read(s, e)

Spec == Init /\ [][Next]_vars /\ \A s \in Surfaces : WF_vars(Finish(s) \/ \E e \in DOMAIN file : Read(s, e))

LoopbackHttp(k) == k.scheme = "http" /\ k.host = "loopback" /\ ~k.extra

\* Issue #1218: http://localhost/mcp is a server, with or without its port.
LoopbackHttpNeverSkipped ==
    \A s \in Surfaces : \A e \in skipped[s] : ~LoopbackHttp(file[e])

\* Plain HTTP goes only to a loopback host, whatever the port.
PlainHttpOnlyToLoopback ==
    \A s \in Surfaces : \A e \in loaded[s] :
        file[e].scheme = "http" => file[e].host = "loopback"

\* One entry fx can't read costs only itself: once a surface has read the
\* file, every entry the rules take runs there. Both surfaces use the same
\* rules, so they end with the same servers.
OneBadEntrySkipsOnlyItself ==
    \A s \in Surfaces : Ended(s) =>
        \A e \in DOMAIN file : Readable(file[e]) => e \in loaded[s]

\* Every entry left out is named: a note on the CLI, a trace line in ACP.
EverySkipNoted == \A s \in Surfaces : skipped[s] \subseteq noted[s]

\* Each surface finishes reading the file.
Termination == <>(\A s \in Surfaces : Ended(s))
====

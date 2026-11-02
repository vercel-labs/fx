---- MODULE Era ----
\* U04 version detection, client side, one server process at a time.
\* Rules: VER-01, VER-02, VER-03, VER-05 to VER-09, WIRE-03. VER-04 (HTTP
\* mechanics) maps HTTP replies onto these same events in U06.
\* It also models which modern errors are recognized, a -32022 that names
\* only the legacy version, the probe timeout, an error with no id during the
\* probe, 2025-11-25 as the only legacy version, one era per process,
\* initialize answered with another version, and one fall forward after a
\* modern server rejects initialize.
\*
\* The server is the environment and may answer anything: a DiscoverResult
\* listing any versions, an error with any code (for -32022, with any supported
\* list), an error without an id, or nothing, so the probe times out. It may
\* answer initialize with a result naming any version, or an error that may
\* carry a modern hint. The client has at most one detection request pending,
\* and a late answer to an abandoned probe is ignored by the request table (U02).
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Preferred,     \* modern versions in the client's order of preference
    Legacy,        \* the one legacy version
    Other,         \* versions only servers know
    MaxProcesses

\* Values for the configs, which can't write sequences.
SmokePreferred == <<"m1", "m2">>
StressPreferred == <<"m1", "m2", "m3">>

ModernVersions == {Preferred[k] : k \in 1..Len(Preferred)}
Versions == ModernVersions \cup {Legacy} \cup Other
States == {"unknown", "probing", "initializing", "modern", "legacy", "failed"}
Ready == {"modern", "legacy"}

ASSUME Len(Preferred) > 0 /\ Legacy \notin ModernVersions /\ MaxProcesses \in Nat \ {0}

VARIABLES
    state,         \* where detection is for the current process
    version,       \* the probe's version, the chosen version, or Legacy
    tried,         \* [ModernVersions -> 0..2]: probes sent per version, this process
    pending,       \* the detection request in flight: "none", "discover", "initialize"
    advertised,    \* versions the server last listed (discover or -32022)
    process,       \* the server process generation
    lastMeta,      \* the version an operation request last carried, "none", or "unset"
    \* Ghost variables for the safety properties.
    modernSeen,    \* this process answered like a modern server
    processEra,    \* the first ready era of this process, or "none"
    flipped,       \* this process became ready in both eras
    initializedSent, \* notifications/initialized sent, this process
    badFallback,   \* initialize sent after a modern answer that didn't list Legacy
    earlyOp,       \* an operation request sent before detection finished
    unlisted       \* modern without discovery: the server never listed its versions

vars == <<state, version, tried, pending, advertised, process, lastMeta,
          modernSeen, processEra, flipped, initializedSent, badFallback, earlyOp, unlisted>>

ghosts == <<modernSeen, processEra, flipped, initializedSent, badFallback, earlyOp, unlisted>>

Init ==
    /\ state = "unknown"
    /\ version = "none"
    /\ tried = [v \in ModernVersions |-> 0]
    /\ pending = "none"
    /\ advertised = {}
    /\ process = 0
    /\ lastMeta = "unset"
    /\ modernSeen = FALSE
    /\ processEra = "none"
    /\ flipped = FALSE
    /\ initializedSent = 0
    /\ badFallback = FALSE
    /\ earlyOp = FALSE
    /\ unlisted = FALSE

\* The first preferred version in s not yet tried; else the current version,
\* tried once, if s lists it (a server that rejects a version it claims to
\* support gets one retry); else "none".
NextCandidate(s) ==
    LET untried == {k \in 1..Len(Preferred) : Preferred[k] \in s /\ tried[Preferred[k]] = 0}
    IN IF untried # {}
          THEN Preferred[CHOOSE k \in untried : \A j \in untried : k <= j]
       ELSE IF version \in ModernVersions /\ version \in s /\ tried[version] = 1
          THEN version
       ELSE "none"

\* The first preferred version in s, or "none".
FirstShared(s) ==
    LET shared == {k \in 1..Len(Preferred) : Preferred[k] \in s}
    IN IF shared = {} THEN "none" ELSE Preferred[CHOOSE k \in shared : \A j \in shared : k <= j]

Probe(v) ==
    /\ state' = "probing"
    /\ version' = v
    /\ tried' = [tried EXCEPT ![v] = @ + 1]
    /\ pending' = "discover"

\* Fall back to initialize (VER-03). After a modern answer that is allowed only
\* when the server listed the legacy version.
StartInitialize(sawModern, listed) ==
    /\ state' = "initializing"
    /\ version' = Legacy
    /\ pending' = "initialize"
    /\ badFallback' = (badFallback \/ (sawModern /\ Legacy \notin listed))
    /\ UNCHANGED tried

Fail ==
    /\ state' = "failed"
    /\ pending' = "none"
    /\ UNCHANGED <<version, tried>>

BecomeReady(era) ==
    /\ processEra' = IF processEra = "none" THEN era ELSE processEra
    /\ flipped' = (flipped \/ (processEra # "none" /\ processEra # era))

\* Environment: a new server process starts (the first, or a restart).
ProcessStarted ==
    /\ process < MaxProcesses
    /\ process' = process + 1
    /\ state' = "unknown"
    /\ version' = "none"
    /\ tried' = [v \in ModernVersions |-> 0]
    /\ pending' = "none"
    /\ advertised' = {}
    /\ lastMeta' = "unset"
    /\ modernSeen' = FALSE
    /\ processEra' = "none"
    /\ initializedSent' = 0
    /\ unlisted' = FALSE
    /\ UNCHANGED <<flipped, badFallback, earlyOp>>

\* The client starts detection with its most preferred version (VER-02, VER-03).
DetectRequested ==
    /\ state = "unknown"
    /\ process > 0
    /\ Probe(Preferred[1])
    /\ UNCHANGED <<advertised, process, lastMeta, ghosts>>

DiscoverResult(s) ==
    /\ pending = "discover"
    /\ advertised' = s
    /\ modernSeen' = TRUE
    /\ LET chosen == FirstShared(s)
       IN IF chosen # "none"
             THEN /\ state' = "modern" /\ version' = chosen /\ pending' = "none"
                  /\ BecomeReady("modern") /\ UNCHANGED <<tried, badFallback>>
          ELSE IF Legacy \in s
             THEN StartInitialize(TRUE, s) /\ UNCHANGED <<processEra, flipped>>
          ELSE Fail /\ UNCHANGED <<processEra, flipped, badFallback>>
    /\ unlisted' = FALSE
    /\ UNCHANGED <<process, lastMeta, initializedSent, earlyOp>>

\* -32022 (VER-01): retry with a shared version, else the legacy version if
\* listed, else fail.
UnsupportedVersion(s) ==
    /\ pending = "discover"
    /\ advertised' = s
    /\ modernSeen' = TRUE
    /\ LET next == NextCandidate(s)
       IN IF next # "none"
             THEN Probe(next) /\ UNCHANGED badFallback
          ELSE IF Legacy \in s
             THEN StartInitialize(TRUE, s)
          ELSE Fail /\ UNCHANGED badFallback
    /\ unlisted' = FALSE
    /\ UNCHANGED <<process, lastMeta, processEra, flipped, initializedSent, earlyOp>>

\* -32020 or -32021: a modern server that won't serve this client.
ModernRejection ==
    /\ pending = "discover"
    /\ modernSeen' = TRUE
    /\ Fail
    /\ UNCHANGED <<advertised, process, lastMeta, processEra, flipped, initializedSent, badFallback, earlyOp, unlisted>>

\* Any other error, an error without an id, or no answer in time:
\* the server is legacy, unless it already answered like a modern server in
\* this process. Then it is a modern server that stopped answering, and only
\* a listed legacy version allows initialize (VER-03).
LegacyAnswer ==
    /\ pending = "discover"
    /\ IF modernSeen /\ Legacy \notin advertised
          THEN Fail /\ UNCHANGED badFallback
          ELSE StartInitialize(modernSeen, advertised)
    /\ UNCHANGED <<advertised, process, lastMeta, modernSeen, processEra, flipped, initializedSent, earlyOp, unlisted>>

ProbeTimedOut == LegacyAnswer

\* HTTP only: a 404 with -32601 to server/discover is a modern server
\* that doesn't implement discovery. It is served with the probe's version;
\* a -32022 to a later request corrects it (OperationVersionRejected).
DiscoverNotImplemented ==
    /\ pending = "discover"
    /\ state' = "modern"
    /\ pending' = "none"
    /\ modernSeen' = TRUE
    /\ unlisted' = TRUE
    /\ BecomeReady("modern")
    /\ UNCHANGED <<version, tried, advertised, process, lastMeta, initializedSent, badFallback, earlyOp>>

\* VER-07, VER-09: the legacy version is accepted and initialized sent;
\* any other version ends detection.
InitializeResult(v) ==
    /\ pending = "initialize"
    /\ IF v = Legacy
          THEN /\ state' = "legacy" /\ version' = v /\ pending' = "none" /\ initializedSent' = initializedSent + 1
               /\ BecomeReady("legacy") /\ UNCHANGED tried
          ELSE Fail /\ UNCHANGED <<initializedSent, processEra, flipped>>
    /\ UNCHANGED <<advertised, process, lastMeta, modernSeen, badFallback, earlyOp, unlisted>>

\* Initialize rejected with a modern hint (a recognized modern error, or a
\* supported list naming a preferred version) means a modern server that missed
\* the probe, for example one still starting up. Probe once more; otherwise fail.
InitializeError(hint) ==
    /\ pending = "initialize"
    \* Detection always starts with Preferred[1], so its two-probe limit allows
    \* exactly one fall forward.
    /\ IF hint /\ tried[Preferred[1]] < 2
          THEN Probe(Preferred[1]) /\ modernSeen' = TRUE
          ELSE Fail /\ UNCHANGED modernSeen
    /\ UNCHANGED <<advertised, process, lastMeta, processEra, flipped, initializedSent, badFallback, earlyOp, unlisted>>

\* The initialize request ended without an answer (its U02 timeout).
InitializeTimedOut ==
    /\ pending = "initialize"
    /\ Fail
    /\ UNCHANGED <<advertised, process, lastMeta, modernSeen, processEra, flipped, initializedSent, badFallback, earlyOp, unlisted>>

\* The version each operation request carries (WIRE-03): the chosen version on
\* a modern server, none on a legacy one.
MetaFor == IF state = "modern" THEN version ELSE "none"

\* An operation request (anything but detection) goes out.
OperationSent ==
    /\ state \in Ready
    /\ lastMeta' = MetaFor
    /\ earlyOp' = (earlyOp \/ state \notin Ready)
    /\ UNCHANGED <<state, version, tried, pending, advertised, process,
                   modernSeen, processEra, flipped, initializedSent, badFallback, unlisted>>

\* VER-01 after detection: an operation request got -32022. Switch to another
\* shared modern version, else fail; never switch eras mid-process (VER-05).
OperationVersionRejected(s) ==
    /\ state = "modern"
    /\ advertised' = s
    /\ LET next == NextCandidate(s)
       IN IF next # "none"
             THEN /\ version' = next /\ tried' = [tried EXCEPT ![next] = @ + 1]
                  /\ lastMeta' = "unset" /\ UNCHANGED <<state, pending>>
          ELSE Fail /\ UNCHANGED lastMeta
    /\ unlisted' = FALSE
    /\ UNCHANGED <<process, modernSeen, processEra, flipped, initializedSent, badFallback, earlyOp>>

Next ==
    \/ ProcessStarted
    \/ DetectRequested
    \/ \E s \in SUBSET Versions: DiscoverResult(s) \/ UnsupportedVersion(s) \/ OperationVersionRejected(s)
    \/ ModernRejection
    \/ LegacyAnswer
    \/ DiscoverNotImplemented
    \/ \E v \in Versions: InitializeResult(v)
    \/ \E hint \in BOOLEAN: InitializeError(hint)
    \/ InitializeTimedOut
    \/ OperationSent

\* Time: a probe and an initialize request always end (U02 timeouts).
Spec == Init /\ [][Next]_vars /\ WF_vars(ProbeTimedOut) /\ WF_vars(InitializeTimedOut)

TypeOK ==
    /\ state \in States
    /\ version \in Versions \cup {"none"}
    /\ tried \in [ModernVersions -> Nat]
    /\ pending \in {"none", "discover", "initialize"}
    /\ advertised \subseteq Versions
    /\ process \in 0..MaxProcesses
    /\ lastMeta \in Versions \cup {"none", "unset"}
    /\ modernSeen \in BOOLEAN
    /\ processEra \in {"none", "modern", "legacy"}
    /\ flipped \in BOOLEAN
    /\ initializedSent \in 0..1
    /\ badFallback \in BOOLEAN
    /\ earlyOp \in BOOLEAN
    /\ unlisted \in BOOLEAN

\* VER-03: one detection request in flight at a time (`pending` holds one),
\* and each version is probed at most twice per process: once, plus one retry
\* when the server rejects a version it lists.
ProbesBounded == \A v \in ModernVersions: tried[v] <= 2

\* VER-05: a process is served in one era only.
EraSticky == ~flipped

\* VER-03: no fallback to initialize after a modern answer, unless the
\* server listed the legacy version.
NoFallbackAfterModern == ~badFallback

\* VER-06 to VER-08: no operation request before detection finishes, and a
\* legacy process sent notifications/initialized exactly once.
LegacyOrder ==
    /\ ~earlyOp
    /\ state = "legacy" => initializedSent = 1

\* VER-01, VER-09: the version in use is one both sides support.
ChosenSupported ==
    /\ state = "modern" => version \in ModernVersions /\ (version \in advertised \/ unlisted)
    /\ state = "legacy" => version = Legacy

\* WIRE-03: modern operation requests carry the version in use, legacy ones none.
VersionOnEveryRequest ==
    /\ state = "modern" => lastMeta \in {"unset", version}
    /\ state = "legacy" => lastMeta \in {"unset", "none"}

\* Detection always ends.
ReachesEra == state \in {"probing", "initializing"} ~> state \in {"modern", "legacy", "failed", "unknown"}
====

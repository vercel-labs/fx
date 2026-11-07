------------------------------ MODULE TlsRoots ------------------------------
(***************************************************************************)
(* How fx loads the trusted roots for an HTTPS client                      *)
(* (src/core/shared/tls_roots.zig `prepare` and `load`), and the clients   *)
(* that must use it.                                                       *)
(*                                                                         *)
(* A client starts with no clock (std.http.Client.now is null) and an      *)
(* empty bundle. Each request on it checks the clock under the bundle lock *)
(* (Check). When the clock is unset, the request scans the system's roots  *)
(* into a bundle of its own (Scan), then takes the lock exclusively and    *)
(* installs that bundle together with the clock, unless another request    *)
(* installed one first (Install). Only then does it start the TLS          *)
(* handshake with the client's bundle (Handshake).                         *)
(*                                                                         *)
(* On macOS std's scan reads two keychain files in order and stops at the  *)
(* first that fails. When it stopped on a permission error, the loader     *)
(* drops what the scan read and loads /etc/ssl/cert.pem instead; that file *)
(* unreadable, or holding no roots, fails. Any other scan error fails, and *)
(* so does every error on other systems, where std reads the system's own *)
(* bundle files (modeled by the same two files).                           *)
(*                                                                         *)
(* The file system is chosen once, at the start: each keychain file reads, *)
(* is denied, or is broken (any other read or parse error), and the public *)
(* bundle holds roots, is empty, is denied, or is missing.                 *)
(*                                                                         *)
(* Rule picks the loader. "fixed" is the design. "today" is fx before it,  *)
(* where every scan error failed the request. The others each plant one   *)
(* defect, named in check.sh. Skips names clients that keep std's own scan *)
(* instead of calling the loader, which is today's rule for them.         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    OSes,       \* systems to explore: "macos", "linux"
    Sites,      \* HTTPS clients, such as "pool" and "mcp"
    Skips,      \* clients that do not call the loader (planted defect)
    Requests,   \* concurrent requests per client
    Rule        \* "fixed", "today", or a planted defect

Files == {"roots", "system"}
FileStates == {"ok", "denied", "broken"}
BundleStates == {"roots", "empty", "denied", "missing"}
Threads == Sites \X Requests
None == <<"none", 0>>
Done == {"tls", "failed"}

VARIABLES
    os,         \* the system fx runs on
    keychain,   \* [Files -> FileStates]: how each scanned file reads
    pem,        \* how /etc/ssl/cert.pem reads
    clock,      \* [Sites -> BOOLEAN]: the client's clock is set
    bundle,     \* [Sites -> SUBSET sources]: what the client's bundle holds
    owner,      \* [Sites -> Threads \cup {None}]: the request that installed it
    pc,         \* [Threads -> stage]
    local,      \* [Threads -> SUBSET sources]: the bundle a request loaded
    seen        \* [Threads -> SUBSET sources]: the bundle a handshake used

vars == <<os, keychain, pem, clock, bundle, owner, pc, local, seen>>

Site(t) == t[1]

\* Where the scan stops: the state of the first file that does not read,
\* "none" when both read. std reads the root certificates file first.
StopAt == IF keychain["roots"] # "ok" THEN keychain["roots"]
          ELSE IF keychain["system"] # "ok" THEN keychain["system"]
          ELSE "none"

\* What the scan read before it stopped.
Partial == IF keychain["roots"] # "ok" THEN {}
           ELSE IF keychain["system"] # "ok" THEN {"roots"}
           ELSE {"roots", "system"}

\* The roots fx can trust here: the whole scan, or on macOS after a denied
\* scan the public bundle when it holds roots.
RootsAvailable ==
    \/ StopAt = "none"
    \/ os = "macos" /\ StopAt = "denied" /\ pem = "roots"

LoaderOf(s) == IF s \in Skips THEN "today" ELSE Rule

FallsBack(rule) ==
    /\ rule # "today"
    /\ os = "macos" \/ rule = "any_os"
    /\ StopAt = "denied" \/ (rule = "any_error" /\ StopAt = "broken")

\* The bundle the fallback builds. "keep_partial" adds the public bundle to
\* the partial scan instead of replacing it.
FallbackBundle(rule) ==
    (IF rule = "keep_partial" THEN Partial ELSE {})
        \cup (IF pem = "roots" THEN {"pem"} ELSE {})

FallbackFails(rule) ==
    \/ pem \in {"denied", "missing"}
    \/ FallbackBundle(rule) = {} /\ rule # "accept_empty"

InitWith(system, files, public) ==
    /\ os = system
    /\ keychain = files
    /\ pem = public
    /\ clock = [s \in Sites |-> FALSE]
    /\ bundle = [s \in Sites |-> {}]
    /\ owner = [s \in Sites |-> None]
    /\ pc = [t \in Threads |-> "idle"]
    /\ local = [t \in Threads |-> {}]
    /\ seen = [t \in Threads |-> {}]

Init == \E o \in OSes, f \in [Files -> FileStates], p \in BundleStates : InitWith(o, f, p)

\* InitWith as a step, so TlsRootsTrace.tla can start the next run.
ResetTo(system, files, public) ==
    /\ os' = system
    /\ keychain' = files
    /\ pem' = public
    /\ clock' = [s \in Sites |-> FALSE]
    /\ bundle' = [s \in Sites |-> {}]
    /\ owner' = [s \in Sites |-> None]
    /\ pc' = [t \in Threads |-> "idle"]
    /\ local' = [t \in Threads |-> {}]
    /\ seen' = [t \in Threads |-> {}]

\* Under the shared lock: a set clock means the roots are installed.
Check(t) ==
    /\ pc[t] = "idle"
    /\ pc' = [pc EXCEPT ![t] = IF clock[Site(t)] THEN "ready" ELSE "scan"]
    /\ UNCHANGED <<os, keychain, pem, clock, bundle, owner, local, seen>>

Scan(t) ==
    LET rule == LoaderOf(Site(t)) IN
    /\ pc[t] = "scan"
    /\ CASE StopAt = "none" ->
              /\ local' = [local EXCEPT ![t] = {"roots", "system"}]
              /\ pc' = [pc EXCEPT ![t] = "install"]
         [] FallsBack(rule) /\ ~FallbackFails(rule) ->
              /\ local' = [local EXCEPT ![t] = FallbackBundle(rule)]
              /\ pc' = [pc EXCEPT ![t] = "install"]
         [] OTHER ->
              /\ pc' = [pc EXCEPT ![t] = "failed"]
              /\ UNCHANGED local
    /\ UNCHANGED <<os, keychain, pem, clock, bundle, owner, seen>>

\* Under the exclusive lock: the clock and the bundle go in together, once.
Install(t) ==
    LET s == Site(t) IN
    /\ pc[t] = "install"
    /\ LoaderOf(s) # "clock_first"
    /\ IF clock[s]
         THEN UNCHANGED <<clock, bundle, owner>>
         ELSE /\ clock' = [clock EXCEPT ![s] = TRUE]
              /\ bundle' = [bundle EXCEPT ![s] = local[t]]
              /\ owner' = [owner EXCEPT ![s] = t]
    /\ pc' = [pc EXCEPT ![t] = "ready"]
    /\ UNCHANGED <<os, keychain, pem, local, seen>>

\* Planted: the clock is set in one step and the bundle swapped in later.
SetClock(t) ==
    LET s == Site(t) IN
    /\ pc[t] = "install"
    /\ LoaderOf(s) = "clock_first"
    /\ clock' = [clock EXCEPT ![s] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "swap"]
    /\ UNCHANGED <<os, keychain, pem, bundle, owner, local, seen>>

Swap(t) ==
    LET s == Site(t) IN
    /\ pc[t] = "swap"
    /\ bundle' = [bundle EXCEPT ![s] = local[t]]
    /\ owner' = [owner EXCEPT ![s] = t]
    /\ pc' = [pc EXCEPT ![t] = "ready"]
    /\ UNCHANGED <<os, keychain, pem, clock, local, seen>>

Handshake(t) ==
    /\ pc[t] = "ready"
    /\ seen' = [seen EXCEPT ![t] = bundle[Site(t)]]
    /\ pc' = [pc EXCEPT ![t] = "tls"]
    /\ UNCHANGED <<os, keychain, pem, clock, bundle, owner, local>>

Finished == \A t \in Threads : pc[t] \in Done

Next ==
    \/ \E t \in Threads : Check(t) \/ Scan(t) \/ Install(t) \/ SetClock(t) \/ Swap(t) \/ Handshake(t)
    \/ Finished /\ UNCHANGED vars

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

-----------------------------------------------------------------------------
Sources == {"roots", "system", "pem"}
Stages == {"idle", "scan", "install", "swap", "ready", "tls", "failed"}

TypeOK ==
    /\ os \in OSes
    /\ keychain \in [Files -> FileStates]
    /\ pem \in BundleStates
    /\ clock \in [Sites -> BOOLEAN]
    /\ bundle \in [Sites -> SUBSET Sources]
    /\ owner \in [Sites -> Threads \cup {None}]
    /\ pc \in [Threads -> Stages]
    /\ local \in [Threads -> SUBSET Sources]
    /\ seen \in [Threads -> SUBSET Sources]

\* A loaded bundle is the whole scan or the public bundle alone, never part
\* of a scan.
OneSource == \A t \in Threads : local[t] \in {{}, {"roots", "system"}, {"pem"}}

\* The public bundle stands in only after a denied scan on macOS.
FallbackOnlyOnDenial ==
    \A t \in Threads : "pem" \in local[t] => (os = "macos" /\ StopAt = "denied")

\* An installed bundle is never empty: fail closed.
InstalledNotEmpty == \A s \in Sites : owner[s] # None => bundle[s] # {}

\* No handshake starts without roots to check the server against.
HandshakeHasRoots == \A t \in Threads : pc[t] = "tls" => seen[t] # {}

\* With no trusted roots to read, every request fails before it connects.
FailsWithoutRoots == ~RootsAvailable => \A t \in Threads : pc[t] # "tls"

\* The bug: with roots fx can read, no request fails to load them.
NoFailureWhileRootsReadable == RootsAvailable => \A t \in Threads : pc[t] # "failed"

\* Every request ends, with a handshake or a failure.
EveryRequestEnds == <>Finished
=============================================================================

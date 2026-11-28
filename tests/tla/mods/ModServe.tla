------------------------------ MODULE ModServe ------------------------------
(***************************************************************************)
(* Models the MCP servers that a running fx starts from its mods while     *)
(* other fx processes change the mod store (src/core/mods/store.zig). The  *)
(* code is Runtime.PinTracker in src/core/mcp_host/runtime.zig, and        *)
(* serve-walk in tests/tla/drivers/mods/driver.ts drives it along this     *)
(* model.                                                                  *)
(*                                                                         *)
(* It builds on ModUse.tla, which proves the pin protocol: a reader pins   *)
(* the version that the link names and checks that the folder is still    *)
(* there. Here that pin is one step. One mod with one stdio server.        *)
(*                                                                         *)
(* Readers 1..NR are fx processes, and each runs its own copy of the       *)
(* server: no shared owner. A server runs from the version that its        *)
(* reader's server list came from. When the link names a new version, the  *)
(* reader pins it and its live server retires: the old server drains its   *)
(* calls and exits, and a new one can start from the new version. A reader *)
(* keeps a version's pin while its list or any server of its own uses it,  *)
(* counted per server. A normal exit stops every server first. A crash     *)
(* drops the reader's pins at once, and fx's helper stops its servers soon *)
(* after; those dying servers can find their files gone, which the design  *)
(* accepts (mods-serve-crash-window.cfg shows it).                         *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS NR, MaxVersion, MaxRetire, Bug

ASSUME NR \in Nat /\ NR >= 1 /\ MaxVersion \in Nat /\ MaxVersion >= 1
ASSUME MaxRetire \in Nat /\ MaxRetire >= 1
ASSUME Bug \in {"none", "release_on_reload", "release_on_first_exit", "outlives_reader", "no_restart"}

Readers == 1..NR
Versions == 1..MaxVersion
None == 0

VARIABLES
    link,      \* the version the mod's link names, or None with no mod installed
    present,   \* the version folders on disk
    latest,    \* the newest version a change installed
    pins,      \* pins[v]: the readers that hold a shared lock on version v
    up,        \* up[r]: reader r runs
    loaded,    \* loaded[r]: the version that reader r's server list came from
    serving,   \* serving[r]: the version reader r's live server runs from
    retiring,  \* retiring[r][v]: reader r's servers from v that drain, then exit
    orphans,   \* versions of servers that run on after their reader ended
    dying      \* versions of servers that fx's helper stops after a crash

vars == <<link, present, latest, pins, up, loaded, serving, retiring, orphans, dying>>

TypeOK ==
    /\ link \in {None} \cup Versions
    /\ present \subseteq Versions
    /\ latest \in Versions
    /\ pins \in [Versions -> SUBSET Readers]
    /\ up \in [Readers -> BOOLEAN]
    /\ loaded \in [Readers -> {None} \cup Versions]
    /\ serving \in [Readers -> {None} \cup Versions]
    /\ retiring \in [Readers -> [Versions -> 0..MaxRetire]]
    /\ orphans \subseteq Versions
    /\ dying \subseteq Versions

NoRetiring == [v \in Versions |-> 0]

Init ==
    /\ link = 1
    /\ present = {1}
    /\ latest = 1
    /\ pins = [v \in Versions |-> {}]
    /\ up = [r \in Readers |-> FALSE]
    /\ loaded = [r \in Readers |-> None]
    /\ serving = [r \in Readers |-> None]
    /\ retiring = [r \in Readers |-> NoRetiring]
    /\ orphans = {}
    /\ dying = {}

\* The versions that reader r's own servers run from.
ServedBy(r) ==
    {v \in Versions : retiring[r][v] > 0} \cup (IF serving[r] = None THEN {} ELSE {serving[r]})

\* pins with reader r's lock on version v dropped.
Unpin(p, r, v) == IF v = None THEN p ELSE [p EXCEPT ![v] = @ \ {r}]

\* Every lock of reader r dropped, as the OS does when its process ends.
UnpinAll(p, r) == [v \in Versions |-> p[v] \ {r}]

----------------------------------------------------------------------------
(* Changes and cleanup, as in ModUse.tla. *)

Install ==
    /\ latest < MaxVersion
    /\ present' = present \cup {latest + 1}
    /\ latest' = latest + 1
    /\ link' = latest + 1
    /\ UNCHANGED <<pins, up, loaded, serving, retiring, orphans, dying>>

Remove ==
    /\ link # None
    /\ link' = None
    /\ UNCHANGED <<present, latest, pins, up, loaded, serving, retiring, orphans, dying>>

\* Cleanup's exclusive try-lock fails on a pinned version.
Cleanup(v) ==
    /\ v \in present
    /\ v # link
    /\ pins[v] = {}
    /\ present' = present \ {v}
    /\ UNCHANGED <<link, latest, pins, up, loaded, serving, retiring, orphans, dying>>

----------------------------------------------------------------------------
(* Readers and their servers. *)

Start(r) ==
    /\ ~up[r]
    /\ up' = [up EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<link, present, latest, pins, loaded, serving, retiring, orphans, dying>>

\* The reader loads the server list of the version that the link names now
\* (a pin, as ModUse.tla proves), and its live server retires. The old
\* list's pin goes now unless a server of the reader still runs from it.
Reload(r) ==
    /\ up[r]
    /\ link # loaded[r]
    /\ ~(Bug = "no_restart" /\ loaded[r] # None)
    /\ serving[r] # None => retiring[r][serving[r]] < MaxRetire
    /\ LET old == loaded[r]
           p1 == IF link = None THEN pins ELSE [pins EXCEPT ![link] = @ \cup {r}]
           ret == IF serving[r] = None THEN retiring[r]
                  ELSE [retiring[r] EXCEPT ![serving[r]] = @ + 1]
           still_used == old # None /\ ret[old] > 0
       IN /\ pins' = IF old = None \/ (still_used /\ Bug # "release_on_reload")
                     THEN p1 ELSE Unpin(p1, r, old)
          /\ retiring' = [retiring EXCEPT ![r] = ret]
    /\ loaded' = [loaded EXCEPT ![r] = link]
    /\ serving' = [serving EXCEPT ![r] = None]
    /\ UNCHANGED <<link, present, latest, up, orphans, dying>>

\* A server starts from the version that the reader's list came from.
StartServer(r) ==
    /\ up[r]
    /\ loaded[r] # None
    /\ serving[r] = None
    /\ retiring[r][loaded[r]] < MaxRetire
    /\ serving' = [serving EXCEPT ![r] = loaded[r]]
    /\ UNCHANGED <<link, present, latest, pins, up, loaded, retiring, orphans, dying>>

\* fx stops its live server, for example when you turn the server off.
StopServer(r) ==
    /\ serving[r] # None
    /\ retiring' = [retiring EXCEPT ![r][serving[r]] = @ + 1]
    /\ serving' = [serving EXCEPT ![r] = None]
    /\ UNCHANGED <<link, present, latest, pins, up, loaded, orphans, dying>>

\* A retiring server exits. The version's pin goes when the last server of
\* the reader that runs from it has exited and the reader's list no longer
\* comes from it.
RetireDone(r, v) ==
    /\ retiring[r][v] > 0
    /\ retiring' = [retiring EXCEPT ![r][v] = @ - 1]
    /\ LET last == retiring[r][v] = 1 \/ Bug = "release_on_first_exit"
       IN pins' = IF last /\ v # loaded[r] /\ v # serving[r] THEN Unpin(pins, r, v) ELSE pins
    /\ UNCHANGED <<link, present, latest, up, loaded, serving, orphans, dying>>

\* A normal exit: fx stops its servers and waits for them before it ends,
\* and then the OS drops its locks. With bug outlives_reader, the servers run
\* on without a pin, as a shared owner process would.
Exit(r) ==
    /\ up[r]
    /\ Bug # "outlives_reader" => ServedBy(r) = {}
    /\ up' = [up EXCEPT ![r] = FALSE]
    /\ pins' = UnpinAll(pins, r)
    /\ orphans' = orphans \cup ServedBy(r)
    /\ loaded' = [loaded EXCEPT ![r] = None]
    /\ serving' = [serving EXCEPT ![r] = None]
    /\ retiring' = [retiring EXCEPT ![r] = NoRetiring]
    /\ UNCHANGED <<link, present, latest, dying>>

OrphanDone(v) ==
    /\ v \in orphans
    /\ orphans' = orphans \ {v}
    /\ UNCHANGED <<link, present, latest, pins, up, loaded, serving, retiring, dying>>

\* A crash: the OS drops the reader's locks at once, and fx's helper stops
\* the reader's servers within its grace period.
Crash(r) ==
    /\ up[r]
    /\ up' = [up EXCEPT ![r] = FALSE]
    /\ pins' = UnpinAll(pins, r)
    /\ dying' = dying \cup ServedBy(r)
    /\ loaded' = [loaded EXCEPT ![r] = None]
    /\ serving' = [serving EXCEPT ![r] = None]
    /\ retiring' = [retiring EXCEPT ![r] = NoRetiring]
    /\ UNCHANGED <<link, present, latest, orphans>>

DyingDone(v) ==
    /\ v \in dying
    /\ dying' = dying \ {v}
    /\ UNCHANGED <<link, present, latest, pins, up, loaded, serving, retiring, orphans>>

Next ==
    \/ Install
    \/ Remove
    \/ \E v \in Versions : Cleanup(v) \/ OrphanDone(v) \/ DyingDone(v)
    \/ \E r \in Readers :
        \/ Start(r) \/ Reload(r) \/ StartServer(r) \/ StopServer(r)
        \/ Exit(r) \/ Crash(r)
        \/ \E v \in Versions : RetireDone(r, v)

\* A reader reloads when the link moves, retiring servers exit (fx kills one
\* that does not, after a deadline), and cleanup runs when it can.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ \A r \in Readers :
        /\ WF_vars(Reload(r))
        /\ \A v \in Versions : WF_vars(RetireDone(r, v))
    /\ \A v \in Versions : WF_vars(Cleanup(v)) /\ WF_vars(OrphanDone(v)) /\ WF_vars(DyingDone(v))

----------------------------------------------------------------------------
(* Rules. *)

LinkedVersionPresent == link # None => link \in present

\* A reader's server list comes from a version it holds.
ListPinned == \A r \in Readers : loaded[r] # None => r \in pins[loaded[r]]

\* Every server of a running reader runs from a version the reader holds.
ServersPinned == \A r \in Readers : \A v \in ServedBy(r) : r \in pins[v]

\* No live or retiring server, and no server that runs on after its reader,
\* finds its mod's folder gone.
ServersFindFiles ==
    /\ \A r \in Readers : ServedBy(r) \subseteq present
    /\ orphans \subseteq present

\* Fails on purpose: after a crash, a dying server can lose its files.
DyingFindsFiles == dying \subseteq present

\* A running reader moves to the version that the link names.
ServesCurrent ==
    \A r \in Readers : (up[r] /\ loaded[r] # link) ~> (~up[r] \/ loaded[r] = link)

\* A version that no link names is deleted in the end.
UnusedVersionsGo ==
    \A v \in Versions : (v \in present /\ v # link) ~> (v \notin present)

=============================================================================

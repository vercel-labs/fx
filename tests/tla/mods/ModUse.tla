------------------------------- MODULE ModUse -------------------------------
(***************************************************************************)
(* Models how a running fx reads an installed mod while other fx processes *)
(* change the mod store (src/core/mods/store.zig). Not landed yet: design  *)
(* "link" is how PR 2's loaders read; design "pin" is planned for the mod  *)
(* skills, profiles and MCP servers in src/core/mods/.                     *)
(*                                                                         *)
(* One mod. A change installs the next version (a copy, then one switch of *)
(* the link, which ModStore.tla proves atomic) or removes the mod. Cleanup *)
(* deletes a version folder that no link names, right after a change or    *)
(* any time later.                                                         *)
(*                                                                         *)
(* Readers 1..NR are running fx processes. A reader loads the mod (its     *)
(* skill index, its profiles, its MCP server list), later uses the mod's   *)
(* files (a skill's SKILL.md, a profile's prompt.md, an MCP server that    *)
(* runs in the mod's folder for as long as it lives), and reloads when the *)
(* link names a new version: MCP servers, skills and profiles reload live. *)
(*                                                                         *)
(* Design "link" reads every file through the link. Design "pin" resolves  *)
(* the link once, takes a shared lock on that version, checks that the     *)
(* version is still there, and reads only that version. A reload pins the  *)
(* new version before it lets the old one go. Cleanup takes an exclusive   *)
(* try-lock, so it skips a pinned version. The OS drops the locks of a     *)
(* reader that exits or crashes.                                           *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS NR, MaxVersion, Design, Bug

ASSUME NR \in Nat /\ NR >= 1 /\ MaxVersion \in Nat /\ MaxVersion >= 1
ASSUME Design \in {"link", "pin"}
ASSUME Bug \in {"none", "cleanup_ignores_pins", "no_check", "keeps_old_pin", "no_reload"}

Readers == 1..NR
Versions == 1..MaxVersion
None == 0
Phases == {"off", "resolve", "lock", "check", "ready", "using"}

VARIABLES
    link,     \* the version the mod's link names, or None with no mod installed
    present,  \* the version folders on disk
    latest,   \* the newest version a change installed
    pins,     \* pins[v]: the readers that hold a shared lock on version v
    rpc,      \* each reader's phase
    want,     \* the version a reader read from the link and is about to pin
    loaded,   \* the version a reader's index and config came from
    held      \* the version folder that a reader's current use reads

vars == <<link, present, latest, pins, rpc, want, loaded, held>>

Pinning == Design = "pin"

TypeOK ==
    /\ link \in {None} \cup Versions
    /\ present \subseteq Versions
    /\ latest \in Versions
    /\ pins \in [Versions -> SUBSET Readers]
    /\ rpc \in [Readers -> Phases]
    /\ want \in [Readers -> {None} \cup Versions]
    /\ loaded \in [Readers -> {None} \cup Versions]
    /\ held \in [Readers -> {None} \cup Versions]

Init ==
    /\ link = 1
    /\ present = {1}
    /\ latest = 1
    /\ pins = [v \in Versions |-> {}]
    /\ rpc = [r \in Readers |-> "off"]
    /\ want = [r \in Readers |-> None]
    /\ loaded = [r \in Readers |-> None]
    /\ held = [r \in Readers |-> None]

\* pins without reader r's lock on version v.
Unpin(p, r, v) == IF v = None THEN p ELSE [p EXCEPT ![v] = @ \ {r}]

----------------------------------------------------------------------------
(* Changes and cleanup. *)

Install ==
    /\ latest < MaxVersion
    /\ present' = present \cup {latest + 1}
    /\ latest' = latest + 1
    /\ link' = latest + 1
    /\ UNCHANGED <<pins, rpc, want, loaded, held>>

Remove ==
    /\ link # None
    /\ link' = None
    /\ UNCHANGED <<present, latest, pins, rpc, want, loaded, held>>

\* With pins, cleanup's exclusive try-lock fails on a pinned version.
Cleanup(v) ==
    /\ v \in present
    /\ v # link
    /\ (Pinning /\ Bug # "cleanup_ignores_pins") => pins[v] = {}
    /\ present' = present \ {v}
    /\ UNCHANGED <<link, latest, pins, rpc, want, loaded, held>>

----------------------------------------------------------------------------
(* Readers. *)

Start(r) ==
    /\ rpc[r] = "off"
    /\ rpc' = [rpc EXCEPT ![r] = "resolve"]
    /\ UNCHANGED <<link, present, latest, pins, want, loaded, held>>

\* Reads the link. With no mod installed the reader drops what it loaded.
Resolve(r) ==
    /\ rpc[r] = "resolve"
    /\ IF link = None
       THEN /\ pins' = IF Pinning /\ Bug # "keeps_old_pin" THEN Unpin(pins, r, loaded[r]) ELSE pins
            /\ loaded' = [loaded EXCEPT ![r] = None]
            /\ rpc' = [rpc EXCEPT ![r] = "ready"]
            /\ UNCHANGED want
       ELSE IF Pinning
            THEN /\ want' = [want EXCEPT ![r] = link]
                 /\ rpc' = [rpc EXCEPT ![r] = "lock"]
                 /\ UNCHANGED <<pins, loaded>>
            \* Through the link, the index comes from the version it names now.
            ELSE /\ loaded' = [loaded EXCEPT ![r] = link]
                 /\ rpc' = [rpc EXCEPT ![r] = "ready"]
                 /\ UNCHANGED <<pins, want>>
    /\ UNCHANGED <<link, present, latest, held>>

\* Takes a shared lock on the version it read from the link.
Lock(r) ==
    /\ rpc[r] = "lock"
    /\ pins' = [pins EXCEPT ![want[r]] = @ \cup {r}]
    /\ rpc' = [rpc EXCEPT ![r] = "check"]
    /\ UNCHANGED <<link, present, latest, want, loaded, held>>

\* Cleanup can delete the version between the read of the link and the lock,
\* so the reader checks that it is still there and resolves again if not. On
\* success a reload lets the old version go.
Check(r) ==
    /\ rpc[r] = "check"
    /\ IF want[r] \in present \/ Bug = "no_check"
       THEN /\ loaded' = [loaded EXCEPT ![r] = want[r]]
            /\ pins' = IF Bug = "keeps_old_pin" \/ loaded[r] = want[r]
                       THEN pins
                       ELSE Unpin(pins, r, loaded[r])
            /\ rpc' = [rpc EXCEPT ![r] = "ready"]
       ELSE /\ pins' = IF loaded[r] = want[r] THEN pins ELSE Unpin(pins, r, want[r])
            /\ rpc' = [rpc EXCEPT ![r] = "resolve"]
            /\ UNCHANGED loaded
    /\ want' = [want EXCEPT ![r] = None]
    /\ UNCHANGED <<link, present, latest, held>>

\* A use reads the pinned version, or with design link whatever the link
\* names when the use starts (an MCP server's working folder, a skill file).
StartUse(r) ==
    /\ rpc[r] = "ready"
    /\ loaded[r] # None
    /\ ~Pinning => link # None
    /\ held' = [held EXCEPT ![r] = IF Pinning THEN loaded[r] ELSE link]
    /\ rpc' = [rpc EXCEPT ![r] = "using"]
    /\ UNCHANGED <<link, present, latest, pins, want, loaded>>

\* fx stops an MCP server before it reloads, and a file read ends.
EndUse(r) ==
    /\ rpc[r] = "using"
    /\ held' = [held EXCEPT ![r] = None]
    /\ rpc' = [rpc EXCEPT ![r] = "ready"]
    /\ UNCHANGED <<link, present, latest, pins, want, loaded>>

\* MCP servers, skills and profiles reload when the link names a new version.
Reload(r) ==
    /\ Bug # "no_reload"
    /\ rpc[r] = "ready"
    /\ link # loaded[r]
    /\ rpc' = [rpc EXCEPT ![r] = "resolve"]
    /\ UNCHANGED <<link, present, latest, pins, want, loaded, held>>

\* An exit or a crash: the OS drops every lock the reader held.
Exit(r) ==
    /\ rpc[r] # "off"
    /\ rpc' = [rpc EXCEPT ![r] = "off"]
    /\ pins' = [v \in Versions |-> pins[v] \ {r}]
    /\ want' = [want EXCEPT ![r] = None]
    /\ loaded' = [loaded EXCEPT ![r] = None]
    /\ held' = [held EXCEPT ![r] = None]
    /\ UNCHANGED <<link, present, latest>>

Next ==
    \/ Install
    \/ Remove
    \/ \E v \in Versions : Cleanup(v)
    \/ \E r \in Readers :
        \/ Start(r) \/ Resolve(r) \/ Lock(r) \/ Check(r)
        \/ StartUse(r) \/ EndUse(r) \/ Reload(r) \/ Exit(r)

\* A reader finishes what it started and ends each use; it reloads when a
\* reload stays possible; cleanup runs when it can.
Spec ==
    /\ Init /\ [][Next]_vars
    /\ \A r \in Readers :
        /\ WF_vars(Resolve(r)) /\ WF_vars(Lock(r)) /\ WF_vars(Check(r))
        /\ WF_vars(EndUse(r)) /\ SF_vars(Reload(r))
    /\ \A v \in Versions : WF_vars(Cleanup(v))

----------------------------------------------------------------------------
(* Rules. *)

LinkedVersionPresent == link # None => link \in present

\* No read of a mod's file finds its folder gone.
UseFindsFiles == \A r \in Readers : rpc[r] = "using" => held[r] \in present

\* A use reads the same version that the reader's index and config came from.
UseIsCoherent == \A r \in Readers : rpc[r] = "using" => held[r] = loaded[r]

\* A running reader moves to the version the link names.
ReloadsToCurrent ==
    \A r \in Readers : (rpc[r] # "off" /\ loaded[r] # link) ~> (rpc[r] = "off" \/ loaded[r] = link)

\* A version that no link names is deleted in the end.
UnusedVersionsGo ==
    \A v \in Versions : (v \in present /\ v # link) ~> (v \notin present)

=============================================================================

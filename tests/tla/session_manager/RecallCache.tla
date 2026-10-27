---------------------------- MODULE RecallCache ----------------------------
(***************************************************************************)
(* Step: recall's per-tree cache of node indexes (D125).                   *)
(*                                                                         *)
(* Each node's log grows as its turns commit; `ver` is its newest line.    *)
(* A recall call first reads the node's version without a lock (`seen`),   *)
(* then, under the cache's mutex, serves the cached index labelled with    *)
(* that version or builds a new one from the log. A build reads the log    *)
(* as it is then, so it may hold turns newer than its label; the next      *)
(* call sees a newer version and builds again. The cache keeps at most     *)
(* `Slots` indexes, one per node, and the tree frees it only after every   *)
(* node host has closed, so no call runs on a freed cache.                 *)
(*                                                                         *)
(* Design: system-design.md D125. Code: src/core/recall/recall.zig         *)
(* (search, Cache.indexFor), src/core/subagent/tree.zig (destroy) and      *)
(* recall_source.zig.                                                      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Nodes, Slots, MaxVer

VARIABLES
    ver,      \* [Nodes -> 0..MaxVer]: the newest line of each node's log
    cache,    \* set of [node, label, content]: label is the version it answers for
    phase,    \* [Nodes -> {"idle", "seen"}]: a recall call of that node in flight
    seen,     \* [Nodes -> 0..MaxVer]: the version the in-flight call read
    served,   \* [Nodes -> 0..MaxVer]: the content the last call returned
    hosts,    \* the node hosts still open
    freed     \* the tree freed the cache

vars == <<ver, cache, phase, seen, served, hosts, freed>>

Entry == [node : Nodes, label : 0..MaxVer, content : 0..MaxVer]

TypeOK ==
    /\ ver \in [Nodes -> 0..MaxVer]
    /\ cache \subseteq Entry
    /\ phase \in [Nodes -> {"idle", "seen"}]
    /\ seen \in [Nodes -> 0..MaxVer]
    /\ served \in [Nodes -> 0..MaxVer]
    /\ hosts \subseteq Nodes
    /\ freed \in BOOLEAN

Init ==
    /\ ver = [n \in Nodes |-> 0]
    /\ cache = {}
    /\ phase = [n \in Nodes |-> "idle"]
    /\ seen = [n \in Nodes |-> 0]
    /\ served = [n \in Nodes |-> 0]
    /\ hosts = Nodes
    /\ freed = FALSE

\* A turn of n commits: its log grows.
Commit(n) ==
    /\ ver[n] < MaxVer
    /\ ver' = [ver EXCEPT ![n] = ver[n] + 1]
    /\ UNCHANGED <<cache, phase, seen, served, hosts, freed>>

\* A recall call of n reads n's version without a lock.
Begin(n) ==
    /\ n \in hosts /\ ~freed
    /\ phase[n] = "idle"
    /\ phase' = [phase EXCEPT ![n] = "seen"]
    /\ seen' = [seen EXCEPT ![n] = ver[n]]
    /\ UNCHANGED <<ver, cache, served, hosts, freed>>

Hit(n) == {e \in cache : e.node = n /\ e.label = seen[n]}

\* Under the mutex: the index labelled with the seen version, else a build
\* from the log as it is now, replacing n's older index and, when full,
\* another node's.
Serve(n) ==
    /\ phase[n] = "seen"
    /\ IF Hit(n) # {}
       THEN /\ served' = [served EXCEPT ![n] = (CHOOSE e \in Hit(n) : TRUE).content]
            /\ UNCHANGED cache
       ELSE LET fresh == [node |-> n, label |-> seen[n], content |-> ver[n]]
                others == {e \in cache : e.node # n}
            IN /\ served' = [served EXCEPT ![n] = ver[n]]
               /\ IF Cardinality(others) < Slots
                  THEN cache' = others \cup {fresh}
                  ELSE \E victim \in others : cache' = (others \ {victim}) \cup {fresh}
    /\ phase' = [phase EXCEPT ![n] = "idle"]
    /\ UNCHANGED <<ver, seen, hosts, freed>>

\* A node host closes once no call of its node runs.
CloseHost(n) ==
    /\ n \in hosts
    /\ phase[n] = "idle"
    /\ hosts' = hosts \ {n}
    /\ UNCHANGED <<ver, cache, phase, seen, served, freed>>

\* The tree frees the cache after every host closed.
Free ==
    /\ ~freed
    /\ hosts = {}
    /\ freed' = TRUE
    /\ cache' = {}
    /\ UNCHANGED <<ver, phase, seen, served, hosts>>

Next ==
    \/ \E n \in Nodes : Commit(n) \/ Begin(n) \/ Serve(n) \/ CloseHost(n)
    \/ Free

Spec == Init /\ [][Next]_vars

\* A call answers with everything its node held when the call began.
FreshAtStart == [][\A n \in Nodes : Serve(n) => served'[n] >= seen[n]]_vars

\* The cache holds at most Slots indexes, one per node.
CacheBounded ==
    /\ Cardinality(cache) <= Slots
    /\ \A a, b \in cache : a.node = b.node => a = b

\* No call is in flight on a freed cache.
NoUseAfterFree == freed => \A n \in Nodes : phase[n] = "idle"

\* An index never claims a version its log had not reached when it was built.
LabelsAreReal == \A e \in cache : e.label <= e.content /\ e.content <= ver[e.node]
=============================================================================

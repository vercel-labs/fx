------------------------------- MODULE Rewind -------------------------------
(***************************************************************************)
(* Step: rewinding a node of a tree, and its abandoned children (D97).    *)
(*                                                                         *)
(* Node n is a child of the root. Its turns are numbered as they start,   *)
(* and `kept` is the set its history holds. A rewind drops n's newest     *)
(* kept turn and abandons each child first spawned in that turn. It runs  *)
(* only while n and every node below it are idle. The root's record of    *)
(* n's earlier work is never changed: a rewind only changes what n's      *)
(* later turns see. An abandoned child, and every node below it, stays    *)
(* readable but takes no more work: a person's message is refused, and    *)
(* nothing spawns it again (a new child under the same name is a new      *)
(* node).                                                                  *)
(*                                                                         *)
(* x and y are n's possible children; g is x's child, so a busy           *)
(* grandchild blocks a rewind of n, and x's abandonment makes g read-only. *)
(* A person's message runs a turn of a child of n while n itself is       *)
(* idle, as node hosts allow (NodeHosts.tla).                              *)
(*                                                                         *)
(* Design: system-design.md D97. Code: src/core/session_manager/fold.zig   *)
(* (plan .rewound, apply), src/core/session/session_adapter.zig            *)
(* (Session.rewind, replay), src/core/subagent/node_ops.zig (rewindLatest) *)
(* and node_hosts.zig (freeze).                                            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANT MaxTurns

Kids == {"x", "y"}
Below == {"x", "y", "g"}
Turns == 1..MaxTurns

VARIABLES
    turns,      \* the newest turn number of n started
    kept,       \* the turns n's history holds
    nrun,       \* a turn of n runs
    current,    \* the running turn's number, 0 when none
    spawnedIn,  \* [Kids -> 0..MaxTurns]: the turn of n that first spawned it
    gspawned,   \* x spawned g
    run,        \* [Below -> BOOLEAN]: a turn of that node runs
    abandoned,  \* [Kids -> BOOLEAN]
    recorded    \* the turns of n whose results the root recorded

vars == <<turns, kept, nrun, current, spawnedIn, gspawned, run, abandoned, recorded>>

\* A node is read-only once it or an ancestor below n was abandoned.
ReadOnly(k) == IF k = "g" THEN abandoned["x"] ELSE abandoned[k]
Idle == ~nrun /\ \A k \in Below : ~run[k]
Max(S) == CHOOSE t \in S : \A u \in S : u <= t

TypeOK ==
    /\ turns \in 0..MaxTurns
    /\ kept \subseteq Turns
    /\ nrun \in BOOLEAN
    /\ current \in 0..MaxTurns
    /\ spawnedIn \in [Kids -> 0..MaxTurns]
    /\ gspawned \in BOOLEAN
    /\ run \in [Below -> BOOLEAN]
    /\ abandoned \in [Kids -> BOOLEAN]
    /\ recorded \subseteq Turns

Init ==
    /\ turns = 0
    /\ kept = {}
    /\ nrun = FALSE
    /\ current = 0
    /\ spawnedIn = [k \in Kids |-> 0]
    /\ gspawned = FALSE
    /\ run = [k \in Below |-> FALSE]
    /\ abandoned = [k \in Kids |-> FALSE]
    /\ recorded = {}

\* The root messages n: a new turn, kept in n's history.
NTurn ==
    /\ ~nrun
    /\ turns < MaxTurns
    /\ turns' = turns + 1
    /\ kept' = kept \cup {turns + 1}
    /\ nrun' = TRUE
    /\ current' = turns + 1
    /\ UNCHANGED <<spawnedIn, gspawned, run, abandoned, recorded>>

\* n's turn ends once the children it waits on are done; the root records
\* its result.
NEnd ==
    /\ nrun
    /\ \A k \in Kids : spawnedIn[k] = current => ~run[k]
    /\ nrun' = FALSE
    /\ current' = 0
    /\ recorded' = recorded \cup {current}
    /\ UNCHANGED <<turns, kept, spawnedIn, gspawned, run, abandoned>>

Spawn(k) ==
    /\ nrun
    /\ spawnedIn[k] = 0
    /\ spawnedIn' = [spawnedIn EXCEPT ![k] = current]
    /\ run' = [run EXCEPT ![k] = TRUE]
    /\ UNCHANGED <<turns, kept, nrun, current, gspawned, abandoned, recorded>>

\* A person's message to an idle child of n, outside n's turns.
Message(k) ==
    /\ spawnedIn[k] # 0
    /\ ~run[k]
    /\ ~ReadOnly(k)
    /\ run' = [run EXCEPT ![k] = TRUE]
    /\ UNCHANGED <<turns, kept, nrun, current, spawnedIn, gspawned, abandoned, recorded>>

KidEnd(k) ==
    /\ run[k]
    /\ k = "x" => ~run["g"]
    /\ run' = [run EXCEPT ![k] = FALSE]
    /\ UNCHANGED <<turns, kept, nrun, current, spawnedIn, gspawned, abandoned, recorded>>

SpawnG ==
    /\ run["x"]
    /\ ~gspawned
    /\ gspawned' = TRUE
    /\ run' = [run EXCEPT !["g"] = TRUE]
    /\ UNCHANGED <<turns, kept, nrun, current, spawnedIn, abandoned, recorded>>

MessageG ==
    /\ gspawned
    /\ ~run["g"]
    /\ ~ReadOnly("g")
    /\ run' = [run EXCEPT !["g"] = TRUE]
    /\ UNCHANGED <<turns, kept, nrun, current, spawnedIn, gspawned, abandoned, recorded>>

GEnd ==
    /\ run["g"]
    /\ run' = [run EXCEPT !["g"] = FALSE]
    /\ UNCHANGED <<turns, kept, nrun, current, spawnedIn, gspawned, abandoned, recorded>>

\* /undo on n: drop its newest kept turn, abandon what that turn spawned.
Rewind ==
    /\ ~nrun
    /\ \A k \in Below : ~run[k]
    /\ kept # {}
    /\ LET t == Max(kept) IN
       /\ kept' = kept \ {t}
       /\ abandoned' = [k \in Kids |-> abandoned[k] \/ spawnedIn[k] = t]
    /\ UNCHANGED <<turns, nrun, current, spawnedIn, gspawned, run, recorded>>

Next ==
    \/ NTurn \/ NEnd \/ Rewind
    \/ \E k \in Kids : Spawn(k) \/ Message(k) \/ KidEnd(k)
    \/ SpawnG \/ MessageG \/ GEnd

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* An abandoned node, or one below it, never runs again.
AbandonedReadOnly == \A k \in Below : ReadOnly(k) => ~run[k]

\* Exactly the children first spawned in a dropped turn are abandoned.
AbandonedAreLate ==
    \A k \in Kids :
        abandoned[k] <=> (spawnedIn[k] # 0 /\ spawnedIn[k] \notin kept)

\* The history holds only turns that ran.
KeptAreTurns == kept \subseteq 1..turns

(* Action properties *)

\* A step that drops turns from n's history.
Drops == kept' \subseteq kept /\ kept' # kept

\* A step that drops a turn starts with n and everything below it idle.
NoRewindWhileBusy == [][Drops => Idle]_vars

\* The root's record of n's work only grows, and a rewind leaves it as is.
ParentRecordStable ==
    [][/\ recorded \subseteq recorded'
       /\ Drops => recorded' = recorded]_vars
=============================================================================

------------------------------- MODULE Tree --------------------------------
(***************************************************************************)
(* Step: nested subagents, a tree of session nodes (D91, D92).            *)
(*                                                                         *)
(* Every agent is a session node. The root's turn holds no run slot; each *)
(* child's turn waits for one of the tree's `Slots` before it runs. A     *)
(* running node may delegate to children of its own, several at once as  *)
(* a parallel tool group does, if the spawn policy admits each: the      *)
(* node's depth is below `MaxDepth` and the tree has fewer than           *)
(* `MaxNodes` nodes below the root. While it waits on its children it     *)
(* lends its slot back, and takes one again before its turn               *)
(* goes on. A cancel of the root's call reaches each level in turn; a    *)
(* node stops only once the child it waits on has stopped, so the        *)
(* subtree stops deepest first. The root's turn ends only with no         *)
(* descendant alive.                                                       *)
(*                                                                         *)
(* The node universe is fixed: r is the root; a, b, c form a chain below  *)
(* it to depth 3; s is a second child of r, which may run beside a; d     *)
(* would sit under c at depth 4, which the policy refuses.                 *)
(*                                                                         *)
(* Design: system-design.md D91 and D92. Code: src/core/subagent/tree.zig *)
(* (SpawnPolicy), slot_pool.zig (Permit), tool_host.zig (runChild,        *)
(* observeLendingSlot).                                                    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS MaxDepth, MaxNodes, Slots

Root == "r"
Nodes == {"r", "a", "b", "c", "d", "s"}
Children == Nodes \ {Root}
Parent == [n \in Children |->
             CASE n = "a" -> "r"
               [] n = "b" -> "a"
               [] n = "c" -> "b"
               [] n = "d" -> "c"
               [] n = "s" -> "r"]

RECURSIVE Depth(_)
Depth(n) == IF n = Root THEN 0 ELSE 1 + Depth(Parent[n])

RECURSIVE Ancestors(_)
Ancestors(n) == IF n = Root THEN {} ELSE {Parent[n]} \cup Ancestors(Parent[n])

\* "idle": not started, or the root's turn has ended. "queued": started,
\* waiting for a slot. "waiting": blocked on its child. "reclaiming": its
\* child is done and it waits for a slot again.
States == {"idle", "queued", "running", "waiting", "reclaiming", "done"}

VARIABLES
    spawned,   \* [Nodes -> BOOLEAN]: the node exists (its parent logged it)
    st,        \* [Nodes -> States]
    holds,     \* [Nodes -> BOOLEAN]: the node holds a run slot
    cancel     \* [Nodes -> BOOLEAN]: the node's work is being cancelled

vars == <<spawned, st, holds, cancel>>

Live(n) == st[n] \in {"queued", "running", "waiting", "reclaiming"}
InUse == Cardinality({n \in Nodes : holds[n]})
TreeSize == Cardinality({n \in Children : spawned[n]})
\* What a parent does once child `c` stops: it keeps waiting on any other
\* live child, else needs a slot again (the root holds none).
AfterChild(p, c) ==
    IF \E o \in Children : Parent[o] = p /\ o # c /\ Live(o) THEN "waiting"
    ELSE IF p = Root THEN "running" ELSE "reclaiming"

TypeOK ==
    /\ spawned \in [Nodes -> BOOLEAN]
    /\ st \in [Nodes -> States]
    /\ holds \in [Nodes -> BOOLEAN]
    /\ cancel \in [Nodes -> BOOLEAN]

Init ==
    /\ spawned = [n \in Nodes |-> n = Root]
    /\ st = [n \in Nodes |-> IF n = Root THEN "running" ELSE "idle"]
    /\ holds = [n \in Nodes |-> FALSE]
    /\ cancel = [n \in Nodes |-> FALSE]

\* The spawn policy (tree.zig SpawnPolicy.admit): a node below the depth
\* limit adds a child, within the tree budget, and waits on it, lending
\* its slot back at once. A node already waiting adds another child of
\* the same parallel group.
Spawn(c) ==
    LET p == Parent[c] IN
    /\ st[p] \in {"running", "waiting"}
    /\ ~cancel[p]
    /\ ~spawned[c]
    /\ Depth(p) < MaxDepth
    /\ TreeSize < MaxNodes
    /\ spawned' = [spawned EXCEPT ![c] = TRUE]
    /\ st' = [st EXCEPT ![c] = "queued", ![p] = "waiting"]
    /\ holds' = [holds EXCEPT ![p] = FALSE]
    /\ UNCHANGED cancel

\* A queued child takes a slot and runs.
Acquire(c) ==
    /\ st[c] = "queued"
    /\ ~cancel[c]
    /\ InUse < Slots
    /\ holds' = [holds EXCEPT ![c] = TRUE]
    /\ st' = [st EXCEPT ![c] = "running"]
    /\ UNCHANGED <<spawned, cancel>>

\* A child's turn ends, or a cancelled one stops before or while it runs.
Finish(c) ==
    LET p == Parent[c] IN
    /\ \/ st[c] = "running"
       \/ st[c] = "queued" /\ cancel[c]
    /\ st' = [st EXCEPT ![c] = "done", ![p] = AfterChild(p, c)]
    /\ holds' = [holds EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<spawned, cancel>>

\* The parent takes a slot again before its turn goes on; cancelled, it
\* stops without one.
Reclaim(p) ==
    /\ st[p] = "reclaiming"
    /\ IF cancel[p]
          THEN /\ st' = [st EXCEPT ![p] = "done", ![Parent[p]] = AfterChild(Parent[p], p)]
               /\ UNCHANGED holds
          ELSE /\ InUse < Slots
               /\ holds' = [holds EXCEPT ![p] = TRUE]
               /\ st' = [st EXCEPT ![p] = "running"]
    /\ UNCHANGED <<spawned, cancel>>

\* The user cancels the root's call while it waits on a child.
CancelRoot ==
    /\ st[Root] = "waiting"
    /\ ~cancel[Root]
    /\ cancel' = [cancel EXCEPT ![Root] = TRUE]
    /\ UNCHANGED <<spawned, st, holds>>

\* A cancelled parent's wait cancels each child it waits on.
Propagate(c) ==
    /\ cancel[Parent[c]]
    /\ Live(c)
    /\ ~cancel[c]
    /\ cancel' = [cancel EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<spawned, st, holds>>

\* The root's turn ends; its host closes only with no descendant alive.
RootEnd ==
    /\ st[Root] = "running"
    /\ \A n \in Children : ~Live(n)
    /\ st' = [st EXCEPT ![Root] = "idle"]
    /\ UNCHANGED <<spawned, holds, cancel>>

Next ==
    \/ \E c \in Children : Spawn(c) \/ Acquire(c) \/ Finish(c) \/ Reclaim(c) \/ Propagate(c)
    \/ CancelRoot
    \/ RootEnd

Fairness ==
    /\ \A c \in Children :
          /\ WF_vars(Acquire(c))
          /\ WF_vars(Finish(c))
          /\ WF_vars(Reclaim(c))
          /\ WF_vars(Propagate(c))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Invariants *)

\* Never more turns hold a slot than the pool has.
SlotsBounded == InUse <= Slots

\* The tree never holds more nodes below the root than the budget.
TreeBudget == TreeSize <= MaxNodes

\* No node sits deeper than the policy allows.
DepthBounded == \A n \in Nodes : spawned[n] => Depth(n) <= MaxDepth

\* A node exists only under an existing parent.
NoOrphan == \A n \in Children : spawned[n] => spawned[Parent[n]]

\* While a node is alive, every ancestor's turn is still open, waiting on
\* its children: no node closes while a descendant runs.
AncestorsOutliveDescendants ==
    \A n \in Children : Live(n) =>
        \A a \in Ancestors(n) : st[a] = "waiting"

\* Only a turn that works holds a slot; a waiting parent lent its slot.
OnlyRunnersHold == \A n \in Nodes : holds[n] => st[n] = "running"

(* Liveness *)

\* Every node waiting for a slot gets one or is cancelled: lending keeps a
\* chain from the root to the deepest node from deadlocking the pool.
WaitersRun == \A c \in Children : st[c] = "queued" ~> st[c] \in {"running", "done"}

\* A root waiting on its subtree always gets its turn back.
RootResumes == st[Root] = "waiting" ~> st[Root] = "running"
=============================================================================

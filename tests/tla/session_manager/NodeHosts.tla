------------------------------ MODULE NodeHosts ------------------------------
(***************************************************************************)
(* Step: every node below the root keeps a host between its turns (D96).  *)
(*                                                                         *)
(* One registry per tree owns the node hosts. A host opens on demand: for *)
(* the node's own turn, which its parent runs, or for a use, such as a     *)
(* person's command or message, which leases the host of every node on    *)
(* its way down. Every open host holds its parent's open. A host closes    *)
(* only when nothing leases it: no turn of its node, no use, no open       *)
(* child host, and no child turn running in it. The root host closes the  *)
(* tree: every turn stops, and the hosts close, deepest first. With       *)
(* fairness, hosts left idle close (the TTL and the cap pick which first, *)
(* which this model leaves free).                                          *)
(*                                                                         *)
(* r is the root, whose host the frontend owns; a, b, c form a chain to   *)
(* depth 3 and s is a second child of r. A turn of a node runs without    *)
(* its parent's turn when a person messages it: that is the work a        *)
(* per-turn host could not take.                                           *)
(*                                                                         *)
(* Design: system-design.md D96. Code: src/core/subagent/node_hosts.zig    *)
(* (Registry.lease, release, sweep, closeAll), node_ops.zig (lease).       *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

Root == "r"
Nodes == {"r", "a", "b", "c", "s"}
Children == Nodes \ {Root}
Parent == [n \in Children |->
             CASE n = "a" -> "r"
               [] n = "b" -> "a"
               [] n = "c" -> "b"
               [] n = "s" -> "r"]

VARIABLES
    open,      \* [Children -> BOOLEAN]: the node's host is open
    turn,      \* [Children -> BOOLEAN]: a turn of the node runs
    uses,      \* [Children -> BOOLEAN]: a command or message leases it
    closing    \* the root host is closing the tree

vars == <<open, turn, uses, closing>>

\* The root's host is open for the tree's life.
HostOpen(n) == IF n = Root THEN TRUE ELSE open[n]
Kids(n) == {k \in Children : Parent[k] = n}

TypeOK ==
    /\ open \in [Children -> BOOLEAN]
    /\ turn \in [Children -> BOOLEAN]
    /\ uses \in [Children -> BOOLEAN]
    /\ closing \in BOOLEAN

Init ==
    /\ open = [n \in Children |-> FALSE]
    /\ turn = [n \in Children |-> FALSE]
    /\ uses = [n \in Children |-> FALSE]
    /\ closing = FALSE

\* The node's parent runs a turn of it, from the parent's own turn or a
\* person's message; the parent's host is open, and the node's host opens
\* if it was closed (Registry.lease with `.turn`).
StartTurn(n) ==
    /\ ~closing
    /\ ~turn[n]
    /\ HostOpen(Parent[n])
    /\ open' = [open EXCEPT ![n] = TRUE]
    /\ turn' = [turn EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<uses, closing>>

EndTurn(n) ==
    /\ turn[n]
    /\ turn' = [turn EXCEPT ![n] = FALSE]
    /\ UNCHANGED <<open, uses, closing>>

\* A command or a message on a node below leases this host; the lease of
\* each host on the way down is handed to the next (node_ops.lease).
Use(n) ==
    /\ ~closing
    /\ ~uses[n]
    /\ HostOpen(Parent[n])
    /\ open' = [open EXCEPT ![n] = TRUE]
    /\ uses' = [uses EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<turn, closing>>

Unuse(n) ==
    /\ uses[n]
    /\ uses' = [uses EXCEPT ![n] = FALSE]
    /\ UNCHANGED <<open, turn, closing>>

\* An idle host closes (Registry.sweep, or closeAll deepest first): no turn
\* of its node, no use, no open child host and no child turn in it.
Close(n) ==
    /\ open[n]
    /\ ~turn[n]
    /\ ~uses[n]
    /\ \A k \in Kids(n) : ~open[k] /\ ~turn[k]
    /\ open' = [open EXCEPT ![n] = FALSE]
    /\ UNCHANGED <<turn, uses, closing>>

\* The root host closes: no new turn or use starts, every turn is asked to
\* stop, and the hosts then close.
CloseTree ==
    /\ ~closing
    /\ closing' = TRUE
    /\ UNCHANGED <<open, turn, uses>>

Next ==
    \/ \E n \in Children : StartTurn(n) \/ EndTurn(n) \/ Use(n) \/ Unuse(n) \/ Close(n)
    \/ CloseTree

Fairness ==
    \A n \in Children :
        /\ WF_vars(Close(n))
        /\ WF_vars(EndTurn(n) /\ closing)
        /\ WF_vars(Unuse(n) /\ closing)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Invariants *)

\* No host outlives its parent's: an open host's ancestors are all open.
HostsNest == \A n \in Children : open[n] => HostOpen(Parent[n])

\* A node's running turn, and a person's use of it, keep its host open.
BusyHostsStayOpen == \A n \in Children : (turn[n] \/ uses[n]) => open[n]

\* A child turn runs in its parent's host, which stays open under it.
ChildWorkKeepsParent == \A n \in Children : turn[n] => HostOpen(Parent[n])

(* Liveness *)

\* Hosts left idle close: once no turn runs and no use holds any host from
\* some point on, every host closes. Memory stays bounded by the busy
\* nodes and their ancestors.
IdleHostsRelease ==
    (<>[](\A n \in Children : ~turn[n] /\ ~uses[n])) => <>[](\A n \in Children : ~open[n])

\* Closing the tree ends with every node host closed.
TreeCloses == closing ~> (\A n \in Children : ~open[n])
=============================================================================

---------------------------- MODULE PythonState ----------------------------
(***************************************************************************)
(* A node's Python state in its session log (D99).                         *)
(*                                                                         *)
(* One kernel global `v` and one store value `s`. Cells and store writes   *)
(* happen inside turns. A turn's end writes a `kernel_snapshot` line when  *)
(* a cell ran, taken under the kernel's gate before the next turn can run  *)
(* a cell; a store write is a `store_set` line of its turn. A rewind drops *)
(* the newest kept turn and the kernel restores from the log. A fork or a  *)
(* rewind to turn t restores the newest kept line at or before t. The      *)
(* invariant: for every kept ended turn, that restore is exactly the state *)
(* the turn ended with.                                                    *)
(*                                                                         *)
(* Code: src/core/session_manager/python_fold.zig (latestKernel, store),   *)
(* src/core/session/python_state.zig (TurnKernels), src/core/kernel/       *)
(* kernel.zig (turnSnapshot, resetToLog), session_adapter.zig (commitTurn).*)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxTurns, Vals

VARIABLES
    turns,    \* the newest turn number started
    open,     \* a turn is running
    v,        \* the kernel's live global
    s,        \* the store's live value
    dirty,    \* a cell ran since the log last recorded the kernel
    pending,  \* the ended turn's snapshot is not written yet
    log,      \* the node's lines: [kind, turn, val]
    kept,     \* ended turns the history keeps
    dropped,  \* turns rewinds dropped
    truthK,   \* [turn -> v at its end]
    truthS    \* [turn -> s at its end]

vars == <<turns, open, v, s, dirty, pending, log, kept, dropped, truthK, truthS>>

Turns == 1..MaxTurns
Init0 == 0

\* The newest kept line of `kind` at or before turn t, or the initial value.
Restore(kind, t, dr) ==
    LET idx == {i \in 1..Len(log) : log[i].kind = kind /\ log[i].turn <= t /\ log[i].turn \notin dr}
    IN IF idx = {} THEN Init0 ELSE log[CHOOSE i \in idx : \A j \in idx : j <= i].val
RestoreK(t) == Restore("kernel", t, dropped)
RestoreS(t) == Restore("store", t, dropped)

Max(S) == CHOOSE x \in S : \A y \in S : y <= x

Init ==
    /\ turns = 0 /\ open = FALSE /\ v = Init0 /\ s = Init0
    /\ dirty = FALSE /\ pending = FALSE /\ log = <<>>
    /\ kept = {} /\ dropped = {}
    /\ truthK = [t \in Turns |-> Init0] /\ truthS = [t \in Turns |-> Init0]

StartTurn ==
    /\ ~open /\ ~pending /\ turns < MaxTurns
    /\ turns' = turns + 1 /\ open' = TRUE
    /\ UNCHANGED <<v, s, dirty, pending, log, kept, dropped, truthK, truthS>>

Cell(x) ==
    /\ open
    /\ v' = x /\ dirty' = TRUE
    /\ UNCHANGED <<turns, open, s, pending, log, kept, dropped, truthK, truthS>>

\* One store write per turn keeps the model finite.
StoreSet(x) ==
    /\ open
    /\ ~\E i \in 1..Len(log) : log[i].kind = "store" /\ log[i].turn = turns
    /\ s' = x
    /\ log' = Append(log, [kind |-> "store", turn |-> turns, val |-> x])
    /\ UNCHANGED <<turns, open, v, dirty, pending, kept, dropped, truthK, truthS>>

\* The turn ends; its state is what any later restore of it must give.
EndTurn ==
    /\ open
    /\ open' = FALSE /\ pending' = dirty
    /\ kept' = kept \cup {turns}
    /\ truthK' = [truthK EXCEPT ![turns] = v]
    /\ truthS' = [truthS EXCEPT ![turns] = s]
    /\ UNCHANGED <<turns, v, s, dirty, log, dropped>>

\* The kernel's snapshot of the ended turn, in its end batch.
Snapshot ==
    /\ pending
    /\ log' = Append(log, [kind |-> "kernel", turn |-> turns, val |-> v])
    /\ pending' = FALSE /\ dirty' = FALSE
    /\ UNCHANGED <<turns, open, v, s, kept, dropped, truthK, truthS>>

\* /undo of the newest kept turn: the kernel and the store go back.
Rewind ==
    /\ ~open /\ ~pending /\ kept # {}
    /\ LET t == Max(kept) IN
       LET rest == kept \ {t} IN
       LET to == IF rest = {} THEN 0 ELSE Max(rest) IN
       /\ kept' = rest
       /\ dropped' = dropped \cup {t}
       /\ v' = Restore("kernel", to, dropped \cup {t})
       /\ s' = Restore("store", to, dropped \cup {t})
    /\ dirty' = FALSE
    /\ UNCHANGED <<turns, open, pending, log, truthK, truthS>>

Next ==
    \/ StartTurn \/ EndTurn \/ Snapshot \/ Rewind
    \/ \E x \in Vals : Cell(x) \/ StoreSet(x)

Spec == Init /\ [][Next]_vars

\* A fork or a rewind to any kept ended turn restores exactly that turn.
RestoreExact ==
    \A t \in kept : (~pending \/ t # turns) =>
        /\ RestoreK(t) = truthK[t]
        /\ RestoreS(t) = truthS[t]
=============================================================================

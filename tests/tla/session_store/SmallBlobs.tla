------------------------------ MODULE SmallBlobs ------------------------------
(***************************************************************************)
(* Where a session's bodies live, and what a crash can leave behind.       *)
(*                                                                         *)
(* Design = "current": every body is a loose file. It is written, fsynced  *)
(*   (session.zig storeBlob), and only then named by a line. Nothing ever  *)
(*   removes a body that no line names.                                    *)
(* Design = "inline": a small body (Size <= Cap) is carried inside the     *)
(*   line that names it, and the small bodies of one line fit one budget   *)
(*   (Cap). Big bodies stay loose, as today. A collector removes unnamed   *)
(*   loose bodies.                                                         *)
(* Design = "pack": a small body is a record in one per-session pack, and  *)
(*   one fsync covers every record written so far. Big bodies stay loose.  *)
(*   This is src/core/session_manager/pack.zig: the pack is synced before   *)
(*   any line names one of its records (Dangling), and a crash cuts the     *)
(*   records that were not synced (the torn tail). No collector is modeled: *)
(*   pack records stay until a later change removes them. Fork copy and the *)
(*   read index are checked by the session tests, not by this model.        *)
(*                                                                         *)
(* A line is appended to the in-memory tail (pend) and becomes durable     *)
(* only by SyncLog, which keeps a prefix. Crash loses every volatile       *)
(* write: pending lines and unsynced bodies. Durable bodies and lines stay.*)
(* Mutant plants one bug per design so each invariant is shown to fail.    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Design,   \* "current" | "inline" | "pack"
  Mutant,   \* "none" | "early_ref" | "no_budget" | "gc_live"
  MaxLines  \* bound on lines, pending plus durable

ASSUME Design \in {"current", "inline", "pack"}
ASSUME Mutant \in {"none", "early_ref", "no_budget", "gc_live"}

Bodies == {"s1", "s2", "big"}
Size(b) == CASE b = "s1" -> 1 [] b = "s2" -> 2 [] OTHER -> 5
Cap == 2

Small(b) == Size(b) <= Cap
Inl(b) == Design = "inline" /\ Small(b)
Stored(b) == ~Inl(b)
Batched(b) == Design = "pack" /\ Small(b)

RECURSIVE SumSize(_)
SumSize(S) == IF S = {} THEN 0
              ELSE LET b == CHOOSE x \in S : TRUE IN Size(b) + SumSize(S \ {b})

BudgetOk(S) == SumSize({b \in S : Inl(b)}) <= Cap

VARIABLES store, pend, disk

vars == <<store, pend, disk>>

Referenced(b) ==
  \/ \E i \in 1..Len(disk) : b \in disk[i]
  \/ /\ Mutant # "gc_live"
     /\ \E j \in 1..Len(pend) : b \in pend[j]

Init ==
  /\ store = [b \in Bodies |-> "none"]
  /\ pend = <<>>
  /\ disk = <<>>

Write(b) ==
  /\ Stored(b)
  /\ store[b] = "none"
  /\ store' = [store EXCEPT ![b] = "volatile"]
  /\ UNCHANGED <<pend, disk>>

SyncOne(b) ==
  /\ Stored(b)
  /\ ~Batched(b)
  /\ store[b] = "volatile"
  /\ store' = [store EXCEPT ![b] = "durable"]
  /\ UNCHANGED <<pend, disk>>

SyncPack ==
  /\ \E b \in Bodies : Batched(b) /\ store[b] = "volatile"
  /\ store' = [b \in Bodies |->
                 IF Batched(b) /\ store[b] = "volatile" THEN "durable" ELSE store[b]]
  /\ UNCHANGED <<pend, disk>>

AppendLine(S) ==
  /\ Len(pend) + Len(disk) < MaxLines
  /\ \A b \in S :
       Inl(b) \/ store[b] = "durable" \/ (Mutant = "early_ref" /\ store[b] = "volatile")
  /\ BudgetOk(S) \/ Mutant = "no_budget"
  /\ pend' = pend \o <<S>>
  /\ UNCHANGED <<store, disk>>

SyncLog ==
  /\ pend # <<>>
  /\ disk' = disk \o pend
  /\ pend' = <<>>
  /\ UNCHANGED store

Crash ==
  /\ pend' = <<>>
  /\ store' = [b \in Bodies |-> IF store[b] = "volatile" THEN "none" ELSE store[b]]
  /\ UNCHANGED disk

Gc(b) ==
  /\ Design = "inline"
  /\ Stored(b)
  /\ store[b] = "durable"
  /\ ~Referenced(b)
  /\ store' = [store EXCEPT ![b] = "none"]
  /\ UNCHANGED <<pend, disk>>

Next ==
  \/ \E b \in Bodies : Write(b) \/ SyncOne(b) \/ Gc(b)
  \/ SyncPack
  \/ \E S \in SUBSET Bodies : AppendLine(S)
  \/ SyncLog
  \/ Crash

Spec == Init /\ [][Next]_vars /\ \A b \in Bodies : WF_vars(Gc(b))

TypeOK == store \in [Bodies -> {"none", "volatile", "durable"}]

\* Every body that a durable line names is inside that line, or durable.
Dangling ==
  \A i \in 1..Len(disk) : \A b \in disk[i] : Inl(b) \/ store[b] = "durable"

\* The small bodies of one line fit its budget, in durable and pending lines.
BudgetHolds ==
  /\ \A i \in 1..Len(disk) : BudgetOk(disk[i])
  /\ \A j \in 1..Len(pend) : BudgetOk(pend[j])

\* A durable body that no line names is collected, unless a line names it
\* again. Per body: a schedule may leak one body and name another in turn.
LeakOf(b) == store[b] = "durable" /\ ~Referenced(b)
NoPermanentLeak == \A b \in Bodies : []( LeakOf(b) => <>(~LeakOf(b)) )

=============================================================================

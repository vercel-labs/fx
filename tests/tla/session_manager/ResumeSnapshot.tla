-------------------------- MODULE ResumeSnapshot --------------------------
(***************************************************************************)
(* Step: L2 fold and resume.                                              *)
(*                                                                         *)
(* open(.resume) folds from the newest snapshot instead of line 1. This  *)
(* spec states the contract that makes that safe: resuming from the      *)
(* newest snapshot gives exactly the state of a full replay, and the     *)
(* snapshot lines themselves can be dropped without changing any state.  *)
(* The Zig implementation must pass the same two checks as property      *)
(* tests.                                                                 *)
(*                                                                         *)
(* Design: system-design.md "Fold".                                       *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Vals, MaxLen, NoVal

Empty == [pref |-> NoVal, turns |-> 0, open |-> FALSE]

\* Every line has the same record shape; `st` is used only by snapshots.
Entry(k, v, s) == [k |-> k, v |-> v, st |-> s]

Step(s, e) ==
    CASE e.k = "set"    -> [s EXCEPT !.pref = e.v]
      [] e.k = "start"  -> [s EXCEPT !.open = TRUE]
      [] e.k = "commit" -> [s EXCEPT !.open = FALSE, !.turns = @ + 1]
      [] OTHER          -> s    \* snapshot lines change nothing

RECURSIVE FoldFrom(_, _, _)
FoldFrom(l, i, s) ==
    IF i > Len(l) THEN s ELSE FoldFrom(l, i + 1, Step(s, l[i]))

Full(l) == FoldFrom(l, 1, Empty)

SnapIdx(l) == {i \in 1..Len(l) : l[i].k = "snap"}

LastSnap(l) ==
    IF SnapIdx(l) = {} THEN 0
    ELSE CHOOSE i \in SnapIdx(l) : \A j \in SnapIdx(l) : j <= i

\* What open(.resume) computes: the newest snapshot, then fold the tail.
Resume(l) ==
    LET j == LastSnap(l) IN
    IF j = 0 THEN Full(l) ELSE FoldFrom(l, j + 1, l[j].st)

RECURSIVE Strip(_)
Strip(l) ==
    IF l = <<>> THEN <<>>
    ELSE IF Head(l).k = "snap" THEN Strip(Tail(l))
         ELSE <<Head(l)>> \o Strip(Tail(l))

VARIABLES log
vars == <<log>>

Init == log = <<>>

Set(v) ==
    /\ Len(log) < MaxLen
    /\ log' = Append(log, Entry("set", v, Empty))

Start ==
    /\ Len(log) < MaxLen
    /\ ~Full(log).open
    /\ log' = Append(log, Entry("start", NoVal, Empty))

Commit ==
    /\ Len(log) < MaxLen
    /\ Full(log).open
    /\ log' = Append(log, Entry("commit", NoVal, Empty))

\* The manager writes a snapshot of the state folded so far. Snapshots
\* may land anywhere, including inside an open turn.
Snapshot ==
    /\ Len(log) < MaxLen
    /\ log' = Append(log, Entry("snap", NoVal, Full(log)))

Next ==
    \/ \E v \in Vals : Set(v)
    \/ Start
    \/ Commit
    \/ Snapshot

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

ResumeEqualsFullReplay == Resume(log) = Full(log)

SnapshotsAreIgnorable == Full(Strip(log)) = Full(log)
=============================================================================

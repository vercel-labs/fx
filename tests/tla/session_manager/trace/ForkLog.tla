------------------------------ MODULE ForkLog ------------------------------
(***************************************************************************)
(* A saved fork against its saved source (D5, D58).                        *)
(*                                                                         *)
(* `Copied` is the fork's lines after line 1 up to its `forked_from.seq`,  *)
(* the lines the manager copied; `Source` is the source's lines after      *)
(* line 1. Both leave out snapshots, which a fork encodes again. Each line *)
(* is a record [k, h]: k its kind as TurnLifecycleLog names kinds, h a     *)
(* hash of its exact bytes. Accepted when the copied lines are exactly the *)
(* source's first lines, byte for byte, and end at a turn boundary: every  *)
(* turn they start, they also end. `NotWritten` then fails, and TLC       *)
(* prints how many copied lines it judged as `matched_lines`.              *)
(*                                                                         *)
(* A `Child` fork is a fork's copy of one of its source's children (D97):  *)
(* each record also has t, its time, and `Point` is the time of the fork   *)
(* point's line in the parent's source. Its copied lines end at that time, *)
(* not at a turn, so they may end inside a turn; `After`, the copy's next  *)
(* line as [k, r] with r its reason, must then end that turn as cancelled. *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC, SavedFork

VARIABLE checked

Starts(s) == {i \in 1..Len(s) : s[i].k = "start"}
Ends(s) == {i \in 1..Len(s) : s[i].k \in {"commit", "interrupt"}}

IsPrefix ==
    /\ Len(Copied) <= Len(Source)
    /\ \A i \in 1..Len(Copied) : Copied[i] = Source[i]

AtBoundary == Cardinality(Starts(Copied)) = Cardinality(Ends(Copied))

\* A child's copy cut inside a turn: its next line ends that turn as
\* cancelled, as Esc ends one.
CutEndsTurn ==
    /\ Child
    /\ Cardinality(Starts(Copied)) = Cardinality(Ends(Copied)) + 1
    /\ Len(After) = 1
    /\ After[1].k = "interrupt"
    /\ After[1].r = "cancel"

\* A child's copy holds its source's lines to the fork point's time: none
\* after it, and every one before it. A line stamped with the point's own
\* millisecond may fall on either side (ForkChildren.tla CopyAtPoint).
AtPoint ==
    Child =>
        /\ \A i \in 1..Len(Copied) : Copied[i].t <= Point
        /\ Len(Source) > Len(Copied) => Source[Len(Copied) + 1].t >= Point

LogInit == checked = FALSE
LogNext ==
    /\ ~checked
    /\ IsPrefix
    /\ AtBoundary \/ CutEndsTurn
    /\ AtPoint
    /\ PrintT(<<"matched_lines", Len(Copied)>>)
    /\ checked' = TRUE
LogSpec == LogInit /\ [][LogNext]_checked

NotWritten == ~checked
=============================================================================

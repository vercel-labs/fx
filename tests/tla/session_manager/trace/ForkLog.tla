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
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC, SavedFork

VARIABLE checked

Starts(s) == {i \in 1..Len(s) : s[i].k = "start"}
Ends(s) == {i \in 1..Len(s) : s[i].k \in {"commit", "interrupt"}}

IsPrefix ==
    /\ Len(Copied) <= Len(Source)
    /\ \A i \in 1..Len(Copied) : Copied[i] = Source[i]

AtBoundary == Cardinality(Starts(Copied)) = Cardinality(Ends(Copied))

LogInit == checked = FALSE
LogNext == ~checked /\ IsPrefix /\ AtBoundary /\ PrintT(<<"matched_lines", Len(Copied)>>) /\ checked' = TRUE
LogSpec == LogInit /\ [][LogNext]_checked

NotWritten == ~checked
=============================================================================

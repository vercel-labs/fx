--------------------------- MODULE MCAcpToolDiffs ---------------------------
(* Exhaustive model of AcpToolDiffs: two edits to one file that exists, c1 *)
(* and c2, and c3, which creates a second file, in every order of prepare, *)
(* approval, commit, completion, and delivery. The configs say which calls *)
(* need approval and which are over the limit.                             *)
EXTENDS AcpToolDiffs
MCFileOf == [c \in {"c1", "c2", "c3"} |-> IF c = "c3" THEN "f2" ELSE "f1"]
MCInitVer == [f \in {"f1", "f2"} |-> IF f = "f1" THEN 1 ELSE 0]
=============================================================================

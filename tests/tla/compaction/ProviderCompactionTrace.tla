--------------------------- MODULE ProviderCompactionTrace ---------------------------
(***************************************************************************)
(* Replays the requests a built fx sent, as tests/tla/drivers/compaction/  *)
(* provider.test.ts captured them in ProviderCompactionObserved.tla, and   *)
(* checks ProviderCompaction's properties on each one.                     *)
(*                                                                         *)
(* Requests[r] is one agent or compaction request: the model it went to,   *)
(* its items after the instructions, and the step its reply wrote (0 for a *)
(* compaction). An item is a user message, a step sent with its reasoning, *)
(* a step sent as text, fx's summary, or a provider block, whose b names   *)
(* the compaction request it answered. A provider reads its own block as   *)
(* what that request sent.                                                 *)
(*                                                                         *)
(* A check passes only when TLC stops on ReplayIncomplete: every request   *)
(* was replayed and no property failed first.                              *)
(***************************************************************************)
EXTENDS Naturals, Sequences, ProviderCompactionObserved

RECURSIVE ReadSeq(_, _)
ReadItem(w, m) ==
  CASE w.k = "block" /\ w.m = m -> ReadSeq(Requests[w.b].items, m)
    [] w.k = "block" -> << [a |-> "unreadable", n |-> w.b] >>
    [] OTHER -> << [a |-> w.k, n |-> w.n] >>
ReadSeq(s, m) == IF s = <<>> THEN <<>> ELSE ReadItem(Head(s), m) \o ReadSeq(Tail(s), m)

\* The request whose reply wrote step n, and what its model read before it.
Origin(n) == CHOOSE r \in DOMAIN Requests : Requests[r].produces = n
Bound(n) == ReadSeq(Requests[Origin(n)].items, Requests[Origin(n)].model)
Written(n) == \E r \in DOMAIN Requests : Requests[r].produces = n

VARIABLE i

Init == i = 1
Next == i <= Len(Requests) /\ i' = i + 1
Spec == Init /\ [][Next]_i

Here == Requests[i]

NoDroppedReasoning ==
  i <= Len(Requests) =>
    \A j \in 1..Len(Here.items) :
      LET w == Here.items[j] IN
        (w.k = "step" /\ w.m = Here.model /\ Written(w.n)) =>
          ReadSeq(SubSeq(Here.items, 1, j - 1), Here.model) = Bound(w.n)

Readable ==
  i <= Len(Requests) => \A j \in 1..Len(Here.items) : Here.items[j].k = "block" => Here.items[j].m = Here.model

NoForeignReasoning ==
  i <= Len(Requests) => \A j \in 1..Len(Here.items) : Here.items[j].k = "step" => Here.items[j].m = Here.model

\* Fails once every request was replayed: the run's sentinel.
ReplayIncomplete == i <= Len(Requests)
=============================================================================

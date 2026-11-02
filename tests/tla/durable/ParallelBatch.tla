---------------------------- MODULE ParallelBatch ----------------------------
(***************************************************************************)
(* Step: parallel host tools with writers as fences.                     *)
(*                                                                         *)
(* One model response asks for calls 1..N, in the model's order. Calls   *)
(* run in parallel by default, like Pi. A tool marked `writes: true` is a *)
(* fence: it starts only after every earlier call finished, and no later *)
(* call starts until it finished. Results go to the model, and into the  *)
(* journal's turn record, in the model's order, whatever order the calls *)
(* finish in. The process can crash mid-batch (fault injection): durable *)
(* results stay, unfinished calls are dispatched again (ToolReplay.tla   *)
(* decides whether a call may run again).                                 *)
(*                                                                         *)
(* list-then-read is two readers: they overlap, and the model still sees *)
(* list's result first. write-then-read is a fence then a reader: the    *)
(* read never starts before the write finished.                          *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS N, Writes, MaxCrashes

ASSUME Writes \subseteq 1..N

Calls == 1..N

VARIABLES
    status,    \* [Calls -> "waiting" | "running" | "done"]
    reported,  \* results handed to the model, as call numbers, in order
    crashes

vars == <<status, reported, crashes>>

TypeOK ==
    /\ status \in [Calls -> {"waiting", "running", "done"}]
    /\ reported \in Seq(Calls)
    /\ Len(reported) <= N
    /\ crashes \in 0..MaxCrashes

Init ==
    /\ status = [i \in Calls |-> "waiting"]
    /\ reported = <<>>
    /\ crashes = 0

\* Fence rule.
CanStart(i) ==
    /\ \A j \in 1..(i - 1) : j \in Writes => status[j] = "done"
    /\ i \in Writes => \A j \in 1..(i - 1) : status[j] = "done"

Start(i) ==
    /\ status[i] = "waiting"
    /\ CanStart(i)
    /\ status' = [status EXCEPT ![i] = "running"]
    /\ UNCHANGED <<reported, crashes>>

Finish(i) ==
    /\ status[i] = "running"
    /\ status' = [status EXCEPT ![i] = "done"]
    /\ UNCHANGED <<reported, crashes>>

\* The next result in model order goes to the model once it is done.
Report ==
    /\ Len(reported) < N
    /\ status[Len(reported) + 1] = "done"
    /\ reported' = Append(reported, Len(reported) + 1)
    /\ UNCHANGED <<status, crashes>>

\* Fault injection: the process dies with calls in flight.
Crash ==
    /\ crashes < MaxCrashes
    /\ \E i \in Calls : status[i] = "running"
    /\ status' = [i \in Calls |-> IF status[i] = "done" THEN "done" ELSE "waiting"]
    /\ crashes' = crashes + 1
    /\ UNCHANGED reported

Next ==
    \/ \E i \in Calls : Start(i) \/ Finish(i)
    \/ Report
    \/ Crash

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* A writer never overlaps any other call.
WriterRunsAlone ==
    \A i \in Writes :
        status[i] = "running" => \A j \in Calls \ {i} : status[j] # "running"

\* No call starts before an earlier writer finished.
NothingPassesWriter ==
    \A i \in Writes, j \in Calls :
        j > i /\ status[j] # "waiting" => status[i] = "done"

\* A writer starts only after every earlier call finished.
WriterAfterEarlier ==
    \A i \in Writes, j \in Calls :
        j < i /\ status[i] # "waiting" => status[j] = "done"

\* The model sees results in its own order, and only finished ones.
ResultsInModelOrder ==
    \A k \in 1..Len(reported) : reported[k] = k /\ status[k] = "done"

-----------------------------------------------------------------------------
(* Witness, not an invariant: mutants.py adds it to the .cfg and requires *)
(* TLC to violate it, which proves two readers really do run at once.    *)

NoReaderOverlap ==
    ~\E i, j \in Calls \ Writes :
        i # j /\ status[i] = "running" /\ status[j] = "running"

=============================================================================

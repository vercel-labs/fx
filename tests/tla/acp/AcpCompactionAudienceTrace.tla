---------------------- MODULE AcpCompactionAudienceTrace ----------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real fx acp binary,   *)
(* with its clients on the leader socket, against AcpCompactionAudience    *)
(* in design "a" with Class "nonideal". TraceLog and the constants come    *)
(* from the generated AcpCompactionAudienceObs module.                     *)
(*                                                                         *)
(* An observation is a step the driver took, or a compaction message fx    *)
(* wrote and one client read:                                              *)
(* - start: fx's first in_progress, written to the listing members;        *)
(* - join, leave: a client connects, or disconnects, on the leader socket; *)
(* - main_gone: the main's connection breaks. The driver does not read the *)
(*   main's frames after this, so its last message counts as unread, as    *)
(*   the model's failed write does;                                        *)
(* - read: one client read one message, in the order fx wrote it to it;    *)
(* - settle: fx's end, with its outcome;                                   *)
(* - quiet: the run's last step. Every present client has read everything  *)
(*   written to it, so a message the model writes and fx never sends fails  *)
(*   here.                                                                  *)
(*                                                                         *)
(* Hidden: the compactor's choice (Choose). It is the only step fx does    *)
(* that no observation names, and it changes stage alone. Start needs      *)
(* stage "chosen", so Choose is taken before it, and it cannot turn a      *)
(* wrong run into a pass: with Class "nonideal", no churn reads stage.     *)
(*                                                                         *)
(* NotDone is violated when every observation has been matched.            *)
(***************************************************************************)
EXTENDS AcpCompactionAudience, AcpCompactionAudienceObs, Naturals, Sequences

VARIABLES i

TraceInit == i = 0 /\ Init

M(name) == CASE name = "m1" -> m1 [] name = "m2" -> m2 [] name = "m3" -> m3

\* The compactor picks the compaction. fx writes nothing for it.
Hidden == Choose

\* The run is over: the compaction ended, and every present client read all it was sent.
Quiet == Ended /\ \A m \in Present : pending[m] = <<>> /\ UNCHANGED vars

ClientStep(o) ==
    CASE o.op = "start" -> Start
      [] o.op = "join" -> Join(M(o.who))
      [] o.op = "leave" -> Leave(M(o.who))
      [] o.op = "main_gone" -> Failover
      [] o.op = "read" -> (Head1(M(o.who)) = o.msg /\ Deliver(M(o.who)))
      [] o.op = "settle" -> Settle(o.arg)
      [] o.op = "quiet" -> Quiet
      [] OTHER -> FALSE

TraceNext ==
    \/ /\ i < Len(TraceLog)
       /\ ClientStep(TraceLog[i + 1])
       /\ i' = i + 1
    \/ /\ Hidden
       /\ UNCHANGED i

\* TLC violates this when every observation is matched, so a run is accepted
\* when TLC reaches that state and rejected when it does not.
NotDone == i < Len(TraceLog)
=============================================================================

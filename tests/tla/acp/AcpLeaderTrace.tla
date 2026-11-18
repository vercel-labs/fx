------------------------- MODULE AcpLeaderTrace -------------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real `fx acp` binary  *)
(* against AcpLeader. TraceLog and the constants come from the generated   *)
(* AcpLeaderObs module.                                                    *)
(*                                                                         *)
(* An observation is a process the driver started, with whether its socket *)
(* can listen; a session made live, once its prompt or load was answered;  *)
(* a read of the lock file, which names the process, none, or a process    *)
(* the driver did not start (other); a connect, connected or stale; an     *)
(* ask, found or notleader; a process's exit; or its kill. Each read that  *)
(* names a process is followed by connect, and by ask when connected.      *)
(*                                                                         *)
(* Every other step is hidden: a socket starts or fails, a process takes   *)
(* the lock, its record is written, and the reader restarts after an end   *)
(* state. A process releases its session, which clears its record and      *)
(* unlocks, only before its exit is observed.                              *)
(*                                                                         *)
(* A session is released only on its process's way out in these runs, so a *)
(* record can't disappear between two reads while its holder lives.        *)
(*                                                                         *)
(* published is a stutter with a guard, not a free step. fx writes the     *)
(* record while it makes a session live, before it answers the prompt or   *)
(* the load, so the guard requires the record once the holder listens and  *)
(* records.                                                                *)
(*                                                                         *)
(* canListen exists because a process whose temp folder is usable may not  *)
(* take the no-socket path. The rules model would otherwise explain an     *)
(* empty lock as a failed socket, so Fail is allowed only for a process    *)
(* the driver started with no usable folder.                               *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a step of the model. Exhausting the search without  *)
(* that violation means the run is not a behavior of the model.            *)
(***************************************************************************)
EXTENDS AcpLeader, AcpLeaderObs, Naturals, Sequences

VARIABLES i, mayFail

TraceInit ==
    /\ i = 0
    /\ mayFail = [p \in Procs |-> FALSE]
    /\ Init

\* The holder's session is live, and recorded once its socket listens.
Published(p) ==
    /\ holder = p
    /\ ((Records /\ listening[p]) => record = p)
    /\ UNCHANGED <<vars, mayFail>>

\* The reader reads the lock file: it names the process t, or nothing.
ReadAs(t) ==
    /\ Read
    /\ ftarget' = IF t = "none" THEN None ELSE P(t)
    /\ UNCHANGED mayFail

\* One observed step, as the model takes it. Any other operation matches
\* nothing.
ClientStep(o) ==
    CASE o.op = "start" ->
            (Start(P(o.proc))
             /\ mayFail' = [mayFail EXCEPT ![P(o.proc)] = ~o.canListen])
      [] o.op = "published" -> Published(P(o.proc))
      [] o.op = "read" ->
            (IF o.target \in {"none", "p1", "p2"}
             THEN ReadAs(o.target)
             ELSE FALSE)
      [] o.op = "connect" ->
            (Connect /\ fstep' = o.result /\ UNCHANGED mayFail)
      [] o.op = "ask" ->
            (Ask /\ fstep' = o.result /\ UNCHANGED mayFail)
      [] o.op = "exit" -> (Exit(P(o.proc)) /\ UNCHANGED mayFail)
      [] o.op = "kill" -> (Crash(P(o.proc)) /\ UNCHANGED mayFail)
      [] OTHER -> FALSE

\* Steps the trace does not observe: a socket fails, a process locks or
\* records, and the reader restarts. A process may fail only when the driver
\* started it with no usable folder. A process releases its session, clearing
\* its record and unlocking, only before its exit is observed: fx does that
\* when it closes its sessions on the way out.
ExitIsNextFor(p) ==
    IF i < Len(TraceLog)
    THEN IF TraceLog[i + 1].op = "exit"
         THEN P(TraceLog[i + 1].proc) = p
         ELSE FALSE
    ELSE FALSE

Hidden ==
    \/ \E p \in Procs :
        \/ Listen(p) \/ (Fail(p) /\ mayFail[p]) \/ Lock(p) \/ Record(p)
        \/ (ExitIsNextFor(p) /\ (Clear(p) \/ Unlock(p)))
    \/ Again

TraceNext ==
    \/ /\ i < Len(TraceLog)
       /\ ClientStep(TraceLog[i + 1])
       /\ i' = i + 1
    \/ /\ Hidden
       /\ UNCHANGED <<i, mayFail>>

NotDone == i < Len(TraceLog)
=============================================================================

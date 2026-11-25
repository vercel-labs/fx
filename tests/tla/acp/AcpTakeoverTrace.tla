------------------------- MODULE AcpTakeoverTrace -------------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real `fx acp` binary  *)
(* against AcpTakeover. TraceLog, the constants and Mutation come from the *)
(* generated AcpTakeoverObs module.                                        *)
(*                                                                         *)
(* An observation is one step the driver saw: a process started; a prompt  *)
(* sent, and its answer; a load sent, and its answer, loaded or busy; a    *)
(* process killed, and then whether its pid is gone or taken by another    *)
(* process; a process exited; a read of the lock file, which names the     *)
(* process, none, or a process the driver did not start (other); the lock  *)
(* line the driver forged; a folder present or gone; a turn the session    *)
(* log shows as interrupted; the count of model requests; and a permission *)
(* question the client received.                                           *)
(*                                                                         *)
(* Steps that fx takes between two observations are hidden: a process      *)
(* loads (only as the first prompt of a session), takes the lock, writes   *)
(* its record, repairs an interrupted turn, removes a dead holder's        *)
(* folder, clears and unlocks. The trace is accepted when every observation *)
(* matches a step, in order, with hidden steps between them.               *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every observation *)
(* matched. Exhausting the search without that violation means the run is  *)
(* not a behavior of the model.                                            *)
(***************************************************************************)
EXTENDS AcpTakeover, AcpTakeoverObs, Naturals, Sequences

VARIABLES i

TraceInit == i = 0 /\ Init

\* The lock line names the process t, or nothing. A read of "other" finds a
\* line the driver forged, which names no process of this run.
ReadLock(t) ==
    /\ line = IF t \in {"none", "other"} THEN NoProc ELSE P(t)
    /\ UNCHANGED vars

\* The client's load answer is "loaded": the process holds the lock, its record
\* is written, and the load is no longer waiting.
Loaded(p) ==
    /\ p \in holders /\ line = p /\ ~loading[p]
    /\ UNCHANGED vars

\* The folder of a process is present (made) or gone.
FolderIs(q, state) ==
    /\ folder[q] = IF state = "present" THEN "made" ELSE "gone"
    /\ UNCHANGED vars

\* The driver replaces the lock line with content that names no process of
\* this run. fx does not write it, so no ghost variable changes.
Forge ==
    /\ line' = NoProc
    /\ UNCHANGED <<procVars, holders, loadVars, memVars, turnVars, folVars, ghostVars>>

\* One observed step, as the model takes it.
ClientStep(o) ==
    CASE o.op = "start" -> Start(P(o.proc))
      [] o.op = "prompt" -> StartTurn(P(o.proc))
      [] o.op = "answered" -> (o.arg = "end_turn" /\ Commit(P(o.proc)))
      [] o.op = "load" -> Load(P(o.proc))
      [] o.op = "loaded" -> Loaded(P(o.proc))
      [] o.op = "busy" -> Busy(P(o.proc))
      [] o.op = "kill" -> Crash(P(o.proc))
      [] o.op = "pidgone" -> (~reused[P(o.proc)] /\ UNCHANGED vars)
      [] o.op = "pidother" -> (reused[P(o.proc)] /\ UNCHANGED vars)
      [] o.op = "exit" -> Exit(P(o.proc))
      [] o.op = "read" -> ReadLock(o.proc)
      [] o.op = "forge" -> Forge
      [] o.op = "folder" -> FolderIs(P(o.proc), o.arg)
      [] o.op = "interrupted" -> (turn = "interrupted" /\ UNCHANGED vars)
      [] o.op = "calls" -> (calls = o.arg /\ UNCHANGED vars)
      [] o.op = "asked" -> Ask(P(o.proc))
      [] OTHER -> FALSE

\* Steps the trace does not observe. A process loads its first session as its
\* first prompt, takes the lock and writes its record; the lock is cleared and
\* released before a holder exits; a turn of a dead holder is repaired; a dead
\* holder's folder is removed; a pid is reused and freed.
Hidden ==
    \/ \E p \in Procs :
        \/ Load(p) \/ Take(p) \/ Write(p) \/ Clear(p) \/ Unlock(p)
        \/ UnclearedRelease(p) \/ Repair(p) \/ PidFree(p)
    \/ \E h \in Procs : \E q \in Procs : Clean(h, q)

TraceNext ==
    \/ /\ i < Len(TraceLog)
       /\ ClientStep(TraceLog[i + 1])
       /\ i' = i + 1
    \/ /\ Hidden
       /\ UNCHANGED i

NotDone == i < Len(TraceLog)
=============================================================================

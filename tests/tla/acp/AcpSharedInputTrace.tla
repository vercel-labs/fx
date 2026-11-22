------------------------ MODULE AcpSharedInputTrace ------------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real fx acp binary,   *)
(* with the owner on stdio and a follower on the leader socket, against    *)
(* AcpSharedInput. TraceLog and TRules come from the generated              *)
(* AcpSharedInputObs module.                                               *)
(*                                                                         *)
(* An observation is what fx wrote or what the driver did:                 *)
(*   - join: a follower's session/load answered, with the user chunks its    *)
(*     replay gave. load: the prompt that load sent, which the driver chose *)
(*     (a driver act, like the kind of a prompt); the session uses it from   *)
(*     then on, and each turn's start checks that prompt against fx's.       *)
(*   - start, refuse, queued, pending: what fx did with a prompt: a turn    *)
(*     started (its Gateway request arrived), an error answer came at once,  *)
(*     or fx queued it or held it as a steer (the trace line fx writes).    *)
(*   - chunks, absorb: the user chunk of a prompt, or of a steer the turn   *)
(*     took, on each client's wire.                                         *)
(*   - request: a further model request of the running turn, with its       *)
(*     system prompt.                                                       *)
(*   - finish, stopped: answers on the senders' wires, with their stop      *)
(*     reasons.                                                             *)
(*   - started, idle: a queued prompt that started after the answer of the  *)
(*     turn before it, or nothing started.                                  *)
(*   - cancel, leave: session/cancel, and the follower's disconnect.        *)
(*   - end: the run is over. Nothing runs and nothing waits.                 *)
(*   - unmatched: an answer, chunk or model request that no observation      *)
(*     above took. Every such frame makes the run rejected.                 *)
(*                                                                         *)
(* No step is hidden. Each model step is taken by an observation, so a     *)
(* step fx did not make cannot be filled in by the trace. A run that fx    *)
(* ends early is rejected too: its last observation is not end.           *)
(***************************************************************************)
EXTENDS AcpSharedInput, AcpSharedInputObs, Naturals, Sequences

VARIABLES i

TraceInit == i = 0 /\ Init

\* The code fx answers a prompt that finds a turn running, or a follower's prompt
\* that this model refuses, with: writePromptInProgress (server.zig), -32600. TLA+
\* has no negative literals, so an observation carries the magnitude, 32600.
RefusalCode == 32600

\* Nothing runs and nothing waits: the state after a run.
Quiet == turn = NoReq /\ Pending = {} /\ queue = <<>>

\* The requests that were answered by the turn that ended: its own prompt, and
\* the steers it took (a turn answers each of them when it ends).
TurnDone == {turn} \cup {r \in Req : status[r] = "absorbed"}

\* A follower's session/load: it joins, and its replay gives it the user chunks
\* of the requests in rs. The model's Join records no chunk, so the step adds
\* the replayed ones; the replay is fx's own output, and each such chunk is a
\* delivery the model must account for.
TJoin(rs) ==
    /\ fstate = "absent"
    /\ fstate' = "present"
    /\ chunkTo' = [r \in Req |-> IF r \in rs THEN chunkTo[r] \cup {Follower} ELSE chunkTo[r]]
    /\ UNCHANGED <<status, kindOf, queue, turn, turnStart, turnSys, sysNow, sysBefore,
                   atStart, cancelPending, cancelIgnored, endReason, lastEnded,
                   misrouted, twice, echoBroken, orderBroken, leftRan>>

\* The same load, applied: the session's prompt becomes the one the driver sent
\* with the load (v). The driver's own act, recorded as the load's prompt, not
\* a choice of the trace: a session the load does not change keeps its prompt
\* (Rules FALSE, sysNow' = sysNow), so a load of a new prompt is rejected there.
TLoad(v) == Load /\ sysNow' = v

\* A prompt that starts a turn, with the prompt the turn's Gateway request carried.
TStart(r, k, v) == SendIdle(r, k) /\ turnSys' = v

\* A prompt fx answered at once with an error code.
TRefuse(r, k, code) == SendRefused(r, k) /\ code = RefusalCode

TQueued(r) == SendQueue(r)

TPending(r) == SendSteer(r)

\* The user chunk of r reached exactly the clients in `to`.
TChunks(r, to) == UNCHANGED vars /\ chunkTo[r] = to

\* The steers in rs were taken by the running turn, and reached exactly `to`.
TAbsorb(rs, to) == Absorb /\ Pending = rs /\ (\A r \in rs : chunkTo'[r] = to)

\* A further model request of the running turn carries the turn's prompt.
TRequest(v) == turn # NoReq /\ turnSys = v /\ UNCHANGED vars

\* The turn ended normally; the answers went to exactly rs.
TFinish(rs, ok) == ok /\ TurnDone = rs /\ Finish

\* A queued prompt started, after the turn before it ended, with prompt v.
TStarted(r, v) == turn = r /\ turnSys = v /\ UNCHANGED vars

\* Nothing started after the turn before the queue ended.
TIdle == turn = NoReq /\ UNCHANGED vars

TCancel(c) == RequestCancel(c)

\* The turn ended cancelled, by the client `by` that cancelled it; the answers went to rs.
TStopped(rs, by, ok) == ok /\ TurnDone = rs /\ StopTurn(by)

TLeave == Disconnect

TEnd == Quiet /\ UNCHANGED vars

\* One observation, as the model takes it. Any other observation matches no step.
ClientStep(o) ==
    CASE o.op = "join" -> TJoin(o.rs)
      [] o.op = "load" -> TLoad(o.v)
      [] o.op = "start" -> TStart(o.r, o.k, o.v)
      [] o.op = "refuse" -> TRefuse(o.r, o.k, o.code)
      [] o.op = "queued" -> TQueued(o.r)
      [] o.op = "pending" -> TPending(o.r)
      [] o.op = "chunks" -> TChunks(o.r, o.to)
      [] o.op = "absorb" -> TAbsorb(o.rs, o.to)
      [] o.op = "request" -> TRequest(o.v)
      [] o.op = "finish" -> TFinish(o.rs, o.ok)
      [] o.op = "started" -> TStarted(o.r, o.v)
      [] o.op = "idle" -> TIdle
      [] o.op = "cancel" -> TCancel(o.by)
      [] o.op = "stopped" -> TStopped(o.rs, o.by, o.ok)
      [] o.op = "leave" -> TLeave
      [] o.op = "end" -> TEnd
      [] OTHER -> FALSE

\* There is no hidden step: the trace takes exactly the observations, in order.
TraceNext ==
    /\ i < Len(TraceLog)
    /\ ClientStep(TraceLog[i + 1])
    /\ i' = i + 1

\* TLC violates this at the end of every matched observation, so a run is
\* accepted when TLC reaches its last observation.
NotDone == i < Len(TraceLog)
=============================================================================

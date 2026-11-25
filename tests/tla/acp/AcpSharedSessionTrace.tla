------------------------ MODULE AcpSharedSessionTrace ------------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real fx acp binary,   *)
(* with the clients on stdio and on the leader socket, against             *)
(* AcpSharedSession. TraceLog and the constants come from the generated    *)
(* AcpSharedSessionObs module.                                             *)
(*                                                                         *)
(* An observation is what fx wrote or what the driver did:                 *)
(*   - open: a client opened the session with session/new, or with         *)
(*     session/load or resume.                                             *)
(*   - read: a client read the next message fx wrote to it: its answer, a  *)
(*     list of connected clients, or a prompt's or steer's chunk, with the  *)
(*     client that sent it.                                                *)
(*   - prompt, steer: a client's prompt started a turn, or its steer joined *)
(*     the running turn.                                                   *)
(*   - close: a client left the session, after it had read every message.  *)
(*   - endTurn: the running turn ended.                                    *)
(*   - quiet: the run is over, and every message fx wrote has been read.   *)
(*                                                                         *)
(* No step is hidden: each model step is taken by an observation, in order, *)
(* and a run that fx ends early is rejected, since its last observation is  *)
(* not reached.                                                             *)
(***************************************************************************)
EXTENDS AcpSharedSession, AcpSharedSessionObs, Naturals, Sequences
VARIABLES i
TraceInit == i = 0 /\ Init

\* The next message of `c` is the one the observation names.
TRead(c, kind, n, who, main, from) ==
    /\ Read(c)
    /\ LET m == Head(chan[c]) IN
       /\ m.kind = kind
       /\ m.n = n
       /\ m.who = who
       /\ m.main = main
       /\ IF m.kind \in {"echo", "steer"} THEN m.from = from ELSE TRUE

\* Every message fx wrote for the model has been read: no client has one waiting.
TQuiet == (\A c \in Conns : chan[c] = <<>>) /\ UNCHANGED vars

ClientStep(o) ==
    CASE o.op = "open" -> OpenAs(o.c, o.k)
      [] o.op = "quiet" -> TQuiet
      [] o.op = "read" -> TRead(o.c, o.kind, o.n, o.who, o.main, o.from)
      [] o.op = "prompt" -> Prompt(o.c)
      [] o.op = "steer" -> Steer(o.c)
      [] o.op = "close" -> Close(o.c)
      [] o.op = "endTurn" -> EndTurn
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

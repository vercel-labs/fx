--------------------- MODULE AcpApprovalsTrace ---------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real fx acp binary,   *)
(* with the opener on stdio and a follower on the session's leader socket,  *)
(* against AcpApprovals in design "A" (Rules) or "current" (Today). TraceLog *)
(* and the constants come from the generated AcpApprovalsObs module.        *)
(*                                                                         *)
(* An observation is what fx wrote or what the driver did:                  *)
(*   - join: a client joined. Its copy of the open question, if any, was    *)
(*     written with the join, so the id of that copy is part of the step.    *)
(*   - prompt: a client's prompt started the turn.                          *)
(*   - ask: the turn asked the question. Its copies follow as wrote.        *)
(*   - wrote: a client received its copy, with the id it was given. Under    *)
(*     "current" the copy was written by the ask, so the step only checks it. *)
(*   - answer: a client answered with an id and an option. The model accepts *)
(*     the answer or refuses it. A refusal changes nothing, so the run goes *)
(*     on only when fx shows the effect the model gives to that answer.     *)
(*   - cancel: a client received $/cancel_request for its copy.              *)
(*   - leave: a client left (session/close, or its input ended).            *)
(*   - sessionCancel: a client sent session/cancel for the turn.            *)
(*   - resolved: the turn took the decision, with the decision fx's tool     *)
(*     result shows: "once", "always", or "deny".                           *)
(*   - turnEnd: the turn ended.                                              *)
(*   - end: nothing runs and nothing waits.                                  *)
(*   - unmatched: a frame or a wait that no observation above took. Every    *)
(*     such observation makes the run rejected.                              *)
(*                                                                         *)
(* No step is hidden. Each model step is taken by an observation, so the    *)
(* trace cannot fill in a step that fx did not make. A run that fx ends     *)
(* early is rejected too: its last observation is not end.                 *)
(***************************************************************************)
EXTENDS AcpApprovals, AcpApprovalsObs, Naturals, Sequences

VARIABLES i

TraceInit == i = 0 /\ Init

\* Nothing runs and nothing waits: the state after a run.
Quiet == turn = None /\ ~qOpen

\* A client joins. A question that is still open is registered to it and its
\* copy is written with the join (the lock is held until it is listed), so the
\* observed id k is the id of that copy, or 0 when no copy was written.
TJoin(c, k) ==
    /\ ~open[c] /\ joins < MaxJoins
    /\ open' = [open EXCEPT ![c] = TRUE]
    /\ order' = Append(order, c)
    /\ joins' = joins + 1
    /\ LET reg == qOpen /\ ~qDecided /\ Design # "current" IN
       /\ targets' = IF reg THEN targets \cup {c} ELSE targets
       /\ tid' = IF reg THEN [tid EXCEPT ![c] = nextId[c]] ELSE tid
       /\ nextId' = IF reg THEN [nextId EXCEPT ![c] = nextId[c] + 1] ELSE nextId
       /\ sent' = IF reg THEN [sent EXCEPT ![c] = TRUE] ELSE sent
       /\ k = IF reg THEN tid'[c] ELSE 0
    /\ UNCHANGED <<leaves, turn, prompts, asks, hostId, sid, qOpen, qId, qSender,
                   qDecided, qDecision, qWinner, qWinId, wantSend, wantCancel,
                   cancelled, reasked, refusedValid>>

\* One observation, as the model step it is.
TStep(o) ==
    CASE o.op = "join" -> TJoin(o.c, o.k)
      [] o.op = "prompt" -> Prompt(o.c)
      [] o.op = "ask" -> Ask
      [] o.op = "wrote" -> IF Design = "current"
                           THEN o.c \in targets /\ o.k = tid[o.c] /\ UNCHANGED vars
                           ELSE WriteRequest(o.c) /\ o.k = tid[o.c]
      [] o.op = "answer" -> Answer(o.c, o.k, o.opt)
      [] o.op = "cancel" -> WriteCancel(o.c) /\ o.k = tid[o.c]
      [] o.op = "leave" -> Leave(o.c)
      [] o.op = "sessionCancel" -> Cancel(o.c)
      [] o.op = "resolved" -> Clear /\ qDecision = o.dec
      [] o.op = "turnEnd" -> EndTurn
      [] o.op = "end" -> Quiet /\ UNCHANGED vars
      [] OTHER -> FALSE

TraceNext == i < Len(TraceLog) /\ i' = i + 1 /\ TStep(TraceLog[i + 1])

\* Violated at the end of the run, so TLC's counterexample is the accepted run.
NotDone == i < Len(TraceLog)

=============================================================================

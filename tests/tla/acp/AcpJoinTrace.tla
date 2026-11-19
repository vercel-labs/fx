---------------------------- MODULE AcpJoinTrace ----------------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real fx acp           *)
(* binary, with followers on its leader socket, against AcpJoin.           *)
(* TraceLog and the constants come from the generated AcpJoinObs           *)
(* module.                                                                 *)
(*                                                                         *)
(* An observation is what the driver did, or what fx wrote. The driver     *)
(* starts a turn (start), and fx writes a labelled text to the owner       *)
(* (send) and the owner's prompt answer (end). A follower's join (load     *)
(* or resume) is its items up to the answer. An error answer is a          *)
(* refusal (load_refused, resume_refused). A follower's close, its         *)
(* refused change, and its items at the end of the run (finish) come       *)
(* from its own connection. Agent text maps by its label T<t>K<k>. A       *)
(* notice maps to Note; any other text maps to an item that no model       *)
(* step takes, so the run is rejected.                                     *)
(*                                                                         *)
(* Tails are not text. The driver does not map the title and usage         *)
(* updates, so each joiner's items are compared with the model's, with     *)
(* tails removed. The trace therefore does not check whether a joiner      *)
(* got a tail.                                                             *)
(*                                                                         *)
(* Every other step is hidden: a save before the owner's answer, and a     *)
(* release before the next start, join, or the end of the run. Each        *)
(* one has a comment saying why it cannot let a wrong run pass.            *)
(*                                                                         *)
(* NotDone is violated when every observation has been matched.            *)
(***************************************************************************)
EXTENDS AcpJoin, AcpJoinObs, Naturals, Sequences

VARIABLES i

TraceInit == i = 0 /\ Init

\* The operation the trace takes next, or "none" once every observation is taken.
NextOp == IF i < Len(TraceLog) THEN TraceLog[i + 1].op ELSE "none"

\* The model's tail items. The driver does not map fx's title and usage
\* updates, so a joiner's items are compared with these removed.
TailSet == {TailItem(t) : t \in 1..MaxTurns}

\* fx answered a join with an error. The model's join is not taken, so the
\* joiner is not listed. Allowed only when the model has no join (Rules FALSE).
RefusedJoin(j) == ~Rules /\ joiner[j] = "out" /\ UNCHANGED vars

\* The save runs just before the owner's prompt answer, which the trace
\* observes as end. It writes the turn to the log and frees the turn's copy in
\* one step (prompt.zig:3518), and nothing on the wire shows it. It is taken
\* only when the next observation is that answer, so it cannot move past a
\* send or a join.
HiddenSave == phase = "running" /\ NextOp = "end" /\ Save

\* The release frees the turn's copy after the tail (server.zig:3648). It shows
\* on the wire only through a joiner's replay of the tail, and the driver does
\* not map tails. It is taken only right before the next start, join, or the
\* end of the run. A start needs it, since the model starts a turn only from
\* idle. Before a join or the end of the run it changes only the tails, and
\* the comparison removes tails on both sides, so it cannot turn a wrong text
\* item into a pass.
HiddenRelease ==
    phase = "ending" /\ NextOp \in {"start", "load", "resume", "finish"} /\ Release

Hidden == HiddenSave \/ HiddenRelease

\* One observed step, as the model takes it. Any other operation matches nothing.
\* A send's item must be the item the turn sends next. A join's items, with the
\* tails removed, must be the joiner's sequence up to its answer.
ClientStep(o) ==
    CASE o.op = "start" -> Start
      [] o.op = "send" -> (Send /\ SendItem = o.seq[1])
      [] o.op = "end" -> (SendTail /\ turn = o.n)
      [] o.op = "load" -> (Load(J(o.who)) /\ Keep(got'[J(o.who)], TailSet) = o.seq)
      [] o.op = "resume" -> (Resume(J(o.who)) /\ Keep(got'[J(o.who)], TailSet) = o.seq)
      [] o.op = "load_refused" -> RefusedJoin(J(o.who))
      [] o.op = "resume_refused" -> RefusedJoin(J(o.who))
      [] o.op = "close" -> Close(J(o.who))
      [] o.op = "change_refused" -> FollowerChange(J(o.who))
      [] o.op = "finish" ->
            (joiner[J(o.who)] # "out" /\ Keep(got[J(o.who)], TailSet) = o.seq /\ UNCHANGED vars)
      [] OTHER -> FALSE

TraceNext ==
    \/ /\ i < Len(TraceLog)
       /\ ClientStep(TraceLog[i + 1])
       /\ i' = i + 1
    \/ /\ Hidden
       /\ UNCHANGED i

\* TLC violates this at the end of every matched observation, so a run is
\* accepted when TLC reaches that state and rejected when it does not.
NotDone == i < Len(TraceLog)
=============================================================================

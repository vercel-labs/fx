------------------------- MODULE AcpSessionsTrace -------------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real `fx acp` binary *)
(* against AcpSessions. TraceLog, TRules, TMaxPrompts, and TMaxLoads come  *)
(* from the generated AcpSessionsObs module. Each observation names the   *)
(* step and its arguments, and records what the client saw after it: the  *)
(* answer to every prompt so far, in key order, the session id each       *)
(* update a turn sent carried, the workspace each tool write landed in,    *)
(* and whether the step's request worked.                                 *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a step of the model. Exhausting the search without *)
(* that violation means the run is not a behavior of the model.            *)
(***************************************************************************)
EXTENDS AcpSessions, AcpSessionsObs, Sequences

VARIABLE i

\* The position of prompt key k in an observation's `answers`.
Index(k) == (IF k[1] = "A" THEN 0 ELSE MaxPrompts) + k[2]

StepFor(o) ==
    CASE o.act = "new"      -> NewSession(o.ws)
      [] o.act = "prompt"   -> Prompt(o.sid)
      [] o.act = "stream"   -> Stream(o.sid)
      [] o.act = "write"    -> ToolWrite(o.sid)
      [] o.act = "finish"   -> Finish(o.sid)
      [] o.act = "cancel"   -> Cancel(o.sid)
      [] o.act = "close"    -> Close(o.sid)
      [] o.act \in {"load", "resume"} -> Restore(o.act, o.sid, o.ws)
      [] OTHER              -> FALSE

\* What the client saw after the step, as the model holds it.
Fits(o) ==
    /\ \A k \in Keys : answer'[k] = o.answers[Index(k)]
    /\ {<<t[1], t[2]>> : t \in tags'} = o.tags
    /\ {<<w.key, w.used>> : w \in writes'} = o.writes
    /\ last'.sid = o.sid
    /\ last'.ok = o.ok

ASSUME Len(TraceLog) >= 1 /\ TraceLog[1].act = "init"

TraceInit == /\ i = 1
             /\ Init

TraceNext == /\ i < Len(TraceLog)
             /\ StepFor(TraceLog[i + 1])
             /\ Fits(TraceLog[i + 1])
             /\ i' = i + 1

NotDone == i < Len(TraceLog)
=============================================================================

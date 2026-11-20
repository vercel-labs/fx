----------------------- MODULE AcpSessionStateTrace -----------------------
(***************************************************************************)
(* Trace validation: replays one observed run of the real `fx acp` binary *)
(* on one connection, c1, against AcpSessionState. TraceLog and the        *)
(* constants come from the generated AcpSessionStateObs module.            *)
(*                                                                         *)
(* Each element names one action of the model, with what the driver saw:  *)
(* whether a session/list was refused and the state in each row, the      *)
(* session/status answer, or, at a sync, how many state updates and list  *)
(* hints the client had read once fx answered. Between observations the   *)
(* client may read messages fx wrote (Deliver), which this module counts. *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a step of the model.                                *)
(***************************************************************************)
EXTENDS AcpSessionState, AcpSessionStateObs, Sequences

VARIABLES i, sr, hr

RowState(s) == IF Rules /\ Held(s) THEN st[s] ELSE "none"
Listed(o, s) == o.f = All \/ FolderOf[s] = o.f
Pending == \E k \in 1..Len(chan["c1"]) : chan["c1"][k].kind \in {"state", "hint"}

StepFor(o) ==
    CASE o.act = "open"   -> Open("c1", o.s)
      [] o.act = "close"  -> Close("c1", o.s)
      [] o.act = "prompt" -> Prompt("c1", o.s)
      [] o.act = "end"    -> EndTurn(o.s, o.stop)
      [] o.act = "list"   -> List("c1", o.f)
      [] o.act \in {"status", "sync"} -> UNCHANGED vars
      [] OTHER            -> FALSE

Checked(o) ==
    /\ o.act = "list" =>
         /\ refused' = o.refused
         /\ ~o.refused =>
              \A s \in Sessions : Listed(o, s) =>
                  o.rows[s] = IF saved[s] /\ ~deleted[s] THEN RowState(s) ELSE "absent"
    /\ o.act = "status" => Answer("c1", o.s) = o.answer
    /\ o.act = "sync" => ~Pending /\ sr = o.states /\ hr = o.hints

TraceInit == /\ i = 0 /\ sr = 0 /\ hr = 0
             /\ Init

TraceNext ==
    \/ /\ i < Len(TraceLog)
       /\ StepFor(TraceLog[i + 1])
       /\ Checked(TraceLog[i + 1])
       /\ i' = i + 1
       /\ UNCHANGED <<sr, hr>>
    \/ /\ chan["c1"] # <<>>
       /\ sr' = sr + (IF Head(chan["c1"]).kind = "state" THEN 1 ELSE 0)
       /\ hr' = hr + (IF Head(chan["c1"]).kind = "hint" THEN 1 ELSE 0)
       /\ Deliver("c1")
       /\ UNCHANGED i

NotDone == i < Len(TraceLog)
=============================================================================

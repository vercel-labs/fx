---------------------------- MODULE TraceToolEdit ----------------------------
(***************************************************************************)
(* Checks traces the real file path of `fx tool edit` produced against     *)
(* ToolEdit's "bridge" design.                                              *)
(*                                                                          *)
(* tests/tla/drivers/tool_bridge/traces.ts runs event sequences through the *)
(* harness around the real bridge core, file change, and change tracker,    *)
(* with the program's own writes, another process's write, the program's    *)
(* end or kill, and the socket hang-up. It writes each run as one sequence  *)
(* of states into TraceData.tla. Each state is what the real code showed,   *)
(* with the model's variables. TLC walks every trace.                       *)
(*                                                                          *)
(* ConformsToSpec holds when every recorded step is a step of ToolEdit's    *)
(* Next, so each trace is a behavior of the model. The invariants re-export *)
(* the model's safety properties, checked on what the code did. Liveness    *)
(* needs the whole state space, so ToolEdit.tla checks it, not this module. *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TraceData

VARIABLES prog, seen, call, history, raw, other, req, reviewed, prompt,
          tracker, rows, flags, diffDone, trace, at

vars == <<prog, seen, call, history, raw, other, req, reviewed, prompt,
          tracker, rows, flags, diffDone>>

MC == INSTANCE ToolEdit WITH Design <- "bridge", Mutant <- "none", Class <- "nonideal"

ToSet(s) == {s[i] : i \in DOMAIN s}

Load(s) ==
    /\ prog = s.prog
    /\ seen = s.seen
    /\ call = s.call
    /\ history = s.history
    /\ raw = s.raw
    /\ other = s.other
    /\ req = s.req
    /\ reviewed = ToSet(s.reviewed)
    /\ prompt = s.prompt
    /\ tracker = ToSet(s.tracker)
    /\ rows = s.rows
    /\ flags = s.flags
    /\ diffDone = s.diffDone

LoadNext(s) ==
    /\ prog' = s.prog
    /\ seen' = s.seen
    /\ call' = s.call
    /\ history' = s.history
    /\ raw' = s.raw
    /\ other' = s.other
    /\ req' = s.req
    /\ reviewed' = ToSet(s.reviewed)
    /\ prompt' = s.prompt
    /\ tracker' = ToSet(s.tracker)
    /\ rows' = s.rows
    /\ flags' = s.flags
    /\ diffDone' = s.diffDone

TraceInit == trace \in 1..Len(Traces) /\ at = 1 /\ Load(Traces[trace][1])

TraceNext ==
    /\ at < Len(Traces[trace])
    /\ at' = at + 1
    /\ trace' = trace
    /\ LoadNext(Traces[trace][at + 1])

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, trace, at>>

\* Every trace starts where the model starts.
StartsAtInit == at = 1 => MC!Init

\* Every recorded step is a step of the model.
ConformsToSpec == [][MC!Next]_vars

TypeOK == MC!TypeOK
ExactReview == MC!ExactReview
NoStaleApply == MC!NoStaleApply
NoApplyAfterGone == MC!NoApplyAfterGone
NoAskAfterGone == MC!NoAskAfterGone
ShownOnce == MC!ShownOnce
=============================================================================

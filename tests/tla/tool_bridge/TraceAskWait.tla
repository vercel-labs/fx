---------------------------- MODULE TraceAskWait ----------------------------
(***************************************************************************)
(* Checks traces the real `fx tool ask` path produced against AskWait's    *)
(* design.                                                                 *)
(*                                                                         *)
(* tests/tla/drivers/tool_bridge/ask-traces.ts runs event sequences        *)
(* through the real bridge (`bridge.zig`), `runBridgeAsk` and              *)
(* `QuestionWatch` (`tool_runtime.zig`), the worker's question slot        *)
(* (`worker_runtime.zig`), and `managed_execution`, and writes each run as *)
(* one sequence of states into TraceData.tla. Each state is what the real  *)
(* code showed, with the model's variables. TLC walks every trace.         *)
(*                                                                         *)
(* ConformsToSpec holds when every recorded step is a step of AskWait's    *)
(* Next, so each trace is a behavior of the model. The invariants and      *)
(* properties re-export the model's safety properties on what the code did.*)
(* QuestionEndsWhenGone and CallReturnsWhenGone are liveness in the model. *)
(* A finite trace cannot show liveness, so each run ends with an epilogue  *)
(* that ends its program and its open requests, and these two check the    *)
(* last state.                                                             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TraceData

VARIABLES prog, programs, ui, bash, req, lock, slot, crashed, asked, told,
          trace, at

vars == <<prog, programs, ui, bash, req, lock, slot, crashed, asked, told>>

MC == INSTANCE AskWait WITH Reqs <- {1, 2}, MaxPrograms <- 2,
                            Mutation <- "none"

Load(s) ==
    /\ prog = s.prog
    /\ programs = s.programs
    /\ ui = s.ui
    /\ bash = s.bash
    /\ req = s.req
    /\ lock = s.lock
    /\ slot = s.slot
    /\ crashed = s.crashed
    /\ asked = s.asked
    /\ told = s.told

LoadNext(s) ==
    /\ prog' = s.prog
    /\ programs' = s.programs
    /\ ui' = s.ui
    /\ bash' = s.bash
    /\ req' = s.req
    /\ lock' = s.lock
    /\ slot' = s.slot
    /\ crashed' = s.crashed
    /\ asked' = s.asked
    /\ told' = s.told

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
NoCrash == MC!NoCrash
OneShown == MC!OneShown
SlotIsShown == MC!SlotIsShown
LockIsShown == MC!LockIsShown
OpenOnlyInFirstCall == MC!OpenOnlyInFirstCall
NoQuestionWithoutUi == MC!NoQuestionWithoutUi
NoYieldWhileOpen == MC!NoYieldWhileOpen

\* At the end of a run, a question whose program is gone has ended.
QuestionEndsWhenGone ==
    (at = Len(Traces[trace])) => \A r \in {1, 2} : ~(req[r] = "shown" /\ prog = "gone")

\* At the end of a run, a bash call whose program is gone has returned.
CallReturnsWhenGone ==
    (at = Len(Traces[trace])) => ~(bash \in {"first", "yielded"} /\ prog = "gone")
=============================================================================

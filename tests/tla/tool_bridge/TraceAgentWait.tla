---------------------------- MODULE TraceAgentWait ----------------------------
(***************************************************************************)
(* Checks traces the real `fx tool agent wait` path produced against        *)
(* AgentWait's design.                                                     *)
(*                                                                         *)
(* tests/tla/drivers/tool_bridge/agent-traces.ts runs event sequences       *)
(* through the real managed execution, the subagent host's wait, and the   *)
(* child's mail path, and writes each run as one sequence of states into   *)
(* TraceData.tla. Each state is what the real code showed, with the model's *)
(* variables. TLC walks every trace.                                       *)
(*                                                                         *)
(* ConformsToSpec holds when every recorded step is a step of AgentWait's  *)
(* Next, so each trace is a behavior of the model. The invariants and      *)
(* properties re-export the model's safety properties on what the code did.*)
(* WaitEndsWhenGone and CallReturnsWhenGone are liveness in the model. A   *)
(* finite trace cannot show liveness, so each run ends with an epilogue    *)
(* that ends its program and its wait, and these two check the last state. *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TraceData

VARIABLES prog, programs, call, waits, bash, working, posted, queued,
          joined, lost, told, trace, at

vars == <<prog, programs, call, waits, bash, working, posted, queued,
          joined, lost, told>>

MC == INSTANCE AgentWait WITH MaxPosts <- 2, MaxPrograms <- 2, MaxWaits <- 2,
                              Mutation <- "none"

Load(s) ==
    /\ prog = s.prog
    /\ programs = s.programs
    /\ call = s.call
    /\ waits = s.waits
    /\ bash = s.bash
    /\ working = s.working
    /\ posted = s.posted
    /\ queued = s.queued
    /\ joined = s.joined
    /\ lost = s.lost
    /\ told = s.told

LoadNext(s) ==
    /\ prog' = s.prog
    /\ programs' = s.programs
    /\ call' = s.call
    /\ waits' = s.waits
    /\ bash' = s.bash
    /\ working' = s.working
    /\ posted' = s.posted
    /\ queued' = s.queued
    /\ joined' = s.joined
    /\ lost' = s.lost
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
OpenWaitHasNoMail == MC!OpenWaitHasNoMail
MailKept == MC!MailKept
NoMailLost == MC!NoMailLost
NoYieldWhileHeld == MC!NoYieldWhileHeld

\* At the end of a run, a wait whose program is gone has ended.
WaitEndsWhenGone ==
    (at = Len(Traces[trace])) => ~(call = "waiting" /\ prog = "gone")

\* At the end of a run, a bash call whose program is gone has returned.
CallReturnsWhenGone ==
    (at = Len(Traces[trace])) => ~(bash \in {"first", "more"} /\ prog = "gone")
=============================================================================

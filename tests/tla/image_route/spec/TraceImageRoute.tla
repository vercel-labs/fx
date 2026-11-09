--------------------------- MODULE TraceImageRoute ---------------------------
(***************************************************************************)
(* Checks traces the real core produced against ImageRoute.                *)
(*                                                                         *)
(* tests/tla/drivers/image_route/code-to-spec.ts runs event sequences,     *)
(* with crashes, duplicates, stale replies, and catalog outages, through   *)
(* the harness around src/core/images/image_route.zig and writes each run  *)
(* as one sequence of states into TraceData.tla. Each state is what the    *)
(* core showed (abstract(state) and the effects of the step) plus the      *)
(* event the driver sent.                                                  *)
(*                                                                         *)
(* TLC walks every trace. ConformsToSpec holds when every recorded step is *)
(* a step of ImageRoute's Next, so each trace is a behavior of the model;  *)
(* the law names below re-export the model's laws, checked on what the     *)
(* code did.                                                               *)
(***************************************************************************)
EXTENDS Naturals, Sequences, TraceData

VARIABLES support, resolved, notified, pending, out, act, trace, at

IR == INSTANCE ImageRoute

vars == <<support, resolved, notified, pending, out, act>>

Load(s) ==
    /\ support = s.support
    /\ resolved = s.resolved
    /\ notified = s.notified
    /\ pending = s.pending
    /\ out = s.out
    /\ act = s.act

LoadNext(s) ==
    /\ support' = s.support
    /\ resolved' = s.resolved
    /\ notified' = s.notified
    /\ pending' = s.pending
    /\ out' = s.out
    /\ act' = s.act

TraceInit == trace \in 1..Len(Traces) /\ at = 1 /\ Load(Traces[trace][1])

TraceNext ==
    /\ at < Len(Traces[trace])
    /\ at' = at + 1
    /\ trace' = trace
    /\ LoadNext(Traces[trace][at + 1])

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, trace, at>>

\* Every trace starts where the model starts.
StartsAtInit == at = 1 => IR!Init

\* Every recorded step is a step of the model.
ConformsToSpec == [][IR!Next]_vars

TypeOK == IR!TypeOK
Bounded == IR!Bounded
VisionImpliesNative == IR!VisionImpliesNative
UnknownNeverInline == IR!UnknownNeverInline
OneSnapshot == IR!OneSnapshot
RouteModeCoherent == IR!RouteModeCoherent
NativeExcludesFallback == IR!NativeExcludesFallback
NoSilentWithhold == IR!NoSilentWithhold
RequiredWhenPending == IR!RequiredWhenPending
FailExactlyWhenUnroutable == IR!FailExactlyWhenUnroutable
ResolveOnlyWhenNeeded == IR!ResolveOnlyWhenNeeded
AskedBeforeUnknown == IR!AskedBeforeUnknown
NotifyOnlyWhenDown == IR!NotifyOnlyWhenDown
DecideOnlyWhenReady == IR!DecideOnlyWhenReady
TurnResets == IR!TurnResets
PendingWaitsForReply == IR!PendingWaitsForReply
ResolveOncePerTurn == IR!ResolveOncePerTurn
NotifyOncePerTurn == IR!NotifyOncePerTurn
DuplicateRequestIsQuiet == IR!DuplicateRequestIsQuiet
StaleReplyIsQuiet == IR!StaleReplyIsQuiet
=============================================================================

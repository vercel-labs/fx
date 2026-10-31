---------------------------- MODULE TraceMcpCall ----------------------------
(***************************************************************************)
(* Checks traces the real core produced against McpCall.                   *)
(*                                                                         *)
(* tests/tla/drivers/mcp_call/code-to-spec.ts runs event sequences through *)
(* the harness around src/core/mcp_host/mcp_call.zig, with crashes (the    *)
(* process is killed), forged and revoked tokens, duplicated, late, and    *)
(* garbage answers, disconnects at every stage, lost replies, and stops    *)
(* and subagent ends mid-call. It writes each run as one sequence of       *)
(* states into TraceData.tla. Each state is what the core showed           *)
(* (abstract(state) and the effects of the step) plus the event the driver *)
(* sent. The harness prints sets as JSON arrays; Load reads them as sets.  *)
(*                                                                         *)
(* TLC walks every trace. ConformsToSpec holds when every recorded step is *)
(* a step of McpCall's Next, so each trace is a behavior of the model; the *)
(* law names below re-export the model's laws, checked on what the code    *)
(* did.                                                                    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TraceData

CONSTANTS MaxInFlight, MaxIds

VARIABLES open, registered, next, entries, out, act, trace, at

MC == INSTANCE McpCall

vars == <<open, registered, next, entries, out, act>>

ToSet(s) == {s[i] : i \in DOMAIN s}

Load(s) ==
    /\ open = s.open
    /\ registered = ToSet(s.registered)
    /\ next = s.next
    /\ entries = ToSet(s.entries)
    /\ out = ToSet(s.out)
    /\ act = s.act

LoadNext(s) ==
    /\ open' = s.open
    /\ registered' = ToSet(s.registered)
    /\ next' = s.next
    /\ entries' = ToSet(s.entries)
    /\ out' = ToSet(s.out)
    /\ act' = s.act

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
Bounded == MC!Bounded
IdsBelowNext == MC!IdsBelowNext
EffectsCarryEntryOwner == MC!EffectsCarryEntryOwner
LiveWorkHasOwner == MC!LiveWorkHasOwner
ClosedIsQuiet == MC!ClosedIsQuiet
CrashResets == MC!CrashResets
AdmitOnlyValid == MC!AdmitOnlyValid
RefusalsAreQuiet == MC!RefusalsAreQuiet
FreshIds == MC!FreshIds
CallOnlyFromAuthorizing == MC!CallOnlyFromAuthorizing
StagesOnlyAdvance == MC!StagesOnlyAdvance
OneReplyPerRequest == MC!OneReplyPerRequest
ReplyMatchesOutcome == MC!ReplyMatchesOutcome
StaleIsQuiet == MC!StaleIsQuiet
DroppedStateIsLogged == MC!DroppedStateIsLogged
=============================================================================

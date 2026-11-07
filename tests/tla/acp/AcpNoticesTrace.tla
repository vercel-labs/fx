--------------------------- MODULE AcpNoticesTrace ---------------------------
(***************************************************************************)
(* Trace validation: replays one observed turn of the real `fx acp` binary *)
(* against AcpNotices. The driver generates AcpNoticesObs with Notices,    *)
(* whether the client advertised session.notices, TMaxSteps, and          *)
(* TraceLog, whose elements are                                            *)
(*   [kind, blank, type, severity, same]                                   *)
(* kind is the driver's reading of the text: "any" for a blank message,    *)
(* whose kind no client can tell. type is "message" or "notice"; same says *)
(* whether a message has the messageId of the message before it.          *)
(*                                                                         *)
(* A notices client never sees the blank fragments fx drops, or the start  *)
(* of a model attempt, so those are steps without an observation, at most *)
(* three between two observations.                                         *)
(*                                                                         *)
(* NotDone is a sentinel: TLC reporting it violated means every            *)
(* observation matched a step of the spec. Exhausting the search without  *)
(* that violation means the run is not a behavior of the spec.            *)
(***************************************************************************)
EXTENDS AcpNotices, AcpNoticesObs

VARIABLES i, silent

traceVars == <<vars, i, silent>>

Last == sent[Len(sent)]

Match(o) ==
    /\ Len(sent) > 0
    /\ o.kind = "any" \/ Last.kind = o.kind
    /\ Last.blank = o.blank
    /\ Last.out.type = o.type
    /\ Last.out.severity = o.severity
    /\ o.type = "message" => Last.same = o.same

TraceInit ==
    /\ Init
    /\ notices = Notices
    /\ i = 0
    /\ silent = 0

Observe ==
    /\ i < Len(TraceLog)
    /\ \E o \in {TraceLog[i + 1]}, k \in Kinds, b \in BOOLEAN :
           /\ Emit(k, b)
           /\ Match(o)'
    /\ i' = i + 1
    /\ silent' = 0

Unobserved ==
    /\ silent < 3
    /\ \/ Start
       \/ \E k \in Blankable :
              /\ Emit(k, TRUE)
              /\ (Last.out.type = "none")'
    /\ i' = i
    /\ silent' = silent + 1

TraceNext == Observe \/ Unobserved

\* What a later step can depend on. The history in sent and the message
\* numbers differ between paths that took different unobserved steps, but no
\* later step reads them, so TLC keeps one state per view rather than one per
\* path, which would grow exponentially with the trace. TMaxSteps leaves room
\* for every unobserved step, so the length guard never decides a step.
TraceView == <<notices, group, msgId = lastMsg, i, silent>>

NotDone == i < Len(TraceLog)
=============================================================================

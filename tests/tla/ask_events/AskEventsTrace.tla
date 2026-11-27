--------------------------- MODULE AskEventsTrace ---------------------------
(***************************************************************************)
(* Code-to-spec trace checker for tests/tla/ask_events/AskEvents.tla.      *)
(* Driven by tests/tla/drivers/ask_events/ask_events.test.ts against the   *)
(* built `fx ask --json --events-file` binary.                             *)
(*                                                                         *)
(* NotMatched is a sentinel invariant: TLC reporting it violated means the *)
(* observed binary outcome (exitKind, sinkClosed, stdoutLen, fileLen, and  *)
(* sinkEvents) is reachable in AskEvents (Design = "design-b").            *)
(***************************************************************************)
EXTENDS AskEvents, AskEventsObs

NotMatched ==
    ~( /\ phase \in {"exited", "killed"}
       /\ exitKind = ObsExitKind
       /\ sinkClosed = ObsSinkClosed
       /\ Len(stdoutLines) = ObsStdoutLen
       /\ Len(fileLines) = ObsFileLen
       /\ ObsRequiredEvents \subseteq sinkEvents
       /\ ObsForbiddenEvents \cap sinkEvents = {} )
=============================================================================

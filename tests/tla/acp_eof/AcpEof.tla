------------------------------- MODULE AcpEof -------------------------------
(***************************************************************************)
(* ACP server read-loop end of input (stdin EOF) racing an active prompt   *)
(* thread that starts an outbound client request (permission, host tool,   *)
(* or libfx journal flush), plus session/cancel, session/close, and        *)
(* session/load (src/acp/server.zig, src/acp/prompt.zig).                  *)
(*                                                                         *)
(* Read loop (main thread) and prompt worker thread share `outbound_mutex` *)
(* protecting `outboundClosed`, `reqStatus`, and `cancelFlag`.             *)
(*                                                                         *)
(* Designs:                                                                *)
(*   "current"  - handleCancel(&state, false) marks only existing entries  *)
(*                in pending_outbound; beginOutboundRequest has no closed  *)
(*                check; reapActivePrompt joins unboundedly.               *)
(*   "design-a" - handleEof sets outboundClosed = TRUE under mutex;        *)
(*                beginOutboundRequest refuses when outboundClosed or      *)
(*                session cancelFlag is set (checked under outbound_mutex).*)
(*   "design-b" - reapActivePrompt waits up to D, then re-sweeps           *)
(*                cancelPendingOutbound in a loop until the thread exits.  *)
(*                                                                         *)
(* Mutants:                                                                *)
(*   "none"         - faithful to Design.                                  *)
(*   "no-check"     - Design A sets outboundClosed on EOF, but begin does  *)
(*                    not check it.                                        *)
(*   "unlocked"     - Design A checks outboundClosed before taking the     *)
(*                    lock, then inserts under the lock.                   *)
(*   "cancel-latch" - Design A sets outboundClosed = TRUE on session/cancel*)
(*                    as well as on EOF.                                   *)
(*   "b-no-loop"    - Design B sweeps pending_outbound only once after D.  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Design,   \* "current" | "design-a" | "design-b"
          Mutant,   \* "none" | "no-check" | "unlocked" | "cancel-latch" | "b-no-loop"
          Class     \* "all" | "ideal" | "nonideal"

ReqKinds == {"permission", "host_tool", "journal"}

VARIABLES readerPhase,     \* "reading" | "close_reap" | "eof_cancelling" | "eof_reaping" | "exited"
          promptPhase,     \* "idle" | "running" | "decided_to_ask" | "checked_unlocked"
                           \* | "waiting" | "finished_done" | "finished_cancelled"
          reqKind,         \* "none" \cup ReqKinds
          reqStatus,       \* "none" | "open" | "answered" | "cancelled"
          clientAlive,     \* BOOLEAN: FALSE once stdin hits EOF
          cancelFlag,      \* BOOLEAN: active_session.cancel_flag
          outboundClosed,  \* BOOLEAN: Design A latch set permanently at EOF
          sweepArmed,      \* BOOLEAN: Design B bounded reap timer+loop active
          sweepsLeft,      \* 0..2: remaining sweeps allowed in Design B ("b-no-loop" has 1)
          savedOutcome,    \* "none" | "completed" | "cancelled"
          rejectedOpen,    \* BOOLEAN: TRUE if an open-connection request was refused as closed
          turnsStarted     \* 0..2: bounded number of prompts in a trace

vars == <<readerPhase, promptPhase, reqKind, reqStatus, clientAlive, cancelFlag,
          outboundClosed, sweepArmed, sweepsLeft, savedOutcome, rejectedOpen, turnsStarted>>

TypeOK ==
    /\ readerPhase \in {"reading", "close_reap", "eof_cancelling", "eof_reaping", "exited"}
    /\ promptPhase \in {"idle", "running", "decided_to_ask", "checked_unlocked",
                        "waiting", "finished_done", "finished_cancelled"}
    /\ reqKind \in ({"none"} \cup ReqKinds)
    /\ reqStatus \in {"none", "open", "answered", "cancelled"}
    /\ clientAlive \in BOOLEAN
    /\ cancelFlag \in BOOLEAN
    /\ outboundClosed \in BOOLEAN
    /\ sweepArmed \in BOOLEAN
    /\ sweepsLeft \in 0..2
    /\ savedOutcome \in {"none", "completed", "cancelled"}
    /\ rejectedOpen \in BOOLEAN
    /\ turnsStarted \in 0..2

Init ==
    /\ readerPhase = "reading"
    /\ promptPhase = "idle"
    /\ reqKind = "none"
    /\ reqStatus = "none"
    /\ clientAlive = TRUE
    /\ cancelFlag = FALSE
    /\ outboundClosed = FALSE
    /\ sweepArmed = FALSE
    /\ sweepsLeft = 0
    /\ savedOutcome = "none"
    /\ rejectedOpen = FALSE
    /\ turnsStarted = 0

\* Client sends session/prompt while reading and no prompt is active.
StartPrompt ==
    /\ readerPhase = "reading"
    /\ promptPhase \in {"idle", "finished_done", "finished_cancelled"}
    /\ turnsStarted < 2
    /\ promptPhase' = "running"
    /\ cancelFlag' = FALSE
    /\ reqKind' = "none"
    /\ reqStatus' = "none"
    /\ savedOutcome' = "none"
    /\ turnsStarted' = turnsStarted + 1
    /\ UNCHANGED <<readerPhase, clientAlive, outboundClosed, sweepArmed, sweepsLeft, rejectedOpen>>

\* Prompt decides to ask the client (permission, host tool, or journal flush).
\* Represents entering requestAcpPermission / callHostTool / flushJournal before locking outbound_mutex.
DecideToAsk(k) ==
    /\ Class /= "ideal" \/ clientAlive
    /\ promptPhase = "running"
    /\ ~cancelFlag
    /\ k \in ReqKinds
    /\ promptPhase' = "decided_to_ask"
    /\ reqKind' = k
    /\ UNCHANGED <<readerPhase, reqStatus, clientAlive, cancelFlag, outboundClosed,
                   sweepArmed, sweepsLeft, savedOutcome, rejectedOpen, turnsStarted>>

\* Non-atomic mutant: reads outboundClosed before acquiring outbound_mutex.
CheckUnlocked ==
    /\ Design = "design-a" /\ Mutant = "unlocked"
    /\ promptPhase = "decided_to_ask"
    /\ IF outboundClosed
       THEN /\ promptPhase' = "finished_cancelled"
            /\ savedOutcome' = "cancelled"
            /\ reqKind' = "none"
            /\ reqStatus' = "none"
       ELSE /\ promptPhase' = "checked_unlocked"
            /\ savedOutcome' = savedOutcome
            /\ reqKind' = reqKind
            /\ reqStatus' = reqStatus
    /\ UNCHANGED <<readerPhase, clientAlive, cancelFlag, outboundClosed,
                   sweepArmed, sweepsLeft, rejectedOpen, turnsStarted>>

\* Prompt inserts the outbound request under outbound_mutex and waits in awaitOutboundResponse.
BeginOutbound ==
    /\ (promptPhase = "decided_to_ask" /\ ~(Design = "design-a" /\ Mutant = "unlocked"))
       \/ (promptPhase = "checked_unlocked" /\ Design = "design-a" /\ Mutant = "unlocked")
    /\ LET refuseAsClosed ==
               /\ Design = "design-a"
               /\ Mutant /= "no-check"
               /\ Mutant /= "unlocked"
               /\ (outboundClosed \/ cancelFlag)
       IN IF refuseAsClosed
          THEN /\ IF clientAlive /\ ~cancelFlag
                  THEN rejectedOpen' = TRUE
                  ELSE rejectedOpen' = rejectedOpen
               /\ promptPhase' = "finished_cancelled"
               /\ savedOutcome' = "cancelled"
               /\ reqKind' = "none"
               /\ reqStatus' = "none"
          ELSE /\ promptPhase' = "waiting"
               /\ reqStatus' = "open"
               /\ rejectedOpen' = rejectedOpen
               /\ savedOutcome' = savedOutcome
               /\ reqKind' = reqKind
    /\ UNCHANGED <<readerPhase, clientAlive, cancelFlag, outboundClosed,
                   sweepArmed, sweepsLeft, turnsStarted>>

\* Client answers the waiting outbound request (only possible while stdin is open).
ClientAnswer ==
    /\ clientAlive
    /\ readerPhase = "reading"
    /\ promptPhase = "waiting"
    /\ reqStatus = "open"
    /\ reqStatus' = "answered"
    /\ UNCHANGED <<readerPhase, promptPhase, reqKind, clientAlive, cancelFlag,
                   outboundClosed, sweepArmed, sweepsLeft, savedOutcome, rejectedOpen, turnsStarted>>

\* Prompt resumes after outbound response arrives (answered or cancelled).
ResumeAfterResponse ==
    /\ promptPhase = "waiting"
    /\ reqStatus \in {"answered", "cancelled"}
    /\ IF reqStatus = "cancelled" \/ cancelFlag
       THEN /\ promptPhase' = "finished_cancelled"
            /\ savedOutcome' = "cancelled"
       ELSE /\ promptPhase' = "running"
            /\ savedOutcome' = savedOutcome
    /\ reqKind' = "none"
    /\ reqStatus' = "none"
    /\ UNCHANGED <<readerPhase, clientAlive, cancelFlag, outboundClosed,
                   sweepArmed, sweepsLeft, rejectedOpen, turnsStarted>>

\* Prompt observes cancelFlag while running (without waiting on outbound).
PromptObserveCancel ==
    /\ promptPhase \in {"running", "decided_to_ask"}
    /\ cancelFlag
    /\ promptPhase' = "finished_cancelled"
    /\ savedOutcome' = "cancelled"
    /\ reqKind' = "none"
    /\ reqStatus' = "none"
    /\ UNCHANGED <<readerPhase, clientAlive, cancelFlag, outboundClosed,
                   sweepArmed, sweepsLeft, rejectedOpen, turnsStarted>>

\* Prompt finishes normally when not cancelled.
PromptFinishDone ==
    /\ promptPhase = "running"
    /\ ~cancelFlag
    /\ promptPhase' = "finished_done"
    /\ savedOutcome' = "completed"
    /\ UNCHANGED <<readerPhase, reqKind, reqStatus, clientAlive, cancelFlag,
                   outboundClosed, sweepArmed, sweepsLeft, rejectedOpen, turnsStarted>>

\* Client sends session/cancel while reading.
SessionCancel ==
    /\ readerPhase = "reading"
    /\ cancelFlag' = (promptPhase \in {"running", "decided_to_ask", "checked_unlocked", "waiting"})
    /\ IF reqStatus = "open"
       THEN reqStatus' = "cancelled"
       ELSE reqStatus' = reqStatus
    /\ IF Design = "design-a" /\ Mutant = "cancel-latch"
       THEN outboundClosed' = TRUE
       ELSE outboundClosed' = outboundClosed
    /\ UNCHANGED <<readerPhase, promptPhase, reqKind, clientAlive,
                   sweepArmed, sweepsLeft, savedOutcome, rejectedOpen, turnsStarted>>

\* Client sends session/close or session/load while reading -> cancelAndReapActivePrompt.
SessionCloseOrLoadStart ==
    /\ readerPhase = "reading"
    /\ readerPhase' = "close_reap"
    /\ cancelFlag' = (promptPhase \in {"running", "decided_to_ask", "checked_unlocked", "waiting"})
    /\ IF reqStatus = "open"
       THEN reqStatus' = "cancelled"
       ELSE reqStatus' = reqStatus
    /\ IF Design = "design-b"
       THEN /\ sweepArmed' = TRUE
            /\ sweepsLeft' = IF Mutant = "b-no-loop" THEN 1 ELSE 2
       ELSE /\ sweepArmed' = sweepArmed
            /\ sweepsLeft' = sweepsLeft
    /\ UNCHANGED <<promptPhase, reqKind, clientAlive, outboundClosed,
                   savedOutcome, rejectedOpen, turnsStarted>>

SessionCloseOrLoadDone ==
    /\ readerPhase = "close_reap"
    /\ promptPhase \in {"idle", "finished_done", "finished_cancelled"}
    /\ readerPhase' = "reading"
    /\ promptPhase' = "idle"
    /\ cancelFlag' = FALSE
    /\ sweepArmed' = FALSE
    /\ sweepsLeft' = 0
    /\ savedOutcome' = "none"
    /\ UNCHANGED <<reqKind, reqStatus, clientAlive, outboundClosed,
                   rejectedOpen, turnsStarted>>

\* Stdin hits EOF (may happen at any step while reading).
EofReadLoop ==
    /\ Class /= "ideal"
    /\ readerPhase = "reading"
    /\ clientAlive' = FALSE
    /\ readerPhase' = "eof_cancelling"
    /\ UNCHANGED <<promptPhase, reqKind, reqStatus, cancelFlag, outboundClosed,
                   sweepArmed, sweepsLeft, savedOutcome, rejectedOpen, turnsStarted>>

\* Ideal-class clean quit when idle (for simulate-ideal).
CleanShutdown ==
    /\ readerPhase = "reading"
    /\ promptPhase \in {"idle", "finished_done", "finished_cancelled"}
    /\ clientAlive' = FALSE
    /\ readerPhase' = "eof_cancelling"
    /\ UNCHANGED <<promptPhase, reqKind, reqStatus, cancelFlag, outboundClosed,
                   sweepArmed, sweepsLeft, savedOutcome, rejectedOpen, turnsStarted>>

\* handleCancel(&state, false) runs once after read loop exits on EOF, then enters reapActivePrompt.
EofHandleCancel ==
    /\ readerPhase = "eof_cancelling"
    /\ readerPhase' = "eof_reaping"
    /\ cancelFlag' = TRUE
    /\ IF reqStatus = "open"
       THEN reqStatus' = "cancelled"
       ELSE reqStatus' = reqStatus
    /\ IF Design = "design-a"
       THEN outboundClosed' = TRUE
       ELSE outboundClosed' = outboundClosed
    /\ IF Design = "design-b"
       THEN /\ sweepArmed' = TRUE
            /\ sweepsLeft' = IF Mutant = "b-no-loop" THEN 1 ELSE 2
       ELSE /\ sweepArmed' = FALSE
            /\ sweepsLeft' = 0
    /\ UNCHANGED <<promptPhase, reqKind, clientAlive, savedOutcome, rejectedOpen, turnsStarted>>

\* Design B bounded join timeout fires during eof_reaping and re-sweeps pending_outbound.
\* In design-b it repeats in a loop until the prompt thread finishes; in mutant b-no-loop
\* it sweeps only once and stops arming.
ReapTimeoutSweep ==
    /\ Design = "design-b"
    /\ readerPhase \in {"eof_reaping", "close_reap"}
    /\ sweepArmed
    /\ sweepsLeft > 0
    /\ IF reqStatus = "open"
       THEN reqStatus' = "cancelled"
       ELSE reqStatus' = reqStatus
    /\ IF Mutant = "b-no-loop"
       THEN /\ sweepsLeft' = 0
            /\ sweepArmed' = FALSE
       ELSE /\ sweepsLeft' = sweepsLeft
            /\ sweepArmed' = TRUE
    /\ UNCHANGED <<readerPhase, promptPhase, reqKind, clientAlive, cancelFlag,
                   outboundClosed, savedOutcome, rejectedOpen, turnsStarted>>

\* reapActivePrompt(self, true) joins once prompt thread is done -> process exits.
ReapFinishExit ==
    /\ readerPhase = "eof_reaping"
    /\ promptPhase \in {"idle", "finished_done", "finished_cancelled"}
    /\ readerPhase' = "exited"
    /\ sweepArmed' = FALSE
    /\ UNCHANGED <<promptPhase, reqKind, reqStatus, clientAlive, cancelFlag,
                   outboundClosed, sweepsLeft, savedOutcome, rejectedOpen, turnsStarted>>

Done ==
    /\ readerPhase = "exited"
    /\ UNCHANGED vars

Next ==
    \/ StartPrompt
    \/ \E k \in ReqKinds : DecideToAsk(k)
    \/ CheckUnlocked
    \/ BeginOutbound
    \/ ClientAnswer
    \/ ResumeAfterResponse
    \/ PromptObserveCancel
    \/ PromptFinishDone
    \/ SessionCancel
    \/ SessionCloseOrLoadStart
    \/ SessionCloseOrLoadDone
    \/ EofReadLoop
    \/ CleanShutdown
    \/ EofHandleCancel
    \/ ReapTimeoutSweep
    \/ ReapFinishExit
    \/ Done

Spec == Init /\ [][Next]_vars

FairSpec ==
    Spec
    /\ WF_vars(CheckUnlocked)
    /\ WF_vars(BeginOutbound)
    /\ WF_vars(ResumeAfterResponse)
    /\ WF_vars(PromptObserveCancel)
    /\ WF_vars(SessionCloseOrLoadDone)
    /\ WF_vars(EofHandleCancel)
    /\ WF_vars(ReapTimeoutSweep)
    /\ WF_vars(ReapFinishExit)
    /\ WF_vars(ClientAnswer)

-----------------------------------------------------------------------------
(* Invariants & Properties *)

\* After EOF (or close/load cancel-and-reap), no outbound request can sit
\* open without an active bounded sweep to cancel it.
NoWaitAfterEof ==
    (readerPhase \in {"eof_reaping", "close_reap"} /\ promptPhase = "waiting" /\ reqStatus = "open") =>
        (sweepArmed /\ sweepsLeft > 0)

\* Stronger Design A property: once EOF closed the registry, no new outbound
\* request enters waiting at all.
NoNewOutboundAfterEof ==
    (readerPhase = "eof_reaping") => ~(promptPhase = "waiting" /\ reqStatus = "open")

\* Before EOF, an uncancelled outbound request is never refused as closed.
ClientStillServed ==
    ~rejectedOpen

\* Any turn that ends by observing cancel persists outcome "cancelled".
CancelledTurnSaved ==
    (promptPhase = "finished_cancelled") => (savedOutcome = "cancelled")

\* After EOF, the process always reaches exited.
BoundedExit ==
    (~clientAlive) ~> (readerPhase = "exited")

\* Every outbound waiter after EOF eventually leaves waiting as cancelled.
WaitersEndCancelled ==
    []((readerPhase = "eof_reaping" /\ promptPhase = "waiting") =>
        <> (promptPhase = "finished_cancelled"))

=============================================================================

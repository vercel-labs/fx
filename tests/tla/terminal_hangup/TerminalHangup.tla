--------------------------- MODULE TerminalHangup ---------------------------
(***************************************************************************)
(* Interactive TUI terminal hang-up vs open-terminal EIO classification.   *)
(*                                                                         *)
(* Two actors:                                                             *)
(*   1. Terminal: can close cleanly, close with late poll signs            *)
(*      ("closing_eio_only" -> "hung_up" / "revoked"), become revoked      *)
(*      (macOS POLLNVAL), orphan fx's process group (EIO, poll shows 0),   *)
(*      or deliver SIGHUP at any time (before or after an I/O error).      *)
(*   2. fx: runs startup -> idle <-> turn_running / frame_write /          *)
(*      alt_screen -> exiting -> done.                                     *)
(*                                                                         *)
(* Designs:                                                                *)
(*   - "current": today's code (missing POLLNVAL in pollInput, raw read,   *)
(*     raw writeLifecycleTerminalBytes, initFailure missing hangup check). *)
(*   - "design_a": classify at each site via shared terminalGone +         *)
(*     POLLNVAL in pollInput + isTerminalHangUp in initFailure.            *)
(*   - "design_b": POLLNVAL in pollInput + classify once at exit in        *)
(*     app_entry_runtime (initFailure + run catch).                        *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
  Design,   \* "current" | "design_a" | "design_b"
  Mutant,   \* "none" | "no_init_hangup" | "no_pollnval" | "no_orphan_check" | "blind_eio" | "no_exit_check"
  Class     \* "all" | "ideal" | "nonideal"

ASSUME Design \in {"current", "design_a", "design_b"}
ASSUME Mutant \in {"none", "no_init_hangup", "no_pollnval", "no_orphan_check", "blind_eio", "no_exit_check"}
ASSUME Class \in {"all", "ideal", "nonideal"}

VARIABLES
  termState,          \* "open" | "closing_eio_only" | "hung_up" | "revoked" | "orphaned"
  phase,              \* "startup" | "idle" | "turn_running" | "frame_write" | "alt_screen" | "exiting" | "done"
  sighupPending,      \* BOOLEAN: SIGHUP delivered, closerMain not yet finished
  turnActive,         \* BOOLEAN: a turn is currently running
  errKind,            \* "none" | "eio_lifecycle" | "eio_read" | "sync_recovery_failed" | "terminal_hung_up" | "eof"
  errOnOpenTerm,      \* BOOLEAN: TRUE if errKind occurred while termState = "open"
  failedInInit,       \* BOOLEAN: TRUE if failure occurred in startup (initFailure)
  outcome,            \* "running" | "quiet_hangup" | "saved_turn_hangup" | "error_reported"
  msgPrinted,         \* "none" | "disk" | "terminal_hung_up" | "sync_failed"
  crashSaved,         \* BOOLEAN
  turnSavedForResume, \* BOOLEAN
  spinCount,          \* 0..2: consecutive pollInput spins on a revoked terminal
  altScreen           \* BOOLEAN: alternate screen toggle state

vars == <<
  termState, phase, sighupPending, turnActive, errKind, errOnOpenTerm,
  failedInInit, outcome, msgPrinted, crashSaved, turnSavedForResume,
  spinCount, altScreen
>>

Init ==
  /\ termState = "open"
  /\ phase = "startup"
  /\ sighupPending = FALSE
  /\ turnActive = FALSE
  /\ errKind = "none"
  /\ errOnOpenTerm = FALSE
  /\ failedInInit = FALSE
  /\ outcome = "running"
  /\ msgPrinted = "none"
  /\ crashSaved = FALSE
  /\ turnSavedForResume = FALSE
  /\ spinCount = 0
  /\ altScreen = FALSE

Running == outcome = "running" /\ phase # "done"

(* --------------------------- Terminal Actor ------------------------------ *)

TerminalCloseClean ==
  /\ Running
  /\ termState = "open"
  /\ Class = "ideal" => phase = "idle"
  /\ termState' \in (IF Class = "ideal" THEN {"hung_up"} ELSE {"hung_up", "revoked"})
  /\ UNCHANGED <<phase, sighupPending, turnActive, errKind, errOnOpenTerm,
                 failedInInit, outcome, msgPrinted, crashSaved,
                 turnSavedForResume, spinCount, altScreen>>

TerminalCloseLateSigns ==
  /\ Running
  /\ Class # "ideal"
  /\ termState = "open"
  /\ termState' = "closing_eio_only"
  /\ UNCHANGED <<phase, sighupPending, turnActive, errKind, errOnOpenTerm,
                 failedInInit, outcome, msgPrinted, crashSaved,
                 turnSavedForResume, spinCount, altScreen>>

TerminalSignsArrive ==
  /\ Running
  /\ termState = "closing_eio_only"
  /\ termState' \in {"hung_up", "revoked"}
  /\ UNCHANGED <<phase, sighupPending, turnActive, errKind, errOnOpenTerm,
                 failedInInit, outcome, msgPrinted, crashSaved,
                 turnSavedForResume, spinCount, altScreen>>

TerminalOrphanGroup ==
  /\ Running
  /\ Class # "ideal"
  /\ termState = "open"
  /\ phase # "startup"
  /\ termState' = "orphaned"
  /\ UNCHANGED <<phase, sighupPending, turnActive, errKind, errOnOpenTerm,
                 failedInInit, outcome, msgPrinted, crashSaved,
                 turnSavedForResume, spinCount, altScreen>>

DeliverSighup ==
  /\ Running
  /\ ~sighupPending
  /\ Class = "ideal" => phase = "idle"
  /\ sighupPending' = TRUE
  /\ UNCHANGED <<termState, phase, turnActive, errKind, errOnOpenTerm,
                 failedInInit, outcome, msgPrinted, crashSaved,
                 turnSavedForResume, spinCount, altScreen>>

(* ------------------------------ fx Actor --------------------------------- *)

\* Helper: does Design A classify an EIO at a write/read site as hang-up?
DesignASeesGone(ts) ==
  \/ Mutant = "blind_eio"
  \/ ts \in {"hung_up", "revoked", "closing_eio_only"} \* closing_eio_only resolved via bounded wait
  \/ (ts = "orphaned" /\ Mutant # "no_orphan_check")

LifecycleWrite(fromStartup) ==
  /\ Running
  /\ IF termState = "open"
     THEN
       \/ /\ phase' = IF fromStartup THEN "idle" ELSE (IF turnActive THEN "turn_running" ELSE "idle")
          /\ altScreen' = IF fromStartup THEN altScreen ELSE ~altScreen
          /\ UNCHANGED <<termState, errKind, errOnOpenTerm, failedInInit>>
       \/ /\ Class # "ideal"
          /\ phase' = "exiting"
          /\ errOnOpenTerm' = TRUE
          /\ failedInInit' = fromStartup
          /\ errKind' = IF Design = "design_a" /\ Mutant = "blind_eio"
                        THEN "terminal_hung_up"
                        ELSE "eio_lifecycle"
          /\ UNCHANGED <<termState, altScreen>>
     ELSE
       /\ phase' = "exiting"
       /\ errOnOpenTerm' = FALSE
       /\ failedInInit' = fromStartup
       /\ IF Design = "design_a" /\ DesignASeesGone(termState)
          THEN
            /\ errKind' = "terminal_hung_up"
            /\ termState' = IF termState = "closing_eio_only" THEN "hung_up" ELSE termState
          ELSE
            /\ errKind' = "eio_lifecycle"
            /\ UNCHANGED termState
       /\ UNCHANGED altScreen
  /\ UNCHANGED <<sighupPending, turnActive, outcome, msgPrinted, crashSaved,
                 turnSavedForResume, spinCount>>

StartupLifecycleWrite ==
  /\ phase = "startup"
  /\ LifecycleWrite(TRUE)

EnterOrLeaveAltScreen ==
  /\ phase \in {"idle", "turn_running"}
  /\ LifecycleWrite(FALSE)

StartTurn ==
  /\ Running
  /\ phase = "idle"
  /\ termState = "open"
  /\ ~sighupPending
  /\ phase' = "turn_running"
  /\ turnActive' = TRUE
  /\ UNCHANGED <<termState, sighupPending, errKind, errOnOpenTerm,
                 failedInInit, outcome, msgPrinted, crashSaved,
                 turnSavedForResume, spinCount, altScreen>>

FinishTurn ==
  /\ Running
  /\ phase = "turn_running"
  /\ phase' = "idle"
  /\ turnActive' = FALSE
  /\ UNCHANGED <<termState, sighupPending, errKind, errOnOpenTerm,
                 failedInInit, outcome, msgPrinted, crashSaved,
                 turnSavedForResume, spinCount, altScreen>>

BeginFrameWrite ==
  /\ Running
  /\ phase \in {"idle", "turn_running"}
  /\ phase' = "frame_write"
  /\ UNCHANGED <<termState, sighupPending, turnActive, errKind, errOnOpenTerm,
                 failedInInit, outcome, msgPrinted, crashSaved,
                 turnSavedForResume, spinCount, altScreen>>

FinishFrameWrite ==
  /\ Running
  /\ phase = "frame_write"
  /\ IF termState = "open"
     THEN
       \/ /\ phase' = IF turnActive THEN "turn_running" ELSE "idle"
          /\ UNCHANGED <<termState, errKind, errOnOpenTerm, failedInInit>>
       \/ /\ Class # "ideal"
          /\ phase' = "exiting"
          /\ errOnOpenTerm' = TRUE
          /\ failedInInit' = FALSE
          /\ errKind' = IF Design = "design_a" /\ Mutant = "blind_eio"
                        THEN "terminal_hung_up"
                        ELSE "sync_recovery_failed"
          /\ UNCHANGED termState
     ELSE
       /\ phase' = "exiting"
       /\ errOnOpenTerm' = FALSE
       /\ failedInInit' = FALSE
       /\ IF \/ termState \in {"hung_up", "revoked"}
             \/ (Design = "design_a" /\ DesignASeesGone(termState))
          THEN
            /\ errKind' = "terminal_hung_up"
            /\ termState' = IF termState = "closing_eio_only" THEN "hung_up" ELSE termState
          ELSE
            /\ errKind' = "sync_recovery_failed"
            /\ UNCHANGED termState
  /\ UNCHANGED <<sighupPending, turnActive, outcome, msgPrinted, crashSaved,
                 turnSavedForResume, spinCount, altScreen>>

PollAndReadInput ==
  /\ Running
  /\ phase \in {"idle", "turn_running"}
  /\ CASE termState = "open" ->
            \/ /\ UNCHANGED <<termState, phase, errKind, errOnOpenTerm, failedInInit, spinCount>>
            \/ /\ Class # "ideal"
               /\ phase' = "exiting"
               /\ errOnOpenTerm' = TRUE
               /\ failedInInit' = FALSE
               /\ errKind' = IF Design = "design_a" /\ Mutant = "blind_eio" THEN "eof" ELSE "eio_read"
               /\ UNCHANGED <<termState, spinCount>>
       [] termState = "hung_up" ->
            /\ phase' = "exiting"
            /\ errOnOpenTerm' = FALSE
            /\ failedInInit' = FALSE
            /\ UNCHANGED <<termState, spinCount>>
            /\ \/ errKind' = "eof"
               \* POLLIN | POLLHUP enters TerminalState.read and hits EIO on some kernels
               \/ (Class # "ideal" /\ errKind' = IF Design = "design_a" /\ DesignASeesGone("hung_up")
                                                 THEN "eof"
                                                 ELSE "eio_read")
       [] termState = "revoked" ->
            IF Design = "current" \/ Mutant = "no_pollnval"
            THEN
              \* pollInput ignores POLLNVAL -> event loop spins without closing!
              /\ spinCount' = IF spinCount < 2 THEN spinCount + 1 ELSE 2
              /\ UNCHANGED <<termState, phase, errKind, errOnOpenTerm, failedInInit>>
            ELSE
              /\ phase' = "exiting"
              /\ errKind' = "eof"
              /\ errOnOpenTerm' = FALSE
              /\ failedInInit' = FALSE
              /\ UNCHANGED <<termState, spinCount>>
       [] termState \in {"closing_eio_only", "orphaned"} ->
            /\ phase' = "exiting"
            /\ errOnOpenTerm' = FALSE
            /\ failedInInit' = FALSE
            /\ spinCount' = 0
            /\ IF Design = "design_a" /\ DesignASeesGone(termState)
               THEN
                 /\ errKind' = "eof"
                 /\ termState' = IF termState = "closing_eio_only" THEN "hung_up" ELSE termState
               ELSE
                 /\ errKind' = "eio_read"
                 /\ UNCHANGED termState
  /\ UNCHANGED <<sighupPending, turnActive, outcome, msgPrinted, crashSaved,
                 turnSavedForResume, altScreen>>

HandleSighup ==
  /\ Running
  /\ sighupPending
  /\ phase # "exiting"
  /\ phase' = "done"
  /\ turnSavedForResume' = (turnActive \/ turnSavedForResume)
  /\ outcome' = IF turnActive THEN "saved_turn_hangup" ELSE "quiet_hangup"
  /\ msgPrinted' = "none"
  /\ crashSaved' = FALSE
  /\ UNCHANGED <<termState, sighupPending, turnActive, errKind, errOnOpenTerm,
                 failedInInit, spinCount, altScreen>>

ExitClassify ==
  /\ Running
  /\ phase = "exiting"
  /\ LET
       directHup ==
         \/ errKind = "eof"
         \/ (errKind = "terminal_hung_up" /\
               (~failedInInit \/ (Design # "current" /\ Mutant # "no_init_hangup")))
       designBExitGone ==
         /\ Design = "design_b"
         /\ Mutant # "no_exit_check"
         /\ errKind \in {"eio_lifecycle", "eio_read", "sync_recovery_failed"}
         /\ (Mutant = "blind_eio" \/ termState \in {"closing_eio_only", "hung_up", "revoked", "orphaned"})
       isHup == directHup \/ designBExitGone
     IN
       /\ phase' = "done"
       /\ termState' = IF designBExitGone /\ termState = "closing_eio_only" THEN "hung_up" ELSE termState
       /\ IF isHup
          THEN
            /\ turnSavedForResume' = IF (~failedInInit /\ turnActive) THEN TRUE ELSE turnSavedForResume
            /\ outcome' = IF turnActive THEN "saved_turn_hangup" ELSE "quiet_hangup"
            /\ msgPrinted' = "none"
            /\ crashSaved' = FALSE
          ELSE
            /\ outcome' = "error_reported"
            /\ crashSaved' = ~failedInInit
            /\ msgPrinted' = CASE errKind = "terminal_hung_up"     -> "terminal_hung_up"
                              [] errKind = "sync_recovery_failed" -> "sync_failed"
                              [] OTHER                            -> "disk"
            /\ UNCHANGED turnSavedForResume
  /\ UNCHANGED <<sighupPending, turnActive, errKind, errOnOpenTerm,
                 failedInInit, spinCount, altScreen>>

UserQuit ==
  /\ Running
  /\ phase = "idle"
  /\ termState = "open"
  /\ ~sighupPending
  /\ phase' = "done"
  /\ outcome' = "quiet_hangup"
  /\ msgPrinted' = "none"
  /\ crashSaved' = FALSE
  /\ UNCHANGED <<termState, sighupPending, turnActive, errKind, errOnOpenTerm,
                 failedInInit, turnSavedForResume, spinCount, altScreen>>

Finished == phase = "done" /\ outcome # "running"

Next ==
  \/ TerminalCloseClean
  \/ TerminalCloseLateSigns
  \/ TerminalSignsArrive
  \/ TerminalOrphanGroup
  \/ DeliverSighup
  \/ StartupLifecycleWrite
  \/ EnterOrLeaveAltScreen
  \/ StartTurn
  \/ FinishTurn
  \/ BeginFrameWrite
  \/ FinishFrameWrite
  \/ PollAndReadInput
  \/ HandleSighup
  \/ ExitClassify
  \/ UserQuit
  \/ (Finished /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

(* Weak fairness on progress/exit actions so every finite run terminates.   *)
FairSpec ==
  /\ Spec
  /\ WF_vars(StartupLifecycleWrite)
  /\ WF_vars(FinishFrameWrite)
  /\ SF_vars(FinishTurn)
  /\ WF_vars(PollAndReadInput)
  /\ WF_vars(TerminalSignsArrive)
  /\ WF_vars(HandleSighup)
  /\ WF_vars(ExitClassify)
  /\ SF_vars(UserQuit)

(* ------------------------------ Invariants ------------------------------- *)

TypeOK ==
  /\ termState \in {"open", "closing_eio_only", "hung_up", "revoked", "orphaned"}
  /\ phase \in {"startup", "idle", "turn_running", "frame_write", "alt_screen", "exiting", "done"}
  /\ outcome \in {"running", "quiet_hangup", "saved_turn_hangup", "error_reported"}
  /\ msgPrinted \in {"none", "disk", "terminal_hung_up", "sync_failed"}

(* R1: When the terminal is gone, fx ends quietly through the hang-up path:  *)
(* no disk/hangup message, no crash report, and a running turn is saved.    *)
GoneIsQuiet ==
  (outcome # "running" /\ ~errOnOpenTerm /\
     (termState # "open" \/ errKind \in {"eof", "terminal_hung_up"} \/ sighupPending)) =>
    /\ outcome \in {"quiet_hangup", "saved_turn_hangup"}
    /\ msgPrinted = "none"
    /\ ~crashSaved
    /\ (turnActive => turnSavedForResume)

(* R2: A real EIO while the terminal is still open and fx owns it is not    *)
(* hidden: it keeps today's error report and (post-init) crash report.      *)
OpenEioIsReported ==
  (outcome # "running" /\ errOnOpenTerm /\ termState = "open" /\ ~sighupPending) =>
    /\ outcome = "error_reported"
    /\ msgPrinted \in {"disk", "sync_failed"}
    /\ (~failedInInit => crashSaved)

(* R3: A revoked terminal (POLLNVAL) never makes the event loop spin.       *)
NoSpin == spinCount <= 1

Termination == <>Finished
=============================================================================

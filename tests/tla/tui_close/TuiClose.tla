------------------------------ MODULE TuiClose ------------------------------
(***************************************************************************)
(* How the interactive TUI ends when an outside signal reaches it.        *)
(*                                                                         *)
(* The TUI turns the terminal into raw mode and draws on the alternate     *)
(* screen. Ending it must give back both: the screen modes (alternate      *)
(* screen, mouse, bracketed paste) and the tty mode the shell found        *)
(* (raw mode turns off canonical input, echo, and ISIG). In raw mode a     *)
(* Ctrl-C is a key, so an outside SIGINT is the only INT that arrives.     *)
(*                                                                         *)
(* Design "current" (src/core/app/app_lifecycle.zig) installs a close      *)
(* handler for SIGTERM and SIGHUP after raw mode turns on. The close       *)
(* writes the screen modes and re-raises. It never restores the tty mode.  *)
(* SIGINT keeps its default action: no handler, no save, no restore.       *)
(*                                                                         *)
(* Design "a": SIGINT joins the closer. The handlers are installed before  *)
(* raw mode, after the found tty mode is saved. The closer restores the    *)
(* saved tty mode before it re-raises. The normal shutdown's guard holds   *)
(* SIGINT ignored, and the shutdown's uninstall never restores SIGINT.     *)
(*                                                                         *)
(* Design "b": while the event loop runs, SIGINT is a graceful exit        *)
(* request. The loop reads the request and runs the normal shutdown, which *)
(* saves the request in flight clean before it cancels the turn. Outside   *)
(* the loop, and on a second SIGINT before the loop has begun the shutdown, *)
(* SIGINT is the closer. TERM and HUP close as in design "a".              *)
(*                                                                         *)
(* Process phases:                                                         *)
(* - "setup": before the handlers and raw mode are both in place.         *)
(* - "run": the event loop: idle, a turn running, the alternate screen.   *)
(* - "shut": the normal shutdown, guarded (SIGINT ignored) from its start. *)
(* - "errshut": the error or hang-up shutdown: no guard.                  *)
(* - "ended": the process is gone.                                        *)
(*                                                                         *)
(* A close signal ends the process in one of two ways. The closer runs as  *)
(* one step (Ideal, or the closer thread did not start: the in-handler     *)
(* fallback), or in two steps (CloseStart, CloseFinish) with the main      *)
(* thread free to act between them. A second close signal while the closer *)
(* runs is absorbed (the compare-and-swap in closeSignalHandler). A signal  *)
(* whose default action applies ends the process with nothing restored.    *)
(*                                                                         *)
(* Rules, each an invariant:                                               *)
(* - TtyRestored: after a close signal ends fx, the tty mode and the       *)
(*   screen are the ones fx found at startup.                              *)
(* - NormalTtyRestored: after a normal or error exit, the tty mode is the  *)
(*   found one (today's releaseTerminal does this).                        *)
(* - CloseSavesRequest: a request in flight at a close, or at a graceful   *)
(*   SIGINT exit, is saved as a clean close. Resume.tla NoFalseCrashQuestion *)
(*   says the same for a close: a close is not a crash.                    *)
(* - ShutdownNotCut: a SIGINT during the normal shutdown does not end fx   *)
(*   before the shutdown finishes (GracefulExitSigintGuard).               *)
(* - OneCloser: two close signals at once run the close steps once.        *)
(*                                                                         *)
(* Bug plants one defect in a design. Each config names the one rule that  *)
(* must catch it. Ideal runs the closer as one step and never blocks the   *)
(* loop; with Ideal FALSE the closer's steps interleave, and the loop may  *)
(* be blocked (design b). Resume.tla and Recovery.tla model the request    *)
(* across processes; this model stops at the process's own tty, screen,   *)
(* handlers, and phases, which neither of them models.                     *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Design,   \* "current", "a", or "b"
    Bug,      \* "none", or one defect planted in the design
    Ideal     \* TRUE: the closer is one step and the loop never blocks

Designs == {"current", "a", "b"}
Bugs == {"none", "no_tty", "int_uninstall", "no_once", "cancel", "no_guard", "early_uninstall", "minimal_handler"}

ASSUME Design \in Designs /\ Bug \in Bugs /\ Ideal \in BOOLEAN

Sigs == {"INT", "TERM", "HUP"}

VARIABLES
    phase,       \* "setup", "run", "shut", "errshut", "ended"
    setup,       \* "pre", "raw_only", "hand_only", "ready"
    closerUp,    \* the closer thread started; FALSE: the in-handler fallback
    handled,     \* TERM and HUP run the closer (their handler is installed)
    intDisp,     \* SIGINT's disposition: "default", "ign", "closer", "graceful"
    tty,         \* "cooked" or "raw"
    screen,      \* "normal" or "alt"
    req,         \* "none" or "running": a model request in flight
    rec,         \* "none" or "clean": the request's saved record
    closing,     \* the closer has started and has not finished
    closeRuns,   \* closer runs started in this process
    closeSig,    \* the signal the closer runs for
    stage,       \* shutdown stage: "none", "release", "release_modes", "release_tty", "persist", "release_uninst", "done"
    minimal,     \* planted defect minimal_handler: TERM/HUP restore tty/screen without saving the request
    exitWanted,  \* design b: a graceful SIGINT waits for the loop
    loopBlocked, \* design b: the loop cannot take the request now
    endCause,    \* "none", "signal", "graceful_sig", "user", "error"
    sigWithReq,  \* a request was in flight when the exit saved or ended
    cut          \* a SIGINT ended fx while the normal shutdown was running

vars == <<phase, setup, closerUp, handled, intDisp, tty, screen, req, rec,
          closing, closeRuns, closeSig, stage, minimal, exitWanted, loopBlocked,
          endCause, sigWithReq, cut>>

-----------------------------------------------------------------------------
(* Definitions.                                                            *)

Alive == phase \in {"setup", "run", "shut", "errshut"}

\* Whether the closer restores the found tty mode before it re-raises.
RestoresTty == Design \in {"a", "b"} /\ Bug # "no_tty"

\* What a SIGINT does now. A graceful request is only for the loop; the
\* loop's own shutdown ignores SIGINT through the guard.
IntDo ==
    IF phase = "run" /\ intDisp = "graceful" /\ ~exitWanted THEN "graceful"
    ELSE IF intDisp = "ign" THEN "ign"
    ELSE IF intDisp \in {"closer", "graceful"} THEN "closer"
    ELSE "default"

\* Whether a TERM, HUP, or SIGINT reaches the closer.
ClosesOn(s) ==
    \/ (s \in {"TERM", "HUP"} /\ handled)
    \/ (s = "INT" /\ IntDo = "closer")

-----------------------------------------------------------------------------
(* Initial state and types.                                                *)

Init ==
    /\ phase = "setup" /\ setup = "pre"
    /\ closerUp = FALSE /\ handled = FALSE
    /\ intDisp = "default"
    /\ tty = "cooked" /\ screen = "normal"
    /\ req = "none" /\ rec = "none"
    /\ closing = FALSE /\ closeRuns = 0 /\ closeSig = "none"
    /\ stage = "none" /\ minimal = FALSE
    /\ exitWanted = FALSE /\ loopBlocked = FALSE
    /\ endCause = "none" /\ sigWithReq = FALSE /\ cut = FALSE

TypeOK ==
    /\ phase \in {"setup", "run", "shut", "errshut", "ended"}
    /\ setup \in {"pre", "raw_only", "hand_only", "ready"}
    /\ closerUp \in BOOLEAN /\ handled \in BOOLEAN
    /\ intDisp \in {"default", "ign", "closer", "graceful"}
    /\ tty \in {"cooked", "raw"} /\ screen \in {"normal", "alt"}
    /\ req \in {"none", "running"} /\ rec \in {"none", "clean"}
    /\ closing \in BOOLEAN /\ closeRuns \in 0..2
    /\ closeSig \in {"none", "INT", "TERM", "HUP"}
    /\ stage \in {"none", "release", "release_modes", "release_tty", "persist", "release_uninst", "done"}
    /\ minimal \in BOOLEAN
    /\ exitWanted \in BOOLEAN /\ loopBlocked \in BOOLEAN
    /\ endCause \in {"none", "signal", "graceful_sig", "user", "error"}
    /\ sigWithReq \in BOOLEAN /\ cut \in BOOLEAN

-----------------------------------------------------------------------------
(* Startup. The current design runs raw mode before its handlers exist (the *)
(* window at app_lifecycle.zig:1014-1016). Designs a and b install first.  *)

\* Design a and b: the handlers and the found tty mode come before raw mode.
EarlyInstall ==
    /\ Design \in {"a", "b"} /\ phase = "setup" /\ setup = "pre"
    /\ setup' = "hand_only"
    /\ closerUp' \in BOOLEAN
    /\ handled' = TRUE
    /\ intDisp' = IF Design = "a" THEN "closer" ELSE "graceful"
    /\ UNCHANGED <<phase, tty, screen, req, rec, closing, closeRuns, closeSig,
                   stage, minimal, exitWanted, loopBlocked, endCause, sigWithReq, cut>>

\* Raw mode on: current first, then (after its window) its handlers; a and b
\* after their handlers.
RawOn ==
    /\ phase = "setup" /\ tty = "cooked"
    /\ \/ /\ Design = "current" /\ setup = "pre"
          /\ setup' = "raw_only"
          /\ phase' = "setup"
       \/ /\ Design \in {"a", "b"} /\ setup = "hand_only"
          /\ setup' = "ready"
          /\ phase' = "run"
    /\ tty' = "raw"
    /\ UNCHANGED <<closerUp, handled, intDisp, screen, req, rec, closing,
                   closeRuns, closeSig, stage, minimal, exitWanted, loopBlocked,
                   endCause, sigWithReq, cut>>

\* Current design: its close handlers go in after raw mode.
CurrentInstall ==
    /\ Design = "current" /\ phase = "setup" /\ setup = "raw_only"
    /\ setup' = "ready"
    /\ phase' = "run"
    /\ closerUp' \in BOOLEAN
    /\ handled' = TRUE
    /\ UNCHANGED <<intDisp, tty, screen, req, rec, closing, closeRuns, closeSig,
                   stage, minimal, exitWanted, loopBlocked, endCause, sigWithReq, cut>>

-----------------------------------------------------------------------------
(* The event loop: screens and requests.                                   *)

OpenAlt ==
    /\ phase = "run" /\ screen = "normal" /\ ~closing
    /\ screen' = "alt"
    /\ UNCHANGED <<phase, setup, closerUp, handled, intDisp, tty, req, rec,
                   closing, closeRuns, closeSig, stage, minimal, exitWanted,
                   loopBlocked, endCause, sigWithReq, cut>>

CloseAlt ==
    /\ phase = "run" /\ screen = "alt" /\ ~closing
    /\ screen' = "normal"
    /\ UNCHANGED <<phase, setup, closerUp, handled, intDisp, tty, req, rec,
                   closing, closeRuns, closeSig, stage, minimal, exitWanted,
                   loopBlocked, endCause, sigWithReq, cut>>

StartReq ==
    /\ phase = "run" /\ req = "none" /\ ~closing
    /\ req' = "running"
    /\ UNCHANGED <<phase, setup, closerUp, handled, intDisp, tty, screen, rec,
                   closing, closeRuns, closeSig, stage, minimal, exitWanted,
                   loopBlocked, endCause, sigWithReq, cut>>

FinishReq ==
    /\ phase = "run" /\ req = "running"
    /\ req' = "none" /\ rec' = "none"
    /\ UNCHANGED <<phase, setup, closerUp, handled, intDisp, tty, screen,
                   closing, closeRuns, closeSig, stage, minimal, exitWanted,
                   loopBlocked, endCause, sigWithReq, cut>>

\* The loop stops taking requests for a while (design b's graceful path
\* waits for it). Only in the non-ideal runs.
Block ==
    /\ ~Ideal /\ phase = "run" /\ ~loopBlocked
    /\ loopBlocked' = TRUE
    /\ UNCHANGED <<phase, setup, closerUp, handled, intDisp, tty, screen, req,
                   rec, closing, closeRuns, closeSig, stage, minimal, exitWanted,
                   endCause, sigWithReq, cut>>

Unblock ==
    /\ ~Ideal /\ loopBlocked
    /\ loopBlocked' = FALSE
    /\ UNCHANGED <<phase, setup, closerUp, handled, intDisp, tty, screen, req,
                   rec, closing, closeRuns, closeSig, stage, minimal, exitWanted,
                   endCause, sigWithReq, cut>>

-----------------------------------------------------------------------------
(* Signals. Each one takes its route from SIGINT's disposition and the     *)
(* handler table.                                                          *)

\* No handler: the signal kills fx at once. Nothing is restored, saved, or
\* ended cleanly. With minimal_handler (Design B), TERM/HUP restore tty/screen
\* in the shutdown window without saving an active request.
SigKill(s) ==
    /\ Alive /\ ~closing
    /\ \/ (s = "INT" /\ IntDo = "default")
       \/ (s \in {"TERM", "HUP"} /\ ~handled)
    /\ phase' = "ended"
    /\ endCause' = "signal"
    /\ sigWithReq' = (req = "running")
    /\ cut' = (cut \/ (s = "INT" /\ phase = "shut"))
    /\ tty' = IF s \in {"TERM", "HUP"} /\ minimal THEN "cooked" ELSE tty
    /\ screen' = IF s \in {"TERM", "HUP"} /\ minimal THEN "normal" ELSE screen
    /\ UNCHANGED <<setup, closerUp, handled, intDisp, req, rec,
                   closing, closeRuns, closeSig, stage, minimal, exitWanted, loopBlocked>>

\* The closer as one step: the in-handler fallback, or Ideal.
CloseNow(s) ==
    /\ Alive /\ ~closing /\ closeRuns < 2
    /\ ClosesOn(s)
    /\ (Ideal \/ ~closerUp)
    /\ closeRuns' = closeRuns + 1
    /\ rec' = IF req = "running" THEN "clean" ELSE rec
    /\ sigWithReq' = (req = "running")
    /\ tty' = IF RestoresTty THEN "cooked" ELSE tty
    /\ screen' = "normal"
    /\ phase' = "ended"
    /\ endCause' = "signal"
    /\ closeSig' = s
    /\ cut' = (cut \/ (s = "INT" /\ phase = "shut"))
    /\ UNCHANGED <<setup, closerUp, handled, intDisp, req, closing, stage,
                   minimal, exitWanted, loopBlocked>>

\* The closer's first step, with the thread running: the main thread may act
\* until CloseFinish. A second close signal is absorbed while it runs, except
\* in the planted defect no_once.
CloseStart(s) ==
    /\ Alive /\ ClosesOn(s) /\ ~Ideal /\ closerUp /\ closeRuns < 2
    /\ (~closing \/ Bug = "no_once")
    /\ closing' = TRUE
    /\ closeRuns' = closeRuns + 1
    /\ closeSig' = s
    /\ UNCHANGED <<phase, setup, closerUp, handled, intDisp, tty, screen, req,
                   rec, stage, minimal, exitWanted, loopBlocked, endCause, sigWithReq,
                   cut>>

CloseFinish ==
    /\ closing
    /\ closing' = FALSE
    /\ rec' = IF req = "running" THEN "clean" ELSE rec
    /\ sigWithReq' = (req = "running")
    /\ tty' = IF RestoresTty THEN "cooked" ELSE tty
    /\ screen' = "normal"
    /\ phase' = "ended"
    /\ endCause' = "signal"
    /\ cut' = (cut \/ (closeSig = "INT" /\ phase = "shut"))
    /\ UNCHANGED <<setup, closerUp, handled, intDisp, req, closeRuns, closeSig,
                   stage, minimal, exitWanted, loopBlocked>>

\* Design b: a graceful SIGINT while the loop runs asks it to exit. A second
\* SIGINT before the loop acts takes the closer route (IntDo).
GracefulInt ==
    /\ phase = "run" /\ intDisp = "graceful" /\ ~exitWanted /\ ~closing
    /\ exitWanted' = TRUE
    /\ UNCHANGED <<phase, setup, closerUp, handled, intDisp, tty, screen, req,
                   rec, closing, closeRuns, closeSig, stage, minimal, loopBlocked,
                   endCause, sigWithReq, cut>>

\* The loop reads the request, saves the request in flight clean (except the
\* planted defect cancel), and starts the normal shutdown with the guard on.
LoopExit ==
    /\ phase = "run" /\ exitWanted /\ ~loopBlocked /\ ~closing
    /\ exitWanted' = FALSE
    /\ phase' = "shut" /\ stage' = "release"
    /\ intDisp' = IF Bug = "no_guard" THEN intDisp ELSE "ign"
    /\ endCause' = "graceful_sig"
    /\ sigWithReq' = (req = "running")
    /\ rec' = IF req = "running" /\ Bug # "cancel" THEN "clean" ELSE rec
    /\ req' = "none"
    /\ UNCHANGED <<setup, closerUp, handled, tty, screen, closing, closeRuns,
                   closeSig, minimal, loopBlocked, cut>>

-----------------------------------------------------------------------------
(* Exits by the program itself.                                            *)

\* The user quits (/exit or double Ctrl-C). A running request stays active
\* until shutdownForProcessExit finishes persistence (main.zig:1003-1049).
ExitUser ==
    /\ phase = "run" /\ ~closing /\ ~exitWanted
    /\ phase' = "shut" /\ stage' = "release"
    /\ intDisp' = IF Bug = "no_guard" THEN intDisp ELSE "ign"
    /\ endCause' = "user"
    /\ UNCHANGED <<setup, closerUp, handled, tty, screen, req, rec, closing,
                   closeRuns, closeSig, minimal, exitWanted, loopBlocked, sigWithReq,
                   cut>>

\* The run fails. The shutdown after it has no SIGINT guard.
RunError ==
    /\ phase = "run" /\ ~closing
    /\ phase' = "errshut" /\ stage' = "release"
    /\ endCause' = "error"
    /\ req' = "none"
    /\ UNCHANGED <<setup, closerUp, handled, intDisp, tty, screen, rec, closing,
                   closeRuns, closeSig, minimal, exitWanted, loopBlocked, sigWithReq,
                   cut>>

\* Step 1 of releaseTerminal (leaveAlternateScreens).
ReleaseAlt ==
    /\ phase \in {"shut", "errshut"} /\ stage = "release" /\ ~closing
    /\ screen' = "normal"
    /\ stage' = "release_modes"
    /\ UNCHANGED <<phase, setup, closerUp, handled, intDisp, tty, req, rec,
                   closing, closeRuns, closeSig, minimal, exitWanted, loopBlocked,
                   endCause, sigWithReq, cut>>

\* Current code & planted defects (early_uninstall, minimal_handler) remove the
\* close handlers BEFORE disableRawMode turns raw mode off.
UninstallBeforeRaw ==
    /\ phase \in {"shut", "errshut"} /\ stage = "release_modes" /\ ~closing
    /\ (Design = "current" \/ Bug \in {"early_uninstall", "minimal_handler"})
    /\ handled' = FALSE
    /\ minimal' = (Bug = "minimal_handler")
    /\ intDisp' = IF Bug = "int_uninstall" /\ Design = "a" THEN "default" ELSE intDisp
    /\ stage' = "release_tty"
    /\ UNCHANGED <<phase, setup, closerUp, tty, screen, req, rec, closing,
                   closeRuns, closeSig, exitWanted, loopBlocked, endCause,
                   sigWithReq, cut>>

\* normalExitRestoreSequence + disableRawMode: restores cooked tty.
DisableRaw ==
    /\ phase \in {"shut", "errshut"} /\ ~closing
    /\ \/ (stage = "release_tty" /\ (Design = "current" \/ Bug \in {"early_uninstall", "minimal_handler"}))
       \/ (stage = "release_modes" /\ Design \in {"a", "b"} /\ Bug \notin {"early_uninstall", "minimal_handler"})
    /\ tty' = "cooked"
    /\ minimal' = FALSE
    /\ stage' = "persist"
    /\ UNCHANGED <<phase, setup, closerUp, handled, intDisp, screen, req, rec,
                   closing, closeRuns, closeSig, exitWanted, loopBlocked,
                   endCause, sigWithReq, cut>>

\* Persist (shutdownForProcessExit): finishes stopping/settling any active
\* request; user /exit cancels it once Persist finishes, whereas a TERM/HUP
\* arriving before Persist saved it via closerMain (CloseSavesRequest).
Persist ==
    /\ phase \in {"shut", "errshut"} /\ stage = "persist" /\ ~closing
    /\ req' = "none"
    /\ stage' = IF Design \in {"a", "b"} /\ Bug \notin {"early_uninstall", "minimal_handler"}
                THEN "release_uninst" ELSE "done"
    /\ UNCHANGED <<phase, setup, closerUp, handled, intDisp, tty, screen, rec,
                   closing, closeRuns, closeSig, minimal, exitWanted, loopBlocked,
                   endCause, sigWithReq, cut>>

\* Design a & b: uninstall close handlers AFTER tty is cooked and persistence finished.
UninstallAfterPersist ==
    /\ phase \in {"shut", "errshut"} /\ stage = "release_uninst" /\ ~closing
    /\ handled' = FALSE
    /\ intDisp' = IF Bug = "int_uninstall" /\ Design = "a" THEN "default" ELSE intDisp
    /\ stage' = "done"
    /\ UNCHANGED <<phase, setup, closerUp, tty, screen, req, rec, closing,
                   closeRuns, closeSig, minimal, exitWanted, loopBlocked,
                   endCause, sigWithReq, cut>>

Finish ==
    /\ phase \in {"shut", "errshut"} /\ stage = "done" /\ ~closing
    /\ phase' = "ended"
    /\ UNCHANGED <<setup, closerUp, handled, intDisp, tty, screen, req, rec,
                   closing, closeRuns, closeSig, stage, minimal, exitWanted,
                   loopBlocked, endCause, sigWithReq, cut>>

Done == phase = "ended" /\ UNCHANGED vars

-----------------------------------------------------------------------------

Next ==
    \/ EarlyInstall \/ RawOn \/ CurrentInstall
    \/ OpenAlt \/ CloseAlt \/ StartReq \/ FinishReq
    \/ Block \/ Unblock
    \/ GracefulInt \/ LoopExit
    \/ ExitUser \/ RunError \/ ReleaseAlt \/ UninstallBeforeRaw \/ DisableRaw \/ Persist \/ UninstallAfterPersist \/ Finish
    \/ CloseFinish
    \/ \E s \in Sigs : SigKill(s) \/ CloseNow(s) \/ CloseStart(s)
    \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules. Each one is an invariant that the configs name.                  *)

TtyRestored == endCause = "signal" => (tty = "cooked" /\ screen = "normal")

NormalTtyRestored ==
    (phase = "ended" /\ endCause \in {"user", "error", "graceful_sig"})
        => tty = "cooked"

CloseSavesRequest ==
    (endCause \in {"signal", "graceful_sig"} /\ sigWithReq) => rec = "clean"

ShutdownNotCut == ~cut

OneCloser == closeRuns <= 1
=============================================================================

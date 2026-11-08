--------------------------- MODULE TerminalRevoke ---------------------------
(***************************************************************************)
(* What fx's interactive input loop and its terminal cleanup do when the   *)
(* terminal behind stdin goes away, and under job control:                 *)
(* src/ui/event_loop.zig run and readInput, and in                         *)
(* src/ui/shell_runtime.zig TerminalState.pollInput (through               *)
(* pollResultFromRevents), inputGone, and disableRawMode, which restores   *)
(* the terminal through tcsetattrBestEffort in src/core/shared/io.zig.     *)
(*                                                                         *)
(* The terminal is one of:                                                 *)
(*   "live"     working: a poll waits its timeout, or reports POLLIN when  *)
(*              input is queued                                            *)
(*   "hungup"   its other side closed: POLLHUP (with POLLIN while input    *)
(*              is still queued), and tcsetattr fails with EIO             *)
(*   "revoked"  revoke(2) on macOS: queued input is gone; a poll fx was    *)
(*              already waiting in wakes with POLLHUP, and every poll      *)
(*              after that reports POLLNVAL alone, at once; tcsetattr      *)
(*              fails with ENOENT. Where eio holds, as macOS 15 answered   *)
(*              for a revoked controlling terminal, every poll reports     *)
(*              POLLIN alone and every read fails with EIO. Either way     *)
(*              tcgetattr fails.                                           *)
(*   "closed"   the descriptor is no longer open: POLLNVAL, and tcsetattr  *)
(*              fails with EBADF                                           *)
(* Writes to a terminal that is gone fail.                                 *)
(*                                                                         *)
(* No SIGHUP reaches fx here: the terminal is not fx's controlling         *)
(* terminal, or SIGHUP is blocked or ignored.                              *)
(*                                                                         *)
(* Three callers put stdin in raw mode and restore it on the way out, and  *)
(* site names the one that runs. "shell" is the interactive shell above.   *)
(* "team_picker" is the team picker of fx login and fx teams               *)
(* (TeamPickerRawMode in src/core/auth/login_flow.zig), and "masked_key"   *)
(* is the API key prompt of fx login vercel --api-key (MaskedKeyRawMode    *)
(* in src/core/cli/cli_surface.zig). A prompt reads stdin directly, with   *)
(* no poll. It returns when the person answers (PromptReturns), or when    *)
(* a read on a terminal that is gone fails or reads 0, the end of input    *)
(* (PromptRead), and then restores the terminal through the same Restore.  *)
(* A read of 0 is the end of input: macOS answers it for a revoked         *)
(* terminal unless eio holds, and for one whose other side closed. The     *)
(* team picker used to take it as a key to ignore and read again, at once, *)
(* forever (Bug = "picker_ignores_eof").                                   *)
(*                                                                         *)
(* Job control moves fx between the foreground ("fg"), stopped, and the    *)
(* background ("bg"). Ctrl+Z (Suspend) stops fx. With SIGTTIN and SIGTTOU  *)
(* at their default (stops), a background fx stops at its first terminal   *)
(* call, the tcsetattr its resume makes, so bg leaves it stopped. A parent *)
(* that ignores them lets fx run in the background, where a read fails     *)
(* with EIO on a terminal that is still there. fx keeps its behavior from  *)
(* before the change there: it reports the read error and exits 1. A poll  *)
(* in the background reports queued input here, as Linux does; macOS       *)
(* reports none, so fx never reads there.                                  *)
(*                                                                         *)
(* One Poll is one pass of the loop's waiting poll and what follows it:    *)
(* read, end the loop, or commit a frame and poll again. A pass with       *)
(* nothing to do waits out its timeout on a live terminal; on a terminal   *)
(* that is gone, poll returns at once, so the pass is a spin, and spins    *)
(* counts them. After a read, Drain is the loop's poll(0) and the frame    *)
(* commit for what it read. Restore is one tcsetattr call, which a signal  *)
(* can interrupt with EINTR.                                               *)
(*                                                                         *)
(* Bug plants one defect; check.sh names the rule that must catch each.    *)
(* Bug = "today" is fx before the change: POLLNVAL was dropped, the        *)
(* restore went through std.posix.tcsetattr, which treats EBADF and EINVAL *)
(* as unreachable and reports ENOENT as an unexpected errno, and every     *)
(* read that failed with EIO ended fx with an error. Bug =                 *)
(* "prompts_strict" is fx with the shell's fix but not the prompts': the   *)
(* team picker and the masked key prompt still restore through             *)
(* std.posix.tcsetattr. Bug = "picker_ignores_eof" is fx with every        *)
(* restore fixed and the team picker still reading again after a read of 0.*)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS MaxSpins, MaxIntr, Bug

Bugs == {"none", "today", "prompts_strict", "picker_ignores_eof", "nval_ignored", "badf_unreachable",
         "enoent_unexpected", "no_eintr_retry", "eio_always_eof", "eio_poll_only"}
Sites == {"shell", "team_picker", "masked_key"}
ASSUME Bug \in Bugs

VARIABLES
    tty,      \* "live", "hungup", "revoked", or "closed"
    waking,   \* a revoke woke the poll fx was waiting in
    queued,   \* input waits to be read
    dirty,    \* fx read input it has not drawn yet
    phase,    \* "loop", "cleanup", "exited", or "crashed"
    cause,    \* why the loop ended: "none", "requested", "input_closed",
              \* "write_failed", "read_failed", or "prompt_failed"
    spins,    \* passes of the loop that returned at once with nothing to do
    intr,     \* EINTRs the environment can still deliver to the restore
    restore,  \* "pending", "restored", "gone", "error", or "lost"
    job,      \* "fg", "stopped", or "bg"
    eio,      \* a revoked terminal polls as readable and fails reads with EIO
    stops,    \* SIGTTIN and SIGTTOU keep their default action
    site,     \* "shell", "team_picker", or "masked_key": who restores the terminal
    eof       \* a prompt's read returned 0, the end of input

vars == <<tty, waking, queued, dirty, phase, cause, spins, intr, restore, job, eio, stops, site, eof>>

Init ==
    /\ tty = "live"
    /\ waking = FALSE
    /\ queued = FALSE
    /\ dirty = FALSE
    /\ phase = "loop"
    /\ cause = "none"
    /\ spins = 0
    /\ intr = MaxIntr
    /\ restore = "pending"
    /\ job = "fg"
    /\ eio \in BOOLEAN
    /\ stops \in BOOLEAN
    /\ site \in Sites
    /\ eof = FALSE

Gone == tty # "live"
Running == phase \in {"loop", "cleanup"}

-----------------------------------------------------------------------------
(* The poll (TerminalState.pollInput) and its mapping to PollResult.        *)

Revents ==
    CASE tty = "live"    -> IF queued THEN {"IN"} ELSE {}
      [] tty = "hungup"  -> IF queued THEN {"IN", "HUP"} ELSE {"HUP"}
      [] tty = "revoked" -> IF eio THEN {"IN"} ELSE IF waking THEN {"HUP"} ELSE {"NVAL"}
      [] tty = "closed"  -> {"NVAL"}

Readable(r) == "IN" \in r

\* PollResult.closed(): hung_up or has_error. The fix counts POLLNVAL as an
\* error (pollResultFromRevents).
Closed(r) ==
    \/ "HUP" \in r
    \/ "ERR" \in r
    \/ "NVAL" \in r /\ Bug \notin {"today", "nval_ignored"}

EndLoop(c) ==
    /\ phase' = "cleanup"
    /\ cause' = c

\* read(2) fails with EIO: on a revoked terminal where eio holds, and for a
\* background read that SIGTTIN does not stop.
ReadFails ==
    \/ tty = "revoked" /\ eio
    \/ tty = "live" /\ job = "bg"

\* The second check after a read fails with EIO (TerminalState.inputGone): a
\* fresh poll that reports POLLHUP, POLLERR, or POLLNVAL, or a tcgetattr that
\* fails.
PollShowsGone ==
    \/ tty = "hungup"
    \/ tty = "revoked" /\ ~eio
    \/ tty = "closed"
TcgetattrFails == tty \in {"revoked", "closed"}

\* Whether the loop takes a read that failed with EIO as the end of input
\* (event_loop.zig readInput). Otherwise it reports the error.
EndsInput ==
    CASE Bug = "today"          -> FALSE
      [] Bug = "eio_always_eof" -> TRUE
      [] Bug = "eio_poll_only"  -> PollShowsGone
      [] OTHER                  -> PollShowsGone \/ TcgetattrFails

\* The loop's answer to a read that failed with EIO.
ReadFailed == EndLoop(IF EndsInput THEN "input_closed" ELSE "read_failed")

\* One pass of event_loop.run's waiting poll.
Poll ==
    /\ site = "shell"
    /\ phase = "loop"
    /\ job # "stopped"
    /\ ~dirty
    /\ waking' = FALSE
    /\ LET r == Revents IN
       IF Readable(r)
       THEN IF ReadFails
            THEN /\ ReadFailed
                 /\ UNCHANGED <<tty, queued, dirty, spins, intr, restore, job, eio, stops, site, eof>>
            ELSE IF queued
            \* The bytes are read and handled; one of them may ask fx to quit,
            \* which ends the loop before any frame is drawn.
            THEN /\ queued' = FALSE
                 /\ \E quit \in BOOLEAN :
                        IF quit THEN /\ EndLoop("requested")
                                     /\ UNCHANGED dirty
                                ELSE /\ dirty' = TRUE
                                     /\ UNCHANGED <<phase, cause>>
                 /\ UNCHANGED <<tty, spins, intr, restore, job, eio, stops, site, eof>>
            \* read returned 0: the end of input.
            ELSE /\ EndLoop("input_closed")
                 /\ UNCHANGED <<tty, queued, dirty, spins, intr, restore, job, eio, stops, site, eof>>
       ELSE IF Closed(r)
       THEN /\ EndLoop("input_closed")
            /\ UNCHANGED <<tty, queued, dirty, spins, intr, restore, job, eio, stops, site, eof>>
       \* Nothing to do: settle, commit a frame, and poll again. On a live
       \* terminal that pass waited its timeout; on one that is gone it
       \* returned at once.
       ELSE /\ IF Gone THEN /\ spins < MaxSpins
                            /\ spins' = spins + 1
                       ELSE UNCHANGED spins
            /\ UNCHANGED <<tty, queued, dirty, phase, cause, intr, restore, job, eio, stops, site, eof>>

\* After a read: the loop's poll(0), then the frame for what it read. A poll
\* that still reports input reads again, and a read that fails with EIO gets
\* the loop's answer to it. Input that closed by now ends the loop, and a
\* final frame that fails to write is only logged; a frame written to a
\* terminal that is gone fails and ends fx with an error.
Drain ==
    /\ site = "shell"
    /\ phase = "loop"
    /\ job # "stopped"
    /\ dirty
    /\ dirty' = FALSE
    /\ LET r == Revents IN
       IF Readable(r) /\ ReadFails THEN ReadFailed
       ELSE IF Closed(r) THEN EndLoop("input_closed")
       ELSE IF Gone THEN EndLoop("write_failed")
       ELSE UNCHANGED <<phase, cause>>
    /\ UNCHANGED <<tty, waking, queued, spins, intr, restore, job, eio, stops, site, eof>>

\* The person answers or cancels at a prompt: it returns to its caller, which
\* restores the terminal on the way out (a defer).
PromptReturns ==
    /\ site # "shell"
    /\ phase = "loop"
    /\ ~Gone
    /\ EndLoop("requested")
    /\ UNCHANGED <<tty, waking, queued, dirty, spins, intr, restore, job, eio, stops, site, eof>>

\* A read on a terminal that reads 0 at the end of input: macOS answers that
\* for a revoked terminal unless eio holds, and for one whose other side closed.
\* A revoked terminal with eio fails the read with EIO, and a closed descriptor
\* fails it with EBADF.
ReadsZero == tty = "hungup" \/ (tty = "revoked" /\ ~eio)

\* readTeamPickerKey took a read of 0 as a key to ignore, so it read again.
\* readMaskedKeyDefault returns SetupCancelled at a read of 0.
IgnoresEof ==
    /\ site = "team_picker"
    /\ Bug \in {"today", "prompts_strict", "picker_ignores_eof"}

\* One read of stdin by a prompt on a terminal that is gone: a failed read or
\* a read of 0 returns the prompt's error (the caller prints a short message
\* and exits 1), unless the prompt ignores the end of input and reads again,
\* which returns at once with nothing to do, as a poll on a gone terminal does.
PromptRead ==
    /\ site # "shell"
    /\ phase = "loop"
    /\ Gone
    /\ IF ReadsZero /\ IgnoresEof
       THEN /\ spins < MaxSpins
            /\ spins' = spins + 1
            /\ eof' = TRUE
            /\ UNCHANGED <<phase, cause>>
       ELSE /\ EndLoop("prompt_failed")
            /\ eof' = (eof \/ ReadsZero)
            /\ UNCHANGED spins
    /\ UNCHANGED <<tty, waking, queued, dirty, intr, restore, job, eio, stops, site>>

-----------------------------------------------------------------------------
(* The restore (TerminalState.disableRawMode, TeamPickerRawMode.disable,   *)
(* and MaskedKeyRawMode.disable, each through tcsetattrBestEffort).        *)

Errno ==
    CASE tty = "live"    -> "SUCCESS"
      [] tty = "hungup"  -> "EIO"
      [] tty = "revoked" -> "ENOENT"
      [] tty = "closed"  -> "EBADF"

\* What one call that did not fail with EINTR leaves: "restored", "gone"
\* (nothing left to restore, returned quietly), "error" (an unexpected
\* errno, which Debug builds print to stderr), or "crashed" (unreachable).
\* The restore goes through std.posix.tcsetattr, which treats EBADF and EINVAL
\* as unreachable and reports ENOENT as an unexpected errno: in every site
\* before the change, and in the prompts before their fix.
StrictRestore == Bug = "today" \/ (Bug = "prompts_strict" /\ site # "shell")

Outcome(e) ==
    CASE e = "SUCCESS" -> "restored"
      [] e = "EBADF" /\ (StrictRestore \/ Bug = "badf_unreachable") -> "crashed"
      [] e = "ENOENT" /\ (StrictRestore \/ Bug = "enoent_unexpected") -> "error"
      [] OTHER -> "gone"

Restore ==
    /\ phase = "cleanup"
    /\ \/ /\ intr > 0
          /\ intr' = intr - 1
          /\ IF Bug = "no_eintr_retry"
               \* The interrupted call is taken as done: nothing restored.
               THEN /\ phase' = "exited"
                    /\ restore' = "lost"
               ELSE UNCHANGED <<phase, restore>>
       \/ /\ LET o == Outcome(Errno) IN
                IF o = "crashed"
                THEN /\ phase' = "crashed"
                     /\ UNCHANGED restore
                ELSE /\ phase' = "exited"
                     /\ restore' = o
          /\ UNCHANGED intr
    /\ UNCHANGED <<tty, waking, queued, dirty, cause, spins, job, eio, stops, site, eof>>

-----------------------------------------------------------------------------
(* The environment.                                                         *)

\* The person types; the bytes wait until the loop reads them.
Type ==
    /\ site = "shell"
    /\ phase = "loop"
    /\ tty = "live"
    /\ ~queued
    /\ queued' = TRUE
    /\ UNCHANGED <<tty, waking, dirty, phase, cause, spins, intr, restore, job, eio, stops, site, eof>>

\* The terminal goes away only while fx is in the foreground.

\* revoke(2) while fx is not waiting in its poll: queued input goes with it.
Revoke ==
    /\ Running
    /\ job = "fg"
    /\ tty = "live"
    /\ tty' = "revoked"
    /\ queued' = FALSE
    /\ UNCHANGED <<waking, dirty, phase, cause, spins, intr, restore, job, eio, stops, site, eof>>

\* revoke(2) while fx waits in its poll, which wakes with POLLHUP, or with
\* POLLIN where eio holds.
RevokeInPoll ==
    /\ site = "shell"
    /\ phase = "loop"
    /\ job = "fg"
    /\ tty = "live"
    /\ ~queued
    /\ ~dirty
    /\ tty' = "revoked"
    /\ waking' = TRUE
    /\ UNCHANGED <<queued, dirty, phase, cause, spins, intr, restore, job, eio, stops, site, eof>>

\* The terminal's other side closes.
Hangup ==
    /\ Running
    /\ job = "fg"
    /\ tty = "live"
    /\ tty' = "hungup"
    /\ UNCHANGED <<waking, queued, dirty, phase, cause, spins, intr, restore, job, eio, stops, site, eof>>

\* The descriptor itself is closed under fx.
CloseFd ==
    /\ Running
    /\ job = "fg"
    /\ tty = "live"
    /\ tty' = "closed"
    /\ queued' = FALSE
    /\ UNCHANGED <<waking, dirty, phase, cause, spins, intr, restore, job, eio, stops, site, eof>>

\* Ctrl+Z: fx reads the key, restores the terminal, and stops itself with
\* SIGTSTP (suspendToJobControl).
Suspend ==
    /\ site = "shell"
    /\ phase = "loop"
    /\ job = "fg"
    /\ tty = "live"
    /\ ~queued
    /\ ~dirty
    /\ job' = "stopped"
    /\ UNCHANGED <<tty, waking, queued, dirty, phase, cause, spins, intr, restore, eio, stops, site, eof>>

\* The shell's bg: fx continues in the background. Its resume first sets
\* raw mode again (resumeTerminalAfterJobControl), and SIGTTOU stops that
\* tcsetattr unless a parent ignores it.
Bg ==
    /\ phase = "loop"
    /\ job = "stopped"
    /\ tty = "live"
    /\ job' = IF stops THEN "stopped" ELSE "bg"
    /\ UNCHANGED <<tty, waking, queued, dirty, phase, cause, spins, intr, restore, eio, stops, site, eof>>

\* The shell's fg: fx continues in the foreground.
Fg ==
    /\ phase = "loop"
    /\ job \in {"stopped", "bg"}
    /\ tty = "live"
    /\ job' = "fg"
    /\ UNCHANGED <<tty, waking, queued, dirty, phase, cause, spins, intr, restore, eio, stops, site, eof>>

\* Another job takes the terminal while fx keeps running, which only a
\* parent that ignores SIGTTIN and SIGTTOU allows.
Background ==
    /\ site = "shell"
    /\ phase = "loop"
    /\ job = "fg"
    /\ tty = "live"
    /\ ~stops
    /\ job' = "bg"
    /\ UNCHANGED <<tty, waking, queued, dirty, phase, cause, spins, intr, restore, eio, stops, site, eof>>

Ended ==
    /\ phase \in {"exited", "crashed"}
    /\ UNCHANGED vars

Environment ==
    Type \/ Revoke \/ RevokeInPoll \/ Hangup \/ CloseFd \/ Suspend \/ Bg \/ Fg \/ Background

Next == Poll \/ Drain \/ PromptReturns \/ PromptRead \/ Restore \/ Environment \/ Ended

Spec == Init /\ [][Next]_vars /\ WF_vars(Poll) /\ WF_vars(Drain) /\ WF_vars(PromptRead) /\ WF_vars(Restore)

-----------------------------------------------------------------------------

TypeOK ==
    /\ tty \in {"live", "hungup", "revoked", "closed"}
    /\ waking \in BOOLEAN
    /\ queued \in BOOLEAN
    /\ dirty \in BOOLEAN
    /\ phase \in {"loop", "cleanup", "exited", "crashed"}
    /\ cause \in {"none", "requested", "input_closed", "write_failed", "read_failed", "prompt_failed"}
    /\ spins \in 0..MaxSpins
    /\ intr \in 0..MaxIntr
    /\ restore \in {"pending", "restored", "gone", "error", "lost"}
    /\ job \in {"fg", "stopped", "bg"}
    /\ eio \in BOOLEAN
    /\ stops \in BOOLEAN
    /\ site \in Sites
    /\ eof \in BOOLEAN

\* A pass of the loop never returns at once with nothing to do: once the
\* terminal is gone, the next poll ends the loop.
NoBusyLoop == spins = 0

\* The cleanup never aborts, whatever state the terminal is in.
CleanupNeverCrashes == phase # "crashed"

\* A terminal that is still there gets its original settings back, even
\* when signals interrupt the restore.
RestoredWhenLive == (phase = "exited" /\ tty = "live") => restore = "restored"

\* The cleanup of a terminal that is gone stays quiet: no unexpected errno.
GoneQuietly == restore # "error"

\* The loop ends for closed input or a failed write only when the terminal
\* is gone.
InputClosedOnlyWhenGone == cause \in {"input_closed", "write_failed"} => Gone

\* fx reports a read error only on a terminal that is still there: a
\* background read that SIGTTIN did not stop. A read that fails on a
\* terminal that is gone ends the loop as closed input.
ReadErrorOnlyWhenLive == cause = "read_failed" => tty = "live"

\* With SIGTTIN and SIGTTOU at their default, Ctrl+Z, bg, and fg never end
\* fx: it stays in its loop while it is stopped or in the background. A
\* parent that ignores them gets fx's behavior from before the change: a
\* background read ends fx with an error (ReadErrorOnlyWhenLive allows it).
JobControlKeepsFx == (stops /\ job # "fg") => phase = "loop"

\* Once the terminal is gone, fx ends: the interactive shell, and a prompt
\* that waits for a key.
GoneEndsLoop == Gone ~> (phase \in {"exited", "crashed"})

\* A prompt never reads again after a read of 0, the end of input.
NoReadAfterEof == [][~(PromptRead /\ eof)]_vars
=============================================================================

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
(* The fourth site, "sign_in", is the wait of fx login vercel for browser  *)
(* authorization (waitBetweenPolls and waitForEnterOn in                   *)
(* src/core/auth/login_flow.zig). It sets no raw mode, so it has nothing   *)
(* to restore. Between polls of the issuer it waits for a key in slices of *)
(* 100 ms, and a pass that returns at once with nothing to do goes round   *)
(* again with no time passing: a spin, as in Poll. A poll that answers     *)
(* HUP, ERR, or NVAL without IN means stdin is gone. The wait used to take *)
(* that as "no key" and return at once; it now sleeps out the slice. Bug = *)
(* "sign_in_spins" is the wait before that fix, and Bug =                  *)
(* "sign_in_nval" a fix that misses POLLNVAL alone, which every    *)
(* poll after a revoke outside the wait reports. A poll that answers       *)
(* POLLIN, as a revoke inside it does, is a key: the read ends and the     *)
(* prompt stops polling stdin. Either way eof records that the wait knows  *)
(* stdin is gone. The sign-in itself goes on polling the issuer until the  *)
(* device code is approved, refused, or expires (SignInEnds), so a gone    *)
(* terminal does not end it sooner.                                        *)
(*                                                                         *)
(* The fifth site, "mcp_login", is the wait of fx mcp login for an         *)
(* authorization, with no browser to open (waitForLogin and readPasted in  *)
(* src/core/mcp_host/verbs.zig). It sets no raw mode either. Each pass     *)
(* polls stdin for 100 ms and, when the poll answers anything, reads once. *)
(* A pass that ends the wait, reads what was pasted, or sleeps its slice   *)
(* takes time or makes progress. A read that failed used to return at once *)
(* with nothing done, so the loop went round again with no time passing: a *)
(* spin, as in Poll (Bug = "mcp_login_spins"). It now asks the shell's     *)
(* second check, terminalGone: a failed read on a terminal that is gone    *)
(* (the poll answers HUP, ERR, or NVAL, or tcgetattr fails) ends the wait  *)
(* with status 1 and saves nothing (cause "login_stopped"), and a failed   *)
(* read on a terminal that is still there, as a background read that       *)
(* SIGTTIN did not stop gives, sleeps the slice. A read of 0 is the end of *)
(* input and keeps the wait going until the browser comes back or the      *)
(* login's own deadline (SignInEnds): stdin closed means wait for the      *)
(* browser. Bug = "mcp_login_ends_always" ends on every failed read        *)
(* without the second check, and Bug = "mcp_login_sleeps" sleeps on every  *)
(* one and never ends the wait, which is no spin but breaks                *)
(* GoneReadStopsLogin.                                                     *)
(*                                                                         *)
(* The sign-in itself finishes on the login thread: the browser's callback *)
(* reaches fx's listener, the code is redeemed and saved, and              *)
(* Waiter.onNotice sets done (McpSignInCompletes, the variable signed).    *)
(* The top of waitForLogin's loop reads done once per pass and reports how *)
(* the sign-in ended (McpLoginSees: status 0). A sign-in that finishes     *)
(* while a pass waits is therefore seen only at the next top, and a failed *)
(* read on a gone terminal can end that pass first. The handler of that    *)
(* failed read now reads done again before it ends the login, in one step: *)
(* when the sign-in finished it goes round the loop, and the top reports   *)
(* it. Bug = "mcp_login_done_ignored" is the handler before that re-check: *)
(* a sign-in that finished in the slice of the failed read was reported as *)
(* failed with status 1 (FinishedSignInNeverFails). Bug =                  *)
(* "mcp_login_reports_done" over-corrects and says the sign-in is done     *)
(* whenever the terminal is gone (DoneOnlyWhenSignedIn).                   *)
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
(* Bug = "sign_in_spins" is fx with every fix but the sign-in wait's, and  *)
(* "sign_in_nval" fixes the wait for HUP and ERR but not NVAL.     *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS MaxSpins, MaxIntr, Bug

Bugs == {"none", "today", "prompts_strict", "picker_ignores_eof", "nval_ignored", "badf_unreachable",
         "enoent_unexpected", "no_eintr_retry", "eio_always_eof", "eio_poll_only",
         "sign_in_spins", "sign_in_nval", "mcp_login_spins", "mcp_login_ends_always", "mcp_login_sleeps",
         "mcp_login_done_ignored", "mcp_login_reports_done"}
Prompts == {"team_picker", "masked_key"}
Sites == {"shell", "sign_in", "mcp_login"} \cup Prompts
ASSUME Bug \in Bugs

VARIABLES
    tty,      \* "live", "hungup", "revoked", or "closed"
    waking,   \* a revoke woke the poll fx was waiting in
    queued,   \* input waits to be read
    dirty,    \* fx read input it has not drawn yet
    phase,    \* "loop", "cleanup", "exited", or "crashed"
    cause,    \* why the loop ended: "none", "requested", "input_closed",
              \* "write_failed", "read_failed", "prompt_failed", or, for the
              \* login waits, "sign_in_ended" and "login_stopped"
    spins,    \* passes of the loop that returned at once with nothing to do
    intr,     \* EINTRs the environment can still deliver to the restore
    restore,  \* "pending", "restored", "gone", "error", or "lost"
    job,      \* "fg", "stopped", or "bg"
    eio,      \* a revoked terminal polls as readable and fails reads with EIO
    stops,    \* SIGTTIN and SIGTTOU keep their default action
    site,     \* "shell", "team_picker", "masked_key", "sign_in", or "mcp_login":
              \* who runs, and for the first three, restores the terminal
    eof,      \* stdin reached its end for the code that reads it: a prompt's or
              \* the paste wait's read returned 0, or the sign-in wait found stdin
              \* gone
    signed    \* the login thread of fx mcp login has reported the sign-in done
              \* (Waiter.done is set)

vars == <<tty, waking, queued, dirty, phase, cause, spins, intr, restore, job, eio, stops, site, eof, signed>>

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
    /\ signed = FALSE

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
                 /\ UNCHANGED <<tty, queued, dirty, spins, intr, restore, job, eio, stops, site, eof, signed>>
            ELSE IF queued
            \* The bytes are read and handled; one of them may ask fx to quit,
            \* which ends the loop before any frame is drawn.
            THEN /\ queued' = FALSE
                 /\ \E quit \in BOOLEAN :
                        IF quit THEN /\ EndLoop("requested")
                                     /\ UNCHANGED dirty
                                ELSE /\ dirty' = TRUE
                                     /\ UNCHANGED <<phase, cause>>
                 /\ UNCHANGED <<tty, spins, intr, restore, job, eio, stops, site, eof, signed>>
            \* read returned 0: the end of input.
            ELSE /\ EndLoop("input_closed")
                 /\ UNCHANGED <<tty, queued, dirty, spins, intr, restore, job, eio, stops, site, eof, signed>>
       ELSE IF Closed(r)
       THEN /\ EndLoop("input_closed")
            /\ UNCHANGED <<tty, queued, dirty, spins, intr, restore, job, eio, stops, site, eof, signed>>
       \* Nothing to do: settle, commit a frame, and poll again. On a live
       \* terminal that pass waited its timeout; on one that is gone it
       \* returned at once.
       ELSE /\ IF Gone THEN /\ spins < MaxSpins
                            /\ spins' = spins + 1
                       ELSE UNCHANGED spins
            /\ UNCHANGED <<tty, queued, dirty, phase, cause, intr, restore, job, eio, stops, site, eof, signed>>

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
    /\ UNCHANGED <<tty, waking, queued, spins, intr, restore, job, eio, stops, site, eof, signed>>

\* The person answers or cancels at a prompt: it returns to its caller, which
\* restores the terminal on the way out (a defer).
PromptReturns ==
    /\ site \in Prompts
    /\ phase = "loop"
    /\ ~Gone
    /\ EndLoop("requested")
    /\ UNCHANGED <<tty, waking, queued, dirty, spins, intr, restore, job, eio, stops, site, eof, signed>>

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
    /\ site \in Prompts
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
    /\ UNCHANGED <<tty, waking, queued, dirty, intr, restore, job, eio, stops, site, signed>>

\* A poll the sign-in wait takes as "stdin is gone": HUP, ERR, or NVAL
\* without IN (classifyStdinPoll in login_flow.zig).
SignInGone(r) == r # {} /\ ~Readable(r)

\* Whether the wait returns at once on such an answer, with no time passing.
\* It did before the fix, and still does for POLLNVAL alone in the planted
\* variant.
SignInReturnsAtOnce(r) ==
    /\ SignInGone(r)
    /\ \/ Bug \in {"today", "sign_in_spins"}
       \/ Bug = "sign_in_nval" /\ "NVAL" \in r

\* One pass of waitBetweenPolls on the wait for a key (waitForEnterOn). A
\* pass on a live terminal waits its slice, and one on a terminal that is
\* gone sleeps out the rest of it, so neither is a spin; one that returns at
\* once is.
SignInWait ==
    /\ site = "sign_in"
    /\ phase = "loop"
    /\ waking' = FALSE
    /\ LET r == Revents IN
       IF SignInReturnsAtOnce(r)
       THEN /\ spins < MaxSpins
            /\ spins' = spins + 1
            /\ UNCHANGED eof
       ELSE /\ UNCHANGED spins
            /\ eof' = (eof \/ Gone)
    /\ UNCHANGED <<tty, queued, dirty, phase, cause, intr, restore, job, eio, stops, site, signed>>

\* The device code is approved, refused, or expires, whatever the terminal is
\* doing (the login's own deadline is five minutes). A login wait changed no
\* terminal setting, so nothing is left to restore. The login of fx mcp login
\* ends in two steps, McpSignInCompletes and McpLoginSees.
SignInEnds ==
    /\ site = "sign_in"
    /\ phase = "loop"
    /\ phase' = "exited"
    /\ cause' = "sign_in_ended"
    /\ restore' = "gone"
    /\ UNCHANGED <<tty, waking, queued, dirty, spins, intr, job, eio, stops, site, eof, signed>>

\* A read the paste wait makes that fails: EIO, from a revoked terminal where
\* eio holds or a background read that SIGTTIN did not stop, or EBADF, from a
\* descriptor that is closed. std.posix.read maps both to an error.
McpReadFails == ReadFails \/ tty = "closed"

\* The second check after a failed read (io_mod.terminalGone, which
\* TerminalState.inputGone shares): a poll that answers HUP, ERR, or NVAL, or
\* a tcgetattr that fails.
McpGone == PollShowsGone \/ TcgetattrFails

\* Whether the paste wait ends on a failed read (readPastedFrom).
McpEndsOnFailedRead ==
    CASE Bug \in {"today", "mcp_login_spins", "mcp_login_sleeps"} -> FALSE
      [] Bug = "mcp_login_ends_always"                              -> TRUE
      [] OTHER                                                      -> McpGone

\* Before the fix a failed read returned at once: no end, no sleep.
McpReturnsAtOnce == Bug \in {"today", "mcp_login_spins"}

\* Whether the handler of a failed read on a terminal that is gone reads
\* whether the sign-in finished (loginEnded) before it ends the login. The
\* handler did not when it was written, so a sign-in that finished while the
\* read ran was reported as failed (Bug = "mcp_login_done_ignored").
McpChecksDone == Bug # "mcp_login_done_ignored"

\* The browser's callback reaches fx's listener and the login thread finishes
\* the sign-in: Waiter.onNotice sets done under the waiter's mutex, whatever
\* the terminal is doing, at any moment while the login waits.
McpSignInCompletes ==
    /\ site = "mcp_login"
    /\ phase = "loop"
    /\ ~signed
    /\ signed' = TRUE
    /\ UNCHANGED <<tty, waking, queued, dirty, phase, cause, spins, intr, restore, job, eio, stops, site, eof>>

\* The top of waitForLogin's loop reads done and, when it is set, reports how
\* the sign-in ended and returns: status 0 and "Signed in to NAME".
McpLoginSees ==
    /\ site = "mcp_login"
    /\ phase = "loop"
    /\ signed
    /\ phase' = "exited"
    /\ cause' = "sign_in_ended"
    /\ restore' = "gone"
    /\ UNCHANGED <<tty, waking, queued, dirty, spins, intr, job, eio, stops, site, eof, signed>>

\* One pass of the paste wait (readPastedFrom): poll for up to 100 ms, then
\* read once if the poll answered anything. A pass that returns at once with
\* nothing done is a spin. A failed read on a terminal that is gone reaches
\* the handler in waitForLogin, which reads done and the failed read in one
\* step: signed is as it was when the handler looked. The sign-in may finish
\* before that step, while the poll waited or the read failed, or after it,
\* when the login has already ended.
McpLoginWait ==
    /\ site = "mcp_login"
    /\ phase = "loop"
    /\ waking' = FALSE
    /\ LET r == Revents IN
       IF r = {}
       \* Nothing to read: the poll waited its 100 ms.
       THEN UNCHANGED <<queued, phase, cause, spins, restore, eof>>
       ELSE IF McpReadFails
            THEN IF McpEndsOnFailedRead
                 THEN IF Bug = "mcp_login_reports_done"
                      \* A wrong fix: the handler says the sign-in is done
                      \* whenever the terminal is gone, finished or not.
                      THEN /\ phase' = "exited"
                           /\ cause' = "sign_in_ended"
                           /\ restore' = "gone"
                           /\ UNCHANGED <<queued, spins, eof>>
                      ELSE IF McpChecksDone /\ signed
                           \* The sign-in finished: the handler goes round the
                           \* loop, whose top reports it (McpLoginSees).
                           THEN UNCHANGED <<queued, phase, cause, spins, restore, eof>>
                           \* A failed read on a terminal that is gone, and no
                           \* sign-in done: the wait ends with a short message
                           \* and status 1, and saves nothing.
                           ELSE /\ phase' = "exited"
                                /\ cause' = "login_stopped"
                                /\ restore' = "gone"
                                /\ UNCHANGED <<queued, spins, eof>>
                 ELSE IF McpReturnsAtOnce
                      THEN /\ spins < MaxSpins
                           /\ spins' = spins + 1
                           /\ UNCHANGED <<queued, phase, cause, restore, eof>>
                      \* Any other failed read sleeps the slice.
                      ELSE UNCHANGED <<queued, phase, cause, spins, restore, eof>>
            \* What was typed or pasted is read.
            ELSE IF queued
                 THEN /\ queued' = FALSE
                      /\ UNCHANGED <<phase, cause, spins, restore, eof>>
                 \* A read of 0, the end of input: the wait sleeps its slice and
                 \* goes on waiting for the browser.
                 ELSE /\ eof' = TRUE
                      /\ UNCHANGED <<queued, phase, cause, spins, restore>>
    /\ UNCHANGED <<tty, dirty, intr, job, eio, stops, site, signed>>

\* The pass that finds a read failing on a terminal that is gone.
McpGoneReadFailure ==
    /\ site = "mcp_login"
    /\ phase = "loop"
    /\ Revents # {}
    /\ McpReadFails
    /\ McpGone

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
StrictRestore == Bug = "today" \/ (Bug = "prompts_strict" /\ site \in Prompts)

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
    /\ UNCHANGED <<tty, waking, queued, dirty, cause, spins, job, eio, stops, site, eof, signed>>

-----------------------------------------------------------------------------
(* The environment.                                                         *)

\* The person types; the bytes wait until the loop reads them.
Type ==
    /\ site \in {"shell", "mcp_login"}
    /\ phase = "loop"
    /\ tty = "live"
    /\ ~queued
    /\ queued' = TRUE
    /\ UNCHANGED <<tty, waking, dirty, phase, cause, spins, intr, restore, job, eio, stops, site, eof, signed>>

\* The terminal goes away only while fx is in the foreground.

\* revoke(2) while fx is not waiting in its poll: queued input goes with it.
Revoke ==
    /\ Running
    /\ job = "fg"
    /\ tty = "live"
    /\ tty' = "revoked"
    /\ queued' = FALSE
    /\ UNCHANGED <<waking, dirty, phase, cause, spins, intr, restore, job, eio, stops, site, eof, signed>>

\* revoke(2) while fx waits in its poll, which wakes with POLLHUP, or with
\* POLLIN where eio holds.
RevokeInPoll ==
    /\ site \in {"shell", "sign_in", "mcp_login"}
    /\ phase = "loop"
    /\ job = "fg"
    /\ tty = "live"
    /\ ~queued
    /\ ~dirty
    /\ tty' = "revoked"
    /\ waking' = TRUE
    /\ UNCHANGED <<queued, dirty, phase, cause, spins, intr, restore, job, eio, stops, site, eof, signed>>

\* The terminal's other side closes.
Hangup ==
    /\ Running
    /\ job = "fg"
    /\ tty = "live"
    /\ tty' = "hungup"
    /\ UNCHANGED <<waking, queued, dirty, phase, cause, spins, intr, restore, job, eio, stops, site, eof, signed>>

\* The descriptor itself is closed under fx.
CloseFd ==
    /\ Running
    /\ job = "fg"
    /\ tty = "live"
    /\ tty' = "closed"
    /\ queued' = FALSE
    /\ UNCHANGED <<waking, dirty, phase, cause, spins, intr, restore, job, eio, stops, site, eof, signed>>

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
    /\ UNCHANGED <<tty, waking, queued, dirty, phase, cause, spins, intr, restore, eio, stops, site, eof, signed>>

\* The shell's bg: fx continues in the background. Its resume first sets
\* raw mode again (resumeTerminalAfterJobControl), and SIGTTOU stops that
\* tcsetattr unless a parent ignores it.
Bg ==
    /\ phase = "loop"
    /\ job = "stopped"
    /\ tty = "live"
    /\ job' = IF stops THEN "stopped" ELSE "bg"
    /\ UNCHANGED <<tty, waking, queued, dirty, phase, cause, spins, intr, restore, eio, stops, site, eof, signed>>

\* The shell's fg: fx continues in the foreground.
Fg ==
    /\ phase = "loop"
    /\ job \in {"stopped", "bg"}
    /\ tty = "live"
    /\ job' = "fg"
    /\ UNCHANGED <<tty, waking, queued, dirty, phase, cause, spins, intr, restore, eio, stops, site, eof, signed>>

\* Another job takes the terminal while fx keeps running, which only a
\* parent that ignores SIGTTIN and SIGTTOU allows.
Background ==
    /\ site \in {"shell", "mcp_login"}
    /\ phase = "loop"
    /\ job = "fg"
    /\ tty = "live"
    /\ ~stops
    /\ job' = "bg"
    /\ UNCHANGED <<tty, waking, queued, dirty, phase, cause, spins, intr, restore, eio, stops, site, eof, signed>>

Ended ==
    /\ phase \in {"exited", "crashed"}
    /\ UNCHANGED vars

Environment ==
    Type \/ Revoke \/ RevokeInPoll \/ Hangup \/ CloseFd \/ Suspend \/ Bg \/ Fg \/ Background

Next == Poll \/ Drain \/ PromptReturns \/ PromptRead \/ SignInWait \/ McpLoginWait \/ McpSignInCompletes
        \/ McpLoginSees \/ SignInEnds \/ Restore \/ Environment \/ Ended

Spec == Init /\ [][Next]_vars /\ WF_vars(Poll) /\ WF_vars(Drain) /\ WF_vars(PromptRead) /\ WF_vars(SignInEnds)
        /\ WF_vars(McpSignInCompletes) /\ WF_vars(McpLoginSees) /\ WF_vars(Restore)

-----------------------------------------------------------------------------

TypeOK ==
    /\ tty \in {"live", "hungup", "revoked", "closed"}
    /\ waking \in BOOLEAN
    /\ queued \in BOOLEAN
    /\ dirty \in BOOLEAN
    /\ phase \in {"loop", "cleanup", "exited", "crashed"}
    /\ cause \in {"none", "requested", "input_closed", "write_failed", "read_failed", "prompt_failed", "sign_in_ended", "login_stopped"}
    /\ spins \in 0..MaxSpins
    /\ intr \in 0..MaxIntr
    /\ restore \in {"pending", "restored", "gone", "error", "lost"}
    /\ job \in {"fg", "stopped", "bg"}
    /\ eio \in BOOLEAN
    /\ stops \in BOOLEAN
    /\ site \in Sites
    /\ eof \in BOOLEAN
    /\ signed \in BOOLEAN

\* A pass of the loop never returns at once with nothing to do: once the
\* terminal is gone, the next poll ends the loop, and the sign-in wait
\* sleeps out its slice.
NoBusyLoop == spins = 0

\* The cleanup never aborts, whatever state the terminal is in.
CleanupNeverCrashes == phase # "crashed"

\* A terminal that is still there gets its original settings back, even
\* when signals interrupt the restore. The sign-in wait changes none.
RestoredWhenLive == (phase = "exited" /\ tty = "live" /\ site \notin {"sign_in", "mcp_login"}) => restore = "restored"

\* The cleanup of a terminal that is gone stays quiet: no unexpected errno.
GoneQuietly == restore # "error"

\* The loop ends for closed input or a failed write, and the paste wait for a
\* failed read, only when the terminal is gone.
InputClosedOnlyWhenGone == cause \in {"input_closed", "write_failed", "login_stopped"} => Gone

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
\* that waits for a key. The sign-in ends when its device code does.
GoneEndsLoop == Gone ~> (phase \in {"exited", "crashed"})

\* A prompt never reads again after a read of 0, the end of input.
NoReadAfterEof == [][~(PromptRead /\ eof)]_vars

\* The end-of-input law of the paste wait: a pass that finds its read failing
\* on a terminal that is gone, with no sign-in done, ends the wait. It does not
\* go round at once (NoBusyLoop), and it does not sleep and poll on until the
\* login's own deadline.
GoneReadStopsLogin == [][(McpLoginWait /\ McpGoneReadFailure /\ ~signed) => phase' = "exited"]_vars

\* A sign-in that finished is never reported as failed: the wait does not end
\* the login with "the terminal is gone" once the login thread has reported
\* the sign-in done, however the callback and the loss of the terminal fall
\* within one slice.
FinishedSignInNeverFails == (site = "mcp_login" /\ cause = "login_stopped") => ~signed

\* And the other way: the wait reports a sign-in as done only when it is.
DoneOnlyWhenSignedIn == (site = "mcp_login" /\ cause = "sign_in_ended") => signed
=============================================================================

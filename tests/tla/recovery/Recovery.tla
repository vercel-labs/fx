------------------------------- MODULE Recovery -------------------------------
(***************************************************************************)
(* fx's recovery module for one request (src/core/recovery/recovery.zig),  *)
(* and the world around it.                                                *)
(*                                                                         *)
(* The module is a pure state machine: fx reports an event, step() returns *)
(* a Plan, fx carries it out. Each reaction is folded into the world step  *)
(* that triggers it, because step() is instantaneous and does no I/O.      *)
(*                                                                         *)
(* The module has one job: get a complete response for one request. Tools  *)
(* and the turn loop belong to fx and are not modeled here. The world may  *)
(* inject at most MaxFaults disruptions (dropped requests, network loss,   *)
(* a broken gateway, sign-in or quota trouble, crashes, closed windows)    *)
(* and then heals, which is what lets Heals be checked.                    *)
(*                                                                         *)
(* The world's trouble that only the user can fix is a sign-in here, as   *)
(* the driver reports it. While the module waits for a sign-in it resends *)
(* now and then without the user (SignInPoll), and that resend keeps the  *)
(* sign-in status, so fx never opens a second sign-in for it. Quota       *)
(* trouble asks without resending; recovery.zig's own tests pin that.     *)
(*                                                                         *)
(* The provider's content filter may block the request's reply. On every *)
(* host the module resends the blocked request at once, up to             *)
(* FilterResends times in a row, and the next block needs the user         *)
(* (FilterBounded). The interactive app then waits for the user            *)
(* (AskingHostWaits). A host that cannot ask (`unattended`), such as       *)
(* `fx ask`, ACP, a subagent, or libfx, has nobody to answer, so fx ends   *)
(* the turn on its own error (HostEnds, CannotAskEnds). Such a host keeps  *)
(* no record and never resumes a request, and the turn loop ends a sign-in *)
(* or quota failure there before the module hears of it, so this model     *)
(* gives it neither process deaths nor that trouble.                       *)
(*                                                                         *)
(* The turn loop routes each request's network, gateway, and rate-limit    *)
(* failures through the module, and fx saves the module's record with the  *)
(* session, so a closed window or a crash resumes on the next launch       *)
(* (Resume.tla models that side). Each host counts abrupt deaths of the    *)
(* turn at any point in it and passes that count in `start`. At            *)
(* CrashLoopAfter crashes the module ends the request as `crash_loop`      *)
(* before decoding, saving, or sending (CrashLoopStops). Otherwise fx adds *)
(* no stop of its own, so NeverGivesUp holds for every transient failure   *)
(* fx reports, unclear ones included. tests/tla/drivers/recovery/driver.ts *)
(* walks recovery.zig along this model.                                    *)
(*                                                                         *)
(* Bug selects one planted defect. Each is a bug fx has had or a promise   *)
(* the API makes; check.sh names the rule that must catch it.              *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxFaults,   \* disruptions the world may inject before it heals for good
    Ladder,      \* consecutive counted failures that trigger the stall defect
    Bug          \* "none", or the name of one planted defect

Bugs == {"none", "stall_stop", "no_wake", "stale_socket", "frozen_status",
         "no_closing", "no_guard", "hot_retry", "send_without_save",
         "poll_reopens", "poll_drop_reasks", "yield_retry_status",
         "filter_unbounded", "filter_asks_early", "cannot_ask_resends",
         "asking_host_resends", "filter_answer_keeps_count",
         \* Planted in RecoveryTimed.tla.
         "unbounded_wait", "frozen_countdown", "no_handoff", "poll_hot",
         "never_poll"}

ASSUME /\ MaxFaults \in Nat /\ Ladder \in 1..4 /\ Bug \in Bugs

Min(a, b) == IF a < b THEN a ELSE b

\* done_failed: fx ended the turn on its own error, because the request
\* needs the user on a host that cannot ask.
\* done_crash_loop: a start found the turn at CrashLoopAfter abrupt deaths.
Phases   == {"working", "waiting", "need_user", "done_ok", "done_cancel",
             "done_failed", "done_crash_loop", "stopped"}
Active   == {"working", "waiting", "need_user"}
Terminal == Phases \ Active
\* failed: fx's own terminal status, which replaces the module's.
Statuses == {"clear", "waiting", "retrying", "need_user", "stopped", "failed",
             "none"}
Alarms   == {"waiting", "retrying", "need_user", "stopped", "failed"}
MaxAttempt == 3   \* attempts saturate here; status only distinguishes 1 from >1
FilterResends == 3   \* recovery.zig content_filter_resends
CrashLoopAfter == 3   \* recovery.zig crash_loop_after

VARIABLES
    phase,          \* the request's phase inside the module
    status,         \* the status line ("none" while fx is not running)
    inflight,       \* a send is outstanding
    flowing,        \* the current send's response has started (`responding`)
    attempt,        \* sends for this request (saturating)
    sameFail,       \* consecutive counted failures (offline is not counted)
    lastSendWaited, \* the latest send came after a wait, a relaunch, the user, or a block
    savedInflight,  \* the saved record says a send is outstanding
    savedClean,     \* the saved record was written by `closing`
    hostCrashes,    \* abrupt deaths of the turn the host passes to `start`
    deaths,         \* world truth: abrupt deaths of the turn in any active phase
    cleanExit,      \* world truth: the last exit was SIGHUP or SIGTERM
    net,            \* world: is the network path up
    gateway,        \* world: ok | broken
    needUser,       \* world: sign-in or quota trouble only the user can fix
    faults,         \* disruptions injected so far
    alive,          \* the fx process is running
    cancelled,      \* the user pressed Esc or quit fx
    askedSignIn,    \* the module waits for a sign-in, so it resends now and then
    polling,        \* the send on the wire is such a resend (SignInPoll)
    unattended,     \* the host cannot ask the user (request_recovery.zig canAskUser)
    filterRun,      \* blocks in a row the module counted (its streak)
    blocked,        \* world: the content filter blocks the request's reply
    yielded         \* 0; 1 while fx is down after stopping the request for its own restart; 2 once it continued

vars == <<phase, status, inflight, flowing, attempt, sameFail, lastSendWaited,
          savedInflight, savedClean, hostCrashes, deaths, cleanExit, net,
          gateway, needUser, faults, alive, cancelled, askedSignIn, polling,
          unattended, filterRun, blocked, yielded>>

\* The variables only the content filter's steps change.
filterVars == <<unattended, filterRun, blocked>>

TypeOK ==
    /\ phase \in Phases
    /\ status \in Statuses
    /\ inflight \in BOOLEAN
    /\ flowing \in BOOLEAN
    /\ attempt \in 0..MaxAttempt
    /\ sameFail \in 0..Ladder
    /\ lastSendWaited \in BOOLEAN
    /\ savedInflight \in BOOLEAN
    /\ savedClean \in BOOLEAN
    /\ hostCrashes \in 0..MaxFaults
    /\ deaths \in 0..MaxFaults
    /\ cleanExit \in BOOLEAN
    /\ net \in {"up", "down"}
    /\ gateway \in {"ok", "broken"}
    /\ needUser \in BOOLEAN
    /\ faults \in 0..MaxFaults
    /\ alive \in BOOLEAN
    /\ cancelled \in BOOLEAN
    /\ askedSignIn \in BOOLEAN
    /\ polling \in BOOLEAN
    /\ unattended \in BOOLEAN
    /\ filterRun \in 0..(FilterResends + 1)
    /\ blocked \in BOOLEAN
    /\ yielded \in 0..2

\* start(null): the plan is save, send .{}. Either kind of host.
Init ==
    /\ phase = "working"
    /\ status = "clear"
    /\ inflight = TRUE
    /\ flowing = FALSE
    /\ attempt = 1
    /\ sameFail = 0
    /\ lastSendWaited = TRUE
    /\ savedInflight = TRUE
    /\ savedClean = FALSE
    /\ hostCrashes = 0
    /\ deaths = 0
    /\ cleanExit = FALSE
    /\ net = "up"
    /\ gateway = "ok"
    /\ needUser = FALSE
    /\ faults = 0
    /\ alive = TRUE
    /\ cancelled = FALSE
    /\ askedSignIn = FALSE
    /\ polling = FALSE
    /\ unattended \in BOOLEAN
    /\ filterRun = 0
    /\ blocked = FALSE
    /\ yielded = 0

-----------------------------------------------------------------------------
(* Plan fragments. Each sets phase, status, inflight, flowing, attempt,    *)
(* lastSendWaited, savedInflight, askedSignIn and polling; callers fix     *)
(* every other variable.                                                   *)

\* save, send, status. `waited` records whether time passed (or fx was
\* relaunched, or the user acted) since the previous failure. A block's
\* resend counts as waited too: a block is no transient failure, and no
\* wait changes what the filter decides (FilterBounded bounds it).
SendNow(waited) ==
    /\ phase' = "working"
    /\ inflight' = TRUE
    /\ flowing' = FALSE
    /\ attempt' = Min(attempt + 1, MaxAttempt)
    /\ lastSendWaited' = waited
    \* Planted defect send_without_save: a retry goes out without its save.
    /\ savedInflight' = IF Bug = "send_without_save" /\ attempt > 0
                           THEN savedInflight ELSE TRUE
    /\ status' = IF attempt + 1 > 1 THEN "retrying" ELSE "clear"
    /\ askedSignIn' = FALSE
    /\ polling' = FALSE

\* A failure of the given kind. "offline" does not count toward sameFail.
\* A sign-in wait's own resend that fails on the way, offline, dropped, or
\* on a broken gateway, waits for the sign-in again with its start kept
\* (recovery.zig onFailed), so fx opens no second sign-in. Planted defect
\* poll_drop_reasks: it waits as an ordinary retry instead, and the next
\* sign-in failure opens a second sign-in. A counted failure ends a run of
\* content-filter blocks, since the module's streak now counts its kind
\* (recovery.zig noteStreak); offline and a sign-in wait leave the run.
OnFail(kind) ==
    /\ polling' = FALSE
    /\ IF kind = "need_user" \/ (polling /\ Bug # "poll_drop_reasks")
       THEN /\ phase' = "need_user" /\ status' = "need_user"
            /\ inflight' = FALSE /\ flowing' = FALSE /\ savedInflight' = FALSE
            /\ askedSignIn' = TRUE
            /\ UNCHANGED <<attempt, sameFail, lastSendWaited, filterRun>>
       ELSE LET counted  == kind # "offline"
                nextFail == IF counted THEN Min(sameFail + 1, Ladder) ELSE sameFail
            IN /\ sameFail' = nextFail
               /\ filterRun' = IF counted THEN 0 ELSE filterRun
               /\ askedSignIn' = FALSE
               /\ IF Bug = "hot_retry"
                     \* Planted defect: resend at once, without waiting.
                     THEN SendNow(FALSE)
                  ELSE IF Bug = "stall_stop" /\ counted /\ nextFail >= Ladder
                     \* Planted defect: "kept failing at the same point".
                     THEN /\ phase' = "stopped" /\ status' = "stopped"
                          /\ inflight' = FALSE /\ flowing' = FALSE
                          /\ savedInflight' = FALSE
                          /\ UNCHANGED <<attempt, lastSendWaited>>
                  ELSE /\ phase' = "waiting" /\ status' = "waiting"
                       /\ inflight' = FALSE /\ flowing' = FALSE
                       /\ savedInflight' = FALSE
                       /\ UNCHANGED <<attempt, lastSendWaited>>

\* succeeded: status clear, finish(succeeded). Finishing deletes the record.
OnSuccess ==
    /\ phase' = "done_ok" /\ status' = "clear"
    /\ inflight' = FALSE /\ flowing' = FALSE /\ savedInflight' = FALSE
    /\ askedSignIn' = FALSE /\ polling' = FALSE
    /\ UNCHANGED <<attempt, sameFail, lastSendWaited, filterRun>>

-----------------------------------------------------------------------------
(* The request on the wire.                                                *)

\* `responding`: the first byte arrived, so any retry status clears, and a
\* sign-in resend that gets an answer no longer waits for a sign-in.
Responding ==
    /\ alive /\ phase = "working" /\ inflight /\ ~flowing
    /\ flowing' = TRUE
    /\ status' = IF Bug = "frozen_status" THEN status ELSE "clear"
    /\ askedSignIn' = FALSE /\ polling' = FALSE
    /\ UNCHANGED <<phase, inflight, attempt, sameFail, lastSendWaited,
                   savedInflight, savedClean, hostCrashes, deaths, cleanExit,
                   net, gateway, needUser, faults, alive, cancelled>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

\* `tick` after a resend has shown its retry status for the hand-off time
\* (recovery.zig handoff_ms): fx's thinking row takes the status line back
\* while the model works, since a model can think for a minute before its
\* first byte. RecoveryTimed.tla says when.
HandOff ==
    /\ alive /\ phase = "working" /\ inflight /\ ~flowing /\ status = "retrying"
    /\ status' = "clear"
    /\ UNCHANGED <<phase, inflight, flowing, attempt, sameFail, lastSendWaited,
                   savedInflight, savedClean, hostCrashes, deaths, cleanExit,
                   net, gateway, needUser, faults, alive, cancelled,
                   askedSignIn, polling>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

\* The gateway answers according to the world. These failures follow from
\* conditions already counted as faults. A complete answer needs `responding`,
\* and a reply the filter blocks is Blocked instead.
Respond ==
    /\ alive /\ inflight
    /\ CASE net = "down"         -> OnFail("offline")
         [] needUser             -> OnFail("need_user")
         [] gateway = "broken"   -> OnFail("server")
         [] OTHER                -> flowing /\ ~blocked /\ OnSuccess
    /\ UNCHANGED <<savedClean, hostCrashes, deaths, cleanExit, net, gateway,
                   needUser, faults, alive, cancelled, unattended, blocked>>
    /\ UNCHANGED yielded

\* The provider answers, and its content filter blocks the reply (`failed`
\* with content_filter). On every host the module resends at once while the
\* run of blocks is at most FilterResends long, and the next block needs the
\* user (recovery.zig resendAfterContentFilter). The run is the module's
\* streak, so a streak of another kind ends it, and the user's answer starts
\* it over (UserActs), so the blocks after that answer resend again. Planted
\* defects: filter_unbounded resends every block, and filter_asks_early
\* asks at the first block, as fx did before.
Blocked ==
    /\ alive /\ inflight /\ blocked
    /\ net = "up" /\ ~needUser /\ gateway = "ok"
    /\ LET run   == Min(filterRun + 1, FilterResends + 1)
           limit == IF Bug = "filter_asks_early" THEN 0 ELSE FilterResends
       IN /\ filterRun' = run
          /\ sameFail' = 0
          /\ IF run <= limit \/ Bug = "filter_unbounded"
                THEN SendNow(TRUE)
                ELSE /\ phase' = "need_user" /\ status' = "need_user"
                     /\ inflight' = FALSE /\ flowing' = FALSE
                     /\ savedInflight' = FALSE
                     /\ askedSignIn' = FALSE /\ polling' = FALSE
                     /\ UNCHANGED <<attempt, lastSendWaited>>
    /\ UNCHANGED <<savedClean, hostCrashes, deaths, cleanExit, net, gateway,
                   needUser, faults, alive, cancelled, unattended, blocked>>
    /\ UNCHANGED yielded

\* A fresh transient disruption kills the in-flight send.
Drop ==
    /\ alive /\ inflight /\ faults < MaxFaults
    /\ faults' = faults + 1
    /\ OnFail("dropped")
    /\ UNCHANGED <<savedClean, hostCrashes, deaths, cleanExit, net, gateway,
                   needUser, alive, cancelled, unattended, blocked>>
    /\ UNCHANGED yielded

\* Planted defect: on a healthy world, the transport reports a dead pooled
\* connection instead of retrying it silently on a fresh one.
StaleSocket ==
    /\ Bug = "stale_socket"
    /\ alive /\ inflight
    /\ net = "up" /\ gateway = "ok" /\ ~needUser
    /\ OnFail("dropped")
    /\ UNCHANGED <<savedClean, hostCrashes, deaths, cleanExit, net, gateway,
                   needUser, faults, alive, cancelled, unattended, blocked>>
    /\ UNCHANGED yielded

\* `tick` reaches the deadline: save, send, status retrying.
TimerFires ==
    /\ alive /\ phase = "waiting"
    /\ Bug # "no_wake"
    /\ SendNow(TRUE)
    /\ UNCHANGED <<sameFail, savedClean, hostCrashes, deaths, cleanExit, net,
                   gateway, needUser, faults, alive, cancelled>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

\* While the module waits for a sign-in, it resends after a long wait
\* (recovery.zig sign_in_poll_ms), or at once when the sign-in fx opened
\* closes without a new login (`sign_in_closed`): save, send, and keep the
\* sign-in status, so fx does not open another sign-in for this resend.
\* RecoveryTimed.tla says when. Planted defect poll_reopens: the resend
\* shows the retry status, and its failure then opens a second sign-in.
SignInPoll ==
    /\ alive /\ phase = "need_user" /\ askedSignIn
    /\ phase' = "working"
    /\ inflight' = TRUE
    /\ flowing' = FALSE
    /\ attempt' = Min(attempt + 1, MaxAttempt)
    /\ lastSendWaited' = TRUE
    /\ savedInflight' = TRUE
    /\ status' = IF Bug = "poll_reopens" THEN "retrying" ELSE "need_user"
    /\ polling' = TRUE
    /\ UNCHANGED <<askedSignIn, sameFail, savedClean, hostCrashes, deaths,
                   cleanExit, net, gateway, needUser, faults, alive, cancelled>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

-----------------------------------------------------------------------------
(* The world.                                                              *)

NetDown ==
    /\ net = "up" /\ faults < MaxFaults
    /\ net' = "down" /\ faults' = faults + 1
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, hostCrashes,
                   deaths, cleanExit, gateway, needUser, alive, cancelled,
                   askedSignIn, polling>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

NetUp ==
    /\ net = "down"
    /\ net' = "up"
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, hostCrashes,
                   deaths, cleanExit, gateway, needUser, faults, alive,
                   cancelled, askedSignIn, polling>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

GatewayBreak ==
    /\ gateway = "ok" /\ faults < MaxFaults
    /\ gateway' = "broken" /\ faults' = faults + 1
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, hostCrashes,
                   deaths, cleanExit, net, needUser, alive, cancelled,
                   askedSignIn, polling>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

GatewayHeal ==
    /\ gateway = "broken"
    /\ gateway' = "ok"
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, hostCrashes,
                   deaths, cleanExit, net, needUser, faults, alive, cancelled,
                   askedSignIn, polling>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

\* Sign-in or quota trouble. On a host that cannot ask, the turn loop ends
\* the turn on it before the module hears, so only the other host has it.
NeedUserFault ==
    /\ ~needUser /\ ~unattended /\ faults < MaxFaults
    /\ needUser' = TRUE /\ faults' = faults + 1
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, hostCrashes,
                   deaths, cleanExit, net, gateway, alive, cancelled,
                   askedSignIn, polling>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

\* The trouble goes away without the user: the gateway stops refusing the
\* login, or another fx process signs in. Only a resend finds out.
TroubleClears ==
    /\ needUser
    /\ needUser' = FALSE
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, hostCrashes,
                   deaths, cleanExit, net, gateway, faults, alive, cancelled,
                   askedSignIn, polling>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

\* The content filter starts blocking the request's reply.
FilterFault ==
    /\ ~blocked /\ faults < MaxFaults
    /\ blocked' = TRUE /\ faults' = faults + 1
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, hostCrashes,
                   deaths, cleanExit, net, gateway, needUser, alive, cancelled,
                   askedSignIn, polling, unattended, filterRun>>
    /\ UNCHANGED yielded

\* The filter lets a try through: it does not decide the same way every time.
\* Only a resend finds out.
FilterClears ==
    /\ blocked
    /\ blocked' = FALSE
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, hostCrashes,
                   deaths, cleanExit, net, gateway, needUser, faults, alive,
                   cancelled, askedSignIn, polling, unattended, filterRun>>
    /\ UNCHANGED yielded

-----------------------------------------------------------------------------
(* Process death and relaunch. The saved record survives; the in-flight    *)
(* send and the screen do not. Only a host that can ask keeps the record   *)
(* and resumes a request.                                                  *)

\* A crash: no event reaches the module. Counts as an abrupt death in any
\* active phase (sending, waiting, or waiting for the user).
Crash ==
    /\ alive /\ ~unattended /\ phase \in Active /\ faults < MaxFaults
    /\ faults' = faults + 1
    /\ alive' = FALSE
    /\ cleanExit' = FALSE
    /\ deaths' = Min(deaths + 1, MaxFaults)
    /\ hostCrashes' = Min(hostCrashes + 1, MaxFaults)
    /\ inflight' = FALSE /\ flowing' = FALSE /\ status' = "none"
    /\ polling' = FALSE
    /\ UNCHANGED <<phase, attempt, sameFail, lastSendWaited, savedInflight,
                   savedClean, net, gateway, needUser, cancelled,
                   askedSignIn>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

\* SIGHUP or SIGTERM: fx sends `closing` and saves the plan before exiting.
\* A close does not count as an abrupt death. Planted defect no_closing:
\* the exit is not marked clean, and the host counts it as a crash.
Close ==
    /\ alive /\ ~unattended /\ phase \in Active /\ faults < MaxFaults
    /\ faults' = faults + 1
    /\ alive' = FALSE
    /\ cleanExit' = TRUE
    /\ savedClean' = IF Bug = "no_closing" THEN savedClean ELSE TRUE
    /\ hostCrashes' = IF Bug = "no_closing"
                         THEN Min(hostCrashes + 1, MaxFaults)
                         ELSE hostCrashes
    /\ inflight' = FALSE /\ flowing' = FALSE /\ status' = "none"
    /\ polling' = FALSE
    /\ UNCHANGED <<phase, attempt, sameFail, lastSendWaited, savedInflight,
                   deaths, net, gateway, needUser, cancelled,
                   askedSignIn>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

\* start(record, crashes). At CrashLoopAfter abrupt deaths, the module ends
\* the request as `crash_loop` before decoding, saving, or sending. Otherwise
\* a request that was waiting for the user keeps waiting; any other record
\* resends at once. Planted defect no_guard: the guard is off and the
\* request resumes forever.
Relaunch ==
    /\ ~alive /\ phase \in Active
    /\ yielded # 1
    /\ alive' = TRUE
    /\ savedClean' = FALSE
    /\ LET atGuard == hostCrashes >= CrashLoopAfter /\ Bug # "no_guard" IN
       IF atGuard
          THEN /\ phase' = "done_crash_loop" /\ status' = "clear"
               /\ inflight' = FALSE /\ flowing' = FALSE
               /\ savedInflight' = FALSE
               /\ askedSignIn' = FALSE /\ polling' = FALSE
               /\ UNCHANGED <<attempt, lastSendWaited>>
          ELSE IF phase = "need_user"
          THEN /\ phase' = "need_user" /\ status' = "need_user"
               /\ inflight' = FALSE /\ flowing' = FALSE
               /\ savedInflight' = FALSE
               /\ polling' = FALSE
               /\ UNCHANGED <<attempt, lastSendWaited, askedSignIn>>
          ELSE SendNow(TRUE)
    /\ UNCHANGED <<sameFail, hostCrashes, deaths, cleanExit, net, gateway,
                   needUser, faults, cancelled>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

\* fx stops the request for its own restart (Ctrl+G for an upgrade), at
\* the save right before a send (src/core/quiesce/quiesce.zig): it sends
\* `closing`, so the record is clean, and exits before the send leaves.
\* A yield is not a fault: nothing went wrong in the world. Once is enough
\* for every rule below.
\* Like a close, it happens only in a host that keeps a record.
Yield ==
    /\ alive /\ ~unattended /\ phase = "working" /\ inflight /\ ~flowing /\ ~polling
    /\ yielded = 0
    /\ yielded' = 1
    /\ alive' = FALSE
    /\ cleanExit' = TRUE
    /\ savedClean' = TRUE
    /\ inflight' = FALSE /\ flowing' = FALSE /\ status' = "none"
    /\ UNCHANGED <<phase, attempt, sameFail, lastSendWaited, savedInflight,
                   hostCrashes, deaths, net, gateway, needUser, faults,
                   cancelled, askedSignIn, polling>>
    /\ UNCHANGED filterVars

\* The new fx continues the stopped turn: start(record, crashes, continues).
\* At the guard, the module ends the request as `crash_loop`; otherwise a
\* saved question still applies, and any other send goes out as planned, with
\* the same attempt and nothing on the status line (recovery.zig
\* sendPlanned). Planted defect yield_retry_status: it resumes as a retry,
\* the way fx showed "Resuming the interrupted request" and "attempt 2".
Continue ==
    /\ ~alive /\ yielded = 1 /\ phase \in Active
    /\ yielded' = 2
    /\ alive' = TRUE
    /\ savedClean' = FALSE
    /\ LET atGuard == hostCrashes >= CrashLoopAfter /\ Bug # "no_guard" IN
       IF atGuard
          THEN /\ phase' = "done_crash_loop" /\ status' = "clear"
               /\ inflight' = FALSE /\ flowing' = FALSE
               /\ savedInflight' = FALSE
               /\ askedSignIn' = FALSE /\ polling' = FALSE
               /\ UNCHANGED <<attempt, lastSendWaited>>
          ELSE IF phase = "need_user"
          THEN /\ phase' = "need_user" /\ status' = "need_user"
               /\ inflight' = FALSE /\ flowing' = FALSE
               /\ savedInflight' = FALSE
               /\ askedSignIn' = FALSE /\ polling' = FALSE
               /\ UNCHANGED <<attempt, lastSendWaited>>
          ELSE IF Bug = "yield_retry_status"
          THEN SendNow(TRUE)
          ELSE /\ phase' = "working"
               /\ inflight' = TRUE /\ flowing' = FALSE
               /\ savedInflight' = TRUE
               /\ status' = "clear"
               /\ lastSendWaited' = TRUE
               /\ askedSignIn' = FALSE /\ polling' = FALSE
               /\ UNCHANGED attempt
    /\ UNCHANGED <<sameFail, hostCrashes, deaths, cleanExit, net, gateway,
                   needUser, faults, cancelled>>
    /\ UNCHANGED filterVars

-----------------------------------------------------------------------------
(* The user, and fx's own end of a request nobody can answer.              *)

\* `user_cancel`: Esc, or quitting fx. The only way to end without success
\* on a host that can ask, other than the crash-loop guard.
UserCancels ==
    /\ alive /\ phase \in Active
    /\ phase' = "done_cancel" /\ status' = "clear" /\ cancelled' = TRUE
    /\ inflight' = FALSE /\ flowing' = FALSE /\ savedInflight' = FALSE
    /\ askedSignIn' = FALSE /\ polling' = FALSE
    /\ UNCHANGED <<attempt, sameFail, lastSendWaited, savedClean, hostCrashes,
                   deaths, cleanExit, net, gateway, needUser, faults, alive>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

\* `user_continue`: Enter or a successful /login after fixing what was asked,
\* such as a rephrased request after a block. Only a host that can ask has a
\* user to answer; planted defect cannot_ask_resends resends on one that
\* cannot, as if it had. Answering a request's own question keeps the turn's
\* crash count, and starts the content filter's run of blocks over
\* (recovery.zig onUserContinue); planted defect filter_answer_keeps_count
\* keeps it, as fx did before, so a block after the answer asks at once.
UserActs ==
    /\ alive /\ (~unattended \/ Bug = "cannot_ask_resends") /\ phase = "need_user"
    /\ needUser' = FALSE
    /\ blocked' = FALSE
    /\ filterRun' = IF Bug = "filter_answer_keeps_count" THEN filterRun ELSE 0
    /\ SendNow(TRUE)
    /\ UNCHANGED <<sameFail, savedClean, hostCrashes, deaths, cleanExit, net,
                   gateway, faults, alive, cancelled, unattended>>
    /\ UNCHANGED yielded

\* The request needs the user on a host that cannot ask, which happens only
\* after the content filter's last allowed block: fx ends the turn on its
\* own content-filter error, as it did before the resends
\* (orchestrator.zig), and that error replaces the module's question on the
\* status line. Such a host keeps no record.
HostEnds ==
    /\ alive /\ unattended /\ phase = "need_user"
    /\ phase' = "done_failed" /\ status' = "failed"
    /\ UNCHANGED <<inflight, flowing, attempt, sameFail, lastSendWaited,
                   savedInflight, savedClean, hostCrashes, deaths, cleanExit,
                   net, gateway, needUser, faults, alive, cancelled,
                   askedSignIn, polling>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

\* Planted defect asking_host_resends: a host that can ask resends a request
\* that waits for the user after a block without the user's answer.
HostResends ==
    /\ Bug = "asking_host_resends"
    /\ alive /\ ~unattended /\ phase = "need_user" /\ ~askedSignIn
    /\ SendNow(TRUE)
    /\ UNCHANGED <<sameFail, savedClean, hostCrashes, deaths, cleanExit, net,
                   gateway, needUser, faults, alive, cancelled>>
    /\ UNCHANGED filterVars
    /\ UNCHANGED yielded

\* A finished request stays finished.
Finished ==
    /\ phase \in Terminal
    /\ UNCHANGED vars
    /\ UNCHANGED yielded

Next ==
    \/ Responding \/ HandOff \/ Respond \/ Blocked \/ Drop \/ StaleSocket
    \/ TimerFires \/ SignInPoll
    \/ NetDown \/ NetUp \/ GatewayBreak \/ GatewayHeal \/ NeedUserFault
    \/ TroubleClears \/ FilterFault \/ FilterClears
    \/ Crash \/ Close \/ Relaunch \/ Yield \/ Continue
    \/ UserCancels \/ UserActs \/ HostEnds \/ HostResends
    \/ Finished

\* Time passes, answers arrive, the world heals, fx gets relaunched, and the
\* user eventually does what was asked. Faults, deaths and Esc are never forced.
\* A sign-in wait's own resends take the request out of need_user now and
\* then, so the user's answer is strongly fair: a user who keeps being asked
\* answers at last. A filter that keeps blocking never clears by force.
Fairness ==
    /\ WF_vars(Responding) /\ WF_vars(Respond) /\ WF_vars(Blocked)
    /\ WF_vars(TimerFires) /\ WF_vars(Relaunch) /\ WF_vars(Continue) /\ SF_vars(UserActs)
    /\ WF_vars(HostEnds) /\ WF_vars(NetUp) /\ WF_vars(GatewayHeal)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* The rules the module and fx keep together.                             *)

\* Only Esc, quitting, or the crash-loop guard ends a request without
\* success, except on a host that cannot ask, where fx ends one that needs
\* the user on its own error.
NeverGivesUp ==
    /\ phase # "stopped"
    /\ (phase = "done_cancel" => cancelled)
    /\ (phase = "done_failed" => unattended)
    /\ (phase = "done_crash_loop" =>
           /\ ~inflight
           /\ hostCrashes >= CrashLoopAfter
           /\ (Bug # "no_closing" => deaths >= CrashLoopAfter))

\* Once disruptions stop, every request finishes.
Heals == <>(phase \in {"done_ok", "done_cancel", "done_failed", "done_crash_loop"})

\* On a world that never misbehaved, nothing alarming is shown.
NoFalseAlarm == (status \in Alarms) => faults > 0

\* The status says what is really happening. A retry status clears once
\* the answer flows, or earlier, when fx's thinking row takes the line back
\* from a resend that has not failed (HandOff).
StatusHonest ==
    alive =>
        /\ (phase = "waiting" => status = "waiting")
        /\ (phase = "need_user" => status = "need_user")
        /\ (phase = "working" /\ inflight /\ ~flowing =>
                status \in IF polling THEN {"need_user"}
                           ELSE IF attempt > 1 THEN {"retrying", "clear"}
                           ELSE {"clear"})
        /\ (phase = "working" /\ flowing => status = "clear")

\* After SIGHUP or SIGTERM, the request resumes without stopping or asking.
ResumesAfterClose ==
    [][(Relaunch /\ cleanExit /\ phase # "need_user")
         => (phase' = "working" /\ inflight')]_vars

\* At the guard (CrashLoopAfter abrupt deaths), a relaunch or continuation
\* ends the request as `done_crash_loop`, sends nothing after it, and never
\* opens a question for a crash or age.
CrashLoopStops ==
    [][(Relaunch \/ Continue) =>
         /\ (deaths >= CrashLoopAfter =>
                phase' = "done_crash_loop" /\ ~inflight' /\ ~savedInflight')
         /\ (phase # "need_user" => phase' # "need_user")]_vars

\* A retry after a transient failure always waits first.
NoHotRetry == lastSendWaited

\* A sign-in wait's own resend that fails on the way, for any reason, waits
\* for the sign-in again: one request opens one sign-in. A crash, an
\* answer, or Esc ends the resend another way, and so does a block, which is
\* an answer: the login worked, and the request asks about the block.
PollKeepsSignIn ==
    [][(polling /\ inflight /\ ~Blocked /\ alive' /\ ~inflight'
          /\ phase' \notin Terminal)
         => (phase' = "need_user" /\ askedSignIn')]_vars

\* Every send comes with a save, so the record always knows
\* whether a send is outstanding.
SaveBeforeSend == alive => (savedInflight = inflight)

\* On every host, a block resends at once while fewer than FilterResends
\* blocks came before it in a row, so at most FilterResends resends follow
\* blocks in a row, and the next block needs the user.
FilterBounded ==
    [][Blocked =>
         IF filterRun < FilterResends
            THEN inflight' /\ filterRun' = filterRun + 1
            ELSE phase' = "need_user" /\ ~inflight']_vars

\* The user's answer starts the content filter's run of blocks over, so the
\* blocks after it get FilterResends resends again.
AnswerGivesResends == [][UserActs => filterRun' = 0]_vars

\* A host that can ask waits for the user: only the user's answer, Esc, or a
\* sign-in wait's own resend takes the request out of need_user.
AskingHostWaits ==
    [][(alive /\ ~unattended /\ phase = "need_user" /\ phase' # "need_user")
         => (UserActs \/ UserCancels \/ SignInPoll)]_vars

\* A host that cannot ask ends a request that needs the user, on fx's own
\* error or by Esc, and never sends it again (Heals says it does end).
CannotAskEnds ==
    [][(alive /\ unattended /\ phase = "need_user" /\ phase' # "need_user")
         => phase' \in {"done_failed", "done_cancel"}]_vars

=============================================================================

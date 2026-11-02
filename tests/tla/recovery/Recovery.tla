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
(* The turn loop routes each request's network, gateway, and rate-limit    *)
(* failures through the module, and fx saves the module's record with the  *)
(* session, so a closed window or a crash resumes on the next launch       *)
(* (Resume.tla models that side). fx adds no stop of its own, so           *)
(* NeverGivesUp holds for every transient failure fx reports, unclear ones *)
(* included. tests/tla/drivers/recovery/driver.ts walks recovery.zig along *)
(* this model.                                                             *)
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
         "no_closing", "never_ask", "hot_retry", "send_without_save",
         \* Planted in RecoveryTimed.tla.
         "unbounded_wait", "frozen_countdown"}

ASSUME /\ MaxFaults \in Nat /\ Ladder \in 1..4 /\ Bug \in Bugs

Min(a, b) == IF a < b THEN a ELSE b

Phases   == {"working", "waiting", "need_user", "done_ok", "done_cancel", "stopped"}
Active   == {"working", "waiting", "need_user"}
Terminal == Phases \ Active
Statuses == {"clear", "waiting", "retrying", "need_user", "stopped", "none"}
Alarms   == {"waiting", "retrying", "need_user", "stopped"}
MaxAttempt == 3   \* attempts saturate here; status only distinguishes 1 from >1

VARIABLES
    phase,          \* the request's phase inside the module
    status,         \* the status line ("none" while fx is not running)
    inflight,       \* a send is outstanding
    flowing,        \* the current send's response has started (`responding`)
    attempt,        \* sends for this request (saturating)
    sameFail,       \* consecutive counted failures (offline is not counted)
    lastSendWaited, \* the latest send came after a wait, a relaunch, or the user
    savedInflight,  \* the saved record says a send is outstanding
    savedClean,     \* the saved record was written by `closing`
    seenDeaths,     \* abrupt in-flight deaths the module counted from records
    deaths,         \* world truth: abrupt deaths with a send in flight
    cleanExit,      \* world truth: the last exit was SIGHUP or SIGTERM
    net,            \* world: is the network path up
    gateway,        \* world: ok | broken
    needUser,       \* world: sign-in or quota trouble only the user can fix
    faults,         \* disruptions injected so far
    alive,          \* the fx process is running
    cancelled       \* the user pressed Esc or quit fx

vars == <<phase, status, inflight, flowing, attempt, sameFail, lastSendWaited,
          savedInflight, savedClean, seenDeaths, deaths, cleanExit, net,
          gateway, needUser, faults, alive, cancelled>>

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
    /\ seenDeaths \in 0..MaxFaults
    /\ deaths \in 0..MaxFaults
    /\ cleanExit \in BOOLEAN
    /\ net \in {"up", "down"}
    /\ gateway \in {"ok", "broken"}
    /\ needUser \in BOOLEAN
    /\ faults \in 0..MaxFaults
    /\ alive \in BOOLEAN
    /\ cancelled \in BOOLEAN

\* start(null): the plan is save, send .{}.
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
    /\ seenDeaths = 0
    /\ deaths = 0
    /\ cleanExit = FALSE
    /\ net = "up"
    /\ gateway = "ok"
    /\ needUser = FALSE
    /\ faults = 0
    /\ alive = TRUE
    /\ cancelled = FALSE

-----------------------------------------------------------------------------
(* Plan fragments. Each sets phase, status, inflight, flowing, attempt,    *)
(* lastSendWaited and savedInflight; callers fix every other variable.     *)

\* save, send, status. `waited` records whether time passed (or fx was
\* relaunched, or the user acted) since the previous failure.
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

\* A failure of the given kind. "offline" does not count toward sameFail.
OnFail(kind) ==
    IF kind = "need_user"
       THEN /\ phase' = "need_user" /\ status' = "need_user"
            /\ inflight' = FALSE /\ flowing' = FALSE /\ savedInflight' = FALSE
            /\ UNCHANGED <<attempt, sameFail, lastSendWaited>>
       ELSE LET counted  == kind # "offline"
                nextFail == IF counted THEN Min(sameFail + 1, Ladder) ELSE sameFail
            IN /\ sameFail' = nextFail
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
    /\ UNCHANGED <<attempt, sameFail, lastSendWaited>>

-----------------------------------------------------------------------------
(* The request on the wire.                                                *)

\* `responding`: the first byte arrived, so any retry status clears.
Responding ==
    /\ alive /\ phase = "working" /\ inflight /\ ~flowing
    /\ flowing' = TRUE
    /\ status' = IF Bug = "frozen_status" THEN status ELSE "clear"
    /\ UNCHANGED <<phase, inflight, attempt, sameFail, lastSendWaited,
                   savedInflight, savedClean, seenDeaths, deaths, cleanExit,
                   net, gateway, needUser, faults, alive, cancelled>>

\* The gateway answers according to the world. These failures follow from
\* conditions already counted as faults. A complete answer needs `responding`.
Respond ==
    /\ alive /\ inflight
    /\ CASE net = "down"         -> OnFail("offline")
         [] needUser             -> OnFail("need_user")
         [] gateway = "broken"   -> OnFail("server")
         [] OTHER                -> flowing /\ OnSuccess
    /\ UNCHANGED <<savedClean, seenDeaths, deaths, cleanExit, net, gateway,
                   needUser, faults, alive, cancelled>>

\* A fresh transient disruption kills the in-flight send.
Drop ==
    /\ alive /\ inflight /\ faults < MaxFaults
    /\ faults' = faults + 1
    /\ OnFail("dropped")
    /\ UNCHANGED <<savedClean, seenDeaths, deaths, cleanExit, net, gateway,
                   needUser, alive, cancelled>>

\* Planted defect: on a healthy world, the transport reports a dead pooled
\* connection instead of retrying it silently on a fresh one.
StaleSocket ==
    /\ Bug = "stale_socket"
    /\ alive /\ inflight
    /\ net = "up" /\ gateway = "ok" /\ ~needUser
    /\ OnFail("dropped")
    /\ UNCHANGED <<savedClean, seenDeaths, deaths, cleanExit, net, gateway,
                   needUser, faults, alive, cancelled>>

\* `tick` reaches the deadline: save, send, status retrying.
TimerFires ==
    /\ alive /\ phase = "waiting"
    /\ Bug # "no_wake"
    /\ SendNow(TRUE)
    /\ UNCHANGED <<sameFail, savedClean, seenDeaths, deaths, cleanExit, net,
                   gateway, needUser, faults, alive, cancelled>>

-----------------------------------------------------------------------------
(* The world.                                                              *)

NetDown ==
    /\ net = "up" /\ faults < MaxFaults
    /\ net' = "down" /\ faults' = faults + 1
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, seenDeaths,
                   deaths, cleanExit, gateway, needUser, alive, cancelled>>

NetUp ==
    /\ net = "down"
    /\ net' = "up"
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, seenDeaths,
                   deaths, cleanExit, gateway, needUser, faults, alive,
                   cancelled>>

GatewayBreak ==
    /\ gateway = "ok" /\ faults < MaxFaults
    /\ gateway' = "broken" /\ faults' = faults + 1
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, seenDeaths,
                   deaths, cleanExit, net, needUser, alive, cancelled>>

GatewayHeal ==
    /\ gateway = "broken"
    /\ gateway' = "ok"
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, seenDeaths,
                   deaths, cleanExit, net, needUser, faults, alive, cancelled>>

NeedUserFault ==
    /\ ~needUser /\ faults < MaxFaults
    /\ needUser' = TRUE /\ faults' = faults + 1
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, seenDeaths,
                   deaths, cleanExit, net, gateway, alive, cancelled>>

-----------------------------------------------------------------------------
(* Process death and relaunch. The saved record survives; the in-flight    *)
(* send and the screen do not.                                             *)

\* A crash: no event reaches the module.
Crash ==
    /\ alive /\ phase \in Active /\ faults < MaxFaults
    /\ faults' = faults + 1
    /\ alive' = FALSE
    /\ cleanExit' = FALSE
    /\ deaths' = IF inflight THEN Min(deaths + 1, MaxFaults) ELSE deaths
    /\ inflight' = FALSE /\ flowing' = FALSE /\ status' = "none"
    /\ UNCHANGED <<phase, attempt, sameFail, lastSendWaited, savedInflight,
                   savedClean, seenDeaths, net, gateway, needUser, cancelled>>

\* SIGHUP or SIGTERM: fx sends `closing` and saves the plan before exiting.
Close ==
    /\ alive /\ phase \in Active /\ faults < MaxFaults
    /\ faults' = faults + 1
    /\ alive' = FALSE
    /\ cleanExit' = TRUE
    \* Planted defect no_closing: the exit is not marked, so it looks like a crash.
    /\ savedClean' = IF Bug = "no_closing" THEN savedClean ELSE TRUE
    /\ inflight' = FALSE /\ flowing' = FALSE /\ status' = "none"
    /\ UNCHANGED <<phase, attempt, sameFail, lastSendWaited, savedInflight,
                   seenDeaths, deaths, net, gateway, needUser, cancelled>>

\* start(record). An abrupt death with a send in flight counts toward the
\* crash-loop guard; the second one asks the user once. Otherwise: save, send.
Relaunch ==
    /\ ~alive /\ phase \in Active
    /\ alive' = TRUE
    /\ savedClean' = FALSE
    /\ LET abrupt == savedInflight /\ ~savedClean
           seen   == IF abrupt THEN Min(seenDeaths + 1, MaxFaults) ELSE seenDeaths
           ask    == (seen >= 2 /\ Bug # "never_ask") \/ phase = "need_user"
       IN /\ seenDeaths' = seen
          /\ IF ask
                THEN /\ phase' = "need_user" /\ status' = "need_user"
                     /\ inflight' = FALSE /\ flowing' = FALSE
                     /\ savedInflight' = FALSE
                     /\ UNCHANGED <<attempt, lastSendWaited>>
                ELSE SendNow(TRUE)
    /\ UNCHANGED <<sameFail, deaths, cleanExit, net, gateway, needUser,
                   faults, cancelled>>

-----------------------------------------------------------------------------
(* The user.                                                               *)

\* `user_cancel`: Esc, or quitting fx. The only way to end without success.
UserCancels ==
    /\ alive /\ phase \in Active
    /\ phase' = "done_cancel" /\ status' = "clear" /\ cancelled' = TRUE
    /\ inflight' = FALSE /\ flowing' = FALSE /\ savedInflight' = FALSE
    /\ UNCHANGED <<attempt, sameFail, lastSendWaited, savedClean, seenDeaths,
                   deaths, cleanExit, net, gateway, needUser, faults, alive>>

\* `user_continue`: Enter or a successful /login after fixing what was asked.
\* Only answering the crash-loop question starts the death count over
\* (recovery.zig onUserContinue): a sign-in says nothing about crashes. Two
\* counted deaths while waiting for the user mean the crash-loop question.
UserActs ==
    LET loop == seenDeaths >= 2 IN
    /\ alive /\ phase = "need_user"
    /\ needUser' = FALSE
    /\ seenDeaths' = IF loop THEN 0 ELSE seenDeaths
    /\ deaths' = IF loop THEN 0 ELSE deaths
    /\ SendNow(TRUE)
    /\ UNCHANGED <<sameFail, savedClean, cleanExit, net, gateway, faults,
                   alive, cancelled>>

\* A finished request stays finished.
Finished ==
    /\ phase \in Terminal
    /\ UNCHANGED vars

Next ==
    \/ Responding \/ Respond \/ Drop \/ StaleSocket \/ TimerFires
    \/ NetDown \/ NetUp \/ GatewayBreak \/ GatewayHeal \/ NeedUserFault
    \/ Crash \/ Close \/ Relaunch
    \/ UserCancels \/ UserActs
    \/ Finished

\* Time passes, answers arrive, the world heals, fx gets relaunched, and the
\* user eventually does what was asked. Faults, deaths and Esc are never forced.
Fairness ==
    /\ WF_vars(Responding) /\ WF_vars(Respond) /\ WF_vars(TimerFires)
    /\ WF_vars(Relaunch) /\ WF_vars(UserActs)
    /\ WF_vars(NetUp) /\ WF_vars(GatewayHeal)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* The rules the module and fx keep together.                             *)

\* Only Esc or quitting ends a request without success.
NeverGivesUp ==
    /\ phase # "stopped"
    /\ (phase = "done_cancel" => cancelled)

\* Once disruptions stop, every request finishes.
Heals == <>(phase \in {"done_ok", "done_cancel"})

\* On a world that never misbehaved, nothing alarming is shown.
NoFalseAlarm == (status \in Alarms) => faults > 0

\* The status says what is really happening, and a retry status
\* clears once the answer flows.
StatusHonest ==
    alive =>
        /\ (phase = "waiting" => status = "waiting")
        /\ (phase = "need_user" => status = "need_user")
        /\ (phase = "working" /\ inflight /\ ~flowing =>
                status = IF attempt > 1 THEN "retrying" ELSE "clear")
        /\ (phase = "working" /\ flowing => status = "clear")

\* After SIGHUP or SIGTERM, the request resumes without asking.
ResumesAfterClose ==
    [][(Relaunch /\ cleanExit /\ phase # "need_user") => phase' # "need_user"]_vars

\* The one exception: two abrupt deaths with a send in flight ask once.
CrashLoopAsks ==
    [][(Relaunch /\ ~cleanExit /\ deaths >= 2 /\ phase # "need_user")
         => phase' = "need_user"]_vars

\* A retry after a transient failure always waits first.
NoHotRetry == lastSendWaited

\* Every send comes with a save, so the record always knows
\* whether a send is outstanding.
SaveBeforeSend == alive => (savedInflight = inflight)

=============================================================================

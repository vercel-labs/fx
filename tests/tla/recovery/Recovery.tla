------------------------------- MODULE Recovery -------------------------------
(***************************************************************************)
(* fx's recovery module for one request (src/core/recovery/recovery.zig),  *)
(* fx carrying out its plans (src/core/agent/runtime/request_recovery.zig) *)
(* and the world around them.                                              *)
(*                                                                         *)
(* The module is a pure state machine: fx reports an event, step() returns *)
(* a Plan, fx carries it out. Each reaction is folded into the world step  *)
(* that triggers it, because step() is instantaneous and does no I/O.      *)
(* Carrying out a plan is not instantaneous: fx writes the record (Sync    *)
(* makes the write durable) and only then puts the send on the wire        *)
(* (SendOut). A death between those steps can lose an unsynced write or,   *)
(* when the write was in progress, leave a torn record.                    *)
(*                                                                         *)
(* The module has one job: get a complete response for one request. Tools  *)
(* and the turn loop belong to fx and are not modeled, and neither is a    *)
(* second fx process: Resume.tla models those. The world may inject        *)
(* at most MaxFaults disruptions (dropped requests, network loss, a broken *)
(* gateway, failures fx cannot classify, sign-in or quota trouble, an      *)
(* oversized request, failures fx ends itself, crashes, closes)            *)
(* and then heals, which is what lets Heals be checked.                    *)
(*                                                                         *)
(* What fx implements today, and what is only modeled:                     *)
(* - The turn loop reports offline, dropped, server, and rate-limit        *)
(*   failures to the module (request_recovery.zig failureKind), with       *)
(*   Retry-After, and carries out its waits, sends, and statuses. fx's     *)
(*   stop for unclear failures, its Fast lookahead (request_recovery.zig   *)
(*   repeatedFailure), and fx's terminal kinds are wired.                  *)
(* - fx does not persist Plan.save yet, and Plan.finish has no record to   *)
(*   delete (request_recovery.zig). Everything about the record is model   *)
(*   only: the durable save before each send (DeathCounted), resuming      *)
(*   after a close (ResumesAfterClose), the crash-loop guard               *)
(*   (CrashLoopAsks), and deleting the record at every end                 *)
(*   (NoResumeAfterEnd). So is `closing`: only a close (SIGHUP, SIGTERM,   *)
(*   or EOF on the terminal) resumes on the next launch. /quit and Ctrl+C  *)
(*   twice are an explicit stop, like Esc, and delete the record.          *)
(* - A torn or unreadable record found beside an in-flight request counts  *)
(*   as one abrupt death. recovery.zig does not do that yet: its decode    *)
(*   failure starts the request fresh, which is the planted defect         *)
(*   torn_resets.                                                          *)
(* - Sign-in, quota, too long, rejected, and content-filter failures never *)
(*   reach the module: fx keeps its own handling for them and its own      *)
(*   compaction. The module's paths for them (waiting for the user,        *)
(*   compacting once, NoHotRetry's compaction exception) are model only.   *)
(*   Rate limits are not modeled apart from 5xx; both wait the same way.   *)
(*                                                                         *)
(* RecoveryTimed.tla adds a discrete clock for the time bounds.            *)
(*                                                                         *)
(* Bug selects one planted defect. Each is a bug fx has had or a promise   *)
(* the design makes; check.sh names the one rule that must catch it.       *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxFaults,   \* disruptions the world may inject before it heals for good
    Fast,        \* the request uses the Fast route (Start.fast)
    Bug          \* "none", or the name of one planted defect

Bugs == {"none", "stall_stop", "no_wake", "stale_socket", "frozen_status",
         "no_closing", "never_ask", "hot_retry", "send_without_save",
         "send_before_sync", "torn_resets", "stop_keeps_record",
         "stop_before_fast", "stop_on_class_change", "late_outcome_counts",
         "compact_waits", "unbounded_wait", "frozen_countdown"}

ASSUME /\ MaxFaults \in Nat /\ Fast \in BOOLEAN /\ Bug \in Bugs

EscalateAfter  == 3   \* recovery.zig escalate_after
CrashLoopAfter == 2   \* recovery.zig crash_loop_after
RepeatStop     == 3   \* request_recovery.zig repeat_stop_sends

Min(a, b) == IF a < b THEN a ELSE b

Phases   == {"working", "waiting", "need_user",
             "done_ok", "done_cancel", "stopped", "fx_stopped"}
Active   == {"working", "waiting", "need_user"}
Terminal == Phases \ Active
Statuses == {"clear", "waiting", "retrying", "need_user", "stopped", "none"}
Alarms   == {"waiting", "retrying", "need_user", "stopped"}
\* Status.Need, folded: sign-in, quota, and too long after compacting are
\* "user"; crash_loop is the one whose Enter resets the death count.
Needs    == {"none", "user", "crash_loop"}
\* Failure kinds that count toward a streak (State.streak_kind).
Kinds    == {"none", "dropped", "server"}
\* How a send goes out (recovery.zig Send).
Ways     == {"plain", "no_fast", "compact"}
\* How the process last died, as the world saw it: "inflight" when it tore a
\* write or left this process's own save of a send (InFlightDeath), "lost"
\* when a send's save was durable and the death lost it, "closing" during a
\* close's save, "clean" after a close, "ended" after the request ended,
\* and "other" at any other time.
Deaths   == {"none", "inflight", "lost", "other", "closing", "clean", "ended"}

\* The 32-byte record (recovery.zig encode), reduced to the fields the rules
\* read. ph "none" is no file and "torn" is a file that does not decode.
RecPhases == {"none", "torn", "sending", "waiting", "need_user"}
Records   == [ph: RecPhases, clean: BOOLEAN, deaths: 0..CrashLoopAfter,
              need: Needs, noFast: BOOLEAN, compacted: BOOLEAN,
              streak: 0..EscalateAfter, streakKind: Kinds]
NoRecord   == [ph |-> "none", clean |-> FALSE, deaths |-> 0, need |-> "none",
               noFast |-> FALSE, compacted |-> FALSE, streak |-> 0,
               streakKind |-> "none"]
TornRecord == [NoRecord EXCEPT !.ph = "torn"]

VARIABLES
    \* The module's State, in memory: a death loses it.
    phase,          \* the request's phase inside the module
    need,           \* why it waits for the user
    attempt,        \* sends so far, saturating: status only tells 1 from more
    mdeaths,        \* abrupt in-flight deaths it counted (abrupt_deaths)
    noFast,         \* Fast dropped for the rest of the request (flags.no_fast)
    compacted,      \* the request was compacted once (flags.compacted)
    streak,         \* consecutive failures of streakKind (offline not counted)
    streakKind,
    flowing,        \* the current send's response has started (`responding`)
    closing,        \* `closing` was delivered (flags.clean_exit)
    sendCompact,    \* the current send is the compacted one (compact_first)
    status,         \* the status line ("none" while fx is not running)
    \* fx carrying out plans.
    inflight,       \* a send is on the wire
    pendingSend,    \* the plan's send is not on the wire yet
    dirty,          \* the plan's save is written but not yet durable
    late,           \* the send an explicit stop aborted may still report an
                    \* outcome
    own,            \* the durable record is this process's own save of a
                    \* send (Resume.tla own)
    \* fx's count of unclear failures (RequestRecovery.repeat_sends,
    \* repeat_send, repeat_progress_bytes), and the rule's own count of the
    \* same run, which no planted defect touches.
    rep, repWay, repPoint,
    runLen, runWay, runPoint,
    \* The durable record.
    disk,
    \* The world.
    net,            \* is the network path up
    gateway,        \* ok | broken (5xx and other classified gateway errors)
    needUser,       \* sign-in or quota trouble only the user can fix
    unclear,        \* "none", or the module kind of failures fx cannot
                    \* classify: TLS setup and missing finish are "dropped",
                    \* uncoded and unexplained provider errors "server"
    tooLong,        \* the request exceeds the model's context window
    faults,         \* disruptions injected so far
    alive,          \* the fx process is running
    \* What the rules read.
    ended,          \* the request succeeded, was cancelled, or was stopped
    cancelled,      \* the user stopped it: Esc, /quit, or Ctrl+C twice
    lastDeath,      \* how the process last died (Deaths)
    deaths,         \* in-flight deaths the launches could see since fx last
                    \* saved the crash-loop question
    justified       \* the failure or relaunch behind the status had a cause

modVars   == <<phase, need, attempt, mdeaths, noFast, compacted, streak,
              streakKind, flowing, closing, sendCompact, status>>
fxVars    == <<inflight, pendingSend, dirty, late, own>>
runVars   == <<rep, repWay, repPoint, runLen, runWay, runPoint>>
worldVars == <<net, gateway, needUser, unclear, tooLong, faults, alive>>
ghostVars == <<ended, cancelled, lastDeath, deaths, justified>>
vars == <<modVars, fxVars, runVars, disk, worldVars, ghostVars>>

TypeOK ==
    /\ phase \in Phases
    /\ need \in Needs
    /\ attempt \in 1..2
    /\ mdeaths \in 0..CrashLoopAfter
    /\ noFast \in BOOLEAN
    /\ compacted \in BOOLEAN
    /\ streak \in 0..EscalateAfter
    /\ streakKind \in Kinds
    /\ flowing \in BOOLEAN
    /\ closing \in BOOLEAN
    /\ sendCompact \in BOOLEAN
    /\ status \in Statuses
    /\ inflight \in BOOLEAN
    /\ pendingSend \in BOOLEAN
    /\ dirty \in BOOLEAN
    /\ late \in BOOLEAN
    /\ own \in BOOLEAN
    /\ rep \in 0..RepeatStop /\ repWay \in Ways /\ repPoint \in 0..1
    /\ runLen \in 0..RepeatStop /\ runWay \in Ways /\ runPoint \in 0..1
    /\ disk \in Records
    /\ net \in {"up", "down"}
    /\ gateway \in {"ok", "broken"}
    /\ needUser \in BOOLEAN
    /\ unclear \in Kinds
    /\ tooLong \in BOOLEAN
    /\ faults \in 0..MaxFaults
    /\ alive \in BOOLEAN
    /\ ended \in BOOLEAN
    /\ cancelled \in BOOLEAN
    /\ lastDeath \in Deaths
    /\ deaths \in 0..CrashLoopAfter
    /\ justified \in BOOLEAN

-----------------------------------------------------------------------------
(* Derived values.                                                         *)

\* The record the module's latest save carries (recovery.zig encode).
\* Every change to a saved field comes with a save, and fx delivers no
\* event while a save is unsynced, so while `dirty` this is the pending write.
Rec ==
    [ph |-> CASE phase = "working" -> "sending"
              [] phase = "waiting" -> "waiting"
              [] OTHER             -> "need_user",
     \* Planted defect no_closing: the exit is not marked, so it looks like a crash.
     clean |-> closing /\ Bug # "no_closing",
     deaths |-> mdeaths, need |-> need, noFast |-> noFast,
     compacted |-> compacted, streak |-> streak, streakKind |-> streakKind]

\* The newest record fx has written, durable or not.
Newest == IF dirty THEN Rec ELSE disk

\* The send's save is durable, so the send is on the wire or about to go.
\* The record cannot tell those two apart, so a death in either is an
\* in-flight death, here, in recovery.zig resumeFrom, and in Resume.tla.
SendCommitted == inflight \/ (pendingSend /\ ~dirty)

\* Whether a death is in flight, given the record d it leaves (Resume.tla
\* DeathKind): it tears a write in progress, or it leaves this process's own
\* save of a send, durable or not yet. That is what recovery.zig resumeFrom
\* counts, apart from a stale record an earlier process left, which it
\* already counted.
InFlightDeath(d) ==
    \/ dirty /\ d = TornRecord /\ disk.ph # "torn"
    \/ dirty /\ d = Rec /\ Rec.ph = "sending" /\ ~Rec.clean
    \/ d = disk /\ own

\* A record the launch counts as an abrupt death with a send in flight:
\* recovery.zig resumeFrom's `abrupt`, plus a torn record.
Visible(d) == d.ph = "torn" \/ (d.ph = "sending" /\ ~d.clean)

\* How the current send went out (RequestRecovery.send).
Way == IF sendCompact THEN "compact" ELSE IF noFast THEN "no_fast" ELSE "plain"

\* Whether the module would drop Fast after k more failures of `kind`
\* (recovery.zig noteStreak and escalate).
ProbeNoFast(kind, k) ==
    \/ noFast
    \/ /\ kind = "server" /\ Fast
       /\ (IF streakKind = kind THEN streak + k ELSE k) >= EscalateAfter

\* request_recovery.zig nextSendLocked: does a copy of the module, hearing
\* `kind` up to k more times, send differently from the current send?
ProbeDiffers(kind, k) == sendCompact \/ (ProbeNoFast(kind, k) # noFast)

\* How far fx looks ahead. Planted defect stop_before_fast: one failure, so
\* the stop fires while the module's run toward dropping Fast is unfinished.
Lookahead == IF Bug = "stop_before_fast" THEN 1 ELSE EscalateAfter

Healthy == /\ net = "up" /\ gateway = "ok" /\ ~needUser
           /\ unclear = "none" /\ ~tooLong

\* fx has carried out the last plan.
Idle == ~dirty /\ ~pendingSend

\* fx delivers events to the module only between plans and not while it is
\* closing.
Live == alive /\ Idle /\ ~closing

\* The world may still misbehave. The closing window lasts about a second;
\* the world changes before or after it.
CanFault == faults < MaxFaults /\ ~ended /\ ~closing

\* start(null): the plan is save, send .{}.
Init ==
    /\ phase = "working" /\ need = "none" /\ attempt = 1 /\ mdeaths = 0
    /\ noFast = FALSE /\ compacted = FALSE /\ streak = 0
    /\ streakKind = "none" /\ flowing = FALSE /\ closing = FALSE
    /\ sendCompact = FALSE /\ status = "clear"
    /\ inflight = FALSE /\ pendingSend = TRUE /\ dirty = TRUE /\ late = FALSE
    /\ own = FALSE
    /\ rep = 0 /\ repWay = "plain" /\ repPoint = 0
    /\ runLen = 0 /\ runWay = "plain" /\ runPoint = 0
    /\ disk = NoRecord
    /\ net = "up" /\ gateway = "ok" /\ needUser = FALSE /\ unclear = "none"
    /\ tooLong = FALSE /\ faults = 0 /\ alive = TRUE
    /\ ended = FALSE /\ cancelled = FALSE /\ lastDeath = "none"
    /\ deaths = 0 /\ justified = FALSE

-----------------------------------------------------------------------------
(* Plan fragments.                                                         *)

\* sendNow: save, send, status retrying. `save` is FALSE only for the
\* planted defect send_without_save. Sets phase, attempt, flowing, status,
\* sendCompact, inflight, pendingSend, dirty.
SendNow(compact, save) ==
    /\ phase' = "working" /\ attempt' = 2 /\ flowing' = FALSE
    /\ status' = "retrying" /\ sendCompact' = compact
    /\ inflight' = FALSE /\ pendingSend' = TRUE /\ dirty' = save

\* waitAfter: save, status waiting.
WaitNow ==
    /\ phase' = "waiting" /\ flowing' = FALSE /\ status' = "waiting"
    /\ sendCompact' = FALSE /\ inflight' = FALSE /\ pendingSend' = FALSE
    /\ dirty' = TRUE /\ UNCHANGED attempt

\* askUser: save, status need_user. Sets need too.
AskUser(n) ==
    /\ phase' = "need_user" /\ need' = n /\ flowing' = FALSE
    /\ status' = "need_user" /\ sendCompact' = FALSE /\ inflight' = FALSE
    /\ pendingSend' = FALSE /\ dirty' = TRUE

\* The module's state after `finish` resets it, or after fx drops the request.
Cleared ==
    /\ need' = "none" /\ attempt' = 1 /\ mdeaths' = 0 /\ noFast' = FALSE
    /\ compacted' = FALSE /\ streak' = 0 /\ streakKind' = "none"
    /\ flowing' = FALSE /\ closing' = FALSE /\ sendCompact' = FALSE
    /\ inflight' = FALSE /\ pendingSend' = FALSE /\ dirty' = FALSE
    /\ own' = FALSE

\* finish(succeeded | cancelled): fx deletes the record.
Finish(how) ==
    /\ phase' = how /\ status' = "clear" /\ Cleared
    /\ disk' = NoRecord /\ ended' = TRUE

\* fx ends the request itself, through its terminal path: an unclear failure
\* that keeps repeating, or a failure kind fx ends on its own. Every end must
\* delete the record. Planted defect stop_keeps_record: fx's own end keeps it.
FxEnd ==
    /\ phase' = "fx_stopped" /\ status' = "stopped" /\ Cleared
    /\ disk' = IF Bug = "stop_keeps_record" THEN disk ELSE NoRecord
    /\ ended' = TRUE

\* Planted defect stall_stop: "kept failing at the same point · stopped".
Giveup ==
    /\ phase' = "stopped" /\ status' = "stopped" /\ Cleared
    /\ disk' = NoRecord /\ ended' = TRUE

\* fx's repeat count starts over: the send ended some other way than an
\* unclear failure (request_recovery.zig repeatedFailure with no class, or
\* beginSend after an ending that never reached it), or a new process.
ForgetRun ==
    /\ rep' = 0 /\ repWay' = "plain" /\ repPoint' = 0
    /\ runLen' = 0 /\ runWay' = "plain" /\ runPoint' = 0

\* recovery.zig onFailed for offline, dropped, and server: noteStreak,
\* escalate, then waitAfter. Leaves need, mdeaths, compacted, closing, disk,
\* and ended alone unless the stall defect gives up.
Transient(kind) ==
    LET counted == kind # "offline"
        s2 == IF ~counted THEN streak
              ELSE IF streakKind = kind THEN Min(streak + 1, EscalateAfter)
              ELSE 1
        k2 == IF counted THEN kind ELSE streakKind
        nf == noFast \/ (kind = "server" /\ Fast /\ s2 >= EscalateAfter)
    IN IF Bug = "stall_stop" /\ counted /\ s2 >= EscalateAfter
          THEN Giveup
          ELSE /\ streak' = s2 /\ streakKind' = k2 /\ noFast' = nf
               \* Planted defect hot_retry: resend at once, without waiting.
               /\ IF Bug = "hot_retry" THEN SendNow(FALSE, TRUE) ELSE WaitNow
               /\ UNCHANGED <<need, mdeaths, compacted, closing, own, disk,
                              ended>>

\* recovery.zig onFailed too_long: compact once and send at once, then ask.
\* The compacted request fits; another TooLongFault makes it too long again.
TooLongStep ==
    IF compacted
       THEN /\ AskUser("user")
            /\ UNCHANGED <<attempt, mdeaths, noFast, compacted, streak,
                           streakKind, closing, tooLong>>
       ELSE /\ compacted' = TRUE /\ tooLong' = FALSE
            \* Planted defect compact_waits: the compacted request waits a backoff.
            /\ IF Bug = "compact_waits" THEN WaitNow ELSE SendNow(TRUE, TRUE)
            /\ UNCHANGED <<need, mdeaths, noFast, streak, streakKind, closing>>

-----------------------------------------------------------------------------
(* fx carrying out a plan.                                                 *)

\* The save becomes durable: write, fsync, rename. Once the crash-loop
\* question is saved, fx has asked, and the rules' death count starts over
\* (Resume.tla Sync does the same). A question that was planned but never
\* saved has not been asked.
Sync ==
    /\ alive /\ dirty
    /\ disk' = Rec /\ dirty' = FALSE
    /\ own' = (Rec.ph = "sending" /\ ~Rec.clean)
    /\ deaths' = IF Rec.ph = "need_user" /\ Rec.need = "crash_loop"
                    THEN 0 ELSE deaths
    /\ UNCHANGED <<modVars, inflight, pendingSend, late, runVars, worldVars,
                   ended, cancelled, lastDeath, justified>>

\* The send goes on the wire, after its save is durable.
\* Planted defect send_before_sync: the send goes out before the fsync.
SendOut ==
    /\ alive /\ pendingSend /\ (~dirty \/ Bug = "send_before_sync")
    /\ inflight' = TRUE /\ pendingSend' = FALSE
    /\ UNCHANGED <<modVars, dirty, late, own, runVars, disk, worldVars,
                   ghostVars>>

-----------------------------------------------------------------------------
(* The request on the wire. Answers follow from conditions already counted *)
(* as faults; the guards are exclusive and checked in this order.          *)

\* `responding`: the first byte arrived, so any retry status clears.
Responding ==
    /\ Live /\ phase = "working" /\ inflight /\ ~flowing
    /\ flowing' = TRUE
    /\ status' = IF Bug = "frozen_status" THEN status ELSE "clear"
    /\ UNCHANGED <<phase, need, attempt, mdeaths, noFast, compacted, streak,
                   streakKind, closing, sendCompact, fxVars, runVars, disk,
                   worldVars, ghostVars>>

RespondOffline ==
    /\ Live /\ inflight /\ net = "down"
    /\ Transient("offline") /\ ForgetRun /\ justified' = TRUE
    /\ UNCHANGED <<late, worldVars, cancelled, lastDeath, deaths>>

RespondNeedUser ==
    /\ Live /\ inflight /\ net = "up" /\ needUser
    /\ AskUser("user") /\ ForgetRun /\ justified' = TRUE
    /\ UNCHANGED <<attempt, mdeaths, noFast, compacted, streak, streakKind,
                   closing, late, own, disk, worldVars, ended, cancelled,
                   lastDeath, deaths>>

RespondTooLong ==
    /\ Live /\ inflight /\ net = "up" /\ ~needUser /\ tooLong
    /\ TooLongStep /\ ForgetRun /\ justified' = TRUE
    /\ UNCHANGED <<late, own, disk, net, gateway, needUser, unclear, faults,
                   alive, ended, cancelled, lastDeath, deaths>>

\* An unclear failure. fx counts it before the module hears it
\* (request_recovery.zig repeatedFailure): sends in a row, all sent the same
\* way, that unclear failures of any class ended at the same point. At the
\* bound it stops only when the module, hearing the same failure up to
\* escalate_after more times, would never send differently. Otherwise the
\* module hears the failure as `dropped` or `server`.
RespondUnclear ==
    /\ Live /\ inflight /\ net = "up" /\ ~needUser /\ ~tooLong
    /\ unclear # "none"
    /\ LET kind    == unclear
           point   == IF flowing THEN 1 ELSE 0
           \* Planted defect stop_on_class_change: the count runs on when
           \* the send changes, such as the first send without Fast.
           same    == /\ rep > 0 /\ repPoint = point
                      /\ (repWay = Way \/ Bug = "stop_on_class_change")
           n       == IF same THEN Min(rep + 1, RepeatStop) ELSE 1
           runSame == runLen > 0 /\ runPoint = point /\ runWay = Way
           stop    == n >= RepeatStop /\ ~ProbeDiffers(kind, Lookahead)
       IN /\ rep' = n
          /\ repWay' = IF same THEN repWay ELSE Way
          /\ repPoint' = IF same THEN repPoint ELSE point
          /\ runLen' = IF runSame THEN Min(runLen + 1, RepeatStop) ELSE 1
          /\ runWay' = Way /\ runPoint' = point
          /\ IF stop THEN FxEnd ELSE Transient(kind)
    /\ justified' = TRUE
    /\ UNCHANGED <<late, worldVars, cancelled, lastDeath, deaths>>

\* A 5xx or another classified gateway error.
RespondServer ==
    /\ Live /\ inflight /\ net = "up" /\ ~needUser /\ ~tooLong
    /\ unclear = "none" /\ gateway = "broken"
    /\ Transient("server") /\ ForgetRun /\ justified' = TRUE
    /\ UNCHANGED <<late, worldVars, cancelled, lastDeath, deaths>>

\* succeeded: status clear, finish(succeeded). A complete answer needs
\* `responding` first.
RespondOk ==
    /\ Live /\ inflight /\ flowing /\ Healthy
    /\ Finish("done_ok") /\ ForgetRun
    /\ UNCHANGED <<late, worldVars, cancelled, lastDeath, deaths, justified>>

Answer == \/ RespondOffline \/ RespondNeedUser \/ RespondTooLong
          \/ RespondUnclear \/ RespondServer \/ RespondOk

\* A fresh transient disruption kills the in-flight send.
Drop ==
    /\ Live /\ inflight /\ CanFault
    /\ faults' = faults + 1
    /\ Transient("dropped") /\ ForgetRun /\ justified' = TRUE
    /\ UNCHANGED <<late, net, gateway, needUser, unclear, tooLong, alive,
                   cancelled, lastDeath, deaths>>

\* Planted defect stale_socket: once an earlier outage has healed, a pooled
\* connection that died with it fails before the first byte, and the
\* transport reports it instead of retrying silently on a fresh connection.
\* Each dead connection fails once; the fault budget bounds how many there
\* are, so the defect cannot fail a request forever.
StaleSocket ==
    /\ Bug = "stale_socket"
    /\ Live /\ inflight /\ ~flowing /\ Healthy /\ faults > 0 /\ CanFault
    /\ faults' = faults + 1
    /\ Transient("dropped") /\ ForgetRun /\ justified' = FALSE
    /\ UNCHANGED <<late, net, gateway, needUser, unclear, tooLong, alive,
                   cancelled, lastDeath, deaths>>

\* A failure fx ends on its own, such as a gateway error code it does not
\* retry or a 429 that names a used-up quota (SPEC 10).
TerminalFail ==
    /\ Live /\ inflight /\ CanFault
    /\ faults' = faults + 1
    /\ FxEnd /\ ForgetRun
    /\ UNCHANGED <<late, net, gateway, needUser, unclear, tooLong, alive,
                   cancelled, lastDeath, deaths, justified>>

\* `tick` reaches the deadline: save, send, status retrying.
\* Planted defect send_without_save: the retry goes out without its save.
TimerFires ==
    /\ Live /\ phase = "waiting"
    /\ Bug # "no_wake"
    /\ SendNow(FALSE, Bug # "send_without_save")
    /\ UNCHANGED <<need, mdeaths, noFast, compacted, streak, streakKind,
                   closing, late, own, runVars, disk, worldVars, ghostVars>>

-----------------------------------------------------------------------------
(* The world.                                                              *)

NetDown ==
    /\ CanFault /\ net = "up"
    /\ net' = "down" /\ faults' = faults + 1
    /\ UNCHANGED <<modVars, fxVars, runVars, disk, gateway, needUser, unclear,
                   tooLong, alive, ghostVars>>

NetUp ==
    /\ net = "down"
    /\ net' = "up"
    /\ UNCHANGED <<modVars, fxVars, runVars, disk, gateway, needUser, unclear,
                   tooLong, faults, alive, ghostVars>>

GatewayBreak ==
    /\ CanFault /\ gateway = "ok"
    /\ gateway' = "broken" /\ faults' = faults + 1
    /\ UNCHANGED <<modVars, fxVars, runVars, disk, net, needUser, unclear,
                   tooLong, alive, ghostVars>>

GatewayHeal ==
    /\ gateway = "broken"
    /\ gateway' = "ok"
    /\ UNCHANGED <<modVars, fxVars, runVars, disk, net, needUser, unclear,
                   tooLong, faults, alive, ghostVars>>

UnclearBreak ==
    /\ CanFault /\ unclear = "none"
    /\ unclear' \in {"dropped", "server"} /\ faults' = faults + 1
    /\ UNCHANGED <<modVars, fxVars, runVars, disk, net, gateway, needUser,
                   tooLong, alive, ghostVars>>

UnclearHeal ==
    /\ unclear # "none"
    /\ unclear' = "none"
    /\ UNCHANGED <<modVars, fxVars, runVars, disk, net, gateway, needUser,
                   tooLong, faults, alive, ghostVars>>

NeedUserFault ==
    /\ CanFault /\ ~needUser
    /\ needUser' = TRUE /\ faults' = faults + 1
    /\ UNCHANGED <<modVars, fxVars, runVars, disk, net, gateway, unclear,
                   tooLong, alive, ghostVars>>

TooLongFault ==
    /\ CanFault /\ ~tooLong
    /\ tooLong' = TRUE /\ faults' = faults + 1
    /\ UNCHANGED <<modVars, fxVars, runVars, disk, net, gateway, needUser,
                   unclear, alive, ghostVars>>

-----------------------------------------------------------------------------
(* Process death and relaunch. The record on disk survives; the module's   *)
(* state, the send, an unsynced write, and the screen do not.              *)

\* What a death leaves in memory: nothing. The phase is kept "working" so
\* that dead states differ only in what a launch can read.
Dead ==
    /\ phase' = "working" /\ status' = "none" /\ Cleared /\ late' = FALSE
    /\ ForgetRun /\ justified' = FALSE

\* SIGKILL, a crash, or power loss: no event reaches the module. A write
\* that was not durable yet may survive, vanish, or tear. A death after a
\* send's save is durable is an in-flight death, whether or not the send
\* reached the wire, and so is a SIGKILL during a close's save that leaves
\* the send's record.
Crash ==
    /\ alive /\ phase \in Active /\ faults < MaxFaults
    /\ faults' = faults + 1 /\ alive' = FALSE
    /\ \E d \in IF dirty THEN {disk, Rec, TornRecord} ELSE {disk}:
           /\ disk' = d
           /\ lastDeath' =
                  CASE SendCommitted /\ ~closing /\ d # Newest -> "lost"
                    [] InFlightDeath(d)                       -> "inflight"
                    [] closing                                -> "closing"
                    [] OTHER                                  -> "other"
    /\ Dead
    /\ UNCHANGED <<net, gateway, needUser, unclear, tooLong, ended, cancelled,
                   deaths>>

\* A close: SIGHUP, SIGTERM, or EOF on the terminal. fx delivers `closing`
\* and saves the plan marked clean, and the request resumes on the next
\* launch without a question. Only a close resumes: /quit and Ctrl+C twice
\* are UserCancels. (`fx ask` cancels on a signal instead; the model follows
\* the TUI and ACP.)
Closing ==
    /\ alive /\ Idle /\ ~closing /\ phase \in Active /\ faults < MaxFaults
    /\ faults' = faults + 1
    /\ closing' = TRUE /\ dirty' = TRUE
    /\ UNCHANGED <<phase, need, attempt, mdeaths, noFast, compacted, streak,
                   streakKind, flowing, sendCompact, status, inflight,
                   pendingSend, late, own, runVars, disk, net, gateway,
                   needUser, unclear, tooLong, alive, ghostVars>>

\* Once the closing save is durable, fx exits.
ExitClean ==
    /\ alive /\ closing /\ ~dirty
    /\ alive' = FALSE /\ lastDeath' = "clean"
    /\ Dead
    /\ UNCHANGED <<disk, net, gateway, needUser, unclear, tooLong, faults,
                   ended, cancelled, deaths>>

\* After the request ended, fx exits any way at all.
ExitAfterEnd ==
    /\ alive /\ phase \in Terminal
    /\ alive' = FALSE /\ status' = "none" /\ late' = FALSE
    /\ lastDeath' = "ended"
    /\ UNCHANGED <<phase, need, attempt, mdeaths, noFast, compacted, streak,
                   streakKind, flowing, closing, sendCompact, inflight,
                   pendingSend, dirty, own, runVars, disk, net, gateway,
                   needUser, unclear, tooLong, faults, ended, cancelled,
                   deaths, justified>>

\* start(record): recovery.zig resumeFrom. An abrupt death with a send in
\* flight counts toward the crash-loop guard, which asks once at the
\* second; a request that was waiting for the user asks again; otherwise
\* save and send at once.
Resume(r) ==
    LET abrupt == r.ph = "sending" /\ ~r.clean
        cnt    == IF abrupt THEN Min(r.deaths + 1, CrashLoopAfter) ELSE r.deaths
    IN /\ mdeaths' = cnt /\ noFast' = r.noFast /\ compacted' = r.compacted
       /\ streak' = r.streak /\ streakKind' = r.streakKind /\ closing' = FALSE
       /\ attempt' = 2
       /\ IF cnt >= CrashLoopAfter /\ Bug # "never_ask"
             THEN AskUser("crash_loop")
          ELSE IF r.ph = "need_user"
             THEN AskUser(r.need)
          ELSE SendNow(FALSE, TRUE) /\ need' = "none"

\* A torn record beside an in-flight request: start fresh, but count one
\* abrupt death so the crash-loop guard keeps counting, and resume.
TornStart ==
    /\ mdeaths' = 1 /\ noFast' = FALSE /\ compacted' = FALSE /\ streak' = 0
    /\ streakKind' = "none" /\ closing' = FALSE /\ need' = "none"
    /\ SendNow(FALSE, TRUE)

\* start(null): a new request.
FreshStart ==
    /\ phase' = "working" /\ attempt' = 1 /\ status' = "clear"
    /\ flowing' = FALSE /\ need' = "none" /\ mdeaths' = 0 /\ noFast' = FALSE
    /\ compacted' = FALSE /\ streak' = 0 /\ streakKind' = "none"
    /\ closing' = FALSE /\ sendCompact' = FALSE
    /\ inflight' = FALSE /\ pendingSend' = TRUE /\ dirty' = TRUE

\* fx is opened again and reads the record. No record and no ended request
\* means the request died before its first save was durable: a new start.
\* Planted defect torn_resets: a torn record starts fresh, as recovery.zig's
\* decode failure does today.
Relaunch ==
    /\ ~alive /\ (~ended \/ disk.ph # "none")
    /\ alive' = TRUE
    /\ CASE disk.ph \in {"sending", "waiting", "need_user"} -> Resume(disk)
         [] disk.ph = "torn" /\ Bug # "torn_resets"         -> TornStart
         [] OTHER                                           -> FreshStart
    \* The deaths this launch can see. A torn record shows exactly one and
    \* hides any before it, as in Resume.tla LaunchCount.
    /\ deaths' = CASE disk.ph = "torn"                       -> 1
                   [] lastDeath = "inflight" /\ Visible(disk) ->
                          Min(deaths + 1, CrashLoopAfter)
                   [] OTHER                                  -> deaths
    /\ lastDeath' = "none" /\ justified' = TRUE /\ late' = FALSE
    /\ own' = FALSE
    /\ ForgetRun
    /\ UNCHANGED <<disk, net, gateway, needUser, unclear, tooLong, faults,
                   ended, cancelled>>

-----------------------------------------------------------------------------
(* The user.                                                               *)

\* `user_cancel`: an explicit stop, Esc, /quit, or Ctrl+C twice. `finish`
\* deletes the record, so nothing resumes on the next launch. fx aborts the
\* send, whose outcome may still arrive.
UserCancels ==
    /\ Live /\ phase \in Active
    /\ Finish("done_cancel") /\ cancelled' = TRUE /\ late' = inflight
    /\ ForgetRun
    /\ UNCHANGED <<worldVars, lastDeath, deaths, justified>>

\* `user_continue`: Enter or a successful /login after fixing what was asked.
\* Only the crash-loop question resets the death count.
UserActs ==
    /\ Live /\ phase = "need_user"
    /\ needUser' = FALSE /\ tooLong' = FALSE
    /\ mdeaths' = IF need = "crash_loop" THEN 0 ELSE mdeaths
    /\ need' = "none"
    /\ SendNow(FALSE, TRUE)
    /\ UNCHANGED <<noFast, compacted, streak, streakKind, closing, late, own,
                   runVars, disk, net, gateway, unclear, faults, alive,
                   ghostVars>>

\* The outcome of the send an explicit stop aborted arrives after `finish`.
\* fx discards it and the module ignores it. Planted defect
\* late_outcome_counts: it reaches the module, and its retry warning reaches
\* the screen.
LateOutcome ==
    /\ alive /\ late
    /\ late' = FALSE
    /\ status' = IF Bug = "late_outcome_counts" THEN "waiting" ELSE status
    /\ UNCHANGED <<phase, need, attempt, mdeaths, noFast, compacted, streak,
                   streakKind, flowing, closing, sendCompact, inflight,
                   pendingSend, dirty, own, runVars, disk, worldVars,
                   ghostVars>>

\* A finished request stays finished.
Finished ==
    /\ phase \in Terminal
    /\ UNCHANGED vars

Next ==
    \/ Sync \/ SendOut
    \/ Responding \/ Answer \/ Drop \/ StaleSocket \/ TerminalFail
    \/ TimerFires
    \/ NetDown \/ NetUp \/ GatewayBreak \/ GatewayHeal
    \/ UnclearBreak \/ UnclearHeal \/ NeedUserFault \/ TooLongFault
    \/ Crash \/ Closing \/ ExitClean \/ ExitAfterEnd \/ Relaunch
    \/ UserCancels \/ UserActs \/ LateOutcome
    \/ Finished

\* Time passes, plans are carried out, answers arrive, the world heals, fx
\* gets relaunched, and the user eventually does what was asked. Faults,
\* deaths, closes, exits, and explicit stops are never forced.
Fairness ==
    /\ WF_vars(Sync) /\ WF_vars(SendOut) /\ WF_vars(ExitClean)
    /\ WF_vars(Responding) /\ WF_vars(Answer) /\ WF_vars(TimerFires)
    /\ WF_vars(Relaunch) /\ WF_vars(UserActs)
    /\ WF_vars(NetUp) /\ WF_vars(GatewayHeal) /\ WF_vars(UnclearHeal)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* The rules the module and fx keep together.                              *)

\* Only an explicit stop (Esc, /quit, or Ctrl+C twice) ends a request
\* without success; fx's own stops are bounded by FastBeforeStop and
\* StopOnlyWhenRepeating (recovery.zig module doc; request_recovery.zig
\* Repeating).
NeverGivesUp ==
    /\ phase # "stopped"
    /\ (phase = "done_cancel" => cancelled)

\* Once disruptions stop, every request finishes.
Heals == <>(phase \in Terminal)

\* No alarm without a cause: a status that alarms belongs to a failure the
\* world really caused, or to a relaunch. Judged for each failure, so an
\* alarm after an earlier fault has healed is caught too (recovery.zig
\* onStart).
NoFalseAlarm == (alive /\ phase \in Active /\ status \in Alarms) => justified

\* The status says what is really happening, and a retry status clears once
\* the answer flows (recovery.zig onResponding; request_recovery.zig deinit).
StatusHonest ==
    alive =>
        /\ (phase = "waiting" => status = "waiting")
        /\ (phase = "need_user" => status = "need_user")
        /\ (phase = "working" /\ inflight /\ ~flowing =>
                status = IF attempt > 1 THEN "retrying" ELSE "clear")
        /\ (phase = "working" /\ flowing => status = "clear")

\* A retry after a transient failure always waits first, and the compacted
\* request after a first too_long goes out at once: it is a new request, not
\* a resend (recovery.zig waitAfter and compactAndSend).
NoHotRetry ==
    [][ /\ (\/ RespondOffline \/ RespondServer \/ Drop \/ StaleSocket
            \/ (RespondUnclear /\ phase' # "fx_stopped")) => ~pendingSend'
        /\ (RespondTooLong /\ ~compacted) => (pendingSend' /\ sendCompact')
      ]_vars

\* Every send comes with a save, so the newest record says a send is out
\* (recovery.zig sendNow).
SaveBeforeSend == (alive /\ inflight) => Newest.ph = "sending"

\* An abrupt death while a send is out leaves the next launch the record
\* saved for that send, death count included: fx makes the save durable
\* before the send goes out. With SaveBeforeSend, the next launch sees the
\* death (request_recovery.zig does not persist saves yet).
DeathCounted == lastDeath # "lost"

\* After a close (SIGHUP, SIGTERM, or EOF on the terminal), the request
\* resumes without asking (recovery.zig resumeFrom).
ResumesAfterClose ==
    [][(Relaunch /\ lastDeath = "clean" /\ disk.ph # "need_user")
         => phase' # "need_user"]_vars

\* The one exception: the second in-flight death a launch can see, since fx
\* last asked about a crash loop, asks (recovery.zig resumeFrom,
\* crash_loop_after). fx has asked once the question is saved. A death
\* after a send's save is durable is in flight even if the send never
\* reached the wire (InFlightDeath). It must hold when a crash tears the
\* record: a torn record shows exactly one abrupt death, so the launch that
\* finds it never has to ask. DeathCounted makes every in-flight death
\* visible.
CrashLoopAsks ==
    [][(Relaunch /\ lastDeath = "inflight" /\ Visible(disk)
        /\ deaths' >= CrashLoopAfter)
         => (phase' = "need_user" /\ need' = "crash_loop")]_vars

\* A request that succeeded, was cancelled, or was stopped is never sent
\* again, in this process or after a relaunch: every end deletes the record
\* (recovery.zig Plan.finish; src/core/agent/runtime/orchestrator.zig
\* stopRepeatedFailure clears fx's own checkpoint the same way).
NoResumeAfterEnd == ended => (~inflight /\ ~pendingSend)

\* After `finish`, the status line shows the end and nothing else: a late
\* outcome of an aborted send is ignored (recovery.zig "events that don't
\* apply are ignored").
NothingAfterFinish ==
    (alive /\ phase \in Terminal) =>
        status = IF phase \in {"stopped", "fx_stopped"} THEN "stopped" ELSE "clear"

\* fx never stops a Fast request on a gateway error before the request has
\* gone out without Fast: its lookahead reaches through the module's whole
\* run to escalate_after (request_recovery.zig nextSendLocked).
FastBeforeStop ==
    [][(RespondUnclear /\ phase' = "fx_stopped")
         => ~(Fast /\ ~noFast /\ unclear = "server")]_vars

\* fx stops only after unclear failures ended repeat_stop_sends sends in a
\* row, all sent the same way with no progress between them, and only when
\* the module's next send would repeat the last one (request_recovery.zig
\* repeatedFailure).
StopOnlyWhenRepeating ==
    [][(RespondUnclear /\ phase' = "fx_stopped")
         => (runLen' >= RepeatStop /\ ~ProbeDiffers(unclear, 1))]_vars

=============================================================================

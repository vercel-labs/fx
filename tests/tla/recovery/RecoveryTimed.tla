---------------------------- MODULE RecoveryTimed ----------------------------
(***************************************************************************)
(* Recovery.tla on a discrete clock: one Tick is one second of the boot    *)
(* clock, the `tick` fx delivers once a second (request_recovery.zig       *)
(* waitForSend and the in-flight ticker). The constants are small: Ceiling *)
(* stands for the 30-second cap on every wait, SendTicks for how long an   *)
(* answer may take once a send is on the wire, and HealTicks for how soon  *)
(* a request must end once the world is healthy.                           *)
(*                                                                         *)
(* Carrying out a plan takes no time, so no tick falls between a save, its *)
(* fsync, and its send. Time while no fx process runs is not modeled: a    *)
(* relaunch resends at once, so the downtime served as the wait. Backoff   *)
(* steps and jitter are abstracted to any wait from 1 to Ceiling; their    *)
(* exact values are tested in recovery.zig.                                *)
(***************************************************************************)
EXTENDS Recovery

CONSTANTS
    Ceiling,     \* the longest wait, in ticks (recovery.zig backoff_ms cap)
    SendTicks,   \* ticks a send may stay on the wire before its answer
    HealTicks    \* ticks of a healthy world within which the request ends

ASSUME /\ Ceiling \in 1..10 /\ SendTicks \in 1..5 /\ HealTicks \in Nat

VARIABLES
    waitLeft,    \* ticks until the wait's deadline; 0 when not waiting
    fresh,       \* the status line changed since the last tick
    sendAge,     \* ticks the current send has been on the wire
    healAge      \* ticks of a healthy world with fx running and nobody asked

timeVars == <<waitLeft, fresh, sendAge, healAge>>
tvars == <<vars, timeVars>>

TTypeOK ==
    /\ TypeOK
    /\ waitLeft \in 0..(Ceiling + 1)
    /\ fresh \in BOOLEAN
    /\ sendAge \in 0..SendTicks
    /\ healAge \in 0..(HealTicks + 1)

\* A server's Retry-After longer than the ceiling.
LongHint == Ceiling + 1

\* The waits a new wait may take. Backoff and jitter give any value up to
\* the ceiling, and a 5xx or 429 Retry-After longer than the ceiling waits
\* the ceiling (recovery.zig transientDelay: "no hint waits past the
\* ceiling"). Planted defect unbounded_wait: the hint is not capped.
Waits(hinted) ==
    (1..Ceiling) \cup
        (IF hinted THEN {IF Bug = "unbounded_wait" THEN LongHint ELSE Ceiling}
                   ELSE {})

\* A new send planned in this step.
NewSend == pendingSend' /\ ~pendingSend

\* Time bookkeeping for a step of Recovery.tla, which takes no time.
\* `hinted` is TRUE for the one failure that may carry Retry-After.
Follow(A, hinted) ==
    /\ A
    /\ waitLeft' \in IF phase' = "waiting" /\ phase # "waiting" THEN Waits(hinted)
                     ELSE IF phase' = "waiting" THEN {waitLeft}
                     ELSE {0}
    /\ fresh' = (fresh \/ status' # status \/ NewSend)
    /\ sendAge' = IF inflight' /\ inflight THEN sendAge ELSE 0
    /\ healAge' = IF faults' > faults \/ ~alive' THEN 0 ELSE healAge

\* The status line must change at this tick: the countdown while waiting,
\* the elapsed time while a retry is on the wire (recovery.zig onTick).
\* Every retrying text carries that time, the resuming and compacting ones
\* included (recovery.zig retryingStatus).
MustRefresh ==
    \/ phase = "waiting"
    \/ phase = "working" /\ inflight /\ ~flowing /\ status = "retrying"

\* One second passes while fx runs the request. The answer to a send comes
\* within SendTicks.
Tick ==
    /\ Live /\ phase \in Active
    /\ (inflight => sendAge < SendTicks)
    /\ healAge' = IF Healthy /\ phase # "need_user"
                     THEN Min(healAge + 1, HealTicks + 1) ELSE 0
    /\ sendAge' = IF inflight THEN sendAge + 1 ELSE 0
    /\ IF phase = "waiting" /\ waitLeft <= 1
          \* `tick` reaches the deadline: save, send, status retrying.
          THEN /\ TimerFires
               /\ waitLeft' = 0 /\ fresh' = TRUE
          \* Planted defect frozen_countdown: the status is not redrawn.
          ELSE /\ UNCHANGED vars
               /\ waitLeft' = IF phase = "waiting" THEN waitLeft - 1 ELSE 0
               /\ fresh' = (MustRefresh /\ Bug # "frozen_countdown")

TInit ==
    /\ Init
    /\ waitLeft = 0 /\ fresh = TRUE
    /\ sendAge = 0 /\ healAge = 0

\* Every Recovery.tla step except TimerFires, which only a Tick may take.
TNext ==
    \/ Follow(Sync, FALSE) \/ Follow(SendOut, FALSE)
    \/ Follow(Responding, FALSE)
    \/ Follow(RespondOffline, FALSE) \/ Follow(RespondNeedUser, FALSE)
    \/ Follow(RespondTooLong, FALSE) \/ Follow(RespondUnclear, FALSE)
    \/ Follow(RespondServer, TRUE) \/ Follow(RespondOk, FALSE)
    \/ Follow(Drop, FALSE) \/ Follow(StaleSocket, FALSE)
    \/ Follow(TerminalFail, FALSE)
    \/ Follow(NetDown, FALSE) \/ Follow(NetUp, FALSE)
    \/ Follow(GatewayBreak, FALSE) \/ Follow(GatewayHeal, FALSE)
    \/ Follow(UnclearBreak, FALSE) \/ Follow(UnclearHeal, FALSE)
    \/ Follow(NeedUserFault, FALSE) \/ Follow(TooLongFault, FALSE)
    \/ Follow(Crash, FALSE) \/ Follow(Closing, FALSE)
    \/ Follow(ExitClean, FALSE) \/ Follow(ExitAfterEnd, FALSE)
    \/ Follow(Relaunch, FALSE)
    \/ Follow(UserCancels, FALSE) \/ Follow(UserActs, FALSE)
    \/ Follow(LateOutcome, FALSE)
    \/ Tick
    \/ Follow(Finished, FALSE)

TSpec == TInit /\ [][TNext]_tvars

-----------------------------------------------------------------------------
(* Time bounds.                                                            *)

\* No wait is longer than the 30-second ceiling, a server's Retry-After
\* included (recovery.zig transientDelay).
WaitBounded == waitLeft <= Ceiling

\* While a status is shown and nothing is flowing, it changes every tick:
\* the countdown while waiting, the elapsed time while a retry is on the
\* wire (recovery.zig onTick).
StatusFresh == (alive /\ ~flowing /\ MustRefresh) => fresh

\* Once the world is healthy, with fx running and nobody asked, the request
\* ends within HealTicks: at most one wait at the ceiling, then one send.
HealsWithin == (alive /\ phase \in Active) => healAge <= HealTicks

=============================================================================

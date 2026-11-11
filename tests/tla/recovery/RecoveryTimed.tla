---------------------------- MODULE RecoveryTimed ----------------------------
(***************************************************************************)
(* Recovery.tla on a discrete clock: one Tick is one second of the boot    *)
(* clock, the `tick` fx delivers once a second (request_recovery.zig       *)
(* waitForSend, and its ticker while a send is on the wire). The constants *)
(* are small: Ceiling stands for the 30-second cap on every wait,          *)
(* SendTicks for how long an answer may take once a send is on the wire,   *)
(* HandoffTicks for how long a resend shows its retry status before fx's   *)
(* thinking row takes the line back, HealTicks for how soon a request     *)
(* must end once the world is healthy, and PollTicks for how long a wait   *)
(* for a sign-in lasts before the module resends by itself.                *)
(*                                                                         *)
(* Carrying out a plan takes no time, so no tick falls between a save and  *)
(* its send. Time while no fx process runs is not modeled: a relaunch      *)
(* resends at once, so the downtime served as the wait. Backoff steps and  *)
(* jitter are abstracted to any wait from 1 to Ceiling; recovery.zig's own *)
(* tests pin their exact values.                                           *)
(***************************************************************************)
EXTENDS Recovery

CONSTANTS
    Ceiling,     \* the longest wait, in ticks (recovery.zig backoff_ms cap)
    SendTicks,   \* ticks a send may stay on the wire before its answer
    HandoffTicks,\* ticks a resend shows its retry status (recovery.zig handoff_ms)
    HealTicks,   \* ticks of a healthy world within which the request ends
    PollTicks    \* ticks a sign-in wait lasts before it resends (recovery.zig sign_in_poll_ms)

ASSUME /\ Ceiling \in 1..10 /\ SendTicks \in 1..5 /\ HandoffTicks \in 1..SendTicks
       /\ HealTicks \in Nat /\ PollTicks \in 1..10

VARIABLES
    waitLeft,    \* ticks until the wait's deadline; 0 when not waiting
    fresh,       \* the status line changed since the last tick
    sendAge,     \* ticks the current send has been on the wire
    healAge,     \* ticks of a healthy world with fx running and nobody asked
    signInAge,   \* ticks the current sign-in wait has lasted
    pollWaited   \* the latest timed sign-in resend came after PollTicks

timeVars == <<waitLeft, fresh, sendAge, healAge, signInAge, pollWaited>>
tvars == <<vars, timeVars>>

TTypeOK ==
    /\ TypeOK
    /\ waitLeft \in 0..(Ceiling + 1)
    /\ fresh \in BOOLEAN
    /\ sendAge \in 0..SendTicks
    /\ healAge \in 0..(HealTicks + 1)
    /\ signInAge \in 0..(PollTicks + 1)
    /\ pollWaited \in BOOLEAN

\* Nothing in the world is failing the request.
Healthy == net = "up" /\ gateway = "ok" /\ ~needUser

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

\* A send planned in this step.
NewSend == inflight' /\ ~inflight

\* The module waits for a sign-in.
SignInWait == phase = "need_user" /\ askedSignIn

\* Time bookkeeping for a step of Recovery.tla, which takes no time.
\* `hinted` is TRUE for the failure that may carry Retry-After. A sign-in
\* wait that starts, or that fx resumes after a relaunch, starts its own
\* clock (recovery.zig askUser).
Follow(A, hinted) ==
    /\ A
    /\ waitLeft' \in IF phase' = "waiting" /\ phase # "waiting" THEN Waits(hinted)
                     ELSE IF phase' = "waiting" THEN {waitLeft}
                     ELSE {0}
    \* A sign-in wait that starts shows its status again, with its new
    \* time, even when the line already asked for a sign-in.
    /\ fresh' = (fresh \/ status' # status \/ NewSend \/ (SignInWait' /\ ~SignInWait))
    /\ sendAge' = IF inflight' /\ inflight THEN sendAge ELSE 0
    /\ healAge' = IF faults' > faults \/ ~alive' THEN 0 ELSE healAge
    /\ signInAge' = IF SignInWait' /\ SignInWait /\ alive THEN signInAge ELSE 0
    /\ UNCHANGED pollWaited

\* The status line must change at this tick: the countdown while waiting,
\* and the time waited while waiting for a sign-in (recovery.zig onTick).
\* A resend's retry status holds still, and its bullet blinks like the
\* thinking row's until HandOff.
MustRefresh == phase = "waiting" \/ SignInWait

\* This tick ends a resend's retry status: it has shown for HandoffTicks
\* and nothing has flowed or failed.
HandOffDue ==
    /\ phase = "working" /\ inflight /\ ~flowing /\ status = "retrying"
    /\ sendAge + 1 >= HandoffTicks

\* One second passes while fx runs the request. The answer to a send comes
\* within SendTicks.
Tick ==
    /\ alive /\ phase \in Active
    /\ (inflight => sendAge < SendTicks)
    /\ healAge' = IF Healthy /\ phase # "need_user"
                     THEN Min(healAge + 1, HealTicks + 1) ELSE 0
    /\ sendAge' = IF inflight THEN sendAge + 1 ELSE 0
    /\ IF phase = "waiting" /\ waitLeft <= 1
          \* `tick` reaches the deadline: save, send, status retrying.
          THEN /\ TimerFires
               /\ waitLeft' = 0 /\ fresh' = TRUE
               /\ signInAge' = 0 /\ UNCHANGED pollWaited
          \* `tick` reaches the end of a sign-in wait: save, send, and keep
          \* the sign-in status. Planted defects: never_poll waits for the
          \* user forever, and poll_hot resends at the first tick.
          ELSE IF SignInWait /\ Bug # "never_poll"
                  /\ (signInAge + 1 >= PollTicks \/ Bug = "poll_hot")
          THEN /\ SignInPoll
               /\ pollWaited' = (signInAge + 1 >= PollTicks)
               /\ signInAge' = 0 /\ waitLeft' = 0 /\ fresh' = TRUE
          \* `tick` past the hand-off time: the thinking row takes the line
          \* back. Planted defect no_handoff: the retry status stays.
          ELSE IF HandOffDue /\ Bug # "no_handoff"
          THEN /\ HandOff
               /\ waitLeft' = 0 /\ fresh' = TRUE
               /\ signInAge' = 0 /\ UNCHANGED pollWaited
          \* Planted defect frozen_countdown: the countdown is not redrawn.
          ELSE /\ UNCHANGED vars
               /\ waitLeft' = IF phase = "waiting" THEN waitLeft - 1 ELSE 0
               /\ fresh' = (MustRefresh /\ Bug # "frozen_countdown")
               /\ signInAge' = IF SignInWait THEN Min(signInAge + 1, PollTicks + 1) ELSE 0
               /\ UNCHANGED pollWaited

TInit ==
    /\ Init
    /\ waitLeft = 0 /\ fresh = TRUE /\ sendAge = 0 /\ healAge = 0
    /\ signInAge = 0 /\ pollWaited = TRUE

\* Every Recovery.tla step except TimerFires and HandOff, which only a Tick
\* may take. SignInPoll is both: a Tick at the end of the wait, or at once
\* when the sign-in fx opened closes without a new login (`sign_in_closed`).
\* A broken gateway's answer is the one failure that may carry Retry-After.
TNext ==
    \/ Follow(Responding, FALSE)
    \/ Follow(Respond, net = "up" /\ ~needUser /\ gateway = "broken")
    \/ Follow(Drop, FALSE) \/ Follow(StaleSocket, FALSE)
    \/ Follow(NetDown, FALSE) \/ Follow(NetUp, FALSE)
    \/ Follow(GatewayBreak, FALSE) \/ Follow(GatewayHeal, FALSE)
    \/ Follow(NeedUserFault, FALSE) \/ Follow(TroubleClears, FALSE)
    \/ Follow(SignInPoll, FALSE)
    \/ Follow(Crash, FALSE) \/ Follow(Close, FALSE) \/ Follow(Relaunch, FALSE)
    \/ Follow(UserCancels, FALSE) \/ Follow(UserActs, FALSE)
    \/ Tick
    \/ Follow(Finished, FALSE)

TSpec == TInit /\ [][TNext]_tvars

-----------------------------------------------------------------------------
(* Time bounds.                                                            *)

\* No wait is longer than the 30-second ceiling, a server's Retry-After
\* included (recovery.zig transientDelay).
WaitBounded == waitLeft <= Ceiling

\* While fx waits to resend, the countdown changes every tick, so the row
\* never looks dead (recovery.zig onTick).
StatusFresh == (alive /\ ~flowing /\ MustRefresh) => fresh

\* A resend's retry status gives way to fx's thinking row within
\* HandoffTicks, so a model thinking in silence never sits under
\* "Connection lost" (recovery.zig handoff_ms).
HandsOff ==
    (alive /\ phase = "working" /\ inflight /\ ~flowing /\ status = "retrying")
        => sendAge < HandoffTicks

\* Once the world is healthy, with fx running and nobody asked, the request
\* ends within HealTicks: at most one wait at the ceiling, then one send.
HealsWithin == (alive /\ phase \in Active) => healAge <= HealTicks

\* A wait for a sign-in resends within PollTicks, so a request whose
\* trouble cleared by itself never waits for the user for good
\* (recovery.zig sign_in_poll_ms).
PollBounded == (alive /\ SignInWait) => signInAge < PollTicks

\* A timed sign-in resend waits the whole PollTicks first, so a login that
\* stays bad does not hammer the gateway (recovery.zig sign_in_poll_ms).
PollWaits == pollWaited

=============================================================================

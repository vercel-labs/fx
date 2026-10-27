------------------------------ MODULE Checkpoint ------------------------------
(***************************************************************************)
(* Step: the model's checkpoint and rewind on one node (D120).             *)
(*                                                                         *)
(* A node's steps are numbered as they run, and `kept` is the set its      *)
(* context holds. A checkpoint is a step of the running turn; at most one  *)
(* is open, and it closes with its turn. A rewind is a step that drops     *)
(* every kept step after the checkpoint's, keeps its own (which holds the  *)
(* report), and abandons each child first spawned in a dropped step. It    *)
(* runs only while no child of the node runs. It never changes `py`, the   *)
(* steps whose Python state the node keeps: a rewind drops context only.   *)
(* A reply while a checkpoint is open gets a hidden reminder instead of    *)
(* ending the turn, at most Cap times a turn.                              *)
(*                                                                         *)
(* x and y are the node's possible children. A person's message runs an   *)
(* idle child that is not abandoned.                                       *)
(*                                                                         *)
(* Design: system-design.md D120. Code:                                    *)
(* src/core/agent/runtime/checkpoint_rewind.zig (scan, pendingRewind,      *)
(* remind), src/tools/session/checkpoint.zig (callCheckpoint, callRewind), *)
(* src/core/session/session_adapter.zig (Session.rewindToCheckpoint) and   *)
(* src/core/session_manager/fold.zig (plan .rewound with `from`).          *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS MaxSteps, Cap

Kids == {"x", "y"}
Steps == 1..MaxSteps

VARIABLES
    turn,       \* a turn of the node runs
    steps,      \* the newest step number
    kept,       \* the steps the node's context holds
    opens,      \* the steps of the checkpoints open now
    spawnedIn,  \* [Kids -> 0..MaxSteps]: the step that first spawned it
    run,        \* [Kids -> BOOLEAN]
    abandoned,  \* [Kids -> BOOLEAN]
    py,         \* the steps whose Python state the node keeps
    reminders   \* hidden reminders spent in this turn

vars == <<turn, steps, kept, opens, spawnedIn, run, abandoned, py, reminders>>

Max(S) == CHOOSE t \in S : \A u \in S : u <= t
Idle == \A k \in Kids : ~run[k]

TypeOK ==
    /\ turn \in BOOLEAN
    /\ steps \in 0..MaxSteps
    /\ kept \subseteq Steps
    /\ opens \subseteq Steps
    /\ spawnedIn \in [Kids -> 0..MaxSteps]
    /\ run \in [Kids -> BOOLEAN]
    /\ abandoned \in [Kids -> BOOLEAN]
    /\ py \subseteq Steps
    /\ reminders \in Nat

Init ==
    /\ turn = FALSE
    /\ steps = 0
    /\ kept = {}
    /\ opens = {}
    /\ spawnedIn = [k \in Kids |-> 0]
    /\ run = [k \in Kids |-> FALSE]
    /\ abandoned = [k \in Kids |-> FALSE]
    /\ py = {}
    /\ reminders = 0

\* One more step of the running turn.
Advance ==
    /\ turn
    /\ steps < MaxSteps
    /\ steps' = steps + 1

\* One more step, kept in context.
NextStep ==
    /\ Advance
    /\ kept' = kept \cup {steps + 1}

StartTurn ==
    /\ ~turn
    /\ turn' = TRUE
    /\ reminders' = 0
    /\ UNCHANGED <<steps, kept, opens, spawnedIn, run, abandoned, py>>

\* A tool step; a cell may leave Python state behind.
Explore ==
    /\ NextStep
    /\ \E keep \in BOOLEAN : py' = IF keep THEN py \cup {steps + 1} ELSE py
    /\ UNCHANGED <<turn, opens, spawnedIn, run, abandoned, reminders>>

Checkpoint ==
    /\ NextStep
    /\ opens = {}
    /\ opens' = {steps + 1}
    /\ UNCHANGED <<turn, spawnedIn, run, abandoned, py, reminders>>

Spawn(k) ==
    /\ NextStep
    /\ spawnedIn[k] = 0
    /\ spawnedIn' = [spawnedIn EXCEPT ![k] = steps + 1]
    /\ run' = [run EXCEPT ![k] = TRUE]
    /\ UNCHANGED <<turn, opens, abandoned, py, reminders>>

KidEnd(k) ==
    /\ run[k]
    /\ run' = [run EXCEPT ![k] = FALSE]
    /\ UNCHANGED <<turn, steps, kept, opens, spawnedIn, abandoned, py, reminders>>

\* A person's message to an idle child that is not abandoned.
Message(k) ==
    /\ spawnedIn[k] # 0
    /\ ~run[k]
    /\ ~abandoned[k]
    /\ run' = [run EXCEPT ![k] = TRUE]
    /\ UNCHANGED <<turn, steps, kept, opens, spawnedIn, abandoned, py, reminders>>

\* The rewind's own step keeps the report; the steps between go.
Rewind ==
    /\ Advance
    /\ opens # {}
    /\ Idle
    /\ LET cp == Max(opens) IN
       /\ kept' = {s \in kept : s <= cp} \cup {steps + 1}
       /\ abandoned' = [k \in Kids |-> abandoned[k] \/ spawnedIn[k] > cp]
    /\ opens' = {}
    /\ UNCHANGED <<turn, spawnedIn, run, py, reminders>>

\* A reply with a checkpoint open: kept in the turn, plus a reminder.
Remind ==
    /\ NextStep
    /\ opens # {}
    /\ reminders < Cap
    /\ reminders' = reminders + 1
    /\ UNCHANGED <<turn, opens, spawnedIn, run, abandoned, py>>

\* A reply ends the turn once nothing is open or the reminders ran out;
\* an open checkpoint closes with its turn.
EndTurn ==
    /\ turn
    /\ opens = {} \/ reminders = Cap
    /\ turn' = FALSE
    /\ opens' = {}
    /\ UNCHANGED <<steps, kept, spawnedIn, run, abandoned, py, reminders>>

Next ==
    \/ StartTurn \/ Explore \/ Checkpoint \/ Rewind \/ Remind \/ EndTurn
    \/ \E k \in Kids : Spawn(k) \/ KidEnd(k) \/ Message(k)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

AtMostOneOpen == Cardinality(opens) <= 1

\* A checkpoint lives inside its turn.
OpenInTurn == opens # {} => turn

\* Exactly the children first spawned in a dropped step are abandoned.
AbandonedAreLate ==
    \A k \in Kids :
        abandoned[k] <=> (spawnedIn[k] # 0 /\ spawnedIn[k] \notin kept)

AbandonedNeverRun == \A k \in Kids : abandoned[k] => ~run[k]

RemindersBounded == reminders <= Cap

(* Action properties *)

\* A step that drops steps from the context.
Drops == ~(kept \subseteq kept')

\* It drops only steps after the open checkpoint's, and keeps that one.
DropsOnlySinceCheckpoint ==
    [][Drops => /\ opens # {}
                /\ \A s \in kept \ kept' : s > Max(opens)
                /\ opens \subseteq kept']_vars

\* It runs with no child running.
NoRewindWhileBusy == [][Drops => Idle]_vars

\* Python state is never dropped by a rewind.
KeepsPython == [][py \subseteq py']_vars
=============================================================================

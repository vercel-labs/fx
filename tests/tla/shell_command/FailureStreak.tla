---------------------------- MODULE FailureStreak ----------------------------
(***************************************************************************)
(* The repeated shell failure guard of one agent turn: ShellExecution-     *)
(* FailureRetryState in src/core/agent/runtime/tool_admission.zig, driven  *)
(* once per model step by processQueuedPromptLoop in                      *)
(* src/core/agent/runtime/orchestrator.zig.                                *)
(*                                                                         *)
(* In each step the model runs some shell commands, each identified by its *)
(* exact arguments, and may write or edit a file. A command either fails   *)
(* or not, and a write either succeeds, fails, or isn't attempted. After   *)
(* the step the guard lets the model continue or ends the turn.            *)
(*                                                                         *)
(* The promise, stated over the history alone:                             *)
(*   EditedRetryContinues  a step that changed a file never ends the turn, *)
(*                         so a rerun after an edit reaches the model.     *)
(*   StopsOnlyAfterLimit   the turn ends only once some command has failed *)
(*                         Limit steps in a row with no file change.       *)
(*   BlindLoopBounded      no command fails Limit steps in a row with no   *)
(*                         file change without the turn ending right then. *)
(*                                                                         *)
(* The constants choose the design: GuardLimit is the streak the guard     *)
(* stops at, and Resets says which writes restart a streak ("ok" for a     *)
(* successful one, "any" for any attempt, "none" for never). fx before     *)
(* this model (current.cfg) used GuardLimit 2 and "none".                  *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
  Cmds,        \* distinct shell commands
  Limit,       \* the promised number of unchanged failures in a row
  GuardLimit,  \* the streak at which the guard ends the turn
  Resets,      \* "ok", "any", or "none"
  MaxSteps     \* bound on model steps per turn

Writes == {"none", "ok", "failed"}

VARIABLES
  streak,  \* [Cmds -> Nat]: consecutive unchanged failing steps per command
  hist,    \* <<[fail |-> SUBSET Cmds, write |-> Writes], ...>>
  ended    \* whether the guard ended the turn

vars == <<streak, hist, ended>>

TypeOK ==
  /\ streak \in [Cmds -> Nat]
  /\ hist \in Seq([fail : SUBSET Cmds, write : Writes])
  /\ ended \in BOOLEAN

RestartsStreak(w) ==
  CASE Resets = "ok" -> w = "ok"
    [] Resets = "any" -> w # "none"
    [] OTHER -> FALSE

Init ==
  /\ streak = [c \in Cmds |-> 0]
  /\ hist = << >>
  /\ ended = FALSE

(* One model step: the commands in `fail` failed and `write` is the step's *)
(* file change. A command that didn't fail this step, by passing or by not *)
(* running, starts over at zero.                                           *)
Step(fail, write) ==
  /\ ~ended
  /\ Len(hist) < MaxSteps
  /\ streak' = [c \in Cmds |->
       IF c \notin fail THEN 0
       ELSE IF RestartsStreak(write) THEN 1
       ELSE streak[c] + 1]
  /\ ended' = \E c \in fail : streak'[c] >= GuardLimit
  /\ hist' = Append(hist, [fail |-> fail, write |-> write])

Next == \E fail \in SUBSET Cmds, write \in Writes : Step(fail, write)

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* The promise, over hist. Run(c, i, k): command c failed in each of the    *)
(* k steps ending at step i, and none of those steps after the first        *)
(* changed a file. The first may: it is the first run after the change.     *)

Run(c, i, k) ==
  /\ k <= i
  /\ \A j \in (i - k + 1)..i : c \in hist[j].fail
  /\ \A j \in (i - k + 2)..i : hist[j].write # "ok"

EditedRetryContinues ==
  ended => hist[Len(hist)].write # "ok"

StopsOnlyAfterLimit ==
  ended => \E c \in Cmds : Run(c, Len(hist), Limit)

BlindLoopBounded ==
  \A i \in 1..Len(hist), c \in Cmds :
    Run(c, i, Limit) => (ended /\ i = Len(hist))
=============================================================================

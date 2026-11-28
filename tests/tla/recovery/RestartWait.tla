---------------------------- MODULE RestartWait ----------------------------
(***************************************************************************)
(* How the interactive app waits to restart for an upgrade (Ctrl+G) while  *)
(* turns run, and how a second Ctrl+G cancels that wait.                   *)
(*                                                                         *)
(* Resume.tla models one conversation's session log across processes.     *)
(* This model takes one process and checks its main loop against the       *)
(* workers of the agents it asks to stop: main and the other instances,    *)
(* each running its own turn on its own thread.                            *)
(*                                                                         *)
(* Ctrl+G with a turn running asks every worker to stop at its next step   *)
(* boundary (WorkerRuntime.requestYield), and a worker asked to stop holds *)
(* its queued work. A turn at its boundary reads the request (quiesce.zig),*)
(* saves its record clean and marks itself yielded (orchestrator.zig       *)
(* yieldTurn), then holds on its worker, checking the request again under  *)
(* the worker's lock (WorkerRuntime.holdForRestart). Each tick the main    *)
(* loop checks the turns (app_upgrade_runtime.zig finishWaitingRestart):   *)
(* once every turn holds or has ended, it releases the held turns          *)
(* (releaseYield), they return, and fx exits for the relaunch once none    *)
(* runs. Until the release, a second Ctrl+G cancels the restart: the       *)
(* requests clear and each held turn goes on with its send. Esc ends a     *)
(* turn wherever it is.                                                    *)
(*                                                                         *)
(* A turn on a provider that never stops between steps runs to its end     *)
(* (End), which no fairness forces: the person's ways out are Cancel and   *)
(* Esc. Subagents are not asked to stop, and the restart waits for them    *)
(* outside this model (app_agents_runtime.zig anyTurnRunning).             *)
(*                                                                         *)
(* Faults turns on the rough world: a turn ends on its own, the record     *)
(* save before the hold fails and the turn goes on, and Esc. Bug plants    *)
(* one defect; each config names the rule that must catch it.              *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Agents,     \* the agents Ctrl+G asks to stop, such as {"main", "inst"}
    Faults,     \* TRUE: turns end, saves fail, and the person presses Esc
    Bug         \* "none", or the name of one planted defect

Bugs == {"none", "stop_at_boundary", "hold_ignores_flag",
         "cancel_while_releasing", "release_early"}

ASSUME /\ Faults \in BOOLEAN
       /\ Bug \in Bugs

\* What the main loop does about the restart. "waiting" can be cancelled;
\* "releasing" has let the held turns return.
Waits == {"none", "waiting", "releasing", "exited"}

\* What each agent's turn is doing. "check" has read the stop request at a
\* boundary and saves before it holds; "stopped" returned for the restart.
Sts == {"idle", "run", "check", "held", "stopped"}

VARIABLES
    wait,       \* the restart, as the main loop sees it
    st,         \* each agent's turn
    asked,      \* each worker's stop request (yield_requested)
    released    \* each worker's release (yield_released)

vars == <<wait, st, asked, released>>

TypeOK ==
    /\ wait \in Waits
    /\ st \in [Agents -> Sts]
    /\ asked \in [Agents -> BOOLEAN]
    /\ released \in [Agents -> BOOLEAN]

None == [a \in Agents |-> FALSE]
All  == [a \in Agents |-> TRUE]

Init ==
    /\ wait = "none"
    /\ st = [a \in Agents |-> "idle"]
    /\ asked = None
    /\ released = None

-----------------------------------------------------------------------------
(* The agents' workers.                                                    *)

\* A prompt or queued work starts a turn. A worker asked to stop holds it.
Start(a) ==
    /\ wait # "exited" /\ st[a] = "idle" /\ ~asked[a]
    /\ st' = [st EXCEPT ![a] = "run"]
    /\ UNCHANGED <<wait, asked, released>>

\* The turn ends on its own: its answer, or a provider that never stops
\* between steps.
End(a) ==
    /\ Faults /\ st[a] = "run"
    /\ st' = [st EXCEPT ![a] = "idle"]
    /\ UNCHANGED <<wait, asked, released>>

\* The turn reaches its save before a model request and reads the stop
\* request there. Planted defect stop_at_boundary, fx before the cancel:
\* the turn stops for good at once.
Boundary(a) ==
    /\ st[a] = "run" /\ asked[a]
    /\ st' = [st EXCEPT ![a] = IF Bug = "stop_at_boundary" THEN "stopped" ELSE "check"]
    /\ UNCHANGED <<wait, asked, released>>

\* The clean record and the marker are saved, and the turn holds, unless a
\* cancel cleared the request after the read: then it goes on. Planted
\* defect hold_ignores_flag: it holds without checking again.
Hold(a) ==
    /\ st[a] = "check"
    /\ st' = [st EXCEPT ![a] = IF asked[a] \/ Bug = "hold_ignores_flag" THEN "held" ELSE "run"]
    /\ UNCHANGED <<wait, asked, released>>

\* The clean record does not land: the turn goes on, and its next boundary
\* asks again (request_recovery.zig closeForYield).
SaveFails(a) ==
    /\ Faults /\ st[a] = "check"
    /\ st' = [st EXCEPT ![a] = "run"]
    /\ UNCHANGED <<wait, asked, released>>

\* A released turn returns from its hold: it stops for the restart.
Return(a) ==
    /\ st[a] = "held" /\ released[a]
    /\ st' = [st EXCEPT ![a] = "stopped"]
    /\ UNCHANGED <<wait, asked, released>>

\* Esc twice, or /quit: the turn ends cancelled, wherever it is.
Esc(a) ==
    /\ Faults /\ st[a] \in {"run", "check", "held"}
    /\ st' = [st EXCEPT ![a] = "idle"]
    /\ UNCHANGED <<wait, asked, released>>

-----------------------------------------------------------------------------
(* The main loop.                                                          *)

\* Ctrl+G with a turn running: every worker is asked to stop.
CtrlG ==
    /\ wait = "none" /\ \E a \in Agents : st[a] = "run"
    /\ wait' = "waiting"
    /\ asked' = All
    /\ UNCHANGED <<st, released>>

\* A tick once every turn holds or has ended: the held turns are released.
\* Planted defect release_early: it releases while a turn still runs.
Release ==
    /\ wait = "waiting"
    /\ \A a \in Agents : st[a] \in {"idle", "held"} \/ Bug = "release_early"
    /\ wait' = "releasing"
    /\ released' = All
    /\ UNCHANGED <<st, asked>>

\* A tick once no turn runs: fx exits for the relaunch.
Exit ==
    /\ wait = "releasing"
    /\ \A a \in Agents : st[a] \in {"idle", "stopped"}
    /\ wait' = "exited"
    /\ UNCHANGED <<st, asked, released>>

\* A second Ctrl+G while the restart waits cancels it: the requests clear
\* and each held turn goes on. Planted defect cancel_while_releasing: it
\* also cancels after the release, when a turn may have stopped.
Cancel ==
    /\ \/ wait = "waiting"
       \/ Bug = "cancel_while_releasing" /\ wait = "releasing"
    /\ wait' = "none"
    /\ asked' = None
    /\ released' = None
    /\ st' = [a \in Agents |-> IF st[a] = "held" THEN "run" ELSE st[a]]

\* fx has exited.
Done ==
    /\ wait = "exited"
    /\ UNCHANGED vars

Next ==
    \/ \E a \in Agents :
          \/ Start(a) \/ End(a) \/ Boundary(a) \/ Hold(a) \/ SaveFails(a)
          \/ Return(a) \/ Esc(a)
    \/ CtrlG \/ Release \/ Exit \/ Cancel \/ Done

\* fx's own steps happen; the person's (Start, Esc, CtrlG, Cancel) and a
\* turn's own end may not.
Fairness ==
    /\ \A a \in Agents : WF_vars(Boundary(a)) /\ SF_vars(Hold(a)) /\ WF_vars(Return(a))
    /\ WF_vars(Release) /\ WF_vars(Exit)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Rules.                                                                  *)

\* No turn stops for good while the restart can still be cancelled.
NoStopWhileCancellable ==
    \A a \in Agents : st[a] = "stopped" => wait \in {"releasing", "exited"}

\* A turn holds only while a restart waits or is released: a cancel lets
\* it go on.
HeldOnlyWhileRestartWaits ==
    \A a \in Agents : st[a] = "held" => wait \in {"waiting", "releasing"}

\* Once the release starts, the person cannot cancel, so nothing may still
\* run: what is left is only the held turns' return.
NoUncancellableWait ==
    wait = "releasing" => \A a \in Agents : st[a] \in {"idle", "held", "stopped"}

\* fx exits only when every turn has stopped or ended.
ExitOnlyWhenStopped ==
    wait = "exited" => \A a \in Agents : st[a] \in {"idle", "stopped"}

\* A waiting restart ends: fx restarts, or the person cancels it.
WaitEnds == (wait = "waiting") ~> (wait \in {"none", "exited"})

=============================================================================

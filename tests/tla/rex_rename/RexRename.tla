----------------------------- MODULE RexRename -----------------------------
(***************************************************************************)
(* The Rex session rename queue (src/core/rex_rename/queue.zig, used by    *)
(* src/core/rex_rename/renamer.zig). The main thread asks for titles; one  *)
(* background task applies them by renaming the Rex session. At most one   *)
(* title waits, and a newer title replaces it. The queue's state, under    *)
(* the renamer's mutex, is the three flags of queue.zig State: waiting,    *)
(* running, and stopped. Here `waiting` holds the waiting title itself,    *)
(* 0 for none, so the rules can say which title is applied.                *)
(*                                                                         *)
(* The main thread:                                                        *)
(*   Request    copies title requested + 1 and calls queue.request under   *)
(*              the mutex. When start_task is true it goes on to start a   *)
(*              task before it does anything else (main = "start").        *)
(*   StartTask  awaits the previous task's future, then starts a new task. *)
(*   StartFails awaits the previous task, the start fails, and it calls    *)
(*              queue.startFailed under the mutex.                         *)
(*   Stop       stopForProcessExit: queue.stop under the mutex, then it    *)
(*              awaits the task (AwaitStop).                               *)
(* The task loops on queue.take under the mutex:                           *)
(*   TakeTitle  apply_title is true: it holds the waiting title.           *)
(*   Apply      it reads Rex and maybe renames the session. A stop during  *)
(*              this step cancels the rex call, so it counts as applied.   *)
(*   TakeNone   apply_title is false: the queue marks the task ended in    *)
(*              the same step, and the task returns (End).                 *)
(*                                                                         *)
(* Titles 1..N are requested in order, so a larger title is a newer one.  *)
(* Two task slots let the planted bugs show two tasks alive at once.       *)
(*                                                                         *)
(* Bug plants one defect for the mutation configs:                         *)
(*   start_without_await  starts the task without awaiting the last one    *)
(*   end_without_lock     the task finds nothing waiting, and marks itself *)
(*                        ended in a later step outside the mutex          *)
(*   apply_after_stop     take hands out the waiting title after the stop  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    N,    \* how many titles the main thread asks for
    Bug

ASSUME N \in 1..8

Tasks == 1..2
NoTask == [pc |-> "none", title |-> 0]
TaskPcs == {"none", "take", "apply", "ending", "exit"}

VARIABLES
    requested,  \* the newest title the main thread asked for, 0 before the first
    waiting,    \* the waiting title, 0 for none (State.waiting)
    running,    \* State.running: a task runs or is about to start
    stopped,    \* State.stopped
    main,       \* "idle", "start" after a request that said start_task,
                \* or "stopping" while stopForProcessExit awaits the task
    task,       \* each task slot: where it is and the title it holds
    applied,    \* the last title a task applied, 0 before the first
    failed      \* the title dropped by the last start that failed, 0 for none

vars == <<requested, waiting, running, stopped, main, task, applied, failed>>

Alive(i) == task[i].pc # "none"
NoneAlive == \A i \in Tasks : ~Alive(i)
FreeSlot == CHOOSE i \in Tasks : ~Alive(i)

\* queue.zig take: true when it hands out the waiting title.
TakeApplies == waiting # 0 /\ (~stopped \/ Bug = "apply_after_stop")

\* renamer.zig startTask awaits the previous task's future first.
StartReady ==
    IF Bug = "start_without_await"
    THEN \E i \in Tasks : ~Alive(i)
    ELSE NoneAlive

TypeOK ==
    /\ requested \in 0..N
    /\ waiting \in 0..N
    /\ running \in BOOLEAN
    /\ stopped \in BOOLEAN
    /\ main \in {"idle", "start", "stopping"}
    /\ task \in [Tasks -> [pc : TaskPcs, title : 0..N]]
    /\ applied \in 0..N
    /\ failed \in 0..N

Init ==
    /\ requested = 0 /\ waiting = 0 /\ running = FALSE /\ stopped = FALSE
    /\ main = "idle" /\ task = [i \in Tasks |-> NoTask]
    /\ applied = 0 /\ failed = 0

\* --- the main thread ---------------------------------------------------

\* queue.zig request: after the stop nothing changes. Otherwise the title
\* waits, replacing an older one, and a task starts unless one runs.
Request ==
    /\ main = "idle" /\ requested < N
    /\ requested' = requested + 1
    /\ IF stopped
       THEN UNCHANGED <<waiting, running, main>>
       ELSE /\ waiting' = requested + 1
            /\ running' = TRUE
            /\ main' = IF running THEN "idle" ELSE "start"
    /\ UNCHANGED <<stopped, task, applied, failed>>

StartTask ==
    /\ main = "start" /\ StartReady
    /\ task' = [task EXCEPT ![FreeSlot] = [pc |-> "take", title |-> 0]]
    /\ main' = "idle"
    /\ UNCHANGED <<requested, waiting, running, stopped, applied, failed>>

\* queue.zig startFailed: nothing runs and the waiting title is dropped.
StartFails ==
    /\ main = "start" /\ StartReady
    /\ waiting' = 0 /\ running' = FALSE
    /\ failed' = waiting
    /\ main' = "idle"
    /\ UNCHANGED <<requested, stopped, task, applied>>

\* queue.zig stop. A second stop, as deinit makes, changes nothing.
Stop ==
    /\ main = "idle" /\ ~stopped
    /\ stopped' = TRUE
    /\ main' = "stopping"
    /\ UNCHANGED <<requested, waiting, running, task, applied, failed>>

AwaitStop ==
    /\ main = "stopping" /\ NoneAlive
    /\ main' = "idle"
    /\ UNCHANGED <<requested, waiting, running, stopped, task, applied, failed>>

\* --- the task ----------------------------------------------------------

TakeTitle(i) ==
    /\ task[i].pc = "take" /\ TakeApplies
    /\ waiting' = 0
    /\ task' = [task EXCEPT ![i] = [pc |-> "apply", title |-> waiting]]
    /\ UNCHANGED <<requested, running, stopped, main, applied, failed>>

\* queue.zig take with no title to hand out: the waiting title, if the stop
\* left one, is dropped, and the task is marked ended in the same step.
TakeNone(i) ==
    /\ task[i].pc = "take" /\ ~TakeApplies
    /\ waiting' = 0
    /\ IF Bug = "end_without_lock"
       THEN /\ task' = [task EXCEPT ![i] = [pc |-> "ending", title |-> 0]]
            /\ UNCHANGED running
       ELSE /\ task' = [task EXCEPT ![i] = [pc |-> "exit", title |-> 0]]
            /\ running' = FALSE
    /\ UNCHANGED <<requested, stopped, main, applied, failed>>

\* Only with end_without_lock: the task marks itself ended outside the mutex.
MarkEnded(i) ==
    /\ task[i].pc = "ending"
    /\ running' = FALSE
    /\ task' = [task EXCEPT ![i] = [pc |-> "exit", title |-> 0]]
    /\ UNCHANGED <<requested, waiting, stopped, main, applied, failed>>

Apply(i) ==
    /\ task[i].pc = "apply"
    /\ applied' = task[i].title
    /\ task' = [task EXCEPT ![i] = [pc |-> "take", title |-> 0]]
    /\ UNCHANGED <<requested, waiting, running, stopped, main, failed>>

\* The task's function returns, which completes its future.
End(i) ==
    /\ task[i].pc = "exit"
    /\ task' = [task EXCEPT ![i] = NoTask]
    /\ UNCHANGED <<requested, waiting, running, stopped, main, applied, failed>>

\* Every title was asked for, fx stopped, and the task ended.
Done ==
    /\ main = "idle" /\ requested = N /\ stopped /\ NoneAlive
    /\ UNCHANGED vars

Next ==
    \/ Request \/ StartTask \/ StartFails \/ Stop \/ AwaitStop
    \/ \E i \in Tasks : TakeTitle(i) \/ TakeNone(i) \/ MarkEnded(i) \/ Apply(i) \/ End(i)
    \/ Done

Spec == Init /\ [][Next]_vars

\* --- what must hold ---------------------------------------------------

\* Never two tasks alive: the task owns the pending title and the last
\* label it asked for without a lock.
AtMostOneTask == \A i, j \in Tasks : (Alive(i) /\ Alive(j)) => i = j

\* A waiting title always has a taker: a task that will call take again, or
\* the task the main thread is about to start. After the stop the title may
\* be dropped.
WaitingOnlyWhileRunning ==
    (waiting # 0 /\ ~stopped) =>
        /\ running
        /\ \/ main = "start"
           \/ \E i \in Tasks : task[i].pc \in {"take", "apply"}

\* The running flag is true exactly while a task will take again or is about
\* to start, so a request starts a task exactly when none will take its title.
RunningMeansTaskWillTake ==
    running <=> (main = "start" \/ \E i \in Tasks : task[i].pc \in {"take", "apply", "ending"})

\* After the stop, take never hands out a title.
NoApplyAfterStop ==
    [][\A i \in Tasks : (task[i].pc = "take" /\ task'[i].pc = "apply") => ~stopped]_vars

\* A task never applies an older title after a newer one.
AppliedOnlyIncrease == [][applied' # applied => applied' > applied]_vars

\* Nothing runs, nothing is about to start, and fx did not stop.
Quiescent == main = "idle" /\ ~stopped /\ NoneAlive

\* At quiescence the session carries the newest title, unless the start that
\* should have applied it failed.
NewestApplied == Quiescent => (applied = requested \/ failed = requested)

=============================================================================
